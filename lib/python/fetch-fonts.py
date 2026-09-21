#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "requests>=2.31",
#     "beautifulsoup4>=4.12",
#     "fonttools>=4.43",
#     "brotli>=1.1",
# ]
# ///
"""CLI que baixa as fontes usadas por uma (ou mais) páginas web.

Fluxo:
1. Recebe uma ou mais URLs como argumento.
2. Baixa o HTML e descobre todos os arquivos .css referenciados
   (tags <link rel="stylesheet">, blocos <style> e @import aninhados).
3. Procura regras @font-face dentro desses CSS.
4. Resolve o caminho completo de cada arquivo de fonte (src: url(...))
   e faz o download.
5. Salva cada fonte em ~/Desktop/fonts/<família>/ (Mac e Linux Fedora).
   Uma pasta por font-family; sites com várias famílias geram várias pastas.
   Arquivos já existentes na pasta são sobrescritos.

Fontes duplicadas (mesma URL) são baixadas apenas uma vez.

Com --convert: o invólucro woff/woff2 é descomprimido e as fontes estáticas
com contornos TrueType (glyf) viram .otf (curvas cúbicas/CFF). Fontes
VARIÁVEIS (peso/largura/altura) são preservadas com seus eixos: saem como
.ttf variável (ou .otf, se já forem CFF2). As tabelas de layout (kerning,
ligaduras, etc.) são preservadas.
"""

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

import requests
from bs4 import BeautifulSoup


BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9,pt-BR;q=0.8,pt;q=0.7",
    "Accept-Encoding": "gzip, deflate, br",
}

# Extensões de fontes que reconhecemos dentro do src: url(...).
FONT_EXTENSIONS = (".woff2", ".woff", ".ttf", ".otf", ".eot", ".svg")

# Caracteres proibidos em nomes de arquivo (ao usar o nome da família).
FORBIDDEN_CHARS = r'[<>:"/\\|?*]'

# @font-face { ... }
FONT_FACE_RE = re.compile(r"@font-face\s*\{([^}]*)\}", re.IGNORECASE | re.DOTALL)
# url( ... ) dentro de uma regra src (aspas simples, duplas ou sem aspas).
URL_RE = re.compile(r"""url\(\s*(['"]?)([^'")]+)\1\s*\)""", re.IGNORECASE)
# @import "arquivo.css";  ou  @import url("arquivo.css");
IMPORT_RE = re.compile(
    r"""@import\s+(?:url\(\s*)?(['"]?)([^'")]+)\1\s*\)?""", re.IGNORECASE
)


def eprint(*args, **kwargs):
    """Log para stderr, deixando stdout limpo."""
    print(*args, file=sys.stderr, **kwargs)


def fetch(session, url):
    """Baixa uma URL e devolve (bytes, content_type) ou None em caso de erro."""
    try:
        resp = session.get(url, headers=BROWSER_HEADERS, timeout=30)
        resp.raise_for_status()
        return resp.content, resp.headers.get("Content-Type", "")
    except requests.RequestException as exc:
        eprint(f"  ! falha ao baixar {url}: {exc}")
        return None


def find_css_urls(html, base_url):
    """Extrai as URLs de CSS de uma página: <link>, @import e blocos <style>."""
    soup = BeautifulSoup(html, "html.parser")
    css_urls = []
    inline_blocks = []

    # <link rel="stylesheet" href="...">
    for link in soup.find_all("link"):
        rel = " ".join(link.get("rel", [])).lower()
        href = link.get("href")
        if href and ("stylesheet" in rel or href.lower().split("?")[0].endswith(".css")):
            css_urls.append(urljoin(base_url, href))

    # blocos <style> inline (podem conter @font-face ou @import)
    for style in soup.find_all("style"):
        if style.string:
            inline_blocks.append(style.string)

    return css_urls, inline_blocks


def _declaration(block, prop):
    """Valor de uma propriedade CSS dentro de um bloco @font-face."""
    match = re.search(rf"{prop}\s*:\s*([^;{{}}]+)", block, re.IGNORECASE)
    return match.group(1).strip() if match else ""


def _clean_family(value):
    """Normaliza o valor de font-family: sem aspas, primeira família da lista."""
    value = value.split(",")[0].strip()
    return value.strip("\"'").strip()


def extract_from_css(css_text, css_url, source_id):
    """Devolve (fontes, imports) resolvidos contra css_url.

    Cada fonte é um dict com a URL, os metadados da regra @font-face
    (family, weight, style) para batizar o arquivo, e 'face' — um id único
    da regra de origem (várias src url() de uma mesma regra são só formatos
    diferentes do mesmo arquivo).
    """
    fonts = []
    for index, block in enumerate(FONT_FACE_RE.findall(css_text)):
        family = _clean_family(_declaration(block, "font-family"))
        weight = _declaration(block, "font-weight")
        style = _declaration(block, "font-style")
        face = f"{source_id}#{index}"
        for _, raw in URL_RE.findall(block):
            raw = raw.strip()
            if raw.startswith("data:"):
                continue  # fonte embutida em base64, nada a baixar
            clean = raw.split("?")[0].split("#")[0]
            if clean.lower().endswith(FONT_EXTENSIONS):
                fonts.append({
                    "url": urljoin(css_url, raw),
                    "family": family,
                    "weight": weight,
                    "style": style,
                    "face": face,
                })

    imports = []
    for _, raw in IMPORT_RE.findall(css_text):
        raw = raw.strip()
        if raw and not raw.startswith("data:"):
            imports.append(urljoin(css_url, raw))

    return fonts, imports


def collect_fonts(session, css_urls, inline_blocks, page_url):
    """Varre CSS (seguindo @import) e devolve os registros de fontes (por URL)."""
    fonts_by_url = {}
    seen_css = set()
    # Fila de (texto_css, url_base_para_resolver). Blocos inline resolvem
    # relativos à própria página.
    queue = [(block, page_url) for block in inline_blocks]
    queue += [(None, url) for url in css_urls]

    source_id = 0  # id estável por fonte de CSS (arquivo ou bloco inline)
    while queue:
        css_text, css_url = queue.pop(0)
        source_id += 1

        if css_text is None:
            if css_url in seen_css:
                continue
            seen_css.add(css_url)
            eprint(f"  css: {css_url}")
            result = fetch(session, css_url)
            if result is None:
                continue
            css_text = result[0].decode("utf-8", errors="replace")

        fonts, imports = extract_from_css(css_text, css_url, source_id)
        for font in fonts:
            fonts_by_url.setdefault(font["url"], font)  # 1ª ocorrência vence
        for imp in imports:
            if imp not in seen_css:
                queue.append((None, imp))

    return list(fonts_by_url.values())


# Ordem de preferência ao escolher um único formato por regra (menor download
# primeiro; todos descomprimem para os mesmos contornos).
_FORMAT_PRIORITY = {
    ".woff2": 0, ".woff": 1, ".ttf": 2, ".otf": 3, ".ttc": 4, ".eot": 5, ".svg": 6,
}


def dedupe_faces(fonts):
    """Mantém um só arquivo por regra @font-face (para conversão a OTF).

    Regras diferentes (ex.: subconjuntos unicode-range) são preservadas; só
    os formatos redundantes de uma mesma regra é que são descartados.
    """
    best = {}
    for font in fonts:
        ext = Path(urlparse(font["url"]).path).suffix.lower()
        rank = _FORMAT_PRIORITY.get(ext, 99)
        current = best.get(font["face"])
        if current is None or rank < current[0]:
            best[font["face"]] = (rank, font)
    return [item[1] for item in best.values()]


# Peso numérico -> nome usual (arredondado para a centena mais próxima).
WEIGHT_NAMES = {
    100: "Thin", 200: "ExtraLight", 300: "Light", 400: "Regular",
    500: "Medium", 600: "SemiBold", 700: "Bold", 800: "ExtraBold", 900: "Black",
}


def _weight_label(weight):
    """Converte font-weight (numérico ou palavra) em rótulo legível."""
    w = weight.strip().lower()
    if not w:
        return ""
    if w == "normal":
        return "Regular"
    if w == "bold":
        return "Bold"
    if " " in w:  # intervalo, ex. "100 900" -> fonte variável
        return "Variable"
    try:
        n = int(round(float(w) / 100.0) * 100)
    except ValueError:
        return ""
    return WEIGHT_NAMES.get(n, w)


def _style_label(style):
    s = style.strip().lower()
    if s.startswith("italic"):
        return "Italic"
    if s.startswith("oblique"):
        return "Oblique"
    return ""


def font_stem_from_face(font):
    """Nome-base do arquivo a partir dos metadados @font-face, ou None.

    Ex.: family='JetBrains Mono', weight='700', style='italic'
         -> 'JetBrainsMono-BoldItalic'
    """
    family = font.get("family", "").strip()
    if not family:
        return None
    stem = re.sub(FORBIDDEN_CHARS, "", family).replace(" ", "")
    if not stem:
        return None

    weight = _weight_label(font.get("weight", ""))
    style = _style_label(font.get("style", ""))
    parts = []
    # "Regular" é implícito quando há estilo (ex.: só "Italic").
    if weight and not (weight == "Regular" and style):
        parts.append(weight)
    if style:
        parts.append(style)
    if not parts:
        parts.append("Regular")
    return f"{stem}-{''.join(parts)}"


def resolve_target(dest_dir, filename, written):
    """Caminho final para 'filename' (modo replace: sobrescreve o que já houver).

    - Ainda não escrito nesta execução -> usa o nome (sobrescreve arquivos de
      execuções anteriores).
    - Já escrito nesta execução -> colisão real (ex.: subconjuntos unicode-range
      da mesma variante) -> anexa -1, -2, ... para não perder nenhum.
    """
    target = dest_dir / filename
    if target not in written:
        return target
    stem, suffix = target.stem, target.suffix
    i = 1
    while True:
        candidate = dest_dir / f"{stem}-{i}{suffix}"
        if candidate not in written:
            return candidate
        i += 1


def target_filename(font):
    """Nome final do arquivo baixado: preferindo o nome do @font-face."""
    ext = Path(urlparse(font["url"]).path).suffix.lower() or ".woff"
    stem = font_stem_from_face(font)
    if stem:
        return stem + ext
    # Sem family na regra: cai para o nome que vier na URL.
    return unquote(Path(urlparse(font["url"]).path).name) or ("font" + ext)


# Formatos que sabemos converter para OTF (os demais são mantidos como estão).
CONVERTIBLE_EXTENSIONS = (".woff2", ".woff", ".ttf", ".ttc", ".eot")

# Assinaturas de arquivos SFNT (TrueType/OpenType e invólucros web).
_SFNT_SIGS = (
    b"\x00\x01\x00\x00", b"OTTO", b"true", b"typ1", b"ttcf", b"wOFF", b"wOF2",
)


def _is_sfnt(data):
    return len(data) >= 4 and data[:4] in _SFNT_SIGS


def _is_eot(data):
    """Detecta um arquivo EOT pelo número mágico (0x504C no offset 34)."""
    import struct
    if _is_sfnt(data) or len(data) < 36:
        return False
    return struct.unpack_from("<H", data, 34)[0] == 0x504C


def _extract_eot_sfnt(data):
    """Extrai a fonte SFNT embutida num EOT, ou None se estiver comprimida (MTX)."""
    import struct

    # A fonte ocupa os últimos FontDataSize bytes (FontDataSize no offset 4).
    font_data_size = struct.unpack_from("<I", data, 4)[0]
    if 0 < font_data_size <= len(data):
        sfnt = data[len(data) - font_data_size:]
        if _is_sfnt(sfnt):
            return sfnt
    # Fallback: procura a assinatura SFNT dentro do arquivo.
    for sig in _SFNT_SIGS:
        idx = data.find(sig)
        if idx != -1 and _is_sfnt(data[idx:]):
            return data[idx:]
    return None  # provavelmente comprimido com MicroType Express


def _font_family_name(font):
    """Nome de família (nameID 1) ou 'Font' como padrão."""
    name = font["name"]
    rec = name.getName(1, 3, 1, 0x409) or name.getName(1, 1, 0, 0)
    return str(rec) if rec else "Font"


def _ps_name(font, family):
    """Nome PostScript (nameID 6) ou derivado da família."""
    name = font["name"]
    rec = name.getName(6, 3, 1, 0x409) or name.getName(6, 1, 0, 0)
    if rec:
        return str(rec).replace(" ", "")
    return family.replace(" ", "") + "-Regular"


def _glyf_to_charstrings(font):
    """Converte cada contorno TrueType (quadrático) em charstring T2 (cúbico)."""
    from fontTools.pens.qu2cuPen import Qu2CuPen
    from fontTools.pens.recordingPen import DecomposingRecordingPen
    from fontTools.pens.t2CharStringPen import T2CharStringPen

    glyph_set = font.getGlyphSet()
    hmtx = font["hmtx"]
    charstrings = {}
    for glyph_name in font.getGlyphOrder():
        width = hmtx[glyph_name][0]
        t2_pen = T2CharStringPen(width, glyph_set)
        # Decompõe glifos compostos antes de traçar (CFF não tem componentes).
        rec = DecomposingRecordingPen(glyph_set)
        glyph_set[glyph_name].draw(rec)
        rec.replay(Qu2CuPen(t2_pen, max_err=1.0))
        charstrings[glyph_name] = t2_pen.getCharString()
    return charstrings


def _convert_glyf_to_cff(font):
    """Substitui os contornos TrueType do TTFont por uma tabela CFF (in-place)."""
    from fontTools.fontBuilder import FontBuilder

    family = _font_family_name(font)
    ps_name = _ps_name(font, family)
    charstrings = _glyf_to_charstrings(font)

    fb = FontBuilder(font["head"].unitsPerEm, isTTF=False)
    fb.setupGlyphOrder(font.getGlyphOrder())
    fb.setupCFF(
        ps_name,
        {"FullName": family, "FamilyName": family, "Weight": "Regular"},
        charstrings,
        {},
    )
    font["CFF "] = fb.font["CFF "]
    font.sfntVersion = "OTTO"
    # maxp de fontes CFF é a versão 0.5 (só contém numGlyphs).
    if "maxp" in font:
        font["maxp"].tableVersion = 0x00005000
    # Tabelas específicas de contornos TrueType não fazem sentido em OTF.
    # (Só fontes estáticas chegam aqui; as variáveis são preservadas antes.)
    obsolete = ("glyf", "loca", "cvt ", "fpgm", "prep", "gasp", "LTSH", "hdmx", "VDMX")
    for tag in obsolete:
        if tag in font:
            del font[tag]


def subfamily_label(font):
    """Rótulo de subfamília a partir dos metadados @font-face: 'Bold Italic' etc."""
    weight = _weight_label(font.get("weight", ""))
    style = _style_label(font.get("style", ""))
    parts = []
    if weight and weight not in ("Regular", "Variable"):
        parts.append(weight)
    if style:
        parts.append(style)
    return " ".join(parts) if parts else "Regular"


def _mac_safe(text):
    """True se 'text' pode ser codificado como Mac Roman (registro name plat. 1)."""
    try:
        text.encode("mac_roman")
        return True
    except UnicodeEncodeError:
        return False


def fix_name_table(font, meta):
    """Deixa a tabela 'name' utilizável pelo Font Book da Apple.

    Fontes web costumam trazer registros só na plataforma Windows (3,1); a Apple
    lê os nomes na plataforma Macintosh (1,0). Sem eles o Font Book acusa
    '<no font name>' e 'name table usability'. Aqui garantimos os nomes
    essenciais (preenchendo pelos metadados do @font-face quando faltarem) e
    espelhamos todos os registros para Windows e Macintosh.
    """
    from fontTools.ttLib import newTable

    if "name" not in font:
        tbl = newTable("name")
        tbl.names = []
        font["name"] = tbl
    name = font["name"]

    def current(nid):
        rec = (name.getName(nid, 3, 1, 0x409) or name.getName(nid, 1, 0, 0)
               or name.getName(nid, 0, 3, 0) or name.getName(nid, 0, 4, 0))
        if rec is None:
            found = [r for r in name.names if r.nameID == nid]
            rec = found[0] if found else None
        return str(rec) if rec is not None else ""

    family = (meta.get("family") or "").strip()
    sub = (meta.get("subfamily") or "Regular").strip() or "Regular"
    full = family if sub == "Regular" else f"{family} {sub}".strip()
    ps = (re.sub(r"\s+", "", family) + "-" + re.sub(r"\s+", "", sub)) if family else ""
    defaults = {1: family, 2: sub, 4: full, 6: ps}

    # Preenche IDs essenciais ausentes com base no @font-face.
    for nid, value in defaults.items():
        if value and not current(nid):
            name.setName(value, nid, 3, 1, 0x409)

    # Espelha cada registro para Windows (3,1) e Macintosh (1,0).
    for nid in sorted({r.nameID for r in name.names}):
        text = current(nid)
        if not text:
            continue
        if not name.getName(nid, 3, 1, 0x409):
            name.setName(text, nid, 3, 1, 0x409)
        if not name.getName(nid, 1, 0, 0) and _mac_safe(text):
            name.setName(text, nid, 1, 0, 0)


def convert_font_bytes(data, meta=None, label=""):
    """Converte os bytes de uma fonte. Devolve (novos_bytes, extensão) ou None.

    - Fonte VARIÁVEL (tem 'fvar') -> preserva os eixos, sem achatar:
        * contornos TrueType (glyf) -> mantém variável em .ttf;
        * contornos CFF2            -> mantém variável em .otf.
    - Fonte ESTÁTICA -> contornos TrueType viram CFF e sai em .otf.
    EOT é desembrulhado antes (a fonte SFNT embutida é extraída).
    """
    import io

    from fontTools.ttLib import TTFont

    if _is_eot(data):
        sfnt = _extract_eot_sfnt(data)
        if sfnt is None:
            eprint(f"    ! {label}: EOT comprimido (MicroType Express), "
                   "não é possível extrair a fonte")
            return None
        data = sfnt

    try:
        font = TTFont(io.BytesIO(data), fontNumber=0)
        if "fvar" in font:
            # Fonte variável: preserva peso/largura/altura variáveis.
            ext = ".otf" if ("CFF2" in font or "CFF " in font) else ".ttf"
            eprint(f"    (fonte variável: preservando os eixos, salvando como {ext})")
        elif "glyf" in font:
            _convert_glyf_to_cff(font)
            ext = ".otf"
        else:
            ext = ".otf"  # já CFF/CFF2 estática: só descomprime
        font.flavor = None  # remove o invólucro woff/woff2
        fix_name_table(font, meta or {})
        missing = [t for t in ("cmap", "head", "hhea", "hmtx", "maxp", "name",
                               "OS/2", "post") if t not in font]
        if missing:
            eprint(f"    ! {label}: tabelas ausentes {missing} (fonte de origem incompleta)")
        buf = io.BytesIO()
        font.save(buf)
        return buf.getvalue(), ext
    except Exception as exc:  # noqa: BLE001 - qualquer falha mantém o original
        eprint(f"    ! falha ao converter {label}: {exc}")
        return None


# Tamanho mínimo de prefixo para agrupar duas famílias na mesma pasta.
MIN_FAMILY_PREFIX = 3


def _is_word_boundary(text, i):
    """i marca um fim de palavra em text? (fim, espaço/-/_ ou início de maiúscula)."""
    if i >= len(text):
        return True
    ch = text[i]
    return ch in " -_" or ch.isupper()


def _common_family_prefix(a, b):
    """Maior prefixo comum de a e b que termina em fronteira de palavra em ambos.

    Ex.: 'JetBrains Sans' e 'JetBrainsMono' -> 'JetBrains'.
    """
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    # Recua até uma fronteira de palavra válida nas duas strings.
    while i > 0 and not (_is_word_boundary(a, i) and _is_word_boundary(b, i)):
        i -= 1
    return a[:i].strip(" -_")


def assign_family_folders(families):
    """Mapeia cada font-family para o nome da pasta.

    Famílias que compartilham um prefixo (a "família-mãe", ex.: 'JetBrains')
    são agrupadas na mesma pasta; famílias sem relação ficam em pastas próprias.
    """
    clusters = []  # cada item: {"prefix": str, "members": [str]}
    for family in sorted({f for f in families if f}):
        target = None
        for cluster in clusters:
            prefix = _common_family_prefix(cluster["prefix"], family)
            if len(prefix) >= MIN_FAMILY_PREFIX:
                target = (cluster, prefix)
                break
        if target:
            cluster, prefix = target
            cluster["members"].append(family)
            cluster["prefix"] = prefix
        else:
            clusters.append({"prefix": family, "members": [family]})

    folders = {}
    for cluster in clusters:
        if len(cluster["members"]) > 1:
            name = cluster["prefix"].strip(" -_") or cluster["members"][0]
        else:
            name = cluster["members"][0]  # família única: mantém o nome inteiro
        for member in cluster["members"]:
            folders[member] = name
    return folders


def font_folder(font, fallback):
    """Nome da pasta da fonte (já resolvido em 'folder'), ou 'fallback'."""
    name = re.sub(FORBIDDEN_CHARS, "", font.get("folder", "")).strip()
    return name or fallback


def download_fonts(session, fonts, base_dest, fallback, convert=False):
    """Baixa cada fonte para base_dest/<família>/. Devolve a quantidade baixada.

    Modo replace: arquivos de execuções anteriores são sobrescritos. Colisões
    dentro da mesma execução (subconjuntos unicode-range) ganham -1, -2, ...
    """
    written = set()  # caminhos escritos NESTA execução
    count = 0
    for font in sorted(fonts, key=lambda f: (font_folder(f, fallback), f["url"])):
        result = fetch(session, font["url"])
        if result is None:
            continue

        dest_dir = base_dest / font_folder(font, fallback)
        dest_dir.mkdir(parents=True, exist_ok=True)

        src_name = target_filename(font)
        stem = Path(src_name).stem
        ext = Path(src_name).suffix.lower()
        will_convert = convert and ext in CONVERTIBLE_EXTENSIONS

        data = result[0]
        out_ext = ext
        if will_convert:
            meta = {"family": font.get("family", ""), "subfamily": subfamily_label(font)}
            converted = convert_font_bytes(result[0], meta, label=stem + ".otf")
            if converted is not None:
                data, out_ext = converted  # extensão vem da conversão (.otf ou .ttf)
            # se falhar, mantém os bytes/extensão originais

        target = resolve_target(dest_dir, stem + out_ext, written)
        target.write_bytes(data)
        written.add(target)
        eprint(f"  ✓ {target.name}")
        print(target)  # stdout: caminho dos arquivos salvos
        count += 1
    return count


def process_url(session, page_url, base_dest, convert=False):
    """Processa uma página: descobre CSS, fontes e baixa tudo."""
    eprint(f"\n> {page_url}")
    result = fetch(session, page_url)
    if result is None:
        return 0

    html = result[0].decode("utf-8", errors="replace")
    css_urls, inline_blocks = find_css_urls(html, page_url)
    eprint(f"  {len(css_urls)} arquivo(s) .css e {len(inline_blocks)} bloco(s) <style>")

    fonts = collect_fonts(session, css_urls, inline_blocks, page_url)
    if not fonts:
        eprint("  nenhuma fonte @font-face encontrada")
        return 0

    eprint(f"  {len(fonts)} fonte(s) encontrada(s)")
    if convert:
        deduped = dedupe_faces(fonts)
        if len(deduped) < len(fonts):
            eprint(f"  {len(deduped)} após remover formatos redundantes (1 por regra)")
        fonts = deduped

    # Resolve a pasta de cada fonte agrupando famílias por prefixo comum.
    folder_map = assign_family_folders(f.get("family", "") for f in fonts)
    for font in fonts:
        font["folder"] = folder_map.get(font.get("family", ""), "")

    host = urlparse(page_url).netloc or "fonts"
    return download_fonts(session, fonts, base_dest, host, convert=convert)


def desktop_dir():
    """~/Desktop no Mac e no Linux Fedora; cai em ~ se não existir."""
    desktop = Path.home() / "Desktop"
    return desktop if desktop.is_dir() else Path.home()


def main():
    parser = argparse.ArgumentParser(
        description="Baixa as fontes (@font-face) usadas por páginas web."
    )
    parser.add_argument("urls", nargs="+", help="uma ou mais URLs a analisar")
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=desktop_dir() / "fonts",
        help="diretório de saída (padrão: ~/Desktop/fonts)",
    )
    parser.add_argument(
        "-c",
        "--convert",
        action="store_true",
        help="converte cada fonte baixada para .otf (descomprime woff/woff2 e "
        "converte contornos TrueType para CFF)",
    )
    args = parser.parse_args()

    session = requests.Session()
    total = 0
    for raw in args.urls:
        url = raw if "://" in raw else "https://" + raw
        total += process_url(session, url, args.output, convert=args.convert)

    eprint(f"\nConcluído: {total} fonte(s) salva(s) em {args.output}")
    return 0 if total else 1


if __name__ == "__main__":
    sys.exit(main())
