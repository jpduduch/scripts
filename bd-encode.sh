#!/usr/bin/env bash
#
# bd-encode.sh - shrinks a video just enough to fill the disc in the optical
# drive, as 10-bit HEVC, choosing the least destructive encoder that lets the
# whole job (encode, then burn and verify) finish within a time window.
# Linux (Fedora/GNOME) only.
#
#   1. The disc's free space is read (via bd-burn.sh). No writable disc: stop.
#   2. A video that already fits on the disc is left alone (exit 3).
#   3. The HEVC bitrate that fills the disc is worked out from the duration and
#      the size of the audio/subtitles, which are copied as they are.
#   4. Each encoder is timed on a short clip of the film. Least destructive
#      first: x265 slow, then NVENC (the GPU); the first one projected to finish
#      within the window, burn time included, is used. If neither does, NVENC
#      is used anyway; without a working NVENC, x265 medium.
#   5. The encode goes to ~/Videos/temp/NAME.bd.mkv, and its path is printed on
#      stdout (everything else goes to stderr), ready for bd-burn.sh. An encode
#      left there by an earlier run is checked and reused instead.
#
# Usage: bd-encode.sh [options] VIDEO     (see --help)

set -euo pipefail
# Decimal points, whatever the desktop locale (printf %f rejects "2.5" in pt_BR).
export LC_NUMERIC=C

SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
BD_BURN="$SCRIPT_DIR/bd-burn.sh"

DEVICE=""
HOURS=8
FORCE_PRESET=""
OUTPUT=""
ESTIMATE_ONLY=no

# Least destructive first. x265 beyond slow takes days on a 4K film for no
# visible gain at the light compression a disc needs, so it is not offered.
AUTO_OPTIONS=(slow nvenc)
# Used when the GPU encoder is missing: the fastest sensible x265.
NO_NVENC_FALLBACK=medium
X265_PRESETS=(ultrafast superfast veryfast faster fast medium slow slower veryslow placebo)
# The clip each option is timed on, and how long any one option may be timed.
PROBE_CLIP_SECONDS=6
PROBE_MAX_SECONDS=90
# Timing a short clip is a rough guide; pad the projection.
PROJECTION_PAD=1.10

# bd-burn.sh keeps this much free after a burn; it is set aside twice here, the
# second time for the ISO metadata itself.
FS_RESERVE=$((16 * 1024 * 1024))
SIZE_SAFETY_PERMILLE=20              # muxing overhead and rate-control error
BURN_BYTES_PER_SEC=$((18 * 1000 * 1000))  # BD 4x; writing and reading back
BURN_FIXED_SECONDS=600               # spin-up, lead-in, closing the session
MIN_VIDEO_KBPS=300
ALREADY_FITS=3

log() { printf '[bd-encode %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

human() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }
hms() { printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); }
now() { date +%s; }

usage() {
    cat <<HELP
Usage: ${0##*/} [options] VIDEO

Shrinks VIDEO just enough to fill the disc in the drive, as 10-bit HEVC, and
prints the path of the encode. Audio and subtitles are copied as they are.
The encoder is the least destructive one (x265 slow, else NVENC) that lets the
encode plus the burn finish within --hours; each is timed on a short clip first.

Options:
  --device DEV   optical drive (default: /dev/sr0, else the first /dev/sr*);
                 stdio:/path/file.iso uses an image file instead (testing)
  --hours H      time window for encode + burn, from now (default $HOURS)
  --preset NAME  skip the choice: an x265 preset (slow, medium, ...) or nvenc
  --output FILE  where the encode goes (default ~/Videos/temp/NAME.bd.mkv)
  --estimate     time the encoders and show the choice, then stop
  -h, --help     this text

Exit status: 0 encoded (path on stdout); 3 VIDEO already fits on the disc, so
nothing was done; 1 any other error.
HELP
}

# ------------------------------------------------------------------- probe

videos_dir() {
    local dir
    dir=$(xdg-user-dir VIDEOS 2>/dev/null) || dir=""
    [[ -n $dir && $dir != "$HOME" ]] || dir="$HOME/Videos"
    printf '%s\n' "$dir"
}

probe() {
    ffprobe -v error "$@" -of default=nw=1:nk=1 -- "$VIDEO"
}

duration_of() { ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$1"; }

# Bytes of the audio and subtitle streams, which are copied untouched.
copied_stream_bytes() {
    local stats audio subs
    if [[ -z $(probe -select_streams a -show_entries stream=index) &&
        -z $(probe -select_streams s -show_entries stream=index) ]]; then
        echo 0
        return
    fi
    stats=$(ffmpeg -nostdin -hide_banner -i "$VIDEO" -map '0:a?' -map '0:s?' \
        -c copy -f null - 2>&1 | grep -E 'audio:' | tail -1) ||
        die "Cannot measure the audio and subtitle streams."
    audio=$(grep -oP 'audio:\s*\K[0-9.]+' <<< "$stats")
    subs=$(grep -oP 'subtitle:\s*\K[0-9.]+' <<< "$stats")
    # ffmpeg reports KiB (spelled kB before version 7).
    awk -v a="$audio" -v s="$subs" 'BEGIN { printf "%d", (a + s) * 1024 }'
}

# True when FILE lasts as long as the source, give or take two seconds, and
# (with "full") reads through to the end: Matroska keeps the duration in its
# header, so a cut-off file still reports the full length. The read copies the
# streams without decoding, about a minute for a full disc. Only input-side
# errors count; the null output warns about harmless timestamps.
encode_complete() {
    local got errors
    got=$(duration_of "$1" 2>/dev/null) || return 1
    awk -v a="$got" -v b="$DURATION" 'BEGIN { d = a - b; exit !(a > 0 && d < 2 && d > -2) }' ||
        return 1
    [[ ${2:-} == full ]] || return 0
    errors=$(ffmpeg -nostdin -hide_banner -v error -i "$1" -map 0 -c copy -f null - 2>&1) ||
        return 1
    ! grep -q '^\[in#' <<< "$errors"
}

# --------------------------------------------------------------- encoders

# The ffmpeg video-encoder arguments for OPTION (an x265 preset or nvenc).
encoder_args() {
    if [[ $1 == nvenc ]]; then
        printf '%s\n' -c:v hevc_nvenc -preset p7 -tune hq -rc vbr -multipass fullres \
            -b:v "${VIDEO_KBPS}k" -profile:v main10 -pix_fmt p010le
    else
        printf '%s\n' -c:v libx265 -preset "$1" -b:v "${VIDEO_KBPS}k" -pix_fmt yuv420p10le
    fi
}

# x265 runs twice over the film; NVENC does its passes within a single run.
encoder_runs() { [[ $1 == nvenc ]] && echo 1 || echo 2; }

option_title() {
    [[ $1 == nvenc ]] && echo "NVENC p7 (GPU)" || echo "x265 $1"
}

# True when the GPU encoder is present and actually works here.
nvenc_works() {
    local caps
    caps=$(ffmpeg -hide_banner -encoders 2>/dev/null) || return 1
    grep -q ' hevc_nvenc ' <<< "$caps" || return 1
    ffmpeg -nostdin -v error -f lavfi -i color=black:s=256x256:d=0.2 \
        -c:v hevc_nvenc -profile:v main10 -pix_fmt p010le -f null - 2>/dev/null
}

# Encodes VIDEO into OUTPUT with OPTION, keeping every other stream.
encode() {
    local option=$1 output=$2 part="$2.part.mkv" i codec stats="$WORK/full.stats"
    local -a enc extra=(-map '0:a?' -map '0:s?' -map '0:t?' -map_chapters 0
        -map_metadata 0 -c copy)
    local -a ff=(ffmpeg -nostdin -hide_banner -loglevel error -stats -stats_period 60 -y)
    mapfile -t enc < <(encoder_args "$option")
    # MP4 text subtitles cannot go into Matroska as they are.
    i=0
    while IFS= read -r codec; do
        [[ $codec != mov_text ]] || extra+=("-c:s:$i" srt)
        i=$((i + 1))
    done < <(probe -select_streams s -show_entries stream=codec_name)
    log "Encoding with $(option_title "$option") at ${VIDEO_KBPS} kb/s..."
    # ffmpeg's progress goes to stderr; stdout carries only the final path.
    if [[ $option == nvenc ]]; then
        "${ff[@]}" -i "$VIDEO" -map 0:V:0 "${extra[@]}" "${enc[@]}" "$part" >&2 ||
            { rm -f -- "$part"; die "Encoding failed."; }
    else
        log "Pass 1 of 2..."
        "${ff[@]}" -i "$VIDEO" -map 0:V:0 "${enc[@]}" \
            -x265-params "pass=1:stats=$stats:log-level=error" -an -sn -dn -f null - >&2 ||
            die "Encoding failed in pass 1."
        log "Pass 2 of 2..."
        "${ff[@]}" -i "$VIDEO" -map 0:V:0 "${extra[@]}" "${enc[@]}" \
            -x265-params "pass=2:stats=$stats:log-level=error" "$part" >&2 ||
            { rm -f -- "$part"; die "Encoding failed in pass 2."; }
    fi
    mv -- "$part" "$output"
    encode_complete "$output" ||
        die "The encode lasts $(duration_of "$output")s, the source ${DURATION}s. Kept for inspection: $output"
    log "Encoded: $output ($(human "$(stat -c %s -- "$output")"))."
}

# ------------------------------------------------------------------ choice

# Prints the frames OPTION encodes per second, timed on a clip from the middle
# of the film read straight from the source (so decoding is counted too). The
# rate is taken between progress reports once frames are coming out, so start-up
# and x265's look-ahead delay do not count. Slow presets are stopped after
# PROBE_MAX_SECONDS; one that has output nothing by then fails.
probe_fps() {
    local option=$1 marks="$WORK/probe.marks" pos line start
    local -a enc
    mapfile -t enc < <(encoder_args "$option")
    [[ $option == nvenc ]] || enc+=(-x265-params log-level=error)
    pos=$(awk -v d="$DURATION" 'BEGIN { printf "%.3f", d / 2 }')
    : > "$marks"
    start=$(date +%s.%N)
    # -k: x265 would otherwise finish every frame in its look-ahead first.
    timeout -s INT -k 5 "$PROBE_MAX_SECONDS" ffmpeg -nostdin -v error -y -ss "$pos" \
        -i "$VIDEO" -t "$PROBE_CLIP_SECONDS" -map 0:V:0 "${enc[@]}" \
        -stats_period 1 -progress pipe:1 -f null - 2>/dev/null |
        while IFS= read -r line; do
            [[ $line == frame=* ]] || continue
            printf '%s %s\n' "$(date +%s.%N)" "${line#frame=}"
        done > "$marks" || true
    # A fast encoder can finish the whole clip between two reports; its overall
    # rate is then the measure (start-up included, so on the safe side).
    awk -v s="$start" '$2 > 0 { if (!n++) { t0 = $1; f0 = $2 } t1 = $1; f1 = $2 }
        END {
            if (n >= 2 && f1 > f0 && t1 > t0) printf "%.4f", (f1 - f0) / (t1 - t0)
            else if (n >= 1 && t1 > s) printf "%.4f", f1 / (t1 - s)
            else exit 1
        }' "$marks"
}

# Prints the projected seconds to encode the whole film with OPTION; fails when
# it cannot be timed.
projected_seconds() {
    local option=$1 fps
    fps=$(probe_fps "$option") || return 1
    log "  $(option_title "$option"): $(printf '%.2f' "$fps") fps"
    awk -v f="$FRAMES" -v r="$(encoder_runs "$option")" -v s="$fps" -v p="$PROJECTION_PAD" \
        'BEGIN { printf "%d", f * r / s * p }'
}

# Sets PRESET: the first of the options, least destructive first, whose encode
# plus burn ends within the window; else the last one, late.
choose_preset() {
    local option secs done_at
    local -a options=("${AUTO_OPTIONS[@]}")
    if ! nvenc_works; then
        log "No working NVENC here; x265 $NO_NVENC_FALLBACK takes its place."
        options=("${options[@]/nvenc/$NO_NVENC_FALLBACK}")
    fi
    log "Window: everything done by $(date -d "@$WINDOW_END" '+%a %d/%m %H:%M') (burn and verify ~$(hms "$BURN_SECONDS"))."
    log "Timing each option on a ${PROBE_CLIP_SECONDS}s clip (up to ${PROBE_MAX_SECONDS}s each)..."
    local chosen='' last=''
    for option in "${options[@]}"; do
        if ! secs=$(projected_seconds "$option"); then
            log "  $(option_title "$option"): nothing out within ${PROBE_MAX_SECONDS}s; too slow."
            continue
        fi
        done_at=$(( $(now) + secs + BURN_SECONDS ))
        local verdict="fits"
        (( done_at <= WINDOW_END )) || verdict="past the window"
        log "  -> encode ~$(hms "$secs"), all done ~$(date -d "@$done_at" '+%a %d/%m %H:%M') ($verdict)"
        last=$option
        if [[ -z $chosen && $verdict == fits ]]; then
            chosen=$option
            # --estimate times every option; a real run stops at the first fit.
            [[ $ESTIMATE_ONLY == yes ]] || break
        fi
    done
    [[ -n $last ]] || die "No encoder could be timed."
    if [[ -n $chosen ]]; then
        PRESET=$chosen
        log "Chosen: $(option_title "$PRESET"), the least destructive option that fits."
    else
        # The options run slowest first, so the last one timed is the fastest.
        PRESET=$last
        log "WARNING: nothing fits the window; $(option_title "$PRESET") is the fastest, and finishes late."
    fi
}

# ------------------------------------------------------------------- main

parse_args() {
    VIDEO=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --device|--hours|--preset|--output)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
                case $1 in
                    --device) DEVICE=$2 ;; --hours) HOURS=$2 ;;
                    --preset) FORCE_PRESET=$2 ;; --output) OUTPUT=$2 ;;
                esac
                shift 2 ;;
            --estimate) ESTIMATE_ONLY=yes; shift ;;
            -*) die "Unknown option: $1 (see --help)." ;;
            *) [[ -z $VIDEO ]] || die "Give one video only."; VIDEO=$1; shift ;;
        esac
    done
    [[ -n $VIDEO ]] || { usage >&2; exit 1; }
    [[ -f $VIDEO ]] || die "Not a file: $VIDEO"
    VIDEO=$(realpath -- "$VIDEO")
    [[ $HOURS =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--hours wants a number, e.g. 8 or 6.5"
    if [[ -n $FORCE_PRESET && $FORCE_PRESET != nvenc &&
        " ${X265_PRESETS[*]} " != *" $FORCE_PRESET "* ]]; then
        die "Unknown preset: $FORCE_PRESET (an x265 preset, or nvenc)."
    fi
}

preflight() {
    local bin caps
    for bin in ffmpeg ffprobe awk timeout; do
        command -v "$bin" >/dev/null || die "Missing command: $bin"
    done
    [[ -x $BD_BURN ]] || die "bd-burn.sh is missing next to this script: $BD_BURN"
    # Captured first: grep -q quitting early would SIGPIPE ffmpeg under pipefail.
    caps=$(ffmpeg -hide_banner -encoders 2>/dev/null) || caps=''
    grep -q ' libx265 ' <<< "$caps" ||
        die "This ffmpeg has no libx265 (install ffmpeg from RPM Fusion)."
    if [[ $FORCE_PRESET == nvenc ]]; then
        nvenc_works || die "NVENC was asked for, but it does not work here."
    fi
}

main() {
    local start
    start=$(now)
    parse_args "$@"
    # An encode runs for hours; GNOME would suspend an idle machine meanwhile.
    if [[ -z ${BD_INHIBITED:-} && $ESTIMATE_ONLY == no ]] &&
        command -v systemd-inhibit >/dev/null; then
        BD_INHIBITED=1 exec systemd-inhibit --what=sleep:idle --who=bd-encode \
            --why="Encoding a video for a disc" bash "${BASH_SOURCE[0]}" "$@"
    fi
    preflight
    WINDOW_END=$(awk -v s="$start" -v h="$HOURS" 'BEGIN { printf "%d", s + h * 3600 }')

    local -a dev=()
    [[ -z $DEVICE ]] || dev=(--device "$DEVICE")
    local free
    free=$("$BD_BURN" --free "${dev[@]}") || die "No writable disc in the drive."
    log "Disc free space: $(human "$free")."

    [[ $(probe -select_streams V:0 -show_entries stream=codec_type) == video ]] ||
        die "No video stream in $VIDEO."
    local name=${VIDEO##*/} stem rc=0
    stem=${name%.*}
    "$BD_BURN" --check "${dev[@]}" --name "$name" "$VIDEO" 2>/dev/null || rc=$?
    case $rc in
        0)
            log "$name ($(human "$(stat -c %s -- "$VIDEO")")) already fits on the disc. Nothing to do."
            exit "$ALREADY_FITS" ;;
        3) ;;
        *) die "Cannot work out whether $name fits on the disc." ;;
    esac

    DURATION=$(duration_of "$VIDEO")
    [[ $DURATION =~ ^[0-9.]+$ ]] || die "Cannot read the duration of $name."
    local temp_dir
    temp_dir="$(videos_dir)/temp"
    [[ -n $OUTPUT ]] || OUTPUT="$temp_dir/$stem.bd.mkv"
    mkdir -p -- "$temp_dir" "$(dirname -- "$OUTPUT")"

    if [[ -e $OUTPUT ]]; then
        # Left by an earlier run whose burn failed. encode() names it only
        # once ffmpeg has succeeded; it is read through again anyway.
        log "Found an encode from an earlier run; checking it reads through to the end..."
        encode_complete "$OUTPUT" full ||
            die "$OUTPUT is left from an earlier run but is not a complete encode of $name; remove it to encode again."
        log "Reusing the encode from an earlier run: $OUTPUT ($(human "$(stat -c %s -- "$OUTPUT")")); not encoding again."
        [[ $ESTIMATE_ONLY == yes ]] || printf '%s\n' "$OUTPUT"
        exit 0
    fi

    FRAMES=$(probe -select_streams V:0 -show_entries stream=avg_frame_rate |
        awk -F/ -v d="$DURATION" '{ printf "%d", d * ($2 > 0 ? $1 / $2 : $1) }')
    local copied target
    copied=$(copied_stream_bytes)
    target=$(awk -v f="$free" -v r="$FS_RESERVE" -v s="$SIZE_SAFETY_PERMILLE" \
        'BEGIN { printf "%d", (f - 2 * r) * (1 - s / 1000) }')
    VIDEO_KBPS=$(awk -v t="$target" -v c="$copied" -v d="$DURATION" \
        'BEGIN { printf "%d", (t - c) * 8 / d / 1000 }')
    log "$name is $(human "$(stat -c %s -- "$VIDEO")"); target $(human "$target") ($(human "$copied") of it audio/subtitles, copied as-is)."
    (( VIDEO_KBPS >= MIN_VIDEO_KBPS )) ||
        die "That leaves only ${VIDEO_KBPS} kb/s for the picture; too little to be worth it."
    log "Video bitrate: ${VIDEO_KBPS} kb/s."
    BURN_SECONDS=$((2 * target / BURN_BYTES_PER_SEC + BURN_FIXED_SECONDS))

    # x265 stats and timing scratch go on the same disk as the videos.
    WORK=$(mktemp -d "$temp_dir/.bd-encode.XXXXXX")
    trap 'rm -rf -- "$WORK"' EXIT

    if [[ -n $FORCE_PRESET ]]; then
        PRESET=$FORCE_PRESET
        log "Using $(option_title "$PRESET") as asked."
    else
        choose_preset
    fi
    if [[ $ESTIMATE_ONLY == yes ]]; then
        log "Estimate only; nothing was encoded."
        exit 0
    fi
    encode "$PRESET" "$OUTPUT"
    printf '%s\n' "$OUTPUT"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
