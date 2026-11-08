#!/usr/bin/env bash
#
# bd-pack.sh - sorts the files and folders of a folder into numbered
# subfolders, each one small enough to burn onto a single Blu-ray disc
# (bd-burn.sh FOLDER/N).
# Interactive; Linux (Fedora/GNOME).
#
#   1. Asks the disc size: 25 GB (single layer), 50 GB (dual layer) or
#      100 GB (BDXL triple layer), and the number the first folder is named.
#   2. The items are what sits directly in the folder: each file, and each
#      subfolder as a whole (its full size; it goes onto one disc intact,
#      never split up). Hidden ones are left alone, and so are folders named
#      only with digits: those are disc folders from an earlier run. Disc by
#      disc, it picks the remaining items that together come closest to
#      filling the disc (a subset-sum search), so each disc is as full as
#      the items allow and the last one takes what is left. --keep-order
#      fills the folders in name order instead, one after the other, keeping
#      e.g. a series' episodes together. An item too big for one disc stays
#      where it is (bd-split.sh splits a file).
#   3. The plan is shown before anything moves, and nothing moves without a
#      yes. Items are moved with mv (a rename on the same disk) and never
#      overwrite anything.
#   4. Undo runs only when chosen: when the folder has numbered disc
#      folders, the script asks first whether to pack or to undo. Undo moves
#      what is in each numbered folder (files, and folders whole) back into
#      the folder and removes the numbered folders, then stops. One level
#      only: nothing inside a moved folder is touched. An item whose name is
#      already taken in the folder stays, and so does its numbered folder.
#
# Usage: bd-pack.sh [options] [FOLDER]     (see --help)

set -euo pipefail
export LC_ALL=C.UTF-8

DIR=""
KEEP_ORDER=0
DRY_RUN=0

# Capacities in bytes: the 2048-byte sectors a blank BD-R holds.
CAP_SL=$((12219392 * 2048))   # 25 GB, single layer
CAP_DL=$((24438784 * 2048))   # 50 GB, dual layer
CAP_XL=$((48878592 * 2048))   # 100 GB, BDXL triple layer
SECTOR=2048
# Kept free for the ISO 9660/Joliet filesystem: what bd-burn.sh and
# bd-split.sh set aside, plus a directory record and rounding per file.
FS_RESERVE=$((32 * 1024 * 1024))
PER_FILE=$((2 * SECTOR))

log() { printf '[bd-pack] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
human() { awk -v b="$1" 'BEGIN { printf "%.2f GiB", b / 1073741824 }'; }

ask() {
    local reply
    read -r -p "$1" reply || reply=''
    printf '%s' "$reply"
}

# yes_no PROMPT DEFAULT(y|n)
yes_no() {
    local reply
    while :; do
        reply=$(ask "$1")
        reply=${reply,,}
        [[ -n $reply ]] || reply=$2
        case $reply in
            y|yes) return 0 ;;
            n|no) return 1 ;;
        esac
        echo "Please answer y or n." >&2
    done
}

usage() {
    cat <<HELP
Usage: ${0##*/} [options] [FOLDER]

Sorts the files and subfolders directly in FOLDER (default: the current
folder) into numbered folders, each fitting on one Blu-ray disc. A subfolder
counts as one item and moves whole. Asks the disc size (25, 50 or 100 GB) and
the first folder's number, shows the plan, and moves the items once you
confirm.

Folders named only with digits are disc folders from an earlier run and are
not packed. If there are any, it first asks whether to pack or to undo: move
their contents back into FOLDER and remove them (one level only, nothing is
overwritten). Undo never happens unless you choose it, and it does not pack
afterwards.

Options:
  --keep-order  fill the folders in file-name order, one after the other
                (default: each disc gets the items that fill it the most)
  -n, --dry-run show what would be done, move nothing
  -h, --help    this text
HELP
}

# ------------------------------------------------------------------- undo

# Moves what is in each numbered folder of DIR (files, and folders whole)
# into DIR, then removes the numbered folders left empty. One level only.
unpack() {
    local sub f name moved=0 kept=0
    for sub in "${DISC_DIRS[@]}"; do
        for f in "$sub"/* "$sub"/.[!.]* "$sub"/..?*; do
            [[ -e $f || -L $f ]] || continue
            name=${f##*/}
            if [[ -e $DIR/$name || -L $DIR/$name ]]; then
                log "Kept: ${sub##*/}/$name; a $name is already in the folder."
                kept=$((kept + 1))
            elif (( DRY_RUN )); then
                echo "would move ${sub##*/}/$name -> ./"
                moved=$((moved + 1))
            else
                mv -n -- "$f" "$DIR/" && moved=$((moved + 1))
            fi
        done
        if (( ! DRY_RUN )); then
            rmdir -- "$sub" 2>/dev/null || log "Kept the folder ${sub##*/} (not empty)."
        fi
    done
    log "$( ((DRY_RUN)) && echo "Would move" || echo "Moved") $moved item(s) back into $DIR.$( ((kept)) && echo " $kept item(s) left where they were.")"
}

# ------------------------------------------------------------------- pack

choose_capacity() {
    echo "Which Blu-ray disc?" >&2
    echo "  1) 25 GB  - single layer" >&2
    echo "  2) 50 GB  - dual layer" >&2
    echo "  3) 100 GB - BDXL (triple layer)" >&2
    while :; do
        case $(ask "Choice [1-3]: ") in
            1) CAP=$CAP_SL; CAP_NAME="25 GB single layer"; break ;;
            2) CAP=$CAP_DL; CAP_NAME="50 GB dual layer"; break ;;
            3) CAP=$CAP_XL; CAP_NAME="100 GB BDXL"; break ;;
            *) echo "Please type 1, 2 or 3." >&2 ;;
        esac
    done
    USABLE=$((CAP - FS_RESERVE))
}

choose_start() {
    local reply
    while :; do
        reply=$(ask "Number of the first folder [1]: ")
        [[ -n $reply ]] || reply=1
        if [[ $reply =~ ^[0-9]+$ ]]; then
            START=$((10#$reply))
            break
        fi
        echo "Please type a whole number, e.g. 1." >&2
    done
}

# What a file takes on the disc: its sectors plus a share of the metadata.
disc_bytes() {
    echo $(( ($1 + SECTOR - 1) / SECTOR * SECTOR + PER_FILE ))
}

# What a folder takes on the disc: each file in it as above, plus a
# directory record for each folder in it (itself included).
dir_disc_bytes() {
    find "$1" \( -type f -printf 'f %s\n' \) -o \( -type d -printf 'd 0\n' \) |
        awk -v sec="$SECTOR" -v per="$PER_FILE" '
            { t += ($1 == "f" ? int(($2 + sec - 1) / sec) * sec : 0) + per }
            END { printf "%.0f\n", t }'
}

# Reads "index units" lines and a capacity in units; prints the indices of
# the subset whose units add up closest to the capacity without passing it
# (0/1 knapsack on sizes, i.e. subset sum). reach[s] holds the item that
# first made sum s reachable; walking back from the best sum through it
# only meets earlier items, so each file is picked at most once.
best_subset() {
    awk -v cap="$1" '
        { idx[NR] = $1; w[NR] = $2 }
        END {
            reach[0] = -1
            best = 0
            for (i = 1; i <= NR; i++) {
                for (s = cap - w[i]; s >= 0; s--) {
                    if ((s in reach) && !((s + w[i]) in reach)) {
                        reach[s + w[i]] = i
                        if (s + w[i] > best) best = s + w[i]
                    }
                }
                if (best == cap) break
            }
            for (s = best; s > 0; s -= w[i]) { i = reach[s]; print idx[i] }
        }'
}

# Fills BIN_OF (file index -> bin) and BIN_USED (bytes per bin).
# Default: disc by disc, the remaining files that fill the disc the most.
# --keep-order: in name order, a new disc when the next file does not fit.
plan() {
    local -a left=() chosen=()
    local i b unit units
    BIN_USED=()
    BIN_OF=()
    TOO_BIG=()
    for i in "${!FILES[@]}"; do
        if (( NEED[i] > USABLE )); then TOO_BIG+=("$i"); else left+=("$i"); fi
    done

    if (( KEEP_ORDER )); then
        for i in "${left[@]}"; do
            b=$(( ${#BIN_USED[@]} - 1 ))
            if (( b < 0 || BIN_USED[b] + NEED[i] > USABLE )); then
                b=${#BIN_USED[@]}
                BIN_USED+=(0)
            fi
            BIN_USED[b]=$(( BIN_USED[b] + NEED[i] ))
            BIN_OF[i]=$b
        done
        return 0
    fi

    # Sizes are counted in units of about 1/32768 of the disc (~3 MiB on a
    # 100 GB one), rounded up per file and down for the disc, so a chosen
    # set always fits; the search stays quick in awk.
    unit=$(( (USABLE / 32768 + SECTOR - 1) / SECTOR * SECTOR ))
    units=$(( USABLE / unit ))
    while (( ${#left[@]} )); do
        mapfile -t chosen < <(for i in "${left[@]}"; do
            echo "$i $(( (NEED[i] + unit - 1) / unit ))"; done | best_subset "$units")
        (( ${#chosen[@]} )) || die "Packing found no item to place (bug)."
        b=${#BIN_USED[@]}
        BIN_USED+=(0)
        for i in "${chosen[@]}"; do
            BIN_USED[b]=$(( BIN_USED[b] + NEED[i] ))
            BIN_OF[i]=$b
        done
        mapfile -t left < <(for i in "${left[@]}"; do [[ -n ${BIN_OF[i]-} ]] || echo "$i"; done)
    done
}

label() {
    local f=${FILES[$1]}
    if [[ -d $f ]]; then printf '%s/' "${f##*/}"; else printf '%s' "${f##*/}"; fi
}

show_plan() {
    local b i
    echo >&2
    echo "Plan for $DIR ($CAP_NAME discs, $(human "$USABLE") usable each):" >&2
    for b in "${!BIN_USED[@]}"; do
        printf '\n  %s/  %s (%d%% full)\n' "$((START + b))" "$(human "${BIN_USED[b]}")" \
            $(( BIN_USED[b] * 100 / USABLE )) >&2
        for i in "${!FILES[@]}"; do
            [[ ${BIN_OF[i]-} == "$b" ]] || continue
            printf '      %-60s %s\n' "$(label "$i")" "$(human "${SIZES[i]}")" >&2
        done
    done
    if (( ${#TOO_BIG[@]} )); then
        echo >&2
        echo "  Too big for one disc, left where they are (see bd-split.sh):" >&2
        for i in "${TOO_BIG[@]}"; do
            printf '      %-60s %s\n' "$(label "$i")" "$(human "${SIZES[i]}")" >&2
        done
    fi
    echo >&2
}

pack() {
    local f b i dest
    FILES=()
    SIZES=()
    NEED=()
    for f in "$DIR"/*; do
        [[ ! -L $f ]] || continue
        if [[ -f $f ]]; then
            FILES+=("$f")
            SIZES+=("$(stat -c %s -- "$f")")
            NEED+=("$(disc_bytes "${SIZES[-1]}")")
        elif [[ -d $f && ! ${f##*/} =~ ^[0-9]+$ ]]; then
            FILES+=("$f")
            SIZES+=("$(du -s --apparent-size -B1 -- "$f" | cut -f1)")
            NEED+=("$(dir_disc_bytes "$f")")
        fi
    done
    (( ${#FILES[@]} )) || { log "Nothing to pack in $DIR."; return 0; }

    choose_capacity
    choose_start
    plan
    (( ${#BIN_USED[@]} )) || { show_plan; log "Nothing fits on one disc; nothing to do."; return 0; }

    for b in "${!BIN_USED[@]}"; do
        dest="$DIR/$((START + b))"
        [[ ! -e $dest && ! -L $dest ]] ||
            die "$dest already exists. Pick another first number, or undo the earlier packing first."
    done

    show_plan
    if (( DRY_RUN )); then
        log "Dry run: nothing moved."
        return 0
    fi
    yes_no "Create ${#BIN_USED[@]} folder(s), $START to $((START + ${#BIN_USED[@]} - 1)), and move the items? [y/N] " n ||
        { log "Nothing moved."; return 0; }

    for b in "${!BIN_USED[@]}"; do
        mkdir -- "$DIR/$((START + b))"
    done
    for i in "${!FILES[@]}"; do
        [[ -n ${BIN_OF[i]-} ]] || continue
        mv -n -- "${FILES[i]}" "$DIR/$((START + BIN_OF[i]))/"
    done
    log "Done: ${#BIN_USED[@]} folder(s) in $DIR. Burn each with: bd-burn.sh \"$DIR/N\""
}

# ------------------------------------------------------------------- main

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) usage; exit 0 ;;
            --keep-order) KEEP_ORDER=1; shift ;;
            -n|--dry-run) DRY_RUN=1; shift ;;
            -*) die "Unknown option: $1 (see --help)." ;;
            *) [[ -z $DIR ]] || die "Give one folder only."; DIR=$1; shift ;;
        esac
    done
    [[ -n $DIR ]] || DIR=.
    [[ -d $DIR ]] || die "Not a folder: $DIR"
    DIR=$(realpath -- "$DIR")

    local d
    DISC_DIRS=()
    for d in "$DIR"/*/; do
        d=${d%/}
        [[ -d $d && ! -L $d && ${d##*/} =~ ^[0-9]+$ ]] && DISC_DIRS+=("$d")
    done
    if (( ${#DISC_DIRS[@]} )); then
        echo "$DIR has ${#DISC_DIRS[@]} numbered disc folder(s):" >&2
        for d in "${DISC_DIRS[@]}"; do echo "  ${d##*/}/" >&2; done
        echo "What do you want to do?" >&2
        echo "  1) Pack the other files and folders into new numbered folders (the ones above stay as they are)" >&2
        echo "  2) Undo: move their contents back into $DIR and remove them" >&2
        echo "  3) Quit" >&2
        while :; do
            case $(ask "Choice [1-3]: ") in
                1) break ;;
                2) unpack; return 0 ;;
                3) log "Nothing done."; return 0 ;;
                *) echo "Please type 1, 2 or 3." >&2 ;;
            esac
        done
    fi
    pack
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
