#!/usr/bin/env bash
#
# bd-catalog.sh - lists every file on the disc in the optical drive into one
# CSV catalog shared by all discs: one row per file, "id,path", where id is
# the disc label and path is the file's path relative to the disc root.
# Linux (Fedora/GNOME) only.
#
#   1. The disc is mounted through UDisks if it is not already, and ejected
#      once its rows are written, ready for the next one (--no-eject keeps
#      it in, unmounted again if this script mounted it).
#   2. The catalog gets a header the first time, and is only ever added to.
#      A disc whose id is already in it is refused (exit 4, with a desktop
#      notification): nothing is written and the disc stays in the drive, so
#      a second disc with the same label never goes unnoticed.
#   3. The new catalog is written beside the old one and renamed over it, so
#      an interrupted run never leaves it half written.
#
# Usage: bd-catalog.sh [options]     (see --help)

set -euo pipefail

DEVICE=""
LABEL=""
OUTPUT="$HOME/Documents/bd-catalog.csv"
EJECT=1
MOUNTED_BY_US=0
TMP=""
DUPLICATE=4

log() { printf '[bd-catalog %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Stops on an id already catalogued: on the terminal and on the desktop, as
# the run may be unattended.
flag_duplicate() {
    local msg="Disc id '$LABEL' is already in $OUTPUT. Nothing was written."
    log "DUPLICATE: $msg Re-run with --label NEW_ID if it is another disc."
    command -v notify-send >/dev/null &&
        notify-send -u critical "bd-catalog: duplicate disc id" "$msg" 2>/dev/null
    exit "$DUPLICATE"
}

usage() {
    cat <<HELP
Usage: ${0##*/} [options]

Adds the files of the disc in the drive to a single CSV catalog, one row per
file: the disc label (id), then the file's path relative to the disc.
A disc whose id is already in the catalog is refused (exit 4): nothing is
written and the disc is not ejected. Use --label to give it another id.

Options:
  --device DEV   optical drive (default: /dev/sr0, else the first /dev/sr*)
  --output FILE  catalog to write (default: ~/Documents/bd-catalog.csv)
  --label NAME   id to use instead of the disc's own label
  --no-eject     leave the disc in the drive (default: eject when done)
  -h, --help     this help
HELP
}

cleanup() {
    [[ -z $TMP ]] || rm -f -- "$TMP"
    if ((MOUNTED_BY_US)) && ((!EJECT)); then
        udisksctl unmount --no-user-interaction -b "$DEVICE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

# RFC 4180: quote a field only when it holds a comma, quote or line break.
csv_field() {
    local s=$1
    if [[ $s == *[,\"$'\n\r']* ]]; then
        s=${s//\"/\"\"}
        s="\"$s\""
    fi
    printf '%s' "$s"
}

parse_args() {
    while (($#)); do
        case $1 in
            --device|--output|--label)
                [[ $# -ge 2 ]] || die "$1 needs a value"
                case $1 in
                    --device) DEVICE=$2 ;; --output) OUTPUT=$2 ;; --label) LABEL=$2 ;;
                esac
                shift ;;
            --no-eject) EJECT=0 ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "Unknown argument: $1" ;;
        esac
        shift
    done
}

find_device() {
    if [[ -z $DEVICE ]]; then
        DEVICE=/dev/sr0
        [[ -e $DEVICE ]] || DEVICE=$(compgen -G '/dev/sr*' | head -1 || true)
    fi
    [[ -n $DEVICE && -b $DEVICE ]] || die "No optical drive found${DEVICE:+ at $DEVICE}. Try 'ls /dev/sr*'."
}

# Sets MOUNT_POINT, mounting the disc when nobody has.
mount_disc() {
    MOUNT_POINT=$(findmnt -no TARGET -S "$DEVICE" 2>/dev/null | head -1 || true)
    if [[ -z $MOUNT_POINT ]]; then
        log "Mounting $DEVICE..."
        udisksctl mount --no-user-interaction -b "$DEVICE" >/dev/null 2>&1 ||
            die "Could not mount $DEVICE. Is there a disc in the drive?"
        MOUNTED_BY_US=1
        MOUNT_POINT=$(findmnt -no TARGET -S "$DEVICE" | head -1)
    fi
    [[ -d $MOUNT_POINT ]] || die "Disc mounted, but its mount point was not found."
}

read_label() {
    [[ -n $LABEL ]] && return 0
    LABEL=$(lsblk -dno LABEL -- "$DEVICE" 2>/dev/null || true)
    [[ -n $LABEL ]] || LABEL=$(blkid -s LABEL -o value -- "$DEVICE" 2>/dev/null || true)
    [[ -n $LABEL ]] || die "The disc has no label. Give it one with --label NAME."
}

write_catalog() {
    local id dir count=0 rel
    id=$(csv_field "$LABEL")
    dir=$(dirname -- "$OUTPUT")
    mkdir -p -- "$dir"
    TMP=$(mktemp -- "$dir/.bd-catalog.XXXXXX")

    # Header, then every disc already catalogued, as it was.
    if [[ -s $OUTPUT ]]; then
        awk -v p="$id," 'NR > 1 && index($0, p) == 1 { found = 1; exit }
                         END { exit !found }' "$OUTPUT" && flag_duplicate
        cp -- "$OUTPUT" "$TMP"
    else
        printf 'id,path\n' >"$TMP"
    fi

    while IFS= read -r -d '' rel; do
        printf '%s,%s\n' "$id" "$(csv_field "$rel")" >>"$TMP"
        count=$((count + 1))
    done < <(find "$MOUNT_POINT" -type f -printf '%P\0' | sort -z)

    ((count > 0)) || die "No files found on the disc (mounted at $MOUNT_POINT)."
    chmod --reference="$OUTPUT" -- "$TMP" 2>/dev/null || chmod 644 -- "$TMP"
    mv -f -- "$TMP" "$OUTPUT"
    TMP=""
    log "Catalogued $count files from '$LABEL' into $OUTPUT."
}

main() {
    parse_args "$@"
    for bin in udisksctl findmnt lsblk find awk; do
        command -v "$bin" >/dev/null || die "Missing: $bin"
    done
    find_device
    mount_disc
    read_label
    log "Disc '$LABEL' at $MOUNT_POINT"
    exec 9>>"${XDG_RUNTIME_DIR:-/tmp}/bd-catalog.lock"
    flock 9
    write_catalog
    if ((EJECT)); then
        udisksctl unmount --no-user-interaction -b "$DEVICE" >/dev/null 2>&1 || true
        if eject -- "$DEVICE" 2>/dev/null; then
            log "Ejected $DEVICE."
        else
            log "Could not eject $DEVICE; is a program still using the disc?"
        fi
    fi
}

main "$@"
