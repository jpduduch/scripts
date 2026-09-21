#!/bin/bash
# Fedora Workstation / GNOME (Wayland). Run: sudo bash "$0" --user joao
# WARNING: a successful import replaces DEST and ERASES the labeled USB volume.
set -euo pipefail

USER_NAME="${SUDO_USER:-joao}"
FS_LABEL="TEMP"
DEST="/home/public"
FULLSCREEN="yes"

CONFIG_FILE="/etc/usb-autorun.conf"
UDEV_RULE="/etc/udev/rules.d/99-usb-autorun.rules"
SERVICE_FILE="/etc/systemd/system/usb-autorun@.service"
PLAYER_SERVICE="/etc/systemd/user/usb-autorun-player.service"
SCRIPT_FILE="/usr/local/libexec/usb-autorun"

log() { printf '[usb-autorun] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run with sudo."; }

validate_user() {
    USER_ID=$(id -u "$USER_NAME") || die "User '$USER_NAME' does not exist."
    [[ $USER_ID -ne 0 ]] || die "Choose a desktop user, not root (--user NAME)."
    USER_GROUP=$(id -gn "$USER_NAME")
}

validate_destination() {
    # Restrict destructive replacement to a dedicated directory below a root-owned
    # parent. Never accept an account's home, symlinks, or nested mount points.
    [[ $DEST =~ ^/(home|srv)/[a-zA-Z0-9_-]+$ ]] ||
        die "Unsafe destination: use a dedicated /home/NAME or /srv/NAME directory."
    [[ ! -L $DEST && ( ! -e $DEST || -d $DEST ) ]] || die "Invalid destination: $DEST"
    local parent=${DEST%/*} account_home target mounts mode
    [[ $(realpath -e "$parent") == "$parent" ]] || die "Destination parent is a symlink."
    [[ $(stat -c %u "$parent") == 0 ]] || die "Destination parent must belong to root."
    mode=$(stat -c %a "$parent")
    (( (8#$mode & 0022) == 0 )) || die "Destination parent must not be group/world writable."
    while IFS=: read -r _ _ _ _ _ account_home _; do
        [[ $DEST != "$account_home" ]] || die "Destination is an account's home: $DEST"
    done < <(getent passwd)
    mounts=$(findmnt -rn --raw -o TARGET) || die "Cannot inspect destination mounts."
    while IFS= read -r target; do
        [[ $target != "$DEST" && $target != "$DEST/"* ]] ||
            die "Destination contains a mount point: $target"
    done <<< "$mounts"
}

user_systemctl() {
    runuser -u "$USER_NAME" -- env \
        XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        systemctl --user "$@"
}

require_graphical_session() {
    local sid session_type count=0 manager_env sessions
    sessions=$(loginctl list-sessions --no-legend --no-pager) || die "Cannot query login sessions."
    while read -r sid _; do
        [[ -n $sid ]] || continue
        [[ $(loginctl show-session "$sid" -p Name --value) == "$USER_NAME" ]] || continue
        [[ $(loginctl show-session "$sid" -p Remote --value) == no ]] || continue
        session_type=$(loginctl show-session "$sid" -p Type --value)
        [[ $session_type == wayland || $session_type == x11 ]] || continue
        count=$((count + 1))
        [[ $(loginctl show-session "$sid" -p Active --value) == yes ]] ||
            die "Log into the local desktop as $USER_NAME, then reconnect the USB."
        [[ $(loginctl show-session "$sid" -p LockedHint --value) != yes ]] ||
            die "Unlock $USER_NAME's desktop, then reconnect the USB."
    done <<< "$sessions"
    [[ $count -eq 1 ]] || die "Exactly one local graphical session for $USER_NAME is required."
    user_systemctl is-active --quiet graphical-session.target || die "GNOME session is not ready."
    manager_env=$(user_systemctl show-environment) || die "Cannot connect to the user's systemd manager."
    # VLC 3's Qt interface uses XWayland within a Wayland desktop. GNOME exports
    # its actual DISPLAY/XAUTHORITY to this manager; never guess :0 or use xhost.
    grep -q '^DISPLAY=.' <<< "$manager_env" ||
        die "GNOME has not exported DISPLAY to systemd. Log out/in and reconnect the USB."
}

# Copy/verify/commit is separate from device handling so it can be tested using
# ordinary temporary directories. The USB is only erased after a durable copy.
import_contents() (
    set -euo pipefail
    # These live in this subshell, not in function-local scope: EXIT traps can
    # run after Bash has unwound local variables on a failed nested command.
    source=$1 stage='' backup='' differences='' unsupported='' entries=''
    cleanup_import() {
        local result=$?
        trap - EXIT
        [[ -z $stage ]] || rm -rf -- "$stage"
        # On failure, retain the backup for recovery instead of deleting old data.
        [[ -z $backup ]] || log "Previous contents retained at $backup/content"
        exit "$result"
    }
    trap cleanup_import EXIT
    entries=$(find "$source" -mindepth 1 -print -quit) || die "Cannot read USB contents."
    if [[ -z $entries ]]; then
        log "USB is empty; keeping the current destination."
        return 0
    fi
    unsupported=$(find "$source" -xdev -mindepth 1 ! -type f ! -type d -print -quit) ||
        die "Cannot inspect USB contents."
    [[ -z $unsupported ]] || die "USB must contain only regular files and directories (no links/devices)."
    stage=$(mktemp -d "${DEST%/*}/.usb-autorun-new.XXXXXX")
    rsync -rt --fsync -- "$source/" "$stage/" || die "USB copy failed; source and previous destination kept."
    differences=$(rsync -rct --dry-run --itemize-changes --delete -- "$source/" "$stage/") ||
        die "Copy verification failed; USB left intact."
    [[ -z $differences ]] || die "Copy verification found differences; USB left intact: $differences"
    # Do not import executable bits, ACLs, owners, or SELinux labels from the USB.
    chown -R root:"$USER_GROUP" "$stage"
    find "$stage" -type d -exec chmod 0750 {} +
    find "$stage" -type f -exec chmod 0640 {} +
    # GNU sync -f uses syncfs(), whose errors are observable. Bare sync() does
    # not report writeback errors and is insufficient before deleting a source.
    sync -f "$stage" || die "Staging filesystem flush failed; USB and previous destination kept."
    user_systemctl stop usb-autorun-player.service
    if [[ -e $DEST ]]; then
        backup=$(mktemp -d "${DEST%/*}/.usb-autorun-old.XXXXXX")
        mv -- "$DEST" "$backup/content"
    fi
    if ! mv -- "$stage" "$DEST"; then
        if [[ -n $backup ]]; then
            mv -- "$backup/content" "$DEST"
            rmdir "$backup"
            backup=''
        fi
        die "Cannot publish the verified copy; USB left intact."
    fi
    stage=''
    restorecon -RF "$DEST" || die "SELinux relabel failed; USB left intact."
    sync -f "$DEST" || die "Destination filesystem flush failed; USB left intact."
    # Fail closed on erase errors: never claim that a partial erase succeeded.
    find "$source" -xdev -mindepth 1 -delete || die "USB erase failed; verified copy is in $DEST."
    sync -f "$source" || die "USB filesystem flush failed; verified copy is in $DEST."
    if [[ -n $backup ]]; then
        rm -rf -- "$backup"
        backup=''
    fi
    log "Verified contents installed in $DEST; USB contents erased."
)

handle_device() (
    require_root
    validate_user
    name=${1:-} dev='' properties='' mp='' parent=''
    [[ $name =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid block device name."
    dev="/dev/$name"
    exec 9>/run/lock/usb-autorun.lock
    flock -w 300 9 || die "Another import is still running; reconnect this USB later."
    validate_destination
    [[ -b $dev ]] || die "Block device disappeared: $dev"
    properties=$(udevadm info --query=property --name="$dev")
    grep -qx 'ID_BUS=usb' <<< "$properties" || die "Refusing a non-USB device."
    grep -qx 'ID_FS_USAGE=filesystem' <<< "$properties" || die "Not a filesystem."
    grep -qxF "ID_FS_LABEL=$FS_LABEL" <<< "$properties" || die "USB label no longer matches."
    require_graphical_session
    if findmnt -rn --source "$dev" >/dev/null; then
        die "USB is already mounted. Unmount it, then unplug/reconnect it."
    fi
    cleanup_mount() {
        local result=$?
        trap - EXIT
        if [[ -n $mp ]]; then
            if mountpoint -q "$mp"; then
                umount "$mp" || { log "Could not unmount $mp; do not remove USB yet."; exit 1; }
            fi
            rmdir "$mp" || true
        fi
        exit "$result"
    }
    trap cleanup_mount EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mp=$(mktemp -d /run/usb-autorun-mnt.XXXXXX)
    mount -o rw,nosuid,nodev,noexec "$dev" "$mp"
    import_contents "$mp"
    umount "$mp"
    rmdir "$mp"
    mp=''
    parent=$(lsblk -dnro PKNAME "$dev")
    [[ -n $parent ]] || parent=$name
    # UDisks will refuse unsafe power-off (e.g. another mounted partition).
    if udisksctl power-off --no-user-interaction -b "/dev/$parent"; then
        log "USB powered off; safe to remove."
    else
        log "Imported volume unmounted; power-off failed. Check other partitions before removal."
    fi
    # Do not hold the import service/lock for the duration of the movie.
    user_systemctl restart usb-autorun-player.service
    log "Playback requested; see journalctl --user -u usb-autorun-player.service."
)

play_videos() {
    validate_user
    [[ $EUID -eq $USER_ID ]] || die "Playback must run as $USER_NAME."
    [[ -n ${DISPLAY:-} ]] || die "Missing GNOME/XWayland display environment."
    local video listing
    local -a videos=() options=(--intf=qt --no-one-instance --play-and-exit
        --no-random --no-loop --no-repeat --no-video-title-show --no-qt-privacy-ask --qt-continue=0)
    listing=$(mktemp)
    # Use a file, rather than process substitution, so find/sort errors propagate.
    if ! find "$DEST" -regextype posix-extended -type f \
        -iregex '.*\.(mp4|mkv|avi|mov|m4v|webm|mpg|mpeg|wmv|flv|ts|m2ts|ogv|3gp)$' \
        -print0 | LC_ALL=C sort -z > "$listing"; then
        rm -f "$listing"
        die "Cannot enumerate videos."
    fi
    while IFS= read -r -d '' video; do videos+=("$video"); done < "$listing"
    rm -f "$listing"
    if [[ ${#videos[@]} -eq 0 ]]; then log "No videos in $DEST."; return 0; fi
    [[ $FULLSCREEN != yes ]] || options+=(--fullscreen)
    export QT_QPA_PLATFORM=xcb
    exec vlc "${options[@]}" -- "${videos[@]}"
}

install_autorun() {
    require_root
    [[ -f /etc/fedora-release && ! -e /run/ostree-booted ]] ||
        die "This installer supports DNF-based Fedora Workstation (not Silverblue)."
    validate_user
    [[ $FS_LABEL =~ ^[a-zA-Z0-9_-]+$ ]] || die "Label must use letters, digits, underscores or hyphens."
    validate_destination
    log "Installing Fedora packages..."
    dnf install -y vlc vlc-gui-qt vlc-plugins-all xorg-x11-server-Xwayland \
        udisks2 rsync util-linux coreutils findutils grep systemd-udev \
        policycoreutils policycoreutils-python-utils
    for bin in vlc rsync flock findmnt mountpoint runuser udisksctl restorecon semanage; do
        command -v "$bin" >/dev/null || die "Required command missing after installation: $bin"
    done
    exec 9>/run/lock/usb-autorun.lock
    flock -w 300 9 || die "An import is running. Retry installation after it finishes."
    systemctl stop 'usb-autorun@*.service'
    install -d -m 0755 /usr/local/libexec /etc/systemd/user /etc/udev/rules.d
    install -o root -g root -m 0755 "${BASH_SOURCE[0]}" "$SCRIPT_FILE"
    # %q produces shell-safe values; only root may edit this configuration.
    local config_tmp
    config_tmp=$(mktemp)
    printf 'USER_NAME=%q\nFS_LABEL=%q\nDEST=%q\nFULLSCREEN=%q\n' \
        "$USER_NAME" "$FS_LABEL" "$DEST" "$FULLSCREEN" > "$config_tmp"
    install -o root -g root -m 0644 "$config_tmp" "$CONFIG_FILE"
    rm -f "$config_tmp"
    cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Import labeled USB volume %I and request VLC playback
After=local-fs.target systemd-logind.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE --handle %I
TimeoutStartSec=infinity
UMask=0077
UNIT
    cat > "$PLAYER_SERVICE" <<UNIT
[Unit]
Description=Play imported USB videos in the GNOME session
Requisite=graphical-session.target
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=exec
ExecStart=$SCRIPT_FILE --play
UMask=0077
Slice=app.slice
UNIT
    # Gating only USB filesystems also supports unpartitioned USB media.
    # UDISKS_IGNORE prevents GNOME automount from racing the private mount.
    cat > "$UDEV_RULE" <<RULE
ACTION=="add", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", ENV{ID_FS_LABEL}=="$FS_LABEL", ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-autorun@%k.service"
RULE
    chown root:root "$SERVICE_FILE" "$PLAYER_SERVICE" "$UDEV_RULE"
    chmod 0644 "$SERVICE_FILE" "$PLAYER_SERVICE" "$UDEV_RULE"
    install -d -o root -g "$USER_GROUP" -m 0750 "$DEST"
    # Persist labels across restorecon/relabel, leaving SELinux enforcing.
    local context_pattern="$DEST(/.*)?"
    if semanage fcontext -l -C | awk -v p="$context_pattern" '$1 == p { found=1 } END { exit !found }'; then
        semanage fcontext -m -t user_home_t "$context_pattern"
    else
        semanage fcontext -a -t user_home_t "$context_pattern"
    fi
    restorecon -F "$SCRIPT_FILE" "$CONFIG_FILE" "$SERVICE_FILE" "$PLAYER_SERVICE" "$UDEV_RULE"
    restorecon -RF "$DEST"
    systemctl daemon-reload
    systemctl start udisks2.service
    if [[ -S /run/user/$USER_ID/bus ]]; then
        user_systemctl daemon-reload
    else
        log "$USER_NAME is not logged in; the user service will load at next login."
    fi
    # Remove the previous version's runtime only after installing its replacement.
    rm -f /usr/local/bin/usb-autorun.sh
    udevadm control --reload-rules
    log "Installed for $USER_NAME: USB '$FS_LABEL' -> $DEST -> VLC."
    log "Successful imports REPLACE $DEST and ERASE the USB volume."
    log "Log into GNOME, unlock the desktop, then reconnect the USB. No reboot needed."
    log "Logs: sudo journalctl -u 'usb-autorun@*' -f"
}

uninstall_autorun() {
    require_root
    # Read the installed account rather than assuming the current sudo caller.
    if [[ -f $CONFIG_FILE ]]; then source "$CONFIG_FILE"; fi
    exec 9>/run/lock/usb-autorun.lock
    flock -w 300 9 || die "An import is running. Retry removal after it finishes."
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules
    systemctl stop 'usb-autorun@*.service'
    if USER_ID=$(id -u "$USER_NAME" 2>/dev/null) && [[ -S /run/user/$USER_ID/bus ]]; then
        user_systemctl stop usb-autorun-player.service
    fi
    rm -f "$SERVICE_FILE" "$PLAYER_SERVICE" "$SCRIPT_FILE" "$CONFIG_FILE" /usr/local/bin/usb-autorun.sh
    systemctl daemon-reload
    if [[ -n ${USER_ID:-} && -S /run/user/$USER_ID/bus ]]; then user_systemctl daemon-reload; fi
    log "Uninstalled. Kept $DEST, its SELinux file-context rule, packages, and existing logs."
    log "Unplug/reconnect the USB to restore GNOME's normal handling."
}

usage() {
    cat <<HELP
Usage: sudo bash $0 [--user NAME] [--label TEMP] [--dest /home/public] [--windowed]
       sudo bash $0 --delete

Installs packages, udev/systemd services, permissions, and SELinux labels for Fedora GNOME.
Default user: sudo's calling user (fallback: joao). Default playback: fullscreen.
WARNING: successful imports replace the destination and erase the labeled USB volume.
HELP
}

main() {
    umask 077
    case "${1:-}" in
        --help|-h) usage; return ;;
        --delete) [[ $# -eq 1 ]] || die "--delete takes no arguments."; uninstall_autorun; return ;;
        --handle|--play)
            local mode=$1
            shift
            [[ -r $CONFIG_FILE ]] || die "Missing installed configuration."
            source "$CONFIG_FILE"
            if [[ $mode == --handle ]]; then
                [[ $# -eq 1 ]] || die "--handle requires a device name."
                handle_device "$1"
            else
                [[ $# -eq 0 ]] || die "--play takes no arguments."
                play_videos
            fi
            return ;;
    esac
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user|--label|--dest)
                [[ $# -ge 2 && -n $2 ]] || die "Missing value for $1."
                case "$1" in
                    --user) USER_NAME=$2 ;; --label) FS_LABEL=$2 ;; --dest) DEST=$2 ;;
                esac
                shift 2 ;;
            --windowed) FULLSCREEN=no; shift ;;
            *) die "Unknown argument: $1 (see --help)." ;;
        esac
    done
    install_autorun
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
