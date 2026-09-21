"""Extrator dedicado para posts, threads e Articles do X (Twitter).

Por que um módulo separado: x.com não serve HTML. A página é um app React
que monta tudo no cliente a partir de chamadas GraphQL autenticadas. Um
`requests.get` recebe um shell vazio, então trafilatura/BeautifulSoup não
têm o que extrair. A solução é pegar os dados como dados (JSON), não como
HTML.

Fonte usada: API pública v2 do FxEmbed (api.fxtwitter.com). Sem chave, sem
login, 1000 req/min por IP. É um proxy de terceiros e não oficial, então
trate como algo que pode mudar sem aviso.

Cobertura:
- post simples, com fotos, vídeos, GIF, poll, card de link
- thread (a API já devolve a thread desenrolada no campo `thread`)
- quote post (recursivo, um nível)
- X Article longo (campo `article`), que vem em formato Draft.js
  (blocks + entityMap) e é onde estavam as imagens e a formatação
  que o script antigo perdia
"""

from __future__ import annotations

import json
import re
import sys
from typing import Any, Iterable
from urllib.parse import urlparse, urlunparse, parse_qsl, urlencode

import requests


FX_API = "https://api.fxtwitter.com/2/status/{id}"

# Identifique sua aplicação: a API pede isso e pode bloquear UA genérico.
FX_HEADERS = {
    "User-Agent": "convert-url-to-md/1.0 (personal markdown archiver)",
    "Accept": "application/json",
}

X_HOSTS = re.compile(
    r"^(?:www\.|mobile\.|m\.)?"
    r"(?:x|twitter|nitter\.net|fixupx|fxtwitter|vxtwitter|twittpr)\.com$",
    re.IGNORECASE,
)

# /user/status/123, /user/statuses/123, /i/status/123, /i/web/status/123
X_STATUS_PATH = re.compile(
    r"^/(?:i/(?:web/)?status|[^/]+/status(?:es)?)/(\d{1,20})",
    re.IGNORECASE,
)


# ---------- detecção ----------

def x_status_id(url: str) -> str | None:
    """Retorna o snowflake ID se a URL é um post do X, senão None."""
    try:
        parsed = urlparse(url)
    except Exception:
        return None
    if parsed.scheme not in ("http", "https"):
        return None
    if not X_HOSTS.match(parsed.netloc or ""):
        return None
    m = X_STATUS_PATH.match(parsed.path or "")
    return m.group(1) if m else None


# ---------- utilidades ----------

def _orig(url: str) -> str:
    """Força `name=orig` em URLs de mídia do pbs.twimg.com (resolução cheia)."""
    if not url or "pbs.twimg.com" not in url:
        return url
    parsed = urlparse(url)
    params = dict(parse_qsl(parsed.query))
    if "format" in params or parsed.path.rsplit(".", 1)[-1].lower() in (
        "jpg", "jpeg", "png", "webp", "gif"
    ):
        params["name"] = "orig"
    return urlunparse(parsed._replace(query=urlencode(params)))


def _units(text: str) -> list[bytes]:
    """Quebra o texto em code units UTF-16.

    Os offsets do Draft.js e das facets do X são contados em code units
    UTF-16, não em code points. Em Python, `text[3]` conta code points, então
    qualquer emoji fora do BMP desalinha tudo depois dele. Trabalhar em pares
    de bytes UTF-16-LE resolve.
    """
    raw = text.encode("utf-16-le", "surrogatepass")
    return [raw[i:i + 2] for i in range(0, len(raw), 2)]


def _join(units: Iterable[bytes]) -> str:
    return b"".join(units).decode("utf-16-le", "replace")


def _esc(text: str) -> str:
    """Escapa só o que quebraria markdown, deixando o texto legível."""
    return re.sub(r"([\\`*_\[\]])", r"\\\1", text)


# ---------- mídia ----------

def _media_markdown(info: dict[str, Any], alt: str = "") -> str:
    """Renderiza um `media_info` de Article (ApiImage / ApiVideo / ApiGif)."""
    kind = info.get("__typename") or ""
    alt = alt or info.get("ext_alt_text") or ""

    if kind == "ApiImage" or info.get("original_img_url"):
        url = _orig(info.get("original_img_url") or info.get("media_url_https", ""))
        return f"![{alt}]({url})" if url else ""

    variants = (info.get("video_info") or {}).get("variants") or []
    mp4 = [v for v in variants if v.get("content_type") == "video/mp4"]
    best = max(mp4 or variants, key=lambda v: v.get("bitrate") or 0, default=None)
    poster = _orig(info.get("media_url_https", ""))
    if best and best.get("url"):
        label = alt or ("GIF" if kind == "ApiGif" else "vídeo")
        out = f"[{label}]({best['url']})"
        return f"![{alt}]({poster})\n\n{out}" if poster else out
    return f"![{alt}]({poster})" if poster else ""


def _status_media_markdown(media: dict[str, Any] | None) -> list[str]:
    """Renderiza o bloco `media` de um status normal (não Article)."""
    if not media:
        return []
    out: list[str] = []
    for item in media.get("all") or []:
        kind = item.get("type")
        alt = item.get("altText") or ""
        url = item.get("url") or ""
        if kind == "photo":
            out.append(f"![{alt}]({_orig(url)})")
        elif kind in ("video", "gif"):
            thumb = _orig(item.get("thumbnail_url") or "")
            label = alt or ("GIF" if kind == "gif" else "vídeo")
            if thumb:
                out.append(f"![{alt}]({thumb})\n\n[{label}]({url})")
            else:
                out.append(f"[{label}]({url})")
    external = media.get("external") or {}
    if external.get("url"):
        out.append(f"[vídeo externo]({external['url']})")
    return out


# ---------- Draft.js -> markdown (X Articles) ----------

BLOCK_PREFIX = {
    "unstyled": "",
    "paragraph": "",
    "unordered-list-item": "- ",
    "ordered-list-item": "1. ",
    "blockquote": "> ",
    "atomic": "",
}

# Headings nao usam BLOCK_PREFIX: o nivel e calculado em render_article, que
# reserva o `#` para o titulo do documento e reancora o resto (ver _heading_shift).
HEADER_LEVEL = {
    "header-one": 1,
    "header-two": 2,
    "header-three": 3,
    "header-four": 4,
    "header-five": 5,
    "header-six": 6,
}

# As chaves ficam em UPPER e a consulta normaliza: o Draft.js canonico usa
# "BOLD", mas a API do FxEmbed devolve "Bold"/"Italic" em Title Case. Comparar
# sem normalizar fazia todo negrito/italico ser descartado em silencio.
STYLE_WRAP = {
    "BOLD": ("**", "**"),
    "ITALIC": ("*", "*"),
    "CODE": ("`", "`"),
    "STRIKETHROUGH": ("~~", "~~"),
    "UNDERLINE": ("", ""),  # markdown não tem sublinhado; ignora
}

# Ordem de aplicação, para o markdown sair estável
STYLE_ORDER = ["CODE", "BOLD", "ITALIC", "STRIKETHROUGH", "UNDERLINE"]


def _entity_index(entity_map: Any) -> dict[str, dict[str, Any]]:
    """Normaliza o entityMap, que vem como lista de {key, value} na v2."""
    index: dict[str, dict[str, Any]] = {}
    if isinstance(entity_map, dict):
        for key, value in entity_map.items():
            index[str(key)] = value or {}
    elif isinstance(entity_map, list):
        for pair in entity_map:
            if isinstance(pair, dict) and "key" in pair:
                index[str(pair["key"])] = pair.get("value") or {}
    return index


def _media_lookup(media_entities: Any) -> dict[str, dict[str, Any]]:
    """Indexa media_entities por todos os ids possíveis.

    O entityMap referencia mídia por `mediaId`, mas o payload traz `id`,
    `media_id` e `media_key`. Indexar os três evita imagem perdida.
    """
    lookup: dict[str, dict[str, Any]] = {}
    for entity in media_entities or []:
        info = entity.get("media_info") or {}
        for field in ("media_id", "id", "media_key"):
            value = entity.get(field)
            if value:
                lookup[str(value)] = info
    return lookup


def _render_entity(
    entity: dict[str, Any],
    text: str,
    media_lookup: dict[str, dict[str, Any]],
) -> str:
    """Converte uma entity do Draft.js no markdown correspondente."""
    kind = (entity.get("type") or "").upper()
    data = entity.get("data") or {}

    if kind == "MARKDOWN":
        markdown = data.get("markdown") or ""
        # Já vem pronto (normalmente um link). Se não parecer markdown,
        # devolve o texto visível para não perder conteúdo.
        return markdown if markdown.strip() else _esc(text)

    if kind == "MEDIA":
        chunks = []
        for item in data.get("mediaItems") or []:
            info = media_lookup.get(str(item.get("mediaId") or ""))
            if info:
                rendered = _media_markdown(info)
                if rendered:
                    chunks.append(rendered)
        return "\n\n".join(chunks)

    if kind == "LINK":
        # `data.url` e a URL real; o texto coberto pelo entityRange e o label.
        url = data.get("url") or data.get("href") or ""
        label = _esc(text).strip() or url
        return f"[{label}]({url})" if url else _esc(text)

    if kind == "DIVIDER":
        # Vem como bloco atomic cujo texto e um espaco. Sem tratar, o
        # .strip() do bloco zerava o conteudo e a regra sumia do documento.
        return "---"

    if kind == "TWEET":
        tweet_id = data.get("tweetId")
        if tweet_id:
            return f"> Post citado: https://x.com/i/status/{tweet_id}"
        return _esc(text)

    return _esc(text)


def _render_block(
    block: dict[str, Any],
    entities: dict[str, dict[str, Any]],
    media_lookup: dict[str, dict[str, Any]],
    heading_shift: int = 0,
) -> str:
    """Renderiza um bloco Draft.js, aplicando estilos inline e entities."""
    text = block.get("text") or ""
    btype = block.get("type") or "unstyled"
    units = _units(text)
    total = len(units)

    # code-block é literal: nada de estilo inline nem escape
    if btype == "code-block":
        return f"```\n{text}\n```"

    # Anota cada code unit com os estilos e a entity que o cobrem.
    ents: list[str | None] = [None] * total

    per_unit_styles: list[set[str]] = [set() for _ in range(total)]
    for rng in block.get("inlineStyleRanges") or []:
        start = int(rng.get("offset", 0))
        end = start + int(rng.get("length", 0))
        style = (rng.get("style") or "").upper()
        for i in range(max(0, start), min(total, end)):
            per_unit_styles[i].add(style)
    # Heading no editor do X ja e negrito, e o range vem cobrindo o titulo
    # inteiro. Manter isso viraria `## **Titulo**`, negrito redundante dentro
    # de um heading, entao o negrito e descartado nesses blocos.
    if btype in HEADER_LEVEL:
        per_unit_styles = [s - {"BOLD"} for s in per_unit_styles]
    styles = [frozenset(s) for s in per_unit_styles]

    for rng in block.get("entityRanges") or []:
        start = int(rng.get("offset", 0))
        end = start + int(rng.get("length", 0))
        key = str(rng.get("key"))
        for i in range(max(0, start), min(total, end)):
            ents[i] = key

    # Agrupa code units consecutivos com a mesma anotação.
    out: list[str] = []
    i = 0
    while i < total:
        j = i + 1
        while j < total and styles[j] == styles[i] and ents[j] == ents[i]:
            j += 1
        chunk = _join(units[i:j])
        entity_key = ents[i]

        if entity_key is not None and entity_key in entities:
            piece = _render_entity(entities[entity_key], chunk, media_lookup)
        else:
            piece = _esc(chunk)
            for style in STYLE_ORDER:
                if style not in styles[i]:
                    continue
                open_tag, close_tag = STYLE_WRAP.get(style, ("", ""))
                if not open_tag or not piece.strip():
                    continue
                # `**bold **` nao renderiza: o espaco fica fora dos marcadores.
                lead = piece[: len(piece) - len(piece.lstrip())]
                trail = piece[len(piece.rstrip()) :]
                piece = f"{lead}{open_tag}{piece.strip()}{close_tag}{trail}"
        out.append(piece)
        i = j

    body = "".join(out).strip()

    # Bloco atomic sem texto: a entity carrega tudo (imagem, embed).
    if btype == "atomic":
        return body

    if not body:
        return ""

    if btype in HEADER_LEVEL:
        level = min(6, HEADER_LEVEL[btype] + heading_shift)
        return "#" * level + " " + body

    prefix = BLOCK_PREFIX.get(btype, "")
    if btype == "blockquote":
        return "\n".join(f"> {line}" for line in body.split("\n"))
    return prefix + body


def _heading_shift(blocks: Iterable[dict[str, Any]]) -> int:
    """Quanto empurrar os headings do corpo para baixo.

    O `#` do documento e do titulo do Article, entao nenhum heading do corpo
    pode ser h1 (o pandoc quebra o epub em capitulos a cada h1). O heading mais
    raso que o autor usou passa a ser h2 e os outros descem junto, preservando a
    hierarquia relativa: um Article que so usa header-two vira h2, nao h3, para
    nao abrir buraco de nivel entre o titulo e a primeira secao.
    """
    levels = [
        HEADER_LEVEL[block.get("type")]
        for block in blocks
        if block.get("type") in HEADER_LEVEL and (block.get("text") or "").strip()
    ]
    return (2 - min(levels)) if levels else 0


def render_article(article: dict[str, Any]) -> tuple[str, str]:
    """Renderiza um X Article. Retorna (título, markdown)."""
    title = (article.get("title") or "").strip() or "Article"
    content = article.get("content") or {}
    entities = _entity_index(content.get("entityMap"))
    media_lookup = _media_lookup(article.get("media_entities"))

    parts: list[str] = [f"# {title}"]

    cover = (article.get("cover_media") or {}).get("media_info") or {}
    cover_md = _media_markdown(cover, alt=title)
    if cover_md:
        parts.append(cover_md)

    # Draft.js não agrupa listas: cada item é um bloco irmão. Um markdown
    # com linha em branco entre itens vira lista solta (loose list), então
    # itens consecutivos são colados sem linha em branco.
    blocks = content.get("blocks") or []
    shift = _heading_shift(blocks)

    rendered: list[tuple[str, str]] = []
    for block in blocks:
        text = _render_block(block, entities, media_lookup, heading_shift=shift)
        if text:
            rendered.append((block.get("type") or "unstyled", text))

    buffer: list[str] = []
    prev_type = ""
    for btype, text in rendered:
        list_run = btype.endswith("-list-item") and btype == prev_type
        if buffer and list_run:
            buffer[-1] = buffer[-1] + "\n" + text
        else:
            buffer.append(text)
        prev_type = btype

    parts.extend(buffer)
    body = "\n\n".join(p for p in parts if p)
    return title, re.sub(r"\n{3,}", "\n\n", body).strip() + "\n"


# ---------- status normal ----------

def _expand_links(status: dict[str, Any]) -> str:
    """Devolve o texto do post com os t.co trocados pela URL real.

    `raw_text.facets` traz, para cada link/menção/hashtag, o trecho original,
    a URL expandida e o texto de exibição. Trocar por substring é mais seguro
    que aritmética de offsets aqui, porque cada facet é única no texto.
    """
    raw = status.get("raw_text") or {}
    text = raw.get("text") or status.get("text") or ""
    for facet in raw.get("facets") or []:
        original = facet.get("original")
        replacement = facet.get("replacement")
        display = facet.get("display") or replacement
        if facet.get("type") == "url" and original and replacement:
            text = text.replace(original, f"[{display}]({replacement})")
    return text.strip()


def _render_status(status: dict[str, Any], heading: bool = False) -> str:
    """Renderiza um status simples (com mídia, poll, card e quote)."""
    parts: list[str] = []

    author = status.get("author") or {}
    if heading:
        name = author.get("name") or ""
        handle = author.get("screen_name") or ""
        stamp = status.get("created_at") or ""
        parts.append(f"**{name}** (@{handle}) · {stamp}")

    text = _expand_links(status)
    if text:
        parts.append(text)

    parts.extend(_status_media_markdown(status.get("media")))

    poll = status.get("poll")
    if poll:
        lines = [
            f"- {c.get('label')} — {c.get('percentage')}%"
            for c in poll.get("choices") or []
        ]
        lines.append(f"\n*{poll.get('total_votes')} votos*")
        parts.append("\n".join(lines))

    card = status.get("card") or {}
    if card.get("url") and not status.get("media"):
        card_title = card.get("title") or card["url"]
        block = [f"[{card_title}]({card['url']})"]
        if card.get("description"):
            block.append(card["description"])
        parts.append("\n\n".join(block))

    quote = status.get("quote")
    if isinstance(quote, dict) and quote.get("type") == "status":
        inner = _render_status(quote, heading=True)
        parts.append("\n".join(f"> {line}" for line in inner.split("\n")))

    note = status.get("community_note") or {}
    if note.get("text"):
        parts.append(f"> **Nota da comunidade:** {note['text']}")

    return "\n\n".join(p for p in parts if p).strip()


# ---------- entrada pública ----------

def fetch_x_markdown(
    url: str, verbose: bool = False, *, metadata_out: dict[str, str] | None = None,
) -> tuple[str, str]:
    """Baixa um post/thread/Article do X. Retorna (título, markdown)."""

    def log(msg: str) -> None:
        if verbose:
            print(f"    [x] {msg}", file=sys.stderr)

    status_id = x_status_id(url)
    if not status_id:
        raise RuntimeError(f"não parece um post do X: {url}")

    api_url = FX_API.format(id=status_id)
    log(f"GET {api_url}")
    response = requests.get(api_url, headers=FX_HEADERS, timeout=30)
    response.raise_for_status()

    try:
        payload = response.json()
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"resposta da API não é JSON: {exc}")

    # A API espelha o status HTTP no corpo, então 200 na rede pode ser erro.
    code = payload.get("code")
    if code != 200:
        raise RuntimeError(
            f"API devolveu code={code}: {payload.get('message') or 'sem mensagem'}"
        )

    status = payload.get("status") or {}
    if status.get("type") == "tombstone":
        raise RuntimeError(
            f"post indisponível ({status.get('reason')}): {status.get('message')}"
        )

    author = status.get("author") or payload.get("author") or {}
    handle = author.get("screen_name") or "x"
    if metadata_out is not None:
        metadata_out.update({
            "author": author.get("name") or author.get("screen_name") or "X",
            "lang": (status.get("lang") or status.get("language") or "und").replace("_", "-"),
        })

    article = status.get("article")
    if article:
        log("post é um X Article")
        title, body = render_article(article)
        footer = f"\n\n---\n\nFonte: {status.get('url') or url}\n"
        return f"{handle} - {title}", body + footer

    thread = payload.get("thread")
    if isinstance(thread, list):
        statuses = [s for s in thread if isinstance(s, dict) and s.get("type") == "status"]
    else:
        statuses = []
    if not statuses:
        statuses = [status]
    log(f"{len(statuses)} post(s) na thread")

    name = author.get("name") or handle
    header = f"# {name} (@{handle})"
    meta = f"*{status.get('created_at') or ''}*"

    blocks = [_render_status(s) for s in statuses]
    body = "\n\n".join(b for b in blocks if b)
    footer = f"\n\n---\n\nFonte: {status.get('url') or url}\n"

    first_line = (statuses[0].get("text") or "").strip().split("\n")[0]
    title = f"{handle} - {first_line[:60]}".strip(" -") or handle

    return title, "\n\n".join([header, meta, body]).strip() + footer
