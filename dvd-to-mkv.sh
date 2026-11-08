#!/usr/bin/env bash
#
# dvd-to-mkv.sh - turns DVD-Video discs (ISO images, VIDEO_TS folders or the
# disc in the drive) into MKV files that keep every audio and subtitle track,
# plus a text (SRT) copy of each subtitle made with OCR.
# Linux (Fedora) only.
#
#   1. Asks where the DVDs are and where the MKVs go, unless both are given.
#      The origin can be one .iso, a folder of .iso files (and/or of DVD
#      folders), a VIDEO_TS folder (or the folder holding it) or an optical
#      drive (/dev/sr0).
#   2. Reads the DVD structure straight from the image with ffmpeg's
#      DVD-Video reader, so nothing is mounted. The main title (the longest)
#      is converted, or the one given with --title, or with --all every
#      title of --min minutes or more, except a series disc's "play all"
#      title (the episodes again in a row).
#   3. Copies the title into an MKV: video, every audio track, every
#      subtitle track, their languages and the chapters. Nothing is
#      re-encoded, except DVD LPCM audio, which MKV cannot hold; it becomes
#      FLAC, which is lossless. No subtitle is shown by default.
#   4. Each DVD subtitle is a picture track; subtile-ocr (Tesseract) reads it
#      into an SRT, which is added to the MKV as a text track named
#      "<Language> (OCR)". The picture tracks are kept. A track whose
#      language has no Tesseract pack installed, or that has no language
#      (see --ocr-lang), is left without one. fetch-subtitle.sh later
#      replaces the OCR track of the language it fetches with a proper
#      subtitle.
#   5. The MKV is written under a hidden name in the destination and renamed
#      when complete, so an interrupted run never leaves a half-made file.
#      An MKV that already exists is skipped, never overwritten.
#
# ffmpeg must be built with DVD support (libdvdnav), which Fedora's and RPM
# Fusion's are not. The script looks for one in $DVD_FFMPEG, then
# ~/.local/opt/ffmpeg-dvd/bin/ffmpeg, then the ffmpeg on the PATH; --help
# shows how to install it. CSS-encrypted discs are not decrypted: rip those
# with MakeMKV or dvdbackup first.
#
# Usage: dvd-to-mkv.sh [options] [ORIGIN [DESTINATION]]     (see --help)

set -euo pipefail
export LC_ALL=C.UTF-8

FFMPEG_DVD_URL=https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n8.1-latest-linux64-gpl-8.1.tar.xz
FFMPEG=""
FFPROBE=""

SRC=""
DEST=""
TITLE=0
ALL=0
MIN_MINUTES=5
OCR=1
OCR_UND=""              # language to OCR untagged subtitle tracks as

DISCS=()                # what to convert: .iso files, DVD folders, devices
TESS_LANGS=" "          # installed Tesseract languages, space separated
WORK=""                 # temporary folder for the subtitle files
PARTIALS=()             # MKVs being written, deleted if the run stops
FAILED=0                # titles not converted

log() { printf '[dvd-to-mkv %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1
          while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }
minutes() { awk -v s="$1" 'BEGIN { printf "%d:%02d", s / 60, s % 60 }'; }

usage() {
    cat <<HELP
Usage: ${0##*/} [options] [ORIGIN [DESTINATION]]

Converts DVDs into MKV files with every audio and subtitle track, the
chapters and the track languages, without re-encoding. Each subtitle is also
read with OCR into a text track named "<Language> (OCR)". Asks for the
origin and the destination when they are not given.

  ORIGIN        a .iso file, a folder of .iso files or DVD folders, a VIDEO_TS
                folder (or the folder holding it), or a drive such as /dev/sr0
  DESTINATION   folder for the MKVs (default: ~/Videos)

Options:
  -t, --title N      convert title N instead of the main (longest) title
  -a, --all          convert every title of --min minutes or more
  --min MINUTES      shortest title --all converts (default: $MIN_MINUTES)
  --no-ocr           skip the OCR; keep only the DVD's own subtitle tracks
  --ocr-lang CODE    read subtitle tracks that have no language as this one
                     (an ISO 639-2 code such as eng, por, spa)
  -h, --help         this help

Needs an ffmpeg that reads DVDs (Fedora's does not). To install one for this
script only, with no sudo:

  mkdir -p ~/.local/opt && cd ~/.local/opt
  curl -LO $FFMPEG_DVD_URL
  tar -xf ffmpeg-n8.1-*.tar.xz && rm ffmpeg-n8.1-*.tar.xz
  mv ffmpeg-n8.1-latest-linux64-gpl-8.1 ffmpeg-dvd

The OCR needs Tesseract with a language pack per subtitle language, and
subtile-ocr:

  sudo dnf install tesseract tesseract-langpack-eng tesseract-langpack-por \\
                   tesseract-devel leptonica-devel clang-devel
  cargo install subtile-ocr

Then run fetch-subtitle.sh on the MKV: it replaces the OCR track of the
language it fetches with a downloaded subtitle.
HELP
}

parse_args() {
    local pos=()
    while (($#)); do
        case $1 in
            -t|--title|--min|--ocr-lang)
                [[ $# -ge 2 ]] || die "$1 needs a value"
                case $1 in
                    -t|--title) [[ $2 =~ ^[1-9][0-9]?$ ]] || die "--title takes a number from 1 to 99"
                                TITLE=$2 ;;
                    --min) [[ $2 =~ ^[0-9]+$ ]] || die "--min takes a whole number of minutes"
                           MIN_MINUTES=$2 ;;
                    --ocr-lang) [[ $2 =~ ^[a-z]{3}$ ]] || die "--ocr-lang takes a 3-letter code such as eng"
                                OCR_UND=$2 ;;
                esac
                shift ;;
            -a|--all) ALL=1 ;;
            --no-ocr) OCR=0 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage >&2; die "Unknown option: $1" ;;
            *) pos+=("$1") ;;
        esac
        shift
    done
    ((${#pos[@]} <= 2)) || die "Too many arguments: give one origin and one destination."
    ((TITLE == 0 || ALL == 0)) || die "--title and --all do not go together."
    SRC=${pos[0]:-}
    DEST=${pos[1]:-}
}

# A path typed or dropped into the terminal: ~ expanded, the quotes GNOME
# Terminal adds around a dropped file removed, surrounding spaces trimmed.
clean_path() {
    local p=$1
    p=${p#"${p%%[![:space:]]*}"}; p=${p%"${p##*[![:space:]]}"}
    [[ $p == \'*\' || $p == \"*\" ]] && p=${p:1:-1}
    [[ $p == "~" || $p == "~/"* ]] && p=$HOME${p:1}
    printf '%s' "$p"
}

ask_paths() {
    local default_dest answer
    default_dest=$(xdg-user-dir VIDEOS 2>/dev/null || true)
    [[ -n $default_dest && $default_dest != "$HOME" ]] || default_dest=$HOME/Videos

    if [[ -z $SRC ]]; then
        [[ -t 0 ]] || die "No origin given (and no terminal to ask on). See --help."
        read -e -r -p "DVD origin (.iso, folder of .iso files, VIDEO_TS folder or /dev/sr0): " answer
        SRC=$(clean_path "$answer")
        [[ -n $SRC ]] || die "No origin given."
        if [[ -z $DEST ]]; then
            read -e -r -p "Destination folder [$default_dest]: " answer
            DEST=$(clean_path "$answer")
        fi
    fi
    [[ -n $DEST ]] || DEST=$default_dest
    [[ -e $SRC ]] || die "Not found: $SRC"
    DEST=$(realpath -m -- "$DEST")
    if [[ ! -d $DEST ]]; then
        mkdir -p -- "$DEST" || die "Cannot create $DEST"
    fi
    [[ -w $DEST ]] || die "Cannot write to $DEST"
}

has_dvd_reader() {
    [[ -x $1 ]] && "$1" -hide_banner -h demuxer=dvdvideo 2>/dev/null | grep -q 'DVD-Video demuxer'
}

find_ffmpeg() {
    local c
    for c in "${DVD_FFMPEG:-}" "$HOME/.local/opt/ffmpeg-dvd/bin/ffmpeg" "$(command -v ffmpeg || true)"; do
        [[ -n $c ]] || continue
        if has_dvd_reader "$c" && [[ -x $(dirname -- "$c")/ffprobe ]]; then
            FFMPEG=$c
            FFPROBE=$(dirname -- "$c")/ffprobe
            return 0
        fi
    done
    die "No ffmpeg with DVD support found (Fedora's lacks it). See --help to install one."
}

check_tools() {
    local t missing=()
    for t in mkvmerge mkvextract jq; do
        command -v "$t" >/dev/null || missing+=("$t (sudo dnf install ${t/mkvmerge/mkvtoolnix})")
    done
    if ((OCR)); then
        command -v tesseract >/dev/null ||
            missing+=("tesseract (sudo dnf install tesseract tesseract-langpack-eng)")
        command -v subtile-ocr >/dev/null ||
            missing+=("subtile-ocr (cargo install subtile-ocr; it needs: sudo dnf install tesseract-devel leptonica-devel clang-devel)")
    fi
    if ((${#missing[@]})); then
        log "Missing:"
        for t in "${missing[@]}"; do log "  $t"; done
        ((OCR)) && log "(--no-ocr converts without the OCR.)"
        exit 1
    fi
    find_ffmpeg
    if ((OCR)); then
        TESS_LANGS=" $(tesseract --list-langs 2>/dev/null | tail -n +2 | tr '\n' ' ')"
    fi
}

is_dvd_folder() { [[ -d $1/VIDEO_TS || ( -d $1 && ${1##*/} == [Vv][Ii][Dd][Ee][Oo]_[Tt][Ss] ) ]]; }

collect_discs() {
    local f
    if [[ -b $SRC ]]; then
        DISCS=("$SRC")
    elif [[ -f $SRC ]]; then
        DISCS=("$(realpath -- "$SRC")")
    elif is_dvd_folder "$SRC"; then
        DISCS=("$(realpath -- "$SRC")")
    elif [[ -d $SRC ]]; then
        while IFS= read -r -d '' f; do
            if [[ -f $f && ${f,,} == *.iso ]] || is_dvd_folder "$f"; then
                DISCS+=("$f")
            fi
        done < <(find "$(realpath -- "$SRC")" -mindepth 1 -maxdepth 1 \
                     \( -type f -iname '*.iso' -o -type d \) -print0 | sort -z)
        ((${#DISCS[@]})) || die "No .iso files or DVD folders in $SRC"
    else
        die "Not a file, folder or drive: $SRC"
    fi
}

# The name the MKVs get: the .iso's name, the DVD folder's name, or the
# disc's label.
disc_name() {
    local src=$1 name=""
    if [[ -b $src ]]; then
        name=$(lsblk -dno LABEL -- "$src" 2>/dev/null || true)
        [[ -n $name ]] || name=dvd
    elif [[ -f $src ]]; then
        name=${src##*/}; name=${name%.*}
    else
        name=${src%/}
        [[ ${name##*/} == [Vv][Ii][Dd][Ee][Oo]_[Tt][Ss] ]] && name=${name%/*}
        name=${name##*/}
    fi
    name=${name//\//_}
    printf '%s' "$name"
}

# Prints "number duration-in-seconds" for each title. DVD titles are
# numbered from 1 with no gaps, so the first one that cannot be read is the
# end of the list.
list_titles() {
    local src=$1 n d
    for ((n = 1; n <= 99; n++)); do
        d=$("$FFPROBE" -v error -f dvdvideo -title "$n" -show_entries format=duration \
                -of csv=p=0 -i "$src" 2>/dev/null) || break
        [[ $d =~ ^[0-9.]+$ ]] || break
        printf '%s %s\n' "$n" "$d"
    done
}

# Bytes the DVD takes, as a ceiling for what its MKVs need; 0 if unknown.
disc_size() {
    local src=$1
    if [[ -f $src ]]; then stat -c %s -- "$src"
    elif [[ -d $src ]]; then du -sb -- "$src" | cut -f1
    else echo 0; fi
}

free_space() { df -B1 --output=avail -- "$DEST" | tail -1 | tr -d ' '; }

# Copies one title into an MKV with ffmpeg.
rip_title() {
    local src=$1 title=$2 out=$3 i extra=() codecs=()
    mapfile -t codecs < <("$FFPROBE" -v error -f dvdvideo -title "$title" -select_streams a \
                              -show_entries stream=codec_name -of csv=p=0 -i "$src" 2>/dev/null)
    for i in "${!codecs[@]}"; do
        if [[ ${codecs[i]} == pcm_dvd ]]; then
            extra+=("-c:a:$i" flac)
            log "  audio track $((i + 1)) is LPCM, which MKV cannot hold: stored as FLAC (lossless)."
        fi
    done
    # -preindex reads the title twice, for chapter marks at the right frames,
    # but gives up on a disc with a damaged cell, often the padding at the
    # end of a title; then the title is read once, with the chapter marks
    # the disc lists.
    local preindex rc
    for preindex in 1 0; do
        rc=0
        "$FFMPEG" -nostdin -hide_banner -v error -stats \
            -f dvdvideo -preindex "$preindex" -title "$title" -i "$src" \
            -map 0 -c copy "${extra[@]}" -disposition:s 0 \
            -f matroska -y "$out" || rc=$?
        if [[ -s $out ]] || ((preindex == 0)); then break; fi
        log "  cannot index the title (a damaged cell); reading it once instead."
    done
    printf '\n' >&2                     # past ffmpeg's progress line
    # A read error at the very end is common (padding cells) and harmless;
    # whether the copy is complete is judged by its length, in convert().
    if ((rc)) && [[ -s $out ]]; then
        log "  ffmpeg stopped with a read error (exit $rc); checking the length of what it copied."
    fi
    [[ -s $out ]]
}

# The language's English name, from mkvmerge's table of ISO 639-2 codes.
language_name() {
    local name
    name=$(mkvmerge --list-languages 2>/dev/null |
           awk -F'|' -v c="$1" '{ gsub(/ /, "", $3) } $3 == c { sub(/ +$/, "", $1); print $1; exit }')
    printf '%s' "${name:-$1}"
}

# Tesseract's name for an ISO 639-2 language: mostly the same code, but
# Tesseract uses the terminology form where the bibliographic one differs.
tesseract_lang() {
    case $1 in
        fre) echo fra ;;  ger) echo deu ;;  dut) echo nld ;;  cze) echo ces ;;
        gre) echo ell ;;  per) echo fas ;;  rum) echo ron ;;  slo) echo slk ;;
        ice) echo isl ;;  alb) echo sqi ;;  arm) echo hye ;;  baq) echo eus ;;
        geo) echo kat ;;  mac) echo mkd ;;  may) echo msa ;;  bur) echo mya ;;
        wel) echo cym ;;  tib) echo bod ;;  chi) echo chi_sim ;;
        *) echo "$1" ;;
    esac
}

# Reads every picture subtitle of IN with OCR and writes IN plus the SRTs to
# OUT. Returns 1 only when the final mux fails; a track that cannot be read
# is reported and left out.
ocr_and_mux() {
    local in=$1 out=$2 json id lang tess cues name
    local ids=() langs=() extract=() mux=()
    json=$(mkvmerge -J "$in")
    while IFS=$'\t' read -r id lang; do
        if [[ $lang == und || -z $lang ]]; then
            if [[ -z $OCR_UND ]]; then
                log "  subtitle track $id has no language; no OCR (--ocr-lang sets one)."
                continue
            fi
            lang=$OCR_UND
        fi
        tess=$(tesseract_lang "$lang")
        if [[ $TESS_LANGS != *" $tess "* ]]; then
            log "  subtitle track $id ($(language_name "$lang")): no Tesseract pack for it;" \
                "no OCR. (sudo dnf install tesseract-langpack-$tess)"
            continue
        fi
        ids+=("$id"); langs+=("$lang")
        extract+=("$id:$WORK/s$id.sub")
    done < <(jq -r '.tracks[] | select(.type == "subtitles" and .codec == "VobSub")
                    | "\(.id)\t\(.properties.language // "und")"' <<<"$json")

    if ((${#ids[@]})); then
        mkvextract "$in" tracks "${extract[@]}" >/dev/null ||
            { log "  could not extract the subtitles; no OCR."; ids=(); }
    fi

    local k
    for k in "${!ids[@]}"; do
        id=${ids[k]}; lang=${langs[k]}; tess=$(tesseract_lang "$lang")
        name=$(language_name "$lang")
        log "  OCR: subtitle track $id ($name)..."
        if ! subtile-ocr -l "$tess" -o "$WORK/s$id.srt" "$WORK/s$id.idx" >"$WORK/ocr.log" 2>&1; then
            log "    failed; left out. $(tail -n 3 "$WORK/ocr.log" | tr '\n' ' ')"
            continue
        fi
        cues=$(grep -c -- '-->' "$WORK/s$id.srt" || true)
        if ((cues == 0)); then
            log "    the track is empty; left out."
            continue
        fi
        log "    $cues lines read."
        mux+=(--language "0:$lang" --track-name "0:$name (OCR)"
              --default-track-flag 0:no --sub-charset 0:UTF-8 "$WORK/s$id.srt")
    done

    if ((${#mux[@]} == 0)); then
        mv -- "$in" "$out"
        return 0
    fi
    local rc=0
    mkvmerge -q -o "$out" "$in" "${mux[@]}" || rc=$?
    if ((rc >= 2)); then        # 1 = warnings only
        log "  adding the OCR subtitles failed."
        return 1
    fi
    rm -f -- "$in"
}

# Converts one title of a disc. Returns 1 on failure.
convert() {
    local src=$1 title=$2 length=$3 final=$4
    local base=${final##*/}
    local ripped=$DEST/.${base%.mkv}.rip.mkv
    local muxed=$DEST/.${base%.mkv}.part.mkv
    PARTIALS=("$ripped" "$muxed")

    log "Title $title ($(minutes "$length")) -> $final"
    if ! rip_title "$src" "$title" "$ripped"; then
        log "  ffmpeg failed. (An encrypted disc? See --help.)"
        rm -f -- "$ripped"; return 1
    fi

    # The copy must run the length of the title; a damaged image stops early.
    local got
    got=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 -i "$ripped" 2>/dev/null || echo 0)
    if ! awk -v a="$got" -v b="$length" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 10 || d <= b * 0.02) }'; then
        log "  the copy runs $(minutes "${got%.*}"), the title $(minutes "${length%.*}"): incomplete; left out."
        rm -f -- "$ripped"; return 1
    fi

    if ((OCR)); then
        ocr_and_mux "$ripped" "$muxed" || { rm -f -- "$ripped" "$muxed"; return 1; }
    else
        mv -- "$ripped" "$muxed"
    fi
    chmod 644 -- "$muxed"
    # Never over a file that appeared meanwhile.
    if ! mv -n -- "$muxed" "$final" || [[ -e $muxed ]]; then
        log "  $final appeared meanwhile; the new copy is left as $muxed"
        PARTIALS=(); return 1
    fi
    PARTIALS=()
    log "  done: $(human "$(stat -c %s -- "$final")"), $(mkvmerge -J "$final" |
        jq -r '[.tracks[] | .type] | "\(map(select(. == "audio")) | length) audio, \(map(select(. == "subtitles")) | length) subtitle track(s)"')"
}

# is_play_all I LENGTH...: true when title I runs as long as all the other
# titles together (within 1%), with at least two of them: a series disc's
# "play all", the episodes again in a row.
is_play_all() {
    local i=$1; shift
    (($# >= 3)) || return 1
    printf '%s\n' "$@" | awk -v i="$i" '{ len[NR - 1] = $1; total += $1 }
        END { rest = total - len[i]; d = len[i] - rest; if (d < 0) d = -d
              exit !(rest > 0 && d <= len[i] * 0.01) }'
}

# Converts the chosen titles of one disc, counting failures in FAILED.
do_disc() {
    local src=$1 name n d main=0 longest=0
    local titles=() lengths=()
    name=$(disc_name "$src")
    log "== $src"
    while read -r n d; do
        titles+=("$n"); lengths+=("$d")
        if awk -v a="$d" -v b="$longest" 'BEGIN { exit !(a > b) }'; then main=$n; longest=$d; fi
    done < <(list_titles "$src")
    if ((${#titles[@]} == 0)); then
        log "  cannot read the DVD structure (not a DVD-Video, damaged, or encrypted)."
        FAILED=$((FAILED + 1)); return
    fi

    local pick=() i
    if ((ALL)); then
        for i in "${!titles[@]}"; do
            awk -v d="${lengths[i]}" -v m="$MIN_MINUTES" 'BEGIN { exit !(d >= m * 60) }' || continue
            if is_play_all "$i" "${lengths[@]}"; then
                log "  title ${titles[i]} ($(minutes "${lengths[i]%.*}")) is the other titles played in a row; skipped (--title ${titles[i]} converts it)."
                continue
            fi
            pick+=("$i")
        done
        ((${#pick[@]})) || log "  no title of $MIN_MINUTES minutes or more."
    elif ((TITLE)); then
        for i in "${!titles[@]}"; do [[ ${titles[i]} == "$TITLE" ]] && pick+=("$i"); done
        if ((${#pick[@]} == 0)); then
            log "  this DVD has no title $TITLE (it has ${#titles[@]})."
            FAILED=$((FAILED + 1)); return
        fi
    else
        for i in "${!titles[@]}"; do [[ ${titles[i]} == "$main" ]] && pick+=("$i"); done
        log "  ${#titles[@]} title(s); the main one is title $main ($(minutes "${longest%.*}"))."
        for i in "${!titles[@]}"; do
            [[ ${titles[i]} == "$main" ]] && is_play_all "$i" "${lengths[@]}" &&
                log "  it is the other titles played in a row (episodes?); --all converts them one by one."
        done
    fi

    local size avail final
    size=$(disc_size "$src")
    for i in "${pick[@]}"; do
        if ((ALL)); then
            final=$DEST/$(printf '%s - title %02d.mkv' "$name" "${titles[i]}")
        else
            final=$DEST/$name.mkv
        fi
        if [[ -e $final ]]; then
            log "  $final already exists; skipped."
            continue
        fi
        # The ripped copy and the one with the OCR tracks exist side by side
        # for a moment.
        avail=$(free_space)
        if ((size > 0 && avail < 2 * size)); then
            log "  not enough space in $DEST: $(human "$avail") free, up to $(human $((2 * size))) needed."
            FAILED=$((FAILED + 1)); continue
        fi
        convert "$src" "${titles[i]}" "${lengths[i]}" "$final" || FAILED=$((FAILED + 1))
    done
}

cleanup() {
    local f
    for f in "${PARTIALS[@]}"; do rm -f -- "$f"; done
    [[ -z $WORK ]] || rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

main() {
    parse_args "$@"
    check_tools
    ask_paths
    collect_discs
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/dvd-to-mkv.XXXXXX")
    log "${#DISCS[@]} DVD(s) -> $DEST (ffmpeg: $FFMPEG)"

    local src
    for src in "${DISCS[@]}"; do
        do_disc "$src"
    done
    if ((FAILED)); then
        log "Finished with $FAILED title(s) not converted (see above)."
        return 1
    fi
    log "Finished."
}

main "$@"
