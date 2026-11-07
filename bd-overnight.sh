#!/usr/bin/env bash
#
# bd-overnight.sh - the overnight job: fits a video onto the disc in the drive
# (or onto several, one fewer than it takes as it is) and burns it, then powers
# the computer off. A thin wrapper around bd-encode.sh, bd-split.sh and
# bd-burn.sh, which also work on their own. Linux (Fedora/GNOME) only.
#
#   1. Asks for the disc label up front, so nothing is left to ask later.
#   2. Checks there is a writable disc, before anything is moved.
#   3. A source on an external drive is moved into ~/Videos/temp with rsync
#      (the source file is removed), then that drive is unmounted and powered
#      down. A source on an internal disk is used where it is.
#   4. bd-encode.sh shrinks it to fill the disc, choosing the least destructive
#      encoder that lets encode + burn finish within the window (default 8 h).
#      A video that takes several discs is shrunk onto one fewer (or --discs).
#      A video that already fits on one disc is left alone: nothing is burned,
#      and the computer stays on.
#   5. One disc: bd-burn.sh burns the encode under the label and reads it back
#      against its MD5. Only then is the encode deleted and the computer
#      powered off. After a failed burn the encode is kept, and the next run
#      burns it as it is, without encoding again.
#   6. Several discs: bd-split.sh splits the encode into zip volumes in
#      ~/Videos/temp/NAME.discs, and the encode is deleted. bd-burn.sh --each
#      burns the first disc, then waits, watching the drive, for each next
#      blank disc (a notification asks for it). Each volume is deleted once its
#      disc is verified; the computer powers off after the last. A rerun after
#      a failure burns the volumes still there, without encoding again.
#
# Usage: bd-overnight.sh [options] VIDEO     (see --help)

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
BD_ENCODE="$SCRIPT_DIR/bd-encode.sh"
BD_BURN="$SCRIPT_DIR/bd-burn.sh"
BD_SPLIT="$SCRIPT_DIR/bd-split.sh"

DEVICE=""
HOURS=8
LABEL=""
PRESET=""
DISCS=""
SPEED=""
SHUTDOWN=yes
ALREADY_FITS=3

log() { printf '[bd-overnight %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
notify() {
    command -v notify-send >/dev/null || return 0
    notify-send --app-name="bd-overnight" --urgency=critical -- "$1" "$2" 2>/dev/null || true
}
die() { log "ERROR: $*"; notify "Blu-ray job failed" "$*"; exit 1; }
now() { date +%s; }

usage() {
    cat <<HELP
Usage: ${0##*/} [options] VIDEO

The overnight job: asks for the disc label, moves VIDEO off an external drive
into ~/Videos/temp, shrinks it to fill the disc in the drive (bd-encode.sh),
burns and verifies it (bd-burn.sh), deletes the encode and powers off. A VIDEO
that already fits on the disc is left alone, and the computer stays on.

A VIDEO that takes several discs is shrunk onto one disc fewer, split into zip
volumes (bd-split.sh) and burned one per disc: the first right away, each next
one once a blank disc goes in (a notification asks for it). Every disc is taken
to be the same size as the one in the drive. A rerun after a failure carries
on with the discs still to burn.

Options:
  --device DEV   optical drive (default: /dev/sr0, else the first /dev/sr*);
                 stdio:/path/file.iso writes an image file instead (testing)
  --label TEXT   disc label, up to 32 characters (default: asked first)
  --discs N      fill N discs (default: one fewer than VIDEO takes as it is)
  --hours H      encode + burn must fit in this many hours (default $HOURS);
                 with several discs, only the first one's burn is counted
  --preset NAME  skip the encoder choice: an x265 preset, or nvenc
  --speed N      burn at most at Nx (e.g. 4); default: the drive's maximum
  --no-shutdown  leave the computer on afterwards
  -h, --help     this text

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
    local src=$1 dev dest temp_dir
    if ! dev=$(external_device "$src"); then
        log "Source is on an internal disk; using it where it is."
        VIDEO=$src
        return 0
    fi
    temp_dir="$(videos_dir)/temp"
    mkdir -p -- "$temp_dir" || die "Cannot create $temp_dir."
    dest="$temp_dir/${src##*/}"
    [[ ! -e $dest ]] || die "$dest already exists; nothing was moved. Remove it, or run on it directly."
    log "Moving ${src##*/} off $dev into $temp_dir..."
    # rsync checks every file against its checksum after transfer, and only
    # removes the source once that has succeeded.
    rsync -t --fsync --remove-source-files --info=progress2 -- "$src" "$dest" ||
        die "Moving ${src##*/} failed; the source is still on the drive."
    VIDEO=$dest
    release_drive "$dev"
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
            --device|--label|--discs|--hours|--preset|--speed)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
                case $1 in
                    --device) DEVICE=$2 ;; --label) LABEL=$2 ;; --hours) HOURS=$2 ;;
                    --preset) PRESET=$2 ;; --speed) SPEED=$2 ;; --discs) DISCS=$2 ;;
                esac
                shift 2 ;;
            --no-shutdown) SHUTDOWN=no; shift ;;
            -*) die "Unknown option: $1 (see --help)." ;;
            *) [[ -z $SOURCE ]] || die "Give one video only."; SOURCE=$1; shift ;;
        esac
    done
    [[ -n $SOURCE ]] || { usage >&2; exit 1; }
    [[ -f $SOURCE ]] || die "Not a file: $SOURCE"
    SOURCE=$(realpath -- "$SOURCE")
    [[ $HOURS =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--hours wants a number, e.g. 8 or 6.5"
    [[ -z $DISCS || $DISCS =~ ^[1-9][0-9]*$ ]] || die "--discs wants a number of discs, e.g. 3"
}

# Asks for the label now, while someone is at the keyboard.
ask_label() {
    local stem default reply
    [[ -z $LABEL ]] || return 0
    stem=${SOURCE##*/}
    stem=${stem%.*}
    # Spaces and the like make a poor automatic mount-point name.
    default=${stem//[^A-Za-z0-9_-]/_}
    default=${default:0:32}
    if [[ -r /dev/tty ]]; then
        read -r -p "Disc label [$default]: " reply < /dev/tty || reply=''
    fi
    LABEL=${reply:-$default}
    if [[ ${#LABEL} -gt 32 ]]; then
        LABEL=${LABEL:0:32}
        log "Labels hold 32 characters; it was cut to: $LABEL"
    fi
}

main() {
    local start
    start=$(now)
    parse_args "$@"
    # Asked before anything else, so the rest can run unattended.
    ask_label
    # GNOME suspends an idle machine after a while; hold that off all night.
    # The label goes along, so it is not asked again.
    if [[ -z ${BD_INHIBITED:-} ]] && command -v systemd-inhibit >/dev/null; then
        BD_INHIBITED=1 BD_OVERNIGHT_START=$start exec systemd-inhibit --what=sleep:idle \
            --who=bd-overnight --why="Encoding and burning a disc" \
            bash "${BASH_SOURCE[0]}" "$@" --label "$LABEL"
    fi
    start=${BD_OVERNIGHT_START:-$start}
    local log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/bd-overnight"
    mkdir -p -- "$log_dir"
    LOG_FILE="$log_dir/$(date +%F_%H%M%S).log"
    exec > >(tee -a -- "$LOG_FILE") 2>&1
    log "Log: $LOG_FILE"
    log "Disc label: $LABEL"

    local bin
    for bin in rsync udisksctl findmnt lsblk systemctl awk; do
        command -v "$bin" >/dev/null || die "Missing command: $bin"
    done
    [[ -x $BD_ENCODE && -x $BD_BURN && -x $BD_SPLIT ]] ||
        die "bd-encode.sh, bd-split.sh and bd-burn.sh must sit next to this script in $SCRIPT_DIR."

    local -a dev=()
    [[ -z $DEVICE ]] || dev=(--device "$DEVICE")
    # Checked before anything is moved, so a missing disc leaves the drive alone.
    "$BD_BURN" --free "${dev[@]}" >/dev/null || die "No writable disc in the drive."

    # The original name, not NAME.bd.mkv, goes on the disc (or in the zip).
    local stem=${SOURCE##*/}
    stem=${stem%.*}
    local name="$stem.mkv" temp_dir set_dir
    temp_dir="$(videos_dir)/temp"
    set_dir="$temp_dir/$stem.discs"

    # A set split by an earlier run that did not get every disc burned.
    if [[ -d $set_dir ]]; then
        log "Found $set_dir from an earlier run; burning what is left of it, without encoding again."
        VIDEO=$SOURCE
        burn_set "$set_dir"
        finish
        return 0
    fi

    grab_source "$SOURCE"

    # What is left of the window once the label and the move have taken theirs.
    local hours_left
    hours_left=$(awk -v s="$start" -v h="$HOURS" -v n="$(now)" \
        'BEGIN { l = (s + h * 3600 - n) / 3600; printf "%.3f", (l > 0 ? l : 0) }')
    local -a encode_args=("${dev[@]}" --hours "$hours_left")
    [[ -z $PRESET ]] || encode_args+=(--preset "$PRESET")
    [[ -z $DISCS ]] || encode_args+=(--discs "$DISCS")
    local encoded rc=0 discs
    encoded=$("$BD_ENCODE" "${encode_args[@]}" "$VIDEO") || rc=$?
    if (( rc == ALREADY_FITS )); then
        discs=$("$BD_SPLIT" "${dev[@]}" --discs-needed "$VIDEO") ||
            die "Cannot work out how many discs ${VIDEO##*/} takes."
        if (( discs == 1 )); then
            log "${VIDEO##*/} already fits on the disc; nothing was encoded or burned."
            notify "Blu-ray job: nothing to do" "${VIDEO##*/} already fits on the disc; it was not burned."
            return 0
        fi
        log "${VIDEO##*/} already fits on $discs discs as it is; splitting it without encoding."
        split_into_set "$VIDEO" "$temp_dir"
        burn_set "$set_dir"
        finish
        return 0
    fi
    (( rc == 0 )) && [[ -f $encoded ]] || die "Encoding failed (bd-encode.sh exited with $rc)."

    discs=$("$BD_SPLIT" "${dev[@]}" --discs-needed "$encoded") ||
        die "Cannot work out how many discs $encoded takes."
    if (( discs > 1 )); then
        split_into_set "$encoded" "$temp_dir"
        # The volumes hold all of it, tested; the encode is not needed again.
        rm -f -- "$encoded"
        burn_set "$set_dir"
        finish
        return 0
    fi

    local -a burn_args=(--yes "${dev[@]}" --label "$LABEL" --name "$name")
    [[ -z $SPEED ]] || burn_args+=(--speed "$SPEED")
    "$BD_BURN" "${burn_args[@]}" "$encoded" ||
        die "Burning failed. The encode is kept ($encoded); run again with a new disc to burn it without encoding."

    rm -f -- "$encoded"
    notify "Blu-ray done" "$name was burned and verified."
    log "Done. Source kept at $VIDEO; the encode was deleted after the verified burn."
    finish
}

# These helpers see main's locals (dev, name) through bash's dynamic scope.

# Splits FILE into DIR/STEM.discs, named after the source.
split_into_set() {
    "$BD_SPLIT" "${dev[@]}" --name "$name" --output-dir "$2" "$1" >/dev/null ||
        die "Splitting ${1##*/} into disc volumes failed."
}

# Burns every volume left in SET_DIR, one per disc, deleting each once its
# disc is verified, so a rerun picks up where this one stopped.
burn_set() {
    local dir=$1 path
    local -a volumes burn_args=(--yes "${dev[@]}" --label "$LABEL" --each)
    [[ -z $SPEED ]] || burn_args+=(--speed "$SPEED")
    shopt -s nullglob
    volumes=("$dir"/*.zip.[0-9][0-9][0-9]*)
    shopt -u nullglob
    if [[ ${#volumes[@]} -eq 0 ]]; then
        rmdir -- "$dir" 2>/dev/null || true
        die "$dir holds no volumes; nothing to burn. Run again to start over."
    fi
    log "Burning ${#volumes[@]} disc(s): ${volumes[*]##*/}"
    "$BD_BURN" "${burn_args[@]}" "${volumes[@]}" | while IFS= read -r path; do
        rm -f -- "$path"
        log "${path##*/} is on its disc, verified; deleted here."
    done || die "Burning failed. The volumes not yet burned are kept in $dir; run again with a blank disc to carry on."
    rmdir -- "$dir" || log "$dir is not empty; left as it is."
    notify "Blu-ray done" "All ${#volumes[@]} disc(s) of $name were burned and verified."
    log "Done. Source kept at $VIDEO; every volume was deleted after its verified burn."
}

finish() {
    if [[ $SHUTDOWN == yes ]]; then
        power_off
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
