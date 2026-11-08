#!/usr/bin/env bash
#
# usb-mount.sh - mounts every removable drive plugged into the computer
# (USB hard drives and SSDs, flash drives, card readers, optical drives),
# or, with --off, unmounts them all and powers them off.
# Linux (UDisks); Fedora/GNOME.
#
#   Mounting (the default):
#   1. Drives this script powered off earlier are powered back on: their
#      USB port is switched off and on again, so the drive is detected as if
#      it had just been plugged in. That needs sudo. A drive powered off some
#      other way (GNOME's eject button) is found with --rescan, which does
#      the same to every USB port with nothing on it. A drive with its own
#      power switch turned off can only be switched on by hand.
#   2. An optical drive with no disc gets its tray closed, then a few
#      seconds to read the disc.
#   3. Every filesystem on every removable drive is mounted through UDisks,
#      like the file manager does (under /run/media/$USER). A drive that has
#      spun down wakes up on its own when it is mounted. An encrypted volume
#      asks for its passphrase when run from a terminal.
#
#   --off:
#   1. Every filesystem on the drives is unmounted and encrypted volumes are
#      locked. A busy one (a program still has files open) is reported and
#      its drive is left alone.
#   2. Each drive is then powered off through UDisks (a hard drive parks its
#      heads and spins down) and drops off the USB bus; it is safe to unplug.
#      The USB port is remembered, so the next plain run powers it back on.
#
#   The disk the system runs from is never touched, even when it is on USB.
#   Device names (/dev/sdb or sdb) limit either mode to those drives.
#
# Usage: usb-mount.sh [--off] [options] [DEVICE...]     (see --help)

set -euo pipefail
export LC_ALL=C.UTF-8

HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
# shellcheck source=lib/removable.sh
source "$HERE/lib/removable.sh"

STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/usb-mount
PORTS_FILE=$STATE_DIR/powered-off-ports     # "PORT<TAB>description" lines

MODE=mount
RESCAN=0
DRY_RUN=0
WANTED=()
FAILED=0
UDISKS_OPTS=()

log() { printf '[usb-mount] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    cat <<'EOF'
Usage: usb-mount.sh [options] [DEVICE...]
       usb-mount.sh --off [options] [DEVICE...]

Mounts every removable drive (USB hard drives, flash drives, card readers,
optical drives), powering back on the ones this script powered off.
With --off, unmounts them all and powers them off, ready to unplug.

  DEVICE        only these drives (/dev/sdb or sdb); default: all of them
  --off         unmount, lock and power off instead of mounting
  --rescan      also power-cycle every empty USB port, to bring back a drive
                powered off some other way (GNOME's eject button); needs sudo
  --list        show the removable drives and what is mounted, change nothing
  -n, --dry-run show what would be done
  -h, --help    this help

Exit status: 0 when everything worked, 1 when some drive could not be
mounted, unmounted or powered off (the others are still done).
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --off) MODE=off ;;
            --list) MODE=list ;;
            --rescan) RESCAN=1 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -h|--help) usage; exit 0 ;;
            -*) usage >&2; die "Unknown option: $1" ;;
            *) [[ $1 == /dev/* ]] && WANTED+=("$1") || WANTED+=("/dev/$1") ;;
        esac
        shift
    done
}

# The removable drives this run works on, into DISKS.
select_disks() {
    local d w ok
    DISKS=()
    while IFS= read -r d; do
        if ((${#WANTED[@]})); then
            ok=0
            for w in "${WANTED[@]}"; do [[ $(readlink -f -- "$w") == "$d" || $w == "$d" ]] && ok=1; done
            ((ok)) || continue
        fi
        DISKS+=("$d")
    done < <(rm_disks)
    for w in "${WANTED[@]}"; do
        ok=0
        for d in "${DISKS[@]}"; do [[ $(readlink -f -- "$w") == "$d" || $w == "$d" ]] && ok=1; done
        ((ok)) || { log "$w is not a removable drive (or is the system's own); skipped."; FAILED=1; }
    done
}

# ---------------------------------------------------------------- power on

# Ports to power-cycle: the remembered ones, plus every empty one on --rescan.
ports_to_wake() {
    local p
    if [[ -s $PORTS_FILE ]]; then
        cut -f1 -- "$PORTS_FILE"
    fi
    if ((RESCAN)); then
        for p in /sys/bus/usb/devices/*/usb*-port*; do
            [[ -e $p/disable && ! -e $p/device ]] || continue
            [[ $(cat -- "$p/disable" 2>/dev/null) == 0 ]] || continue   # someone disabled it on purpose
            readlink -f -- "$p"
        done
    fi
}

forget_port() {
    [[ -s $PORTS_FILE ]] || return 0
    local tmp
    tmp=$(mktemp -- "$PORTS_FILE.XXXXXX")
    awk -F'\t' -v p="$1" '$1 != p' "$PORTS_FILE" >"$tmp" || true
    mv -f -- "$tmp" "$PORTS_FILE"
}

port_name() {
    awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$PORTS_FILE" 2>/dev/null || true
}

power_on() {
    local p name i
    local -a ports=() cycled=()
    mapfile -t ports < <(ports_to_wake | awk 'NF && !seen[$0]++')
    ((${#ports[@]})) || return 0
    ((${#WANTED[@]})) && return 0          # a powered-off drive has no /dev name to ask for

    for p in "${ports[@]}"; do
        name=$(port_name "$p"); name=${name:-the drive on ${p##*/}}
        if [[ ! -d $p ]]; then
            log "USB port ${p##*/} is gone (hub unplugged?); forgetting $name."
            ((DRY_RUN)) || forget_port "$p"
            continue
        fi
        if [[ -e $p/device ]]; then        # already back (replugged by hand)
            ((DRY_RUN)) || forget_port "$p"
            continue
        fi
        if [[ ! -e $p/disable ]]; then
            log "Cannot power on $name from software here: unplug it and plug it back in."
            FAILED=1
            continue
        fi
        [[ -n $(port_name "$p") ]] && log "Powering on $name..."
        if ((DRY_RUN)); then
            log "  (dry run) power-cycle USB port ${p##*/}"
            continue
        fi
        if sudo sh -c 'echo 1 >"$1/disable" && sleep 1 && echo 0 >"$1/disable"' sh "$p"; then
            cycled+=("$p")
        else
            log "Could not switch USB port ${p##*/} (sudo refused?)."
            FAILED=1
        fi
    done
    ((${#cycled[@]})) || return 0

    # Wait for whatever is on those ports to show up and get its disks.
    for ((i = 0; i < 20; i++)); do
        local waiting=0
        for p in "${cycled[@]}"; do [[ -e $p/device ]] || waiting=1; done
        ((waiting)) || break
        sleep 1
    done
    sleep 2                                # usb-storage waits before scanning
    udevadm settle --timeout=20 2>/dev/null || true
    for p in "${cycled[@]}"; do
        name=$(port_name "$p")
        if [[ -e $p/device ]]; then
            [[ -n $name ]] && log "$name is back."
            forget_port "$p"
        elif [[ -n $name ]]; then
            log "$name did not come back. Is it switched on? Try unplugging it and plugging it back in."
            FAILED=1
        fi
    done
}

# ---------------------------------------------------------------- mounting

# Closes an empty optical drive's tray and gives the disc time to spin up.
wait_for_disc() {
    local disk=$1 i
    rm_has_medium "$disk" && return 0
    ((DRY_RUN)) && return 1
    eject -t -- "$disk" 2>/dev/null || true
    log "Waiting for a disc in $disk..."
    for ((i = 0; i < 12; i++)); do
        sleep 1
        udevadm settle --timeout=5 2>/dev/null || true
        rm_has_medium "$disk" && { sleep 1; return 0; }
    done
    return 1
}

mount_volume() {
    local dev=$1 out mp
    mp=$(rm_mountpoint "$dev")
    if [[ -n $mp ]]; then
        log "  $dev is already mounted at $mp"
        return 0
    fi
    if ((DRY_RUN)); then
        log "  (dry run) mount $dev"
        return 0
    fi
    if out=$(udisksctl mount "${UDISKS_OPTS[@]}" -b "$dev" 2>&1); then
        mp=$(rm_mountpoint "$dev")
        log "  $dev mounted at ${mp:-?}"
    else
        log "  Could not mount $dev: ${out##*: }"
        FAILED=1
    fi
}

# Unlocks an encrypted volume (asks for its passphrase) and mounts what is
# inside. One that is already unlocked is skipped here: its cleartext
# volume is listed after it and mounted on its own.
unlock_and_mount() {
    local dev=$1 out clear
    if lsblk -nrpo TYPE -- "$dev" | grep -qx crypt; then
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log "  $dev is encrypted; run this from a terminal to type its passphrase."
        FAILED=1
        return 0
    fi
    if ((DRY_RUN)); then
        log "  (dry run) unlock $dev and mount it"
        return 0
    fi
    log "  $dev is encrypted."
    if out=$(udisksctl unlock -b "$dev"); then
        clear=$(sed -n 's/^Unlocked .* as \(.*\)\.$/\1/p' <<<"$out")
        if [[ -n $clear ]]; then
            udevadm settle --timeout=10 2>/dev/null || true
            mount_volume "$clear"
        fi
    else
        log "  Could not unlock $dev."
        FAILED=1
    fi
}

do_mount() {
    local disk dev fs n
    power_on
    select_disks
    if ((${#DISKS[@]} == 0)); then
        log "No removable drives found."
        return 0
    fi
    for disk in "${DISKS[@]}"; do
        log "$disk: $(rm_describe "$disk")"
        if [[ $(rm_field "$disk" TYPE) == rom ]]; then
            wait_for_disc "$disk" || { log "  No disc in the drive."; continue; }
            if udevadm info -q property -n "$disk" 2>/dev/null | grep -qx 'ID_CDROM_MEDIA_STATE=blank'; then
                log "  The disc is blank."
                continue
            fi
        elif ! rm_has_medium "$disk"; then
            log "  No card or medium in it."
            continue
        fi
        n=0
        while IFS=$'\t' read -r dev fs; do
            n=$((n + 1))
            case $fs in
                crypto_LUKS|BitLocker) unlock_and_mount "$dev" ;;
                *) mount_volume "$dev" ;;
            esac
        done < <(rm_volumes "$disk")
        ((n)) || log "  No filesystem on it that can be mounted."
    done
}

# ---------------------------------------------------------------- --off

# Unmounts and locks everything on DISK, innermost first. False when
# something stays in use.
release_disk() {
    local disk=$1 dev fs mp out ok=0
    local -a vols=()
    mapfile -t vols < <(rm_volumes "$disk" | tac)
    for dev in "${vols[@]}"; do
        fs=${dev#*$'\t'}; dev=${dev%%$'\t'*}
        mp=$(rm_mountpoint "$dev")
        if [[ -n $mp ]]; then
            if ((DRY_RUN)); then
                log "  (dry run) unmount $dev from $mp"
            elif out=$(udisksctl unmount "${UDISKS_OPTS[@]}" -b "$dev" 2>&1); then
                log "  Unmounted $dev ($mp)"
            else
                log "  Could not unmount $dev from $mp: ${out##*: }"
                command -v fuser >/dev/null && fuser -vm -- "$mp" 2>&1 | sed 's/^/    /' >&2 || true
                ok=1
            fi
        fi
        if [[ $fs == crypto_LUKS || $fs == BitLocker ]] &&
            lsblk -nrpo TYPE -- "$dev" | grep -qx crypt; then
            if ((DRY_RUN)); then
                log "  (dry run) lock $dev"
            elif out=$(udisksctl lock "${UDISKS_OPTS[@]}" -b "$dev" 2>&1); then
                log "  Locked $dev"
            else
                log "  Could not lock $dev: ${out##*: }"
                ok=1
            fi
        fi
    done
    return "$ok"
}

remember_port() {
    local port=$1 name=$2
    mkdir -p -- "$STATE_DIR"
    forget_port "$port"
    printf '%s\t%s\n' "$port" "$name" >>"$PORTS_FILE"
}

do_off() {
    local disk port name out
    local -a ready=()
    select_disks
    if ((${#DISKS[@]} == 0)); then
        log "No removable drives found."
        return 0
    fi
    # Everything is unmounted first: one USB device can carry several disks
    # (a multi-slot card reader), and powering it off takes them all.
    for disk in "${DISKS[@]}"; do
        log "$disk: $(rm_describe "$disk")"
        if release_disk "$disk"; then
            ready+=("$disk")
        else
            log "  $disk stays on: close what is using it and run again."
            FAILED=1
        fi
    done
    for disk in "${ready[@]}"; do
        [[ -b $disk ]] || continue         # went with a sibling disk
        name=$(rm_describe "$disk")
        port=$(rm_usb_port "$disk" || true)
        if ((DRY_RUN)); then
            log "  (dry run) power off $disk"
            continue
        fi
        if out=$(udisksctl power-off "${UDISKS_OPTS[@]}" -b "$disk" 2>&1); then
            log "Powered off $name; it can be unplugged."
            [[ -n $port ]] && remember_port "$port" "$name"
        elif [[ $(rm_field "$disk" TYPE) == rom ]] && eject -- "$disk" 2>/dev/null; then
            log "$name cannot be powered off; ejected the disc instead."
        else
            log "Could not power off $name: ${out##*: }"
            log "  Its filesystems are unmounted, so it is safe to unplug."
            FAILED=1
        fi
    done
}

# ---------------------------------------------------------------- --list

do_list() {
    local disk dev fs mp label
    select_disks
    ((${#DISKS[@]})) || log "No removable drives found."
    for disk in "${DISKS[@]}"; do
        printf '%s  %s  [%s]\n' "$disk" "$(rm_describe "$disk")" "$(rm_field "$disk" TRAN)"
        rm_has_medium "$disk" || { printf '    (no medium)\n'; continue; }
        while IFS=$'\t' read -r dev fs; do
            mp=$(rm_mountpoint "$dev"); label=$(rm_field "$dev" LABEL)
            printf '    %-22s %-12s %-20s %s\n' "$dev" "$fs" "${label:--}" "${mp:-not mounted}"
        done < <(rm_volumes "$disk")
    done
    if [[ -s $PORTS_FILE ]]; then
        printf '\nPowered off (a plain run powers them back on):\n'
        awk -F'\t' '{ p = $1; sub(/.*\//, "", p); printf "    %s  (USB port %s)\n", $2, p }' "$PORTS_FILE"
    fi
}

main() {
    parse_args "$@"
    local bin
    for bin in udisksctl lsblk findmnt udevadm eject; do
        command -v "$bin" >/dev/null || die "Missing: $bin (sudo dnf install udisks2 util-linux)"
    done
    [[ -t 0 ]] || UDISKS_OPTS=(--no-user-interaction)
    case $MODE in
        mount) do_mount ;;
        off) do_off ;;
        list) do_list ;;
    esac
    return "$FAILED"
}

main "$@"
