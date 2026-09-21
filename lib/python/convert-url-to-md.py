#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "trafilatura>=1.12",
#     "requests>=2.31",
#     "beautifulsoup4>=4.12",
#     "markdownify>=0.13",
#     "Pillow>=10.0",
# ]
# ///
"""CLI que converte artigos de qualquer URL para Markdown ou RTF.

Comportamento:
- Extrai o corpo principal da página.
- Remove links que envolvem imagens (imagens ficam só de exibição, não clicáveis).
- Links para outro site ou outra seção do mesmo site (que não compartilham o
  mesmo prefixo de caminho da URL original) têm o link removido, mas o texto
  visível é preservado.
- Links que compartilham o mesmo prefixo (deeplinks para a mesma seção) têm o
  conteúdo baixado e anexado ao final do documento (profundidade 1). Tudo
  acaba consolidado em um único arquivo.
"""

import argparse
import io
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

import requests
import trafilatura
from bs4 import BeautifulSoup
from markdownify import markdownify
from PIL import Image
from trafilatura.settings import use_config

from x_extract import fetch_x_markdown, x_status_id


FORBIDDEN_CHARS = r'[<>:"/\\|?*()\[\]{}]'

BROWSER_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9,pt-BR;q=0.8,pt;q=0.7",
    "Accept-Encoding": "gzip, deflate, br",
    "Cache-Control": "no-cache",
    "Pragma": "no-cache",
}

# [![alt](img)](url) — imagem envolvida em link
IMAGE_LINK_PATTERN = re.compile(
    r'\[(!\[[^\]]*\]\([^)]+(?:\s+"[^"]*")?\))\]\(([^)]+)\)'
)
# [text](url) — link comum. Lookbehind evita casar com ![...](...)
LINK_PATTERN = re.compile(
    r'(?<!!)\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)'
)
IMAGE_PATTERN = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING_PATTERN = re.compile(r'^(#+)(\s)', flags=re.MULTILINE)

# Texto de UI que pode vazar dos artigos Medium/Substack. Apenas linhas
# inteiras: não remover palavras como "subscribe" do conteúdo do artigo.
ARTICLE_UI_TEXT = re.compile(
    r'(?:'
    r'Press enter or click to view image in full size[.!]?'
    r'|Click (?:on (?:the )?)?image to enlarge[.!]?'
    r'|Click to (?:enlarge|expand|view full[- ]size image)[.!]?'
    r'|Get .+[’\']s stories in your inbox[.!]?'
    r'|Join Medium for free to get updates from this writer[.!]?'
    r'|Remember me for faster sign in[.!]?'
    r'|Would you like to subscribe to (?:all (?:the )?)?'
    r'(?:stories|posts) from this (?:user|writer|author)\?'
    r')',
    re.IGNORECASE,
)

# Descriptor de srcset (`123w` ou `2x`), usado como âncora para achar cada URL.
SRCSET_DESCRIPTOR_RE = re.compile(r'\s+(\d+(?:\.\d+)?)([wx])(?=\s*,|\s*$)')

# CDNs que embrulham a URL original URL-encoded dentro do path (Substack e cia).
# Ex.: https://substackcdn.com/image/fetch/w_1456,c_limit,.../https%3A%2F%2F...
CDN_UNWRAP_PATTERNS = (
    re.compile(
        r'^https?://[^/]*substackcdn\.com/image/fetch/[^/]+/(https?%3A%2F%2F\S+)$',
        re.IGNORECASE,
    ),
)


# ---------- URL utils ----------

def get_url_prefix(url: str) -> str:
    """Retorna a 'pasta' da URL: scheme + host + path prefix.

    Regras:
    - Path vazio ou "/": prefixo é a raiz do domínio.
    - Um único segmento (ex.: /learning ou /learning/): trata como seção
      própria, prefixo inclui o segmento com trailing slash (/learning/).
      Evita colapsar pro domínio inteiro, que traria links de outras seções.
    - Múltiplos segmentos (ex.: /p/artigo ou /2024/01/post): assume que o
      último é o "arquivo", prefixo é o diretório contêiner.

    Exemplos:
      https://user.substack.com/p/artigo     -> https://user.substack.com/p/
      https://cloudflare.com/learning        -> https://cloudflare.com/learning/
      https://cloudflare.com/learning/       -> https://cloudflare.com/learning/
      https://blog.example.com/2024/01/post  -> https://blog.example.com/2024/01/
      https://hpbn.co/                       -> https://hpbn.co/
    """
    parsed = urlparse(url)
    # Normaliza: tira barra do final (menos quando o path é só "/")
    path = (parsed.path or "/").rstrip("/") or "/"
    segments = [s for s in path.split("/") if s]

    if not segments:
        prefix_path = "/"
    elif len(segments) == 1:
        prefix_path = "/" + segments[0] + "/"
    else:
        prefix_path = "/" + "/".join(segments[:-1]) + "/"

    return f"{parsed.scheme}://{parsed.netloc}{prefix_path}"


def is_same_prefix(target_url: str, prefix: str) -> bool:
    try:
        parsed = urlparse(target_url)
    except Exception:
        return False
    if parsed.scheme not in ("http", "https"):
        return False
    normalized = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
    return normalized.startswith(prefix)


def normalize_url(url: str) -> str:
    """Normaliza URL para deduplicação (sem fragment, sem trailing slash)."""
    parsed = urlparse(url)
    normalized = f"{parsed.scheme}://{parsed.netloc}{parsed.path}"
    if parsed.query:
        normalized += f"?{parsed.query}"
    return normalized.rstrip("/")


# ---------- Download ----------

def download(url: str, verbose: bool = False) -> str:
    """Baixa a página tentando dois métodos e usa o que trouxer mais HTML.

    Sites com proteção anti-bot podem servir respostas diferentes dependendo
    do User-Agent e do stack HTTP. `requests` com UA de Chrome funciona bem
    pra maioria dos sites, mas alguns (Substack, por exemplo) servem uma
    resposta reduzida pra ele e uma completa pro UA do trafilatura. Tentando
    os dois e pegando o maior a gente cobre os dois casos.
    """
    def log(msg: str) -> None:
        if verbose:
            print(f"    [download] {msg}", file=sys.stderr)

    responses: list[tuple[str, str]] = []

    try:
        r = requests.get(
            url, headers=BROWSER_HEADERS, timeout=30, allow_redirects=True
        )
        r.raise_for_status()
        log(f"requests -> {len(r.text)} chars (HTTP {r.status_code}, final URL: {r.url})")
        responses.append(("requests", r.text))
    except Exception as exc:
        log(f"requests failed: {exc}")

    try:
        traf = trafilatura.fetch_url(url)
        if traf:
            log(f"trafilatura.fetch_url -> {len(traf)} chars")
            responses.append(("trafilatura", traf))
        else:
            log("trafilatura.fetch_url returned nothing")
    except Exception as exc:
        log(f"trafilatura.fetch_url failed: {exc}")

    if not responses:
        raise RuntimeError("nem requests nem trafilatura.fetch_url conseguiram baixar")

    # Escolhe a resposta com mais bytes — geralmente é a menos truncada
    # por anti-bot / paywall / verificação de assinante.
    responses.sort(key=lambda pair: len(pair[1]), reverse=True)
    chosen_name, content = responses[0]
    log(f"chose '{chosen_name}' ({len(content)} chars)")
    return content


# ---------- Filename ----------

def sanitize_filename(name: str) -> str:
    cleaned = re.sub(FORBIDDEN_CHARS, " ", name)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    cleaned = cleaned.rstrip(". ")
    return cleaned or "article"


# ---------- HTML pre-processing ----------

def pick_srcset_url(srcset: str) -> str:
    """Pega a URL de maior resolução de um srcset.

    Não podemos splitar o srcset por vírgula: URLs de CDN (Substack,
    Cloudinary, etc.) contêm várias vírgulas dentro do path como parâmetros
    (`w_1456,c_limit,f_auto,...`). Aqui usamos o próprio descriptor
    (`123w` ou `2x`) como âncora — a URL de cada entrada vai do fim do
    descriptor anterior até logo antes do próximo.
    """
    best_url = ""
    best_score = -1
    prev_end = 0
    for m in SRCSET_DESCRIPTOR_RE.finditer(srcset):
        url_slice = srcset[prev_end:m.start()].lstrip(", \t\n").strip()
        prev_end = m.end()
        if not url_slice:
            continue
        num = float(m.group(1))
        kind = m.group(2)
        # `w` (largura em px) e `x` (densidade) não são a mesma escala.
        # Pontuação bruta: 100 * densidade parece um proxy razoável.
        score = int(num * (100 if kind == "x" else 1))
        if score >= best_score:
            best_score = score
            best_url = url_slice
    if not best_url:
        # Srcset sem nenhum descriptor — pega a primeira URL "solta".
        tokens = srcset.strip().split()
        if tokens:
            best_url = tokens[0].rstrip(",")
    return best_url


def unwrap_cdn_url(url: str) -> str:
    """Se a URL é um proxy de CDN que embrulha uma URL original URL-encoded,
    desembrulha para termos a URL raw (S3, etc.). Caso contrário retorna igual.
    """
    if not url:
        return url
    for pat in CDN_UNWRAP_PATTERNS:
        m = pat.match(url)
        if m:
            return unquote(m.group(1))
    return url


def image_url(img, base_url: str) -> str:
    src = img.get("src", "").strip()
    for attr in ("srcset", "data-srcset"):
        if img.get(attr):
            picked = pick_srcset_url(img[attr])
            if picked:
                src = picked
                break
    if not src:
        for attr in ("data-src", "data-original", "data-lazy-src"):
            if img.get(attr):
                src = img[attr].strip()
                break
    if src and base_url:
        src = urljoin(base_url, src)
    return unwrap_cdn_url(src)


def normalize_images_inplace(root, base_url: str) -> None:
    for picture in root.find_all("picture"):
        chosen_url = ""
        img = picture.find("img")
        if img is not None:
            chosen_url = image_url(img, base_url)
        if not chosen_url:
            for source in picture.find_all("source"):
                picked = pick_srcset_url(source.get("srcset", ""))
                if picked:
                    chosen_url = urljoin(base_url, picked)
                    break
        if chosen_url:
            chosen_url = unwrap_cdn_url(chosen_url)
            new_img = BeautifulSoup(features="html.parser").new_tag("img", src=chosen_url)
            picture.replace_with(new_img)
        else:
            picture.decompose()

    for img in root.find_all("img"):
        src = image_url(img, base_url)
        img.attrs = {"src": src} if src else {}


def normalize_anchors_inplace(root, base_url: str) -> None:
    """Resolve todo href para URL absoluta, para o filtro de prefixo funcionar."""
    for a in root.find_all("a"):
        href = a.get("href", "").strip()
        if not href or href.startswith("#"):
            continue
        a["href"] = urljoin(base_url, href)


# Extensões e hosts que identificam uma URL como imagem.
_IMAGE_EXTENSIONS = re.compile(
    r'\.(jpe?g|png|gif|webp|avif|svg|bmp|tiff?)(\?[^)]*)?$', re.IGNORECASE
)
_IMAGE_CDN_HOSTS = re.compile(
    r'^https?://(substackcdn\.com|substack-post-media\.s3\.amazonaws\.com'
    r'|imagedelivery\.net|images\.unsplash\.com|miro\.medium\.com'
    r'|cdn-images-\d+\.medium\.com)', re.IGNORECASE
)


def _looks_like_image_url(url: str) -> bool:
    return bool(_IMAGE_EXTENSIONS.search(url) or _IMAGE_CDN_HOSTS.match(url))


def promote_image_anchors_inplace(root, base_url: str) -> None:
    """Converte <a href="IMG_URL">...</a> para <img src="IMG_URL">.

    O Substack (e outros) às vezes renderiza imagens como links de texto puro
    (sem <img> filho) quando o scraper não passa pela verificação de assinante.
    Sem essa etapa, markdownify converte esses <a> em links de texto e as
    imagens ficam quebradas no markdown.

    Critério de promoção: o href parece uma URL de imagem E o conteúdo
    interno do <a> não tem texto legível (só pode haver outra imagem dentro).
    """
    factory = BeautifulSoup(features="html.parser")
    for a in root.find_all("a"):
        href = a.get("href", "").strip()
        if not href:
            continue
        abs_href = urljoin(base_url, href)
        abs_href = unwrap_cdn_url(abs_href)
        if not _looks_like_image_url(abs_href):
            continue
        # Só promove se o texto visível for vazio ou for a própria URL
        text = a.get_text(strip=True)
        if text and text != href and text != abs_href:
            continue
        new_img = factory.new_tag("img", src=abs_href)
        a.replace_with(new_img)


def fix_bare_image_urls(md: str) -> str:
    """Converte linhas que são apenas uma URL de imagem nua em ![](url).

    Acontece quando o site emite a URL da imagem como texto corrido (não
    como <a> nem como <img>), ou quando o markdownify não consegue inferir
    que aquele link é uma imagem.

    Padrão: linha que contém *somente* uma URL http(s) que parece imagem.
    """
    def replace_line(m: re.Match) -> str:
        url = unwrap_cdn_url(m.group(1).strip())
        return f"![]({url})"

    return re.sub(
        r'^(https?://\S+)$',
        lambda m: replace_line(m) if _looks_like_image_url(m.group(1)) else m.group(0),
        md,
        flags=re.MULTILINE,
    )


def unescape_urls_in_markdown(md: str) -> str:
    """Remove escapes de caracteres especiais dentro de URLs em markdown.

    markdownify às vezes escapa `_` e outros caracteres dentro de URLs
    (ex.: `56b99880\\_2048x1190.png`), o que quebra o link. Aqui removemos
    esses escapes apenas dentro dos parênteses de destino de links e imagens.
    """
    def unescape_url(m: re.Match) -> str:
        prefix = m.group(1)    # `![alt](` ou `[text](`
        url    = m.group(2)    # a URL em si
        suffix = m.group(3)    # `)`
        url = re.sub(r'\\(.)', r'\1', url)
        return prefix + url + suffix

    return re.sub(
        r'(!?\[[^\]]*\]\()([^)]+)(\))',
        unescape_url,
        md,
    )


# ---------- HTML -> Markdown ----------

def html_to_markdown(article_html: str) -> str:
    md = markdownify(
        article_html,
        heading_style="ATX",
        bullets="-",
        strip=["script", "style", "noscript"],
        autolinks=False,  # não converter <url> — deixa tudo como [text](url)
    )
    md = re.sub(r"\n{3,}", "\n\n", md)
    md = fix_bare_image_urls(md)
    md = unescape_urls_in_markdown(md)
    return md.strip()


def _has_meaningful_text(element, min_chars: int = 200) -> bool:
    """Elemento tem texto substancial suficiente para ser considerado conteúdo?

    Alguns sites deixam wrappers semânticos vazios (`<article></article>`)
    como stub para SEO ou para injeção via JS. Ignorar esses wrappers é
    essencial para o fallback do body funcionar.
    """
    if element is None:
        return False
    return len(element.get_text(strip=True)) >= min_chars


def extract_article_html(downloaded: str, base_url: str, fallback_to_body: bool = False) -> str:
    """Extrai o container de conteúdo, tentando wrappers semânticos em ordem
    de preferência.

    Ordem: <article> → <main> → role=main → id ou class com "content|post|
    entry|article|main". Wrappers essencialmente vazios são ignorados (o
    threshold de texto está em `_has_meaningful_text`). Retorna string vazia
    se nada casar, a menos que `fallback_to_body=True`, aí usa o <body>
    inteiro como último recurso.
    """
    soup = BeautifulSoup(downloaded, "html.parser")

    # Poda universal antes de escolher o root.
    for tag in soup.find_all(["script", "style", "noscript", "iframe"]):
        tag.decompose()

    candidates = [
        soup.find("article"),
        soup.find("main"),
        soup.find(attrs={"role": "main"}),
        soup.find(id=re.compile(r'^(content|post|entry|article|main)(-\w+)?$', re.I)),
        soup.find(class_=re.compile(r'\b(post|entry|article-content|main-content|page-content|site-content)\b', re.I)),
    ]
    root = next((c for c in candidates if _has_meaningful_text(c)), None)

    used_body_fallback = False
    if root is None:
        if not fallback_to_body:
            return ""
        root = soup.find("body")
        if root is None:
            return ""
        used_body_fallback = True

    # Só remove <button> (UI noise). Antes eu removia nav/aside/header/footer
    # dentro de wrappers, mas isso corta conteúdo real em index/hub pages
    # que colocam listas de artigos dentro de <nav> ou <aside> propositalmente.
    for tag in root.find_all("button"):
        tag.decompose()

    normalize_images_inplace(root, base_url)
    promote_image_anchors_inplace(root, base_url)
    normalize_anchors_inplace(root, base_url)
    return str(root)


def clean_markdown_artifacts(md: str) -> str:
    """Remove texto de UI e colchetes órfãos, preservando imagens e código."""
    lines = []
    fence = ""
    for line in md.split("\n"):
        stripped = line.strip()
        # Exemplos de código podem conter as mesmas frases; não alterá-los.
        if fence:
            lines.append(line)
            if re.fullmatch(re.escape(fence[0]) + "{" + str(len(fence)) + r",}\s*", stripped):
                fence = ""
            continue
        opening_fence = re.match(r'^ {0,3}(`{3,}|~{3,})', line)
        if opening_fence:
            fence = opening_fence.group(1)
            lines.append(line)
            continue
        if line.startswith(("    ", "\t")):
            lines.append(line)
            continue

        # Normaliza NBSP, headings, ênfase e links só para a comparação.
        # O conteúdo original (inclusive URLs/alt das imagens) fica intacto.
        ui_text = re.sub(r'^#{1,6}\s+', '', stripped)
        ui_text = LINK_PATTERN.sub(lambda m: m.group(1), ui_text)
        ui_text = " ".join(ui_text.strip("*_ ").split())
        if ARTICLE_UI_TEXT.fullmatch(ui_text):
            continue
        if stripped in ("[", "]", "[]"):
            continue
        line = re.sub(r"\s*\[\s*$", "", line)
        lines.append(line)
    cleaned = "\n".join(lines)
    cleaned = re.sub(r"\n{3,}", "\n\n", cleaned)
    return cleaned


# ---------- Article fetch ----------

def article_header_metadata(downloaded: str, url: str, metadata) -> dict[str, str]:
    """Lê autor e idioma da página já baixada, sem outra requisição."""
    soup = BeautifulSoup(downloaded, "html.parser")

    def meta_content(selector: str) -> str:
        tag = soup.select_one(selector)
        return (tag.get("content", "") if tag else "").strip()

    # trafilatura lê JSON-LD e bylines, mas pode descartar autores de uma
    # palavra; nesse caso, tenta também o meta author original.
    author = (getattr(metadata, "author", None) or "").strip()
    author = author or meta_content('meta[name="author" i]')
    website = meta_content('meta[property="og:site_name" i]')
    website = website or (getattr(metadata, "sitename", None) or "").strip()
    website = website or (urlparse(url).hostname or "website").removeprefix("www.")

    article = soup.find("article", attrs={"lang": True})
    html = soup.find("html")
    language = (article.get("lang", "") if article else "").strip()
    language = language or (html.get("lang", "") if html else "").strip()
    language = language or meta_content('meta[property="og:locale" i]')
    language = language or meta_content('meta[http-equiv="content-language" i]')
    language = language or (getattr(metadata, "language", None) or "und")
    # og:locale costuma usar en_US; o front matter usa tags como en-US.
    language = language.split(",", 1)[0].strip().replace("_", "-") or "und"
    return {"author": author or website, "lang": language}


def normalize_language_tag(language: str) -> str:
    """Prefere inglês americano e português brasileiro quando falta a região."""
    parts = language.split(",", 1)[0].strip().replace("_", "-").split("-")
    parts[0] = parts[0].lower() or "und"
    if len(parts) == 1:
        return {"en": "en-US", "pt": "pt-BR"}.get(parts[0], parts[0])
    for i, part in enumerate(parts[1:], start=1):
        if len(part) == 2 and part.isalpha():
            parts[i] = part.upper()
        elif len(part) == 4 and part.isalpha():
            parts[i] = part.title()
    return "-".join(parts)


def infer_language(markdown: str) -> str:
    """Infere en-US/pt-BR por palavras comuns; evidência fraca retorna und."""
    # Código e URLs frequentemente contêm inglês mesmo em artigos portugueses.
    text = re.sub(
        r'^ {0,3}(`{3,}|~{3,})[^\n]*\n.*?(?:^ {0,3}\1[ \t]*$|\Z)',
        ' ', markdown, flags=re.MULTILINE | re.DOTALL,
    )
    text = re.sub(r'`[^`\n]*`', ' ', text)
    text = IMAGE_PATTERN.sub(' ', text)
    text = LINK_PATTERN.sub(lambda m: m.group(1), text)
    text = re.sub(r'https?://\S+', ' ', text)
    words = set(re.findall(r'[^\W\d_]+', unicodedata.normalize('NFC', text).casefold()))

    # Evita palavras compartilhadas/ambíguas, como "a", "as", "do" e "no".
    common_words = {
        'en-US': set((
            'the this that these those of in on at to for from with by into '
            'through between and or but if because which who what when where '
            'how you your they their them we our us he his she her it its '
            'is are was were be been have has had not will would can could should'
        ).split()),
        'pt-BR': set((
            'o os de da das dos em na nas nos para com por pelo pela pelos pelas '
            'que e ou mas porque um uma uns umas não você vocês ele ela eles elas '
            'eu nós este esta estes estas esse essa esses essas isso isto aquilo '
            'se seu sua seus suas é são foi foram ser tem têm sobre também mais '
            'muito aos às até entre quando onde como'
        ).split()),
    }
    scores = {lang: len(words & common) for lang, common in common_words.items()}
    winner, runner_up = sorted(scores, key=scores.get, reverse=True)
    # Quatro palavras distintas e vantagem de 2x evitam decidir por uma
    # palavra repetida ou por texto equilibrado entre os dois idiomas.
    if scores[winner] < 4 or scores[winner] < 2 * scores[runner_up]:
        return 'und'
    return winner


def markdown_front_matter(title: str, metadata: dict[str, str]) -> str:
    """Serializa strings como YAML seguro, inclusive títulos com ':' ou aspas."""
    fields = {
        "title": title,
        "author": metadata["author"],
        "lang": normalize_language_tag(metadata["lang"]),
    }
    # Strings JSON também são strings YAML; não precisamos de outra dependência.
    return "---\n" + "".join(
        f"{key}: {json.dumps(value)}\n" for key, value in fields.items()
    ) + "---\n"


def fetch_article(
    url: str, verbose: bool = False, *, metadata_out: dict[str, str] | None = None,
) -> tuple[str, str]:
    """Baixa um artigo. Retorna (title, markdown_body).

    Tenta 3 estratégias, em ordem: wrapper semântico → trafilatura → body
    inteiro. Um output com menos de `MIN_EXTRACT_CHARS` caracteres é
    considerado insuficiente e faz cair pro próximo passo.
    """
    MIN_EXTRACT_CHARS = 100

    def log(msg: str) -> None:
        if verbose:
            print(f"    [extract] {msg}", file=sys.stderr)

    # x.com nao serve HTML: a pagina e um app React que monta o conteudo
    # no cliente. Nenhuma das tres estrategias abaixo tem o que extrair,
    # entao esse caso vai por um caminho proprio, baseado em JSON.
    if x_status_id(url):
        log("URL do X -> extrator dedicado")
        return fetch_x_markdown(url, verbose=verbose, metadata_out=metadata_out)

    config = use_config()

    try:
        downloaded = download(url, verbose=verbose)
    except Exception as exc:
        raise RuntimeError(f"Falha ao baixar {url}: {exc}")

    log(f"downloaded {len(downloaded)} chars of HTML")

    metadata = trafilatura.extract_metadata(downloaded)
    title = (metadata.title if metadata and metadata.title else "").strip()
    if metadata_out is not None:
        metadata_out.update(article_header_metadata(downloaded, url, metadata))

    # Roda as três estratégias e escolhe a MAIOR que passe do threshold.
    # Faz sentido porque cada uma pode falhar de um jeito diferente: o
    # wrapper semântico às vezes só pega o hero, o trafilatura descarta
    # index pages, e o body inteiro às vezes traz chrome demais. A mais
    # extensa tende a ser a mais completa quando todas passam da barra.
    strategies: list[tuple[str, str]] = []

    article_html = extract_article_html(downloaded, url)
    if article_html:
        cand = html_to_markdown(article_html)
        log(f"semantic wrapper -> {len(cand)} chars of markdown")
        strategies.append(("semantic", cand))

    cand = trafilatura.extract(
        downloaded,
        output_format="markdown",
        include_links=True,
        include_images=True,
        include_formatting=True,
        include_tables=True,
        favor_precision=False,
        config=config,
    ) or ""
    log(f"trafilatura -> {len(cand)} chars of markdown")
    strategies.append(("trafilatura", cand))

    article_html = extract_article_html(downloaded, url, fallback_to_body=True)
    if article_html:
        cand = html_to_markdown(article_html)
        log(f"body fallback -> {len(cand)} chars of markdown")
        strategies.append(("body", cand))

    valid = [(name, md) for name, md in strategies if len(md) >= MIN_EXTRACT_CHARS]
    if valid:
        # Prefere a estratégia com maior output. Se der empate, mantém a ordem
        # em que foram inseridas (Python sort é estável).
        valid.sort(key=lambda t: len(t[1]), reverse=True)
        chosen_name, markdown = valid[0]
        log(f"chose '{chosen_name}' ({len(markdown)} chars)")
    else:
        markdown = ""

    if not markdown:
        raise RuntimeError(
            f"Não consegui extrair conteúdo suficiente de: {url} "
            f"(rode com --verbose para ver os passos)"
        )

    markdown = clean_markdown_artifacts(markdown)

    if not title:
        first_line = markdown.lstrip().split("\n", 1)[0]
        title = re.sub(r"^#+\s*", "", first_line).strip() or "article"

    return title, markdown


# ---------- Link processing ----------

def strip_image_hyperlinks(md: str) -> str:
    """Converte [![alt](img)](url) para apenas ![alt](img)."""
    return IMAGE_LINK_PATTERN.sub(lambda m: m.group(1), md)


def process_links(
    md: str,
    source_url: str,
    prefix: str,
    collect_deeplinks: bool,
) -> tuple[str, list[str]]:
    """Reescreve links do markdown:
    - Same-prefix: preserva só o texto visível; opcionalmente coleta a URL
      para ser buscada depois.
    - Qualquer outro link: preserva só o texto visível (link removido).
    """
    deeplinks: list[str] = []
    seen: set[str] = set()
    source_norm = normalize_url(source_url)

    def replace(match: re.Match) -> str:
        text = match.group(1)
        url = match.group(2)
        if (
            collect_deeplinks
            and url.startswith(("http://", "https://"))
            and is_same_prefix(url, prefix)
        ):
            norm = normalize_url(url)
            if norm != source_norm and norm not in seen:
                seen.add(norm)
                deeplinks.append(url)
        return text

    processed = LINK_PATTERN.sub(replace, md)
    return processed, deeplinks


def demote_headings(md: str, by: int = 1) -> str:
    """Aumenta o nível de cada heading ATX (capped em ######)."""
    def bump(m: re.Match) -> str:
        hashes = m.group(1)
        new_len = min(len(hashes) + by, 6)
        return "#" * new_len + m.group(2)
    return HEADING_PATTERN.sub(bump, md)


# ---------- Consolidation ----------

def fetch_consolidated(
    url: str, follow_deeplinks: bool, verbose: bool = False, *,
    metadata_out: dict[str, str] | None = None,
) -> tuple[str, str]:
    """Baixa o artigo principal e, opcionalmente, consolida deeplinks same-prefix."""
    prefix = get_url_prefix(url)
    visited: set[str] = {normalize_url(url)}

    print(f"Baixando: {url}", file=sys.stderr)
    main_title, main_raw = fetch_article(url, verbose=verbose, metadata_out=metadata_out)
    if metadata_out is not None and normalize_language_tag(metadata_out.get("lang", "")) == "und":
        metadata_out["lang"] = infer_language(main_raw)

    # O extrator do X ja devolve markdown final, com links expandidos de
    # t.co para a URL real. Passar por process_links apagaria justamente
    # esses links, e nao existe deeplink same-prefix para consolidar.
    if x_status_id(url):
        return main_title, main_raw.strip() + "\n"

    main_raw = strip_image_hyperlinks(main_raw)
    main_body, deeplinks = process_links(
        main_raw, url, prefix, collect_deeplinks=follow_deeplinks
    )

    if not follow_deeplinks or not deeplinks:
        return main_title, main_body.strip() + "\n"

    print(f"Deeplinks encontrados sob {prefix}: {len(deeplinks)}", file=sys.stderr)

    appended: list[str] = []
    for dl_url in deeplinks:
        norm = normalize_url(dl_url)
        if norm in visited:
            continue
        visited.add(norm)
        try:
            print(f"  → deeplink: {dl_url}", file=sys.stderr)
            dl_title, dl_raw = fetch_article(dl_url, verbose=verbose)
            dl_raw = strip_image_hyperlinks(dl_raw)
            # Sem recursão: no corpo do deeplink todos os links viram texto.
            dl_body, _ = process_links(dl_raw, dl_url, prefix, collect_deeplinks=False)
            if len(dl_body.strip()) < 50:
                print("    ! ignorado (conteúdo vazio)", file=sys.stderr)
                continue
            dl_body = demote_headings(dl_body, by=1)
            appended.append(f"\n\n---\n\n## {dl_title}\n\n{dl_body.strip()}")
        except Exception as exc:
            print(f"    ! falhou: {exc}", file=sys.stderr)

    return main_title, main_body.strip() + "".join(appended) + "\n"


# ---------- RTF rendering ----------

def localize_images(markdown: str, images_dir: Path) -> str:
    images_dir.mkdir(parents=True, exist_ok=True)
    cache: dict[str, str] = {}
    counter = {"n": 0}

    def fetch_one(url: str) -> str:
        if url in cache:
            return cache[url]
        try:
            resp = requests.get(url, headers=BROWSER_HEADERS, timeout=30)
            resp.raise_for_status()
        except Exception as exc:
            print(f"  ! skip image (download failed): {url} ({exc})", file=sys.stderr)
            cache[url] = ""
            return ""

        try:
            img = Image.open(io.BytesIO(resp.content))
            if img.mode in ("RGBA", "LA", "P"):
                img = img.convert("RGBA")
            else:
                img = img.convert("RGB")
        except Exception as exc:
            print(f"  ! skip image (decode failed): {url} ({exc})", file=sys.stderr)
            cache[url] = ""
            return ""

        counter["n"] += 1
        local_path = images_dir / f"img_{counter['n']:03d}.png"
        img.save(local_path, format="PNG")
        cache[url] = str(local_path)
        return cache[url]

    def replace(match: re.Match) -> str:
        alt = match.group(1)
        url = match.group(2)
        if not url.startswith(("http://", "https://")):
            return match.group(0)
        local = fetch_one(url)
        if not local:
            return f"![{alt}]()"
        return f"![{alt}]({local})"

    return IMAGE_PATTERN.sub(replace, markdown)


def render_rtf(markdown_text: str, output_path: Path) -> None:
    if shutil.which("pandoc") is None:
        raise RuntimeError("pandoc não está instalado (necessário para RTF). Instale via: brew install pandoc")

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        images_dir = tmp_dir / "images"
        localized = localize_images(markdown_text, images_dir)

        md_path = tmp_dir / "input.md"
        md_path.write_text(localized, encoding="utf-8")

        result = subprocess.run(
            ["pandoc", str(md_path), "-f", "markdown", "-t", "rtf", "-s", "-o", str(output_path)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"pandoc falhou: {result.stderr.strip()}")


# ---------- Entry point ----------

def main():
    parser = argparse.ArgumentParser(
        description=(
            "Converte um artigo online para Markdown ou RTF. Deeplinks para o "
            "mesmo prefixo têm o conteúdo consolidado no mesmo arquivo; os "
            "demais links são removidos (texto preservado)."
        )
    )
    parser.add_argument("url", help="URL do artigo a converter")
    parser.add_argument(
        "-o", "--output-dir",
        default="converted",
        help="Diretório de saída (default: ./converted)",
    )
    fmt_group = parser.add_mutually_exclusive_group()
    fmt_group.add_argument("-md", dest="format", action="store_const", const="md", help="Saída em Markdown (default)")
    fmt_group.add_argument("-rtf", dest="format", action="store_const", const="rtf", help="Saída em RTF com imagens embutidas")
    parser.add_argument(
        "--no-deeplinks",
        action="store_true",
        help="Não seguir/consolidar deeplinks same-prefix",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Imprime detalhes de cada passo da extração (para diagnosticar sites problemáticos)",
    )
    parser.set_defaults(format="md")
    args = parser.parse_args()

    metadata: dict[str, str] = {}
    try:
        title, document = fetch_consolidated(
            args.url,
            follow_deeplinks=not args.no_deeplinks,
            verbose=args.verbose,
            metadata_out=metadata if args.format == "md" else None,
        )
    except Exception as exc:
        print(f"Erro: {exc}", file=sys.stderr)
        sys.exit(1)

    output_dir = Path.cwd() / args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    base_name = sanitize_filename(title)

    if args.format == "md":
        output_path = output_dir / f"{base_name}.md"
        document = markdown_front_matter(title, metadata) + document
        output_path.write_text(document, encoding="utf-8")
    else:
        output_path = output_dir / f"{base_name}.rtf"
        try:
            render_rtf(document, output_path)
        except Exception as exc:
            print(f"Erro: {exc}", file=sys.stderr)
            sys.exit(1)

    print(f"Salvo: {output_path}")


if __name__ == "__main__":
    main()
