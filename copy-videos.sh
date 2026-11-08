#!/usr/bin/env bash
#
# copy-videos.sh - copies every video file on the removable drives (USB hard
# drives, flash drives, memory cards, optical discs) into ~/Videos.
# Linux (UDisks); Fedora/GNOME.
#
#   1. The drives are mounted first with usb-mount.sh, which also powers
#      back on a drive it powered off earlier (--no-mount uses only what is
#      already mounted). Folders given on the command line are searched
#      instead of the drives.
#   2. Videos are found by extension (mkv, mp4, avi, mov, m2ts, vob, ...),
#      in every folder except hidden ones, the recycle bins and "System
#      Volume Information". A .ts file counts only when it really is an MPEG
#      transport stream, not TypeScript source.
#   3. Every video lands directly in ~/Videos under its own file name; no
#      folders are made there, whatever folder it sat in on the drive:
#      E:\Trips\2024\beach.mp4 lands in ~/Videos/beach.mp4.
#   4. Nothing is overwritten. A file already there with the same size was
#      copied before and is skipped, so running again copies only what is
#      new; a different file with the same name gets " (2)" added. The free
#      space is checked before the first byte is copied.
#   5. Each file is copied with cp straight under its final name, so a
#      player (Kodi) can start on it while it is still copying. A copy that
#      fails or is stopped (Ctrl+C) is deleted; one cut short by a crash or
#      power loss is noted in DEST/.copy-videos-partial, deleted on the next
#      run and copied again.
#      --off powers the drives off afterwards, when every copy worked.
#
# Usage: copy-videos.sh [options] [FOLDER...]     (see --help)

set -euo pipefail
export LC_ALL=C.UTF-8

HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib/removable.sh
source "$HERE/lib/removable.sh"

VIDEO_EXT=(3g2 3gp asf avi divx f4v flv m2t m2ts m2v m4v mkv mov mp4 mpe mpeg
           mpg mts mxf ogm ogv qt rm rmvb ts vob webm wmv wtv)

DEST=""
DRY_RUN=0
MOUNT=1
POWER_OFF=0
FOLDERS=()

SRC_DIRS=()     # where to look
PLAN_SRC=()
PLAN_DST=()
PLAN_SIZE=()
SKIPPED=0
PARTIAL=""      # the file being copied, deleted if the copy fails
MARKER=""       # notes PARTIAL on disk, for a run that dies outright
LEFTOVER=""     # dry run: the half-copied file a real run would delete

log() { printf '[copy-videos] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
human() { awk -v b="$1" 'BEGIN { split("B KiB MiB GiB TiB", u); i = 1
          while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }

usage() {
    cat <<'EOF'
Usage: copy-videos.sh [options] [FOLDER...]

Copies every video on the removable drives (USB disks, flash drives, memory
cards, optical discs) straight into ~/Videos, without subfolders. Nothing
is overwritten: a different video with a name already taken gets " (2)",
and what was copied before is skipped.

  FOLDER        search these folders instead of the removable drives
  -d, --dest DIR   where to copy to (default: ~/Videos)
  -n, --dry-run    list what would be copied, copy nothing
  --no-mount       do not mount drives first; use only the ones mounted
  --off            unmount and power off the drives when everything copied
  -h, --help       this help
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            -d|--dest) [[ $# -ge 2 ]] || die "$1 needs a folder"; DEST=$2; shift ;;
            -n|--dry-run) DRY_RUN=1 ;;
            --no-mount) MOUNT=0 ;;
            --off) POWER_OFF=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage >&2; die "Unknown option: $1" ;;
            *) [[ -d $1 ]] || die "Not a folder: $1"; FOLDERS+=("$1") ;;
        esac
        shift
    done
    if [[ -z $DEST ]]; then
        DEST=$(xdg-user-dir VIDEOS 2>/dev/null || true)
        [[ -n $DEST && $DEST != "$HOME" ]] || DEST=$HOME/Videos
    fi
    DEST=$(realpath -m -- "$DEST")
}

find_sources() {
    local f disk dev fs mp
    if ((${#FOLDERS[@]})); then
        for f in "${FOLDERS[@]}"; do
            SRC_DIRS+=("$(realpath -- "$f")")
        done
        return 0
    fi
    if ((MOUNT)); then
        # Mount errors are reported there; carry on with whatever mounted.
        "$HERE/usb-mount.sh" || log "Some drives could not be mounted; copying from the others."
    fi
    while IFS= read -r disk; do
        while IFS=$'\t' read -r dev fs; do
            mp=$(rm_mountpoint "$dev")
            [[ -n $mp && -d $mp ]] || continue
            SRC_DIRS+=("$mp")
        done < <(rm_volumes "$disk")
    done < <(rm_disks)
    ((${#SRC_DIRS[@]})) || die "No mounted removable drives found. Plug one in (or check usb-mount.sh --list)."
}

# True when a .ts file starts like an MPEG transport stream (0x47 sync byte
# every 188 bytes), and not like TypeScript.
is_mpeg_ts() {
    local a b
    a=$(od -An -tx1 -N1 -- "$1" 2>/dev/null | tr -d ' \n')
    b=$(od -An -tx1 -j188 -N1 -- "$1" 2>/dev/null | tr -d ' \n')
    [[ $a == 47 && $b == 47 ]]
}

# free_name DST SIZE: DST, or DST with " (2)", " (3)"... before the
# extension when that name is taken (or about to be, by an earlier file of
# this run). Fails when one of those names already holds a file of SIZE
# bytes, or is about to: this video was copied on an earlier run, or is
# also on another drive or in another folder and copied once already.
free_name() {
    local dst=$1 size=$2 stem ext n=2 cand j taken
    stem=${dst%.*}; ext=${dst##*.}
    cand=$dst
    while :; do
        taken=0
        if [[ $cand != "$LEFTOVER" ]]; then
            [[ -f $cand && $(stat -c %s -- "$cand") == "$size" ]] && return 1
            [[ -e $cand ]] && taken=1
        fi
        for j in "${!PLAN_DST[@]}"; do
            [[ ${PLAN_DST[j]} == "$cand" ]] || continue
            [[ ${PLAN_SIZE[j]} == "$size" ]] && return 1
            taken=1
        done
        ((taken)) || break
        cand="$stem ($n).$ext"; n=$((n + 1))
    done
    printf '%s' "$cand"
}

plan() {
    local i dir file dst size args=() e
    for e in "${VIDEO_EXT[@]}"; do args+=(-o -iname "*.$e"); done
    args=("${args[@]:1}")

    for i in "${!SRC_DIRS[@]}"; do
        dir=${SRC_DIRS[i]}
        log "Looking for videos in $dir..."
        while IFS= read -r -d '' file; do
            [[ ${file,,} == *.ts ]] && ! is_mpeg_ts "$file" && continue
            size=$(stat -c %s -- "$file")
            if ! dst=$(free_name "$DEST/${file##*/}" "$size"); then
                SKIPPED=$((SKIPPED + 1))
                continue
            fi
            PLAN_SRC+=("$file"); PLAN_DST+=("$dst"); PLAN_SIZE+=("$size")
        done < <(find "$dir" -mindepth 1 \
                    \( -name '.*' -o -iname '$RECYCLE.BIN' -o -iname 'RECYCLER' \
                       -o -iname 'System Volume Information' -o -name 'lost+found' \
                       -o -path "$DEST" \) -prune \
                    -o -type f \( "${args[@]}" \) -print0 2>/dev/null | sort -z)
    done
}

# The free bytes where DEST is (or will be).
free_space() {
    local d=$DEST
    while [[ ! -d $d ]]; do d=$(dirname -- "$d"); done
    df -B1 --output=avail -- "$d" | tail -1 | tr -d ' '
}

copy_one() {
    local src=$1 dst=$2
    mkdir -p -- "$(dirname -- "$dst")"
    # Claim the name first: never write over a file that appeared meanwhile.
    ( set -C; : >"$dst" ) 2>/dev/null || return 1
    PARTIAL=$dst
    printf '%s\n' "$dst" >"$MARKER"
    cp --preserve=timestamps -- "$src" "$dst" || return 1
    [[ $(stat -c %s -- "$dst") == $(stat -c %s -- "$src") ]] || return 1
    chmod 644 -- "$dst"
    PARTIAL=""
    rm -f -- "$MARKER"
}

# Deletes the half-copied file a crashed or killed earlier run left behind.
remove_leftover() {
    local f
    [[ -f $MARKER ]] || return 0
    f=$(head -n1 -- "$MARKER")
    if ((DRY_RUN)); then
        [[ -f $f ]] && log "Would delete $f, left half-copied by an interrupted run."
        LEFTOVER=$f                        # plan as if it were gone
        return 0
    fi
    if [[ -f $f ]]; then
        rm -f -- "$f"
        log "Deleted $f, left half-copied by an interrupted run; it is copied again."
    fi
    rm -f -- "$MARKER"
}

cleanup() {
    [[ -z $PARTIAL ]] || rm -f -- "$PARTIAL" "$MARKER"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

main() {
    parse_args "$@"
    local bin
    for bin in lsblk findmnt find stat df od; do
        command -v "$bin" >/dev/null || die "Missing: $bin"
    done
    MARKER=$DEST/.copy-videos-partial
    find_sources
    remove_leftover
    plan

    local total=0 n=${#PLAN_SRC[@]} i s avail
    for s in "${PLAN_SIZE[@]}"; do total=$((total + s)); done
    local already=""
    ((SKIPPED == 0)) || already="; $SKIPPED already there"
    if ((n == 0)); then
        log "No new videos to copy into $DEST$already."
    else
        log "$n video(s), $(human "$total"), to copy into $DEST$already."
    fi

    if ((DRY_RUN)); then
        for i in "${!PLAN_SRC[@]}"; do
            printf '%10s  %s\n            -> %s\n' "$(human "${PLAN_SIZE[i]}")" "${PLAN_SRC[i]}" "${PLAN_DST[i]}"
        done
        return 0
    fi

    if ((n)); then
        avail=$(free_space)
        ((total < avail)) ||
            die "Not enough space: $(human "$total") to copy, $(human "$avail") free in $DEST."
    fi

    local failed=0 copied=0 done_bytes=0
    for i in "${!PLAN_SRC[@]}"; do
        log "[$((i + 1))/$n] ${PLAN_SRC[i]} ($(human "${PLAN_SIZE[i]}"))"
        if copy_one "${PLAN_SRC[i]}" "${PLAN_DST[i]}"; then
            copied=$((copied + 1)); done_bytes=$((done_bytes + PLAN_SIZE[i]))
        else
            log "  FAILED; left out. (A scratched disc or a dying drive?)"
            cleanup; PARTIAL=""
            failed=$((failed + 1))
        fi
    done
    if ((n)); then
        log "Copied $copied video(s), $(human "$done_bytes"), into $DEST."
        ((failed == 0)) || log "$failed video(s) could not be copied (see above)."
    fi

    if ((POWER_OFF)) && ((${#FOLDERS[@]} == 0)); then
        if ((failed)); then
            log "Not powering the drives off: some copies failed."
        else
            "$HERE/usb-mount.sh" --off || true
        fi
    fi
    ((failed == 0))
}

main "$@"
