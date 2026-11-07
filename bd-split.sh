#!/usr/bin/env bash
#
# bd-split.sh - splits a file too big for one disc into zip volumes, one per
# disc, sized to the disc in the optical drive: NAME.zip.001, NAME.zip.002, ...
# The zip only stores (no compression; video does not compress). These are the
# multi-part sets usb-autorun collects from each disc and extracts once the
# last one has arrived. Linux (Fedora/GNOME) only.
#
#   1. The volume size is the free space of the disc in the drive (via
#      bd-burn.sh), less what the filesystem needs. Every disc of the set is
#      taken to be the same as that one, and blank.
#   2. A file that fits on one disc as it is is left alone (exit 3).
#   3. The volumes are written and tested in a staging folder, which then
#      becomes NAME.discs beside the file (or in --output-dir) in one rename:
#      that folder only ever holds a whole, tested set. A folder of its own
#      also keeps usb-autorun, which collects parts in ~/Videos/temp, from
#      taking the set for one that arrived from discs. The volume paths are
#      printed on stdout, in order; everything else goes to stderr.
#
# bd-encode.sh asks this script how much fits on N discs (--payload), so the
# zip's own headers are reckoned in one place.
#
# Usage: bd-split.sh [options] FILE     (see --help)

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
BD_BURN="$SCRIPT_DIR/bd-burn.sh"

DEVICE=""
VOLUME_SIZE=""
NAME=""
OUT_DIR=""
MODE=split
PAYLOAD_DISCS=""
STAGE=""

# bd-burn.sh keeps this much free after a burn; it is set aside twice, the
# second time for the ISO metadata itself.
FS_RESERVE=$((16 * 1024 * 1024))
# The zip's own bytes around the file: local header, central directory, ZIP64
# records. About 300 bytes for one stored file; a whole MiB is room to spare.
ZIP_OVERHEAD=$((1024 * 1024))
ALREADY_FITS=3

log() { printf '[bd-split %s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
human() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }

usage() {
    cat <<HELP
Usage: ${0##*/} [options] FILE
       ${0##*/} [options] --payload N
       ${0##*/} [options] --discs-needed FILE

Splits FILE into stored zip volumes, NAME.zip.001, .002, ..., each one filling
the disc in the drive, in a folder NAME.discs, and prints their paths. Burn one
volume per disc (bd-burn.sh --each); usb-autorun reassembles them once every
disc has been read.

Options:
  --device DEV      optical drive (default: /dev/sr0, else the first /dev/sr*);
                    stdio:/path/file.iso reads an image file instead (testing)
  --size BYTES      volume size, instead of reading the disc (e.g. testing)
  --name NAME       the file's name inside the zip, which also names the set
                    (default: FILE's name, with a ".bd" before the extension
                    dropped, so movie.bd.mkv becomes movie.mkv in movie.zip)
  --output-dir DIR  where the NAME.discs folder goes (default: FILE's folder)
  --payload N       print the largest file, in bytes, that fits on N discs
                    (N = 1: as it is; more: as a split zip), and stop
  --discs-needed    print how many discs FILE takes, and stop
  -h, --help        this text

Exit status: 0 split (volume paths on stdout); 3 FILE fits on one disc as it
is, so nothing was done; 1 any other error.
HELP
}

# ------------------------------------------------------------------ sizes

# Sets VOLUME: the bytes one disc takes, from --size or the disc in the drive.
read_volume_size() {
    local free
    if [[ -n $VOLUME_SIZE ]]; then
        VOLUME=$VOLUME_SIZE
        return 0
    fi
    local -a dev=()
    [[ -z $DEVICE ]] || dev=(--device "$DEVICE")
    free=$("$BD_BURN" --free "${dev[@]}") || die "No writable disc in the drive."
    VOLUME=$((free - 2 * FS_RESERVE))
    (( VOLUME > 2 * ZIP_OVERHEAD )) || die "The disc in the drive has only $(human "$free") free."
}

# The largest file that fits on N discs: as it is on one, zipped across more.
payload() {
    local n=$1
    if (( n == 1 )); then
        printf '%s\n' "$VOLUME"
    else
        printf '%s\n' $((n * VOLUME - ZIP_OVERHEAD))
    fi
}

# How many discs a file of BYTES takes.
discs_needed() {
    local bytes=$1
    if (( bytes <= VOLUME )); then
        echo 1
    else
        echo $(( (bytes + ZIP_OVERHEAD + VOLUME - 1) / VOLUME ))
    fi
}

# ------------------------------------------------------------------ split

split_file() {
    local size=$1 stem=${NAME%.*} discs avail set_dir vol
    local -a volumes=()
    discs=$(discs_needed "$size")
    if (( discs == 1 )); then
        log "${FILE##*/} ($(human "$size")) fits on one disc as it is. Nothing to do."
        exit "$ALREADY_FITS"
    fi
    set_dir="$OUT_DIR/$stem.discs"
    [[ ! -e $set_dir ]] ||
        die "$set_dir already exists; burn what is in it, or remove it to split again."
    avail=$(df -B1 --output=avail -- "$OUT_DIR" | tail -1 | tr -d ' ')
    (( avail > size + ZIP_OVERHEAD )) ||
        die "$OUT_DIR has $(human "$avail") free; the volumes need $(human "$size")."

    log "${FILE##*/} is $(human "$size"): $discs discs of $(human "$VOLUME") each, as $stem.zip.001-$(printf '%03d' "$discs")."
    # Staged on the same disk, so the finished folder arrives in one rename.
    # The link gives the file its name inside the zip; 7-Zip stores what it
    # points to.
    STAGE=$(mktemp -d "$OUT_DIR/.bd-split.XXXXXX") || die "Cannot write to $OUT_DIR."
    trap 'rm -rf -- "$STAGE"' EXIT
    mkdir -- "$STAGE/in" "$STAGE/set"
    ln -s -- "$FILE" "$STAGE/in/$NAME"
    log "Writing the volumes..."
    (cd -- "$STAGE/in" && 7z a -tzip -mx0 -v"${VOLUME}b" -bso0 -bsp2 -- "$STAGE/set/$stem.zip" "$NAME") >&2 ||
        die "7-Zip failed to write the volumes."
    log "Testing them..."
    7z t -bso0 -bsp2 -- "$STAGE/set/$stem.zip.001" >&2 || die "The volumes do not test as a sound zip."

    shopt -s nullglob
    volumes=("$STAGE/set/$stem".zip.[0-9][0-9][0-9]*)
    shopt -u nullglob
    (( ${#volumes[@]} == discs )) ||
        log "WARNING: expected $discs volumes, 7-Zip wrote ${#volumes[@]}."
    mv -T -- "$STAGE/set" "$set_dir" || die "Cannot move the volumes into $set_dir."
    for vol in "${volumes[@]}"; do
        log "  ${vol##*/}: $(human "$(stat -c %s -- "$set_dir/${vol##*/}")")"
    done
    for vol in "${volumes[@]}"; do
        printf '%s\n' "$set_dir/${vol##*/}"
    done
    log "Split into ${#volumes[@]} volumes in $set_dir. Burn one per disc; ${FILE##*/} is kept."
}

# ------------------------------------------------------------------- main

parse_args() {
    FILE=""
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --device|--size|--name|--output-dir|--payload)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
                case $1 in
                    --device) DEVICE=$2 ;; --size) VOLUME_SIZE=$2 ;;
                    --name) NAME=$2 ;; --output-dir) OUT_DIR=$2 ;;
                    --payload) MODE=payload; PAYLOAD_DISCS=$2 ;;
                esac
                shift 2 ;;
            --discs-needed) MODE=needed; shift ;;
            -*) die "Unknown option: $1 (see --help)." ;;
            *) [[ -z $FILE ]] || die "Give one file only."; FILE=$1; shift ;;
        esac
    done
    [[ -z $VOLUME_SIZE || $VOLUME_SIZE =~ ^[1-9][0-9]*$ ]] || die "--size wants a number of bytes."
    [[ -z $VOLUME_SIZE ]] || (( VOLUME_SIZE > 2 * ZIP_OVERHEAD )) ||
        die "--size is too small; it must exceed $((2 * ZIP_OVERHEAD)) bytes."
    if [[ $MODE == payload ]]; then
        [[ $PAYLOAD_DISCS =~ ^[1-9][0-9]*$ ]] || die "--payload wants a number of discs, e.g. 3."
        [[ -z $FILE ]] || die "--payload takes no FILE."
        return 0
    fi
    [[ -n $FILE ]] || { usage >&2; exit 1; }
    [[ -f $FILE ]] || die "Not a file: $FILE"
    FILE=$(realpath -- "$FILE")
    if [[ -z $NAME ]]; then
        NAME=${FILE##*/}
        [[ $NAME != *.bd.* ]] || NAME="${NAME%.bd.*}.${NAME##*.}"
    fi
    [[ $NAME != */* && $NAME != .* ]] || die "--name must be a plain file name: $NAME"
    [[ -n $OUT_DIR ]] || OUT_DIR=$(dirname -- "$FILE")
    [[ -d $OUT_DIR ]] || die "Not a folder: $OUT_DIR"
    OUT_DIR=$(realpath -- "$OUT_DIR")
}

main() {
    parse_args "$@"
    [[ -n $VOLUME_SIZE || -x $BD_BURN ]] ||
        die "bd-burn.sh is missing next to this script: $BD_BURN"
    read_volume_size
    case $MODE in
        payload) payload "$PAYLOAD_DISCS"; return 0 ;;
        needed) discs_needed "$(stat -c %s -- "$FILE")"; return 0 ;;
    esac
    command -v 7z >/dev/null || die "Missing command: 7z (sudo dnf install 7zip)."
    split_file "$(stat -c %s -- "$FILE")"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
