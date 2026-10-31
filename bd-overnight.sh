#!/usr/bin/env bash
#
# bd-overnight.sh - shrinks a video just enough to fill the Blu-ray in the
# drive, burns it, verifies the burn and powers the computer off. Meant to be
# started before bed. Linux (Fedora/GNOME) only.
#
#   1. A source on an external drive is moved into ~/Videos/temp with rsync
#      (the source file is removed), then that drive is unmounted and powered
#      down. A source on an internal disk is used where it is.
#   2. The disc's free space is read. No writable disc: stop.
#   3. A video that already fits on the disc is left alone: nothing is encoded
#      or burned, and the computer stays on.
#   4. Otherwise the HEVC bitrate that fills the disc is worked out from the
#      duration and the size of the audio/subtitles, which are copied as-is.
#   5. Each encoder option (x265 medium ... placebo, and NVENC when the GPU has
#      it) is timed on a short clip of the film, and the user picks one from a
#      menu showing the estimated time and when everything would be done.
#   6. The video is encoded at that bitrate as 10-bit HEVC (x265: two passes;
#      NVENC: full-resolution multipass in one run).
#   7. It is burned, and the burn is read back and checked against its MD5.
#      Only then is the computer powered off.
#
# Usage: bd-overnight.sh [options] VIDEO     (see --help)

set -euo pipefail
# Decimal points, whatever the desktop locale (printf %f rejects "2.5" in pt_BR).
export LC_NUMERIC=C

DEVICE=""
DEADLINE="07:00"
FORCE_PRESET=""
LABEL=""
SHUTDOWN=yes
ESTIMATE_ONLY=no

# Least to most effort. x265 presets get slower and lose less down the list;
# nvenc is the GPU's encoder: far faster, slightly more loss than x265.
X265_PRESETS=(medium slow slower veryslow placebo)
# The clip each option is timed on, and how long any one option may be timed.
PROBE_CLIP_SECONDS=6
PROBE_MAX_SECONDS=90
# Timing a short clip is a rough guide; pad the projection.
PROJECTION_PAD=1.10

# Left free after a burn (xorriso warns the real figure may be a few MB lower);
# the target also sets this much aside again for the ISO metadata itself.
FS_RESERVE=$((16 * 1024 * 1024))
SIZE_SAFETY_PERMILLE=20              # muxing overhead and rate-control error
BURN_BYTES_PER_SEC=$((18 * 1000 * 1000))  # BD 4x; writing and reading back
BURN_FIXED_SECONDS=600               # spin-up, lead-in, closing the session
MIN_VIDEO_KBPS=300
ISO_OPTS=(-joliet on -compliance iso_9660_level=3:joliet_long_names)

log() { printf '[bd-overnight %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
notify() {
    command -v notify-send >/dev/null || return 0
    notify-send --app-name="bd-overnight" --urgency=critical -- "$1" "$2" 2>/dev/null || true
}
die() { log "ERROR: $*"; notify "Blu-ray job failed" "$*"; exit 1; }

human() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }
hms() { printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60)); }
now() { date +%s; }

usage() {
    cat <<HELP
Usage: ${0##*/} [options] VIDEO

Shrinks VIDEO just enough to fill the Blu-ray in the drive, burns it, checks
the burn and powers the computer off. A VIDEO that already fits is left alone.
A VIDEO on an external drive is first moved into ~/Videos/temp and the drive
is powered down.

Before encoding, every option is timed on a short clip and a menu shows how
long each would take; you pick one.

Options:
  --device DEV     optical drive (default: /dev/sr0, else the first /dev/sr*);
                   stdio:/path/file.iso writes an image file instead (testing)
  --deadline HH:MM the menu's default is the slowest option done by then
                   (default 07:00)
  --preset NAME    skip the menu: ${X265_PRESETS[*]} (x265), or nvenc
  --estimate       show the menu with its time estimates, then stop; nothing
                   is moved, encoded or burned
  --label TEXT     disc label (default: the file name, cut to 32 characters)
  --no-shutdown    leave the computer on afterwards
  -h, --help       this text

Log: \${XDG_STATE_HOME:-~/.local/state}/bd-overnight/
HELP
}

# ----------------------------------------------------------------- source

videos_dir() {
    local dir
    dir=$(xdg-user-dir VIDEOS 2>/dev/null) || dir=""
    [[ -n $dir && $dir != "$HOME" ]] || dir="$HOME/Videos"
    printf '%s\n' "$dir"
}

# The whole-disk device behind a partition: /dev/sdb for /dev/sdb1.
parent_disk() {
    local parent
    parent=$(lsblk -dnro PKNAME -- "$1" 2>/dev/null) || parent=''
    [[ -n $parent ]] || { printf '%s\n' "$1"; return 0; }
    printf '/dev/%s\n' "$parent"
}

# A USB stick or external disk, never an internal one.
removable_drive() {
    local transport removable hotplug
    transport=$(lsblk -dnro TRAN -- "$1" 2>/dev/null) || transport=''
    removable=$(lsblk -dnro RM -- "$1" 2>/dev/null) || removable=''
    hotplug=$(lsblk -dnro HOTPLUG -- "$1" 2>/dev/null) || hotplug=''
    [[ $transport == usb || $removable == 1 || $hotplug == 1 ]]
}

# Prints the block device FILE lives on, when that is an external drive.
external_device() {
    local dev mnt
    dev=$(findmnt -no SOURCE -T "$1" 2>/dev/null) || return 1
    dev=${dev%%\[*}             # btrfs subvolumes read /dev/sdb1[/vol]
    mnt=$(findmnt -no TARGET -T "$1" 2>/dev/null) || mnt=''
    [[ $dev == /dev/* ]] || return 1
    if [[ $mnt == /run/media/* ]] || removable_drive "$(parent_disk "$dev")"; then
        printf '%s\n' "$dev"
        return 0
    fi
    return 1
}

# Unmounts DEV and powers its drive down so it can just be unplugged.
release_drive() {
    local dev=$1 parent
    sync
    if ! udisksctl unmount --no-user-interaction -b "$dev" >/dev/null 2>&1; then
        log "Could not unmount $dev; eject it from Files before unplugging."
        return 0
    fi
    parent=$(parent_disk "$dev")
    # UDisks refuses an unsafe power-off, e.g. with another partition mounted.
    if udisksctl power-off --no-user-interaction -b "$parent" >/dev/null 2>&1; then
        log "$parent is powered down; safe to unplug."
    else
        log "$dev is unmounted, but powering $parent down failed. Check its other partitions."
    fi
}

# Sets VIDEO: the source itself, or its new home in ~/Videos/temp.
grab_source() {
    local src=$1 dev dest
    if ! dev=$(external_device "$src"); then
        log "Source is on an internal disk; using it where it is."
        VIDEO=$src
        return 0
    fi
    mkdir -p -- "$TEMP_DIR" || die "Cannot create $TEMP_DIR."
    dest="$TEMP_DIR/${src##*/}"
    [[ ! -e $dest ]] || die "$dest already exists; nothing was moved. Remove it, or run on it directly."
    log "Moving ${src##*/} off $dev into $TEMP_DIR..."
    # rsync checks every file against its checksum after transfer, and only
    # removes the source once that has succeeded.
    rsync -t --fsync --remove-source-files --info=progress2 -- "$src" "$dest" ||
        die "Moving ${src##*/} failed; the source is still on the drive."
    VIDEO=$dest
    release_drive "$dev"
}

# ------------------------------------------------------------------- disc

# Prints the free space on the disc in bytes; fails without a writable disc.
media_space_bytes() {
    local out sectors status
    out=$(xorriso -outdev "$DEVICE" -tell_media_space 2>&1) || true
    status=$(grep -m1 '^Media status' <<< "$out" || true)
    sectors=$(grep -oP '^Media space\s*:\s*\K[0-9]+(?=s)' <<< "$out" || true)
    [[ -z $status ]] || log "$status"
    [[ -n $sectors && $sectors -gt 0 ]] || return 1
    printf '%s\n' $((sectors * 2048))
}

# Prints the bytes that would be left after burning FILE as /NAME, negative
# when it does not fit. xorriso does the sum, filesystem overhead and older
# sessions included; -rollback_end makes sure nothing is written.
space_after_burn() {
    local out after
    out=$(xorriso -dev "$DEVICE" "${ISO_OPTS[@]}" -map "$1" "/$2" \
        -tell_media_space -rollback_end 2>&1) || true
    after=$(grep -oP '^After commit\s*:\s*\K-?[0-9]+(?=s)' <<< "$out" || true)
    [[ -n $after ]] || { log "$out"; return 1; }
    printf '%s\n' $((after * 2048))
}

fits_on_disc() {
    local after
    after=$(space_after_burn "$1" "$2") || die "Cannot work out whether ${2} fits on the disc."
    (( after >= FS_RESERVE ))
}

burn() {
    local file=$1 name=$2 out
    log "Burning $name to $DEVICE (label '$LABEL')..."
    xorriso -abort_on FAILURE -md5 on -dev "$DEVICE" -overwrite off -volid "$LABEL" \
        "${ISO_OPTS[@]}" -map "$file" "/$name" -commit ||
        die "Burning failed. The encoded file is kept: $file"
    log "Reading the disc back to check it..."
    if ! out=$(xorriso -md5 on -indev "$DEVICE" -return_with FAILURE 32 \
        -check_md5 FAILURE "/$name" -- 2>&1) ||
        ! grep -q '^md5 match' <<< "$out"; then
        log "$out"
        die "The disc does not match $name. The encoded file is kept: $file"
    fi
    log "Disc verified: $name matches its MD5."
    xorriso -outdev "$DEVICE" -eject all >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------- probe

probe() {
    ffprobe -v error "$@" -of default=nw=1:nk=1 -- "$VIDEO"
}

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

# Encodes FILE in place of OUTPUT with OPTION, keeping every other stream.
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
    if [[ $option == nvenc ]]; then
        "${ff[@]}" -i "$VIDEO" -map 0:V:0 "${extra[@]}" "${enc[@]}" "$part" ||
            { rm -f -- "$part"; die "Encoding failed."; }
    else
        log "Pass 1 of 2..."
        "${ff[@]}" -i "$VIDEO" -map 0:V:0 "${enc[@]}" \
            -x265-params "pass=1:stats=$stats:log-level=error" -an -sn -dn -f null - ||
            die "Encoding failed in pass 1."
        log "Pass 2 of 2..."
        "${ff[@]}" -i "$VIDEO" -map 0:V:0 "${extra[@]}" "${enc[@]}" \
            -x265-params "pass=2:stats=$stats:log-level=error" "$part" ||
            { rm -f -- "$part"; die "Encoding failed in pass 2."; }
    fi
    mv -- "$part" "$output"
    local got
    got=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$output")
    awk -v a="$got" -v b="$DURATION" 'BEGIN { d = a - b; exit !(d < 2 && d > -2) }' ||
        die "The encode lasts ${got}s, the source ${DURATION}s. Kept for inspection: $output"
    log "Encoded: $output ($(human "$(stat -c %s -- "$output")"))."
}

# ------------------------------------------------------------------ menu

# Prints the frames OPTION encodes per second, timed on a clip from the middle
# of the film read straight from the source (so decoding is counted too). The
# rate is taken between progress reports once frames are coming out, so start-up
# and x265's look-ahead delay do not count. Slow presets are stopped after
# PROBE_MAX_SECONDS; one that has not output two reports by then fails.
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

# Times every option, prints the menu and sets PRESET: the user's choice, or
# with --estimate stops after the menu.
choose_preset() {
    local option fps secs done_at fits default='' i=0 frames choice
    local -a options=("${X265_PRESETS[@]}") shown=() estimate=()
    if nvenc_works; then options+=(nvenc); else log "No working NVENC on this machine."; fi
    frames=$(awk -v d="$DURATION" -v r="$FRAME_RATE" 'BEGIN { printf "%d", d * r }')
    log "Timing each option on a ${PROBE_CLIP_SECONDS}s clip (up to $((PROBE_MAX_SECONDS / 60))m$((PROBE_MAX_SECONDS % 60))s each)..."
    for option in "${options[@]}"; do
        if ! fps=$(probe_fps "$option"); then
            log "  $(option_title "$option"): no frames within ${PROBE_MAX_SECONDS}s, so too slow to time; left out."
            continue
        fi
        secs=$(awk -v f="$frames" -v r="$(encoder_runs "$option")" -v s="$fps" -v p="$PROJECTION_PAD" \
            'BEGIN { printf "%d", f * r / s * p }')
        log "  $(option_title "$option"): $(printf '%.2f' "$fps") fps"
        shown+=("$option")
        estimate+=("$secs")
    done
    [[ ${#shown[@]} -gt 0 ]] || die "No encoder could be timed."
    # Default: the slowest x265 preset done by the deadline, else the fastest
    # option of all.
    for ((i = 0; i < ${#shown[@]}; i++)); do
        [[ ${shown[$i]} != nvenc ]] || continue
        (( $(now) + estimate[i] + BURN_SECONDS <= DEADLINE_TS )) && default=$((i + 1))
    done
    if [[ -z $default ]]; then
        default=1
        for ((i = 1; i < ${#shown[@]}; i++)); do
            (( estimate[i] < estimate[default - 1] )) && default=$((i + 1))
        done
    fi
    {
        echo
        echo "Encode at ${VIDEO_KBPS} kb/s; done at = encode + burn and verify (~$(hms "$BURN_SECONDS"))."
        printf '  %-2s %-16s %12s   %-16s\n' '#' 'Option' 'Encode' 'All done at'
        for ((i = 0; i < ${#shown[@]}; i++)); do
            done_at=$(( $(now) + estimate[i] + BURN_SECONDS ))
            fits=''
            (( done_at <= DEADLINE_TS )) || fits="  after $DEADLINE"
            [[ $((i + 1)) != "$default" ]] || fits+="  <- default"
            printf '  %-2s %-16s %12s   %-16s%s\n' "$((i + 1))" "$(option_title "${shown[$i]}")" \
                "~$(hms "${estimate[i]}")" "$(date -d "@$done_at" '+%a %d/%m %H:%M')" "$fits"
        done
        echo "Slower x265 presets lose less detail. NVENC is far faster with slightly"
        echo "more loss than x265; at light compression the difference is not visible."
        echo
    } >&2
    if [[ $ESTIMATE_ONLY == yes ]]; then
        log "Estimate only; nothing was moved, encoded or burned."
        exit 0
    fi
    [[ -r /dev/tty ]] || die "No terminal to show the menu on; pass --preset NAME (see --estimate)."
    while true; do
        read -r -p "Choose 1-${#shown[@]} [Enter = $default]: " choice < /dev/tty || choice=''
        choice=${choice:-$default}
        [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#shown[@]} )) && break
        echo "Type a number from 1 to ${#shown[@]}." >&2
    done
    PRESET=${shown[choice - 1]}
    log "Chosen: $(option_title "$PRESET") (~$(hms "${estimate[choice - 1]}"))."
}

# ------------------------------------------------------------------- main

power_off() {
    log "Powering off in 60 seconds (Ctrl-C to cancel)."
    notify "Blu-ray done" "Burned and verified. Powering off in 60 seconds."
    sleep 60
    systemctl poweroff
}

parse_args() {
    SOURCE=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --device|--deadline|--preset|--label)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
                case $1 in
                    --device) DEVICE=$2 ;; --deadline) DEADLINE=$2 ;;
                    --preset) FORCE_PRESET=$2 ;; --label) LABEL=$2 ;;
                esac
                shift 2 ;;
            --no-shutdown) SHUTDOWN=no; shift ;;
            --estimate) ESTIMATE_ONLY=yes; shift ;;
            -*) die "Unknown option: $1 (see --help)." ;;
            *) [[ -z $SOURCE ]] || die "Give one video only."; SOURCE=$1; shift ;;
        esac
    done
    [[ -n $SOURCE ]] || { usage >&2; exit 1; }
    [[ -f $SOURCE ]] || die "Not a file: $SOURCE"
    SOURCE=$(realpath -- "$SOURCE")
    if [[ -n $FORCE_PRESET && $FORCE_PRESET != nvenc &&
        " ${X265_PRESETS[*]} " != *" $FORCE_PRESET "* ]]; then
        die "Unknown preset: $FORCE_PRESET (${X265_PRESETS[*]} nvenc)."
    fi
}

preflight() {
    local bin caps
    for bin in ffmpeg ffprobe xorriso rsync udisksctl findmnt lsblk awk systemctl timeout; do
        command -v "$bin" >/dev/null || die "Missing command: $bin"
    done
    # Captured first: grep -q quitting early would SIGPIPE ffmpeg under pipefail.
    caps=$(ffmpeg -hide_banner -encoders 2>/dev/null) || caps=''
    grep -q ' libx265 ' <<< "$caps" ||
        die "This ffmpeg has no libx265 (install ffmpeg from RPM Fusion)."
    if [[ $FORCE_PRESET == nvenc ]]; then
        nvenc_works || die "NVENC was asked for, but it does not work here."
    fi
    if [[ -z $DEVICE ]]; then
        DEVICE=/dev/sr0
        [[ -e $DEVICE ]] || DEVICE=$(compgen -G '/dev/sr*' | head -1 || true)
        [[ -n $DEVICE ]] || DEVICE=/dev/sr0
    fi
    [[ $DEVICE == stdio:* || -e $DEVICE ]] || die "No optical drive at $DEVICE."
    DEADLINE_TS=$(date -d "$DEADLINE" +%s 2>/dev/null) || die "Bad deadline: $DEADLINE (use HH:MM)."
    (( DEADLINE_TS > $(now) )) || DEADLINE_TS=$(date -d "tomorrow $DEADLINE" +%s)
}

main() {
    parse_args "$@"
    # GNOME suspends an idle machine after a while; hold that off all night.
    if [[ -z ${BD_OVERNIGHT_INHIBITED:-} && $ESTIMATE_ONLY == no ]] &&
        command -v systemd-inhibit >/dev/null; then
        BD_OVERNIGHT_INHIBITED=1 exec systemd-inhibit --what=sleep:idle \
            --who=bd-overnight --why="Encoding and burning a Blu-ray" \
            bash "${BASH_SOURCE[0]}" "$@"
    fi
    local log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/bd-overnight"
    mkdir -p -- "$log_dir"
    LOG_FILE="$log_dir/$(date +%F_%H%M%S).log"
    exec > >(tee -a -- "$LOG_FILE") 2>&1
    log "Log: $LOG_FILE"

    preflight
    TEMP_DIR="$(videos_dir)/temp"

    # Checked before anything is moved, so a missing disc leaves the drive alone.
    local free
    free=$(media_space_bytes) || die "No writable disc in $DEVICE."
    log "Disc free space: $(human "$free")."

    if [[ $ESTIMATE_ONLY == yes ]]; then
        VIDEO=$SOURCE
    else
        grab_source "$SOURCE"
    fi
    [[ $(probe -select_streams V:0 -show_entries stream=codec_type) == video ]] ||
        die "No video stream in $VIDEO."
    local name=${VIDEO##*/} stem
    stem=${name%.*}
    # Spaces and the like make a poor automatic mount-point name.
    if [[ -z $LABEL ]]; then LABEL=${stem//[^A-Za-z0-9_-]/_}; LABEL=${LABEL:0:32}; fi

    if fits_on_disc "$VIDEO" "$name"; then
        log "$name ($(human "$(stat -c %s -- "$VIDEO")")) already fits on the disc. Nothing to do."
        notify "Blu-ray job: nothing to do" "$name already fits on the disc; it was not burned."
        return 0
    fi

    DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 -- "$VIDEO")
    [[ $DURATION =~ ^[0-9.]+$ ]] || die "Cannot read the duration of $name."
    FRAME_RATE=$(probe -select_streams V:0 -show_entries stream=avg_frame_rate |
        awk -F/ '{ printf "%.6f", ($2 > 0 ? $1 / $2 : $1) }')
    local copied target
    copied=$(copied_stream_bytes)
    target=$(awk -v f="$free" -v r="$FS_RESERVE" -v s="$SIZE_SAFETY_PERMILLE" \
        'BEGIN { printf "%d", (f - 2 * r) * (1 - s / 1000) }')
    VIDEO_KBPS=$(awk -v t="$target" -v c="$copied" -v d="$DURATION" \
        'BEGIN { printf "%d", (t - c) * 8 / d / 1000 }')
    log "$name is $(human "$(stat -c %s -- "$VIDEO")"); target $(human "$target") ($(human "$copied") of it audio/subtitles, copied as-is)."
    (( VIDEO_KBPS >= MIN_VIDEO_KBPS )) ||
        die "That leaves only ${VIDEO_KBPS} kb/s for the picture; too little to be worth it."
    log "Video bitrate: ${VIDEO_KBPS} kb/s. Deadline: $(date -d "@$DEADLINE_TS" '+%a %H:%M')."
    BURN_SECONDS=$((2 * target / BURN_BYTES_PER_SEC + BURN_FIXED_SECONDS))

    mkdir -p -- "$TEMP_DIR"
    local output="$TEMP_DIR/$stem.bd.mkv"
    [[ $ESTIMATE_ONLY == yes || ! -e $output ]] ||
        die "$output already exists; remove it or burn it yourself."
    # x265 stats and timing scratch go on the same disk as the videos.
    WORK=$(mktemp -d "$TEMP_DIR/.bd-overnight.XXXXXX")
    trap 'rm -rf -- "$WORK"' EXIT

    if [[ -n $FORCE_PRESET ]]; then
        PRESET=$FORCE_PRESET
        log "Using $(option_title "$PRESET") as asked; no menu."
    else
        choose_preset
    fi
    encode "$PRESET" "$output"

    local burned_name="$stem.mkv"
    fits_on_disc "$output" "$burned_name" ||
        die "The encode came out too big for the disc. Kept: $output"
    burn "$output" "$burned_name"
    notify "Blu-ray done" "$burned_name was burned and verified."
    log "Done. Source kept at $VIDEO; encode kept at $output."

    if [[ $SHUTDOWN == yes ]]; then
        power_off
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
