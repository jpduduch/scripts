#!/usr/bin/env bash
#
# mkv-strip-tracks.sh - keeps only the movie's original-language audio and the
# English subtitles in MKV files. Video, chapters and attachments are kept
# untouched (nothing is re-encoded; mkvmerge just remuxes).
#
# The original language comes from, in order:
#   1. --lang, if given
#   2. tracks the file itself flags as original (Matroska "original" flag)
#   3. Wikidata, looked up by the title and year in the file name
# A file whose audio tracks all share one language needs no lookup.
#
# The new file is written beside the original, checked, and only then replaces
# it, so you need free space for one extra copy of the movie.
#
# Usage: mkv-strip-tracks.sh [options] FILE.mkv...   (see --help)

set -euo pipefail

# Resolve this script's own directory, following symlinks.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
PY_DIR="$SCRIPT_DIR/lib/python"

# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
preflight mkvmerge jq || exit 1

LOOKUP=("$PY_DIR/.venv/bin/python" -I "$PY_DIR/original-language.py")

KEEP_UND=no
DRY_RUN=no
LANG_ARG=""

log() { printf '[mkv-strip-tracks] %s\n' "$*" >&2; }
die() { log "ERROR: $1"; exit "${2:-1}"; }

usage() {
    cat <<HELP
Usage: ${0##*/} [options] FILE.mkv...

Keeps only the original-language audio and the English subtitles, in place.

The original language is taken from --lang, else from tracks the file flags
as original, else looked up on Wikidata by the title and year in the file
name (e.g. "Parasite.2019.1080p.mkv" -> Korean). Files where every audio
track has the same language need no lookup.

Options:
  -l, --lang CODE  original language, skipping the lookup (ja, jpn, pt...);
                   applies to every file given
  --keep-und       also keep tracks with no language set ("und")
  -n, --dry-run    only show what would be kept and removed
  -h, --help       this text

A file is skipped (left untouched) when the language cannot be found or no
audio track is in it; --lang or --keep-und usually sorts that out.
HELP
}

FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -l|--lang) [ $# -ge 2 ] || die "$1 needs a language code"; LANG_ARG="$2"; shift ;;
        --lang=*) LANG_ARG="${1#*=}" ;;
        --keep-und) KEEP_UND=yes ;;
        -n|--dry-run) DRY_RUN=yes ;;
        -h|--help) usage; exit 0 ;;
        --) shift; FILES+=("$@"); break ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) FILES+=("$1") ;;
    esac
    shift
done
[ ${#FILES[@]} -gt 0 ] || { usage >&2; exit 1; }

# Codes for --lang, resolved once: "jpn ja<TAB>Japanese".
LANG_CODES="" LANG_NAME=""
if [ -n "$LANG_ARG" ]; then
    line=$("${LOOKUP[@]}" --code "$LANG_ARG") || die "unknown language: $LANG_ARG"
    LANG_CODES=${line%%$'\t'*}
    LANG_NAME=${line#*$'\t'}
fi

# jq: decides keep/drop per track.
#   $orig    space-separated ISO 639 codes of the original language
#   $flagged "yes" to keep exactly the audio tracks flagged as original
#   $und     "yes" to keep tracks with no language
JQ_DEFS='
  def lang: (.properties.language // "und");
  def ietf: (.properties.language_ietf // "");
  def is_und: lang == "und" and (ietf == "" or ietf == "und");
  def is_lang($codes):
    lang as $l | (ietf | split("-") | .[0] // "") as $p
    | ($codes | index([$l]) != null or index([$p]) != null);
  def keep:
    ($orig | split(" ") | map(select(. != ""))) as $o
    | if .type == "audio" then
        if $flagged == "yes" then .properties.flag_original == true
        else is_lang($o) end
      else is_lang(["eng", "en"]) end
    or ($und == "yes" and is_und);
'

# Prints "id<TAB>type<TAB>lang<TAB>keep<TAB>name" per audio/subtitle track
# (name last: it may be empty, and read collapses consecutive tabs).
list_tracks() {
    jq -r --arg orig "$2" --arg flagged "$3" --arg und "$KEEP_UND" "$JQ_DEFS"'
      .tracks[] | select(.type == "audio" or .type == "subtitles")
      | [.id, .type, (.properties.language_ietf // .properties.language // "und"),
         (if keep then "keep" else "drop" end), (.properties.track_name // "")]
      | @tsv' <<<"$1"
}

count_type() { jq --arg t "$2" '[.tracks[] | select(.type == $t)] | length' <<<"$1"; }

process() {
    local src="$1"
    [ -f "$src" ] || { log "skip: '$src' does not exist"; return 1; }
    case "${src,,}" in
        *.mkv|*.mka|*.mk3d) ;;
        *) log "skip: '$src' is not an MKV"; return 1 ;;
    esac

    local info
    info=$(mkvmerge -J "$src") || { log "skip: mkvmerge could not read '$src'"; return 1; }
    log "$src"

    # Decide the original language.
    local orig="" flagged=no
    local n_flagged n_langs
    n_flagged=$(jq '[.tracks[] | select(.type == "audio" and .properties.flag_original == true)] | length' <<<"$info")
    n_langs=$(jq '[.tracks[] | select(.type == "audio")
                   | (.properties.language_ietf // .properties.language // "und")] | unique | length' <<<"$info")
    if [ -n "$LANG_CODES" ]; then
        orig=$LANG_CODES
        log "  original language: $LANG_NAME (--lang)"
    elif [ "$n_flagged" -gt 0 ]; then
        flagged=yes
        log "  original language: the track(s) flagged as original in the file"
    elif [ "$n_langs" -le 1 ]; then
        # One language (or no audio): nothing to choose, keep all audio.
        orig=$(jq -r '[.tracks[] | select(.type == "audio")
                       | (.properties.language_ietf // .properties.language // "und")
                       | split("-")[0]] | unique | join(" ")' <<<"$info")
        log "  single audio language, no lookup needed"
    else
        local alt out rc=0
        alt=$(jq -r '.container.properties.title // ""' <<<"$info")
        out=$("${LOOKUP[@]}" "$src" ${alt:+--alt "$alt"} 2> >(sed 's/^/  /' >&2)) || rc=$?
        if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
            log "  skip: original language unknown; rerun with --lang CODE"
            return 1
        fi
        orig=$(cut -f1 <<<"$out" | tr '\n' ' ')
        log "  original language: $(cut -f2 <<<"$out" | paste -sd, - | sed 's/,/, /g')"
    fi

    local audio_keep=() sub_keep=() audio_total=0 dropped=0
    local id type lang verdict name
    while IFS=$'\t' read -r id type lang verdict name; do
        [ -n "$id" ] || continue
        printf '    %-4s #%-3s %-9s %-6s %s\n' "$verdict" "$id" "$type" "$lang" "$name" >&2
        if [ "$type" = audio ]; then
            audio_total=$((audio_total + 1))
            [ "$verdict" = keep ] && audio_keep+=("$id")
        else
            [ "$verdict" = keep ] && sub_keep+=("$id")
        fi
        [ "$verdict" = drop ] && dropped=$((dropped + 1))
    done < <(list_tracks "$info" "$orig" "$flagged")

    if [ "$audio_total" -gt 0 ] && [ ${#audio_keep[@]} -eq 0 ]; then
        log "  skip: no audio track in the original language; check --lang, or use"
        log "        --keep-und if that track simply has no language set"
        return 1
    fi
    if [ "$dropped" -eq 0 ]; then
        log "  nothing to remove"
        return 0
    fi
    if [ "$DRY_RUN" = yes ]; then
        log "  dry run: would remove $dropped track(s)"
        return 0
    fi

    local args=()
    if [ ${#audio_keep[@]} -gt 0 ]; then
        args+=(--audio-tracks "$(IFS=,; echo "${audio_keep[*]}")")
    else
        args+=(--no-audio)
    fi
    if [ ${#sub_keep[@]} -gt 0 ]; then
        args+=(--subtitle-tracks "$(IFS=,; echo "${sub_keep[*]}")")
    else
        args+=(--no-subtitles)
    fi

    local dir base tmp
    dir=$(dirname -- "$src")
    base=$(basename -- "$src")
    tmp="$dir/.${base%.*}.stripped.tmp.mkv"
    rm -f -- "$tmp"

    # mkvmerge has no "--"; a ./ prefix keeps a name starting with - from
    # being read as an option. It exits 1 on warnings (file still fine), 2 on
    # errors.
    local in="$src" rc=0
    case "$in" in -*) in="./$in" ;; esac
    mkvmerge --quiet -o "$tmp" "${args[@]}" "$in" || rc=$?
    if [ "$rc" -ge 2 ] || [ ! -s "$tmp" ]; then
        rm -f -- "$tmp"
        log "  ERROR: mkvmerge failed (exit $rc); original left untouched"
        return 1
    fi

    # Verify: right number of tracks of each kind, video intact, same length.
    local out
    out=$(mkvmerge -J "$tmp") || { rm -f -- "$tmp"; log "  ERROR: cannot read result"; return 1; }
    local ok=yes
    [ "$(count_type "$out" audio)" -eq ${#audio_keep[@]} ] || ok=no
    [ "$(count_type "$out" subtitles)" -eq ${#sub_keep[@]} ] || ok=no
    [ "$(count_type "$out" video)" -eq "$(count_type "$info" video)" ] || ok=no
    local d_in d_out
    d_in=$(jq '.container.properties.duration // 0' <<<"$info")
    d_out=$(jq '.container.properties.duration // 0' <<<"$out")
    # Durations are in ns; allow 2 s of difference.
    [ $(( d_in > d_out ? d_in - d_out : d_out - d_in )) -le 2000000000 ] || ok=no
    if [ "$ok" = no ]; then
        rm -f -- "$tmp"
        log "  ERROR: result failed verification; original left untouched"
        return 1
    fi

    local before after
    before=$(stat -c %s -- "$src")
    after=$(stat -c %s -- "$tmp")
    touch -r "$src" -- "$tmp"
    mv -f -- "$tmp" "$src"
    log "  done: removed $dropped track(s), $(( (before - after) / 1048576 )) MiB saved"
}

failed=0
for f in "${FILES[@]}"; do
    process "$f" || failed=$((failed + 1))
done
[ "$failed" -eq 0 ] || { log "$failed file(s) not processed"; exit 1; }
