#!/bin/bash
# Fedora Workstation / GNOME (Wayland). Run: sudo bash "$0" --user joao
# Any USB drive or optical disc opens in Kodi, in the first matching way:
#   watch.txt at its root  -> the paths it lists are copied to DEST;
#   disc labeled 1, 2, ... -> its zip parts collect in DEST, then are extracted;
#   label TEMP             -> the whole drive is copied to DEST;
#   anything else          -> Kodi browses the drive itself.
# A copy REPLACES DEST. Drives are only read. Once Kodi closes, the drive is
# powered off or the disc ejected. Nothing here ever starts VLC.
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
STATE_DIR="/var/lib/usb-autorun"
PENDING_FILE="$STATE_DIR/pending-set"
RUN_DIR="/run/usb-autorun"
FOLDER_FILE="$RUN_DIR/kodi-folder"
KODI_RPC_PORT=9090
# Kodi runs in its own user unit, so the player never owns or stops it.
KODI_UNIT="app-usb-autorun-kodi.service"
VIDEO_REGEX='.*\.(mp4|mkv|avi|mov|m4v|webm|mpg|mpeg|wmv|flv|ts|m2ts|ogv|3gp)$'
# Exit status of a refusal the user was already notified about.
REFUSED=3

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

# Critical urgency keeps the notification on screen until it is dismissed.
notify_user() {
    runuser -u "$USER_NAME" -- env \
        XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        notify-send --app-name="Media autorun" --urgency=critical -- "$1" "$2" ||
        log "Could not show the notification: $1"
}

# Tells the desktop user why the media was not imported, then fails.
refuse() {
    log "ERROR: $2"
    notify_user "$1" "$2"
    exit "$REFUSED"
}

# udev claims media only while the configured user is in front of seat0, so
# discs and drives stay with GNOME for everyone else. Errors leave them to GNOME.
owns_seat() {
    local session
    session=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null) || return 1
    [[ -n $session ]] || return 1
    [[ $(loginctl show-session "$session" -p Name --value 2>/dev/null) == "$USER_NAME" ]]
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
    # GNOME exports its actual WAYLAND_DISPLAY/DISPLAY to this manager, which
    # Kodi inherits; never guess :0 or use xhost.
    grep -qE '^(WAYLAND_DISPLAY|DISPLAY)=.' <<< "$manager_env" ||
        die "GNOME has not exported its display to systemd. Log out/in and reconnect the USB."
}

# Holds what the desktop user's player reads: the folder to open and disc mounts.
prepare_run_dir() {
    mkdir -p "$RUN_DIR"
    chown root:"$USER_GROUP" "$RUN_DIR"
    chmod 0750 "$RUN_DIR"
}

# Asks the desktop user's player to open FOLDER in Kodi.
show_in_kodi() {
    local folder_tmp
    prepare_run_dir
    folder_tmp=$(mktemp "$RUN_DIR/.kodi-folder.XXXXXX") || die "Cannot record the folder for Kodi."
    printf '%s\n' "$1" > "$folder_tmp"
    chown root:"$USER_GROUP" "$folder_tmp"
    chmod 0640 "$folder_tmp"
    mv -f -- "$folder_tmp" "$FOLDER_FILE" || die "Cannot record the folder for Kodi."
    user_systemctl restart usb-autorun-player.service
    log "Opening $1 in Kodi; see journalctl --user -u usb-autorun-player.service."
}

# Copies SOURCE into STAGE, or with LIST only the NUL-separated paths it names,
# and verifies the copy by checksum. LAYOUT "flat" drops the listed files'
# folders; "tree" keeps them and copies listed folders whole.
copy_verified() {
    local source=$1 stage=$2 list=${3:-} layout=${4:-flat} differences
    local -a selection=(-r) verify=(-rc --delete)
    if [[ -n $list ]]; then
        selection=(--from0 --files-from="$list")
        if [[ $layout == flat ]]; then selection+=(--no-relative); else selection+=(-r); fi
        verify=(-c "${selection[@]}")
    fi
    rsync "${selection[@]}" -t --fsync -- "$source/" "$stage/" ||
        die "Media copy failed; source and previous destination kept."
    differences=$(rsync "${verify[@]}" -t --dry-run --itemize-changes -- "$source/" "$stage/") ||
        die "Copy verification failed; source left intact."
    # Symlinks and device files are deliberately not copied; rsync notes each one.
    differences=$(grep -v '^skipping non-regular file ' <<< "$differences" || true)
    [[ -z $differences ]] || die "Copy verification found differences; source left intact: $differences"
}

# Do not import executable bits, ACLs, owners, or SELinux labels from the media.
seal_stage() {
    chown -R root:"$USER_GROUP" "$1"
    find "$1" -type d -exec chmod 0750 {} +
    find "$1" -type f -exec chmod 0640 {} +
    # GNU sync -f uses syncfs(), whose errors are observable. Bare sync() does
    # not report writeback errors and is insufficient before deleting a source.
    sync -f "$1" || die "Staging filesystem flush failed; source and previous destination kept."
}

# The importers below run in subshells that own $stage and $backup. These are
# subshell globals, not function locals: EXIT traps can run after Bash has
# unwound local variables on a failed nested command.
cleanup_staging() {
    local result=$?
    trap - EXIT
    [[ -z $stage ]] || rm -rf -- "$stage"
    # On failure, retain the backup for recovery instead of deleting old data.
    [[ -z $backup ]] || log "Previous contents retained at $backup/content"
    exit "$result"
}

# Replaces $DEST with the verified $stage, keeping the old copy in $backup.
publish_stage() {
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
        die "Cannot publish the verified copy; source left intact."
    fi
    stage=''
    restorecon -RF "$DEST" || die "SELinux relabel failed; source left intact."
    sync -f "$DEST" || die "Destination filesystem flush failed; source left intact."
}

drop_backup() {
    if [[ -n $backup ]]; then
        rm -rf -- "$backup"
        backup=''
    fi
}

# Copy/verify/commit is separate from device handling so it can be tested using
# ordinary temporary directories. With LIST, only the listed paths are copied
# (see copy_verified for LAYOUT). The source is never modified.
import_contents() (
    set -euo pipefail
    source=$1 list=${2:-} layout=${3:-flat} stage='' backup='' entries=''
    trap cleanup_staging EXIT
    if [[ -z $list ]]; then
        entries=$(find "$source" -mindepth 1 -print -quit) || die "Cannot read the drive."
        if [[ -z $entries ]]; then
            log "Drive is empty; keeping the current destination."
            return 0
        fi
    fi
    stage=$(mktemp -d "${DEST%/*}/.usb-autorun-new.XXXXXX")
    copy_verified "$source" "$stage" "$list" "$layout"
    seal_stage "$stage"
    publish_stage
    drop_backup
    log "Verified copy installed in $DEST."
)

# Writes to LIST, NUL-separated, the paths that SOURCE/watch.txt names: one per
# line, relative to the drive root; blank lines and # comments are skipped.
# Refuses the drive when an entry is missing or points outside it.
watch_list() {
    local source=$1 list=$2 line real root
    root=$(realpath -e -- "$source") || die "Cannot read the drive."
    : > "$list"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n $line && $line != \#* ]] || continue
        real=$(realpath -e -- "$root/${line#/}" 2>/dev/null) ||
            refuse "watch.txt not used" "Not found on the drive: $line"
        [[ $real == "$root"/* ]] || refuse "watch.txt not used" "Not on the drive: $line"
        printf '%s\0' "${real#"$root"/}" >> "$list"
    done < "$source/watch.txt"
    [[ -s $list ]] || refuse "watch.txt not used" "It lists no files."
}

refuse_if_pending() {
    if [[ -s $PENDING_FILE ]]; then
        refuse "Drive not copied" "Zip set $(<"$PENDING_FILE") in $DEST is still waiting for discs. Finish it, or discard it with: sudo $SCRIPT_FILE --reset-disc"
    fi
}

# Adds verified copies of the listed disc files to $DEST, keeping its contents.
add_to_destination() (
    set -euo pipefail
    source=$1 list=$2 stage='' backup=''
    trap cleanup_staging EXIT
    stage=$(mktemp -d "${DEST%/*}/.usb-autorun-new.XXXXXX")
    copy_verified "$source" "$stage" "$list"
    seal_stage "$stage"
    # The stage is on DEST's filesystem, so each file arrives by atomic rename.
    find "$stage" -mindepth 1 -maxdepth 1 -exec mv -t "$DEST" -- {} + ||
        die "Cannot move the verified copy into $DEST."
    restorecon -RF "$DEST" || die "SELinux relabel failed."
    sync -f "$DEST" || die "Destination filesystem flush failed."
    log "Verified disc files added to $DEST."
)

# Extracts a complete zip set from $DEST and publishes the result as $DEST,
# which removes the parts.
extract_parts() (
    set -euo pipefail
    volume=$1 stage='' backup='' unsupported=''
    trap cleanup_staging EXIT
    stage=$(mktemp -d "${DEST%/*}/.usb-autorun-new.XXXXXX")
    7z x -y -bso0 -bsp0 -o"$stage" -- "$volume" ||
        die "Extracting $volume failed; parts kept in $DEST."
    unsupported=$(find "$stage" -mindepth 1 ! -type f ! -type d -print -quit) ||
        die "Cannot inspect the extracted files."
    [[ -z $unsupported ]] ||
        die "Archive must contain only regular files and directories; parts kept in $DEST."
    seal_stage "$stage"
    publish_stage
    drop_backup
    log "Extracted ${volume##*/} into $DEST; parts removed."
)

# Prints the zip set (NAME.zip) a part belongs to: 7-Zip/split volumes are
# NAME.zip.001, NAME.zip.002, ...; Info-ZIP spans are NAME.z01, ..., NAME.zip.
part_set() {
    if [[ $1 =~ ^(.+\.zip)\.[0-9]{3,}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ $1 =~ ^(.+)\.z[0-9]{2,}$ ]]; then
        printf '%s.zip\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# Writes the last BYTES of the concatenated PARTS, seeking within large parts
# instead of streaming them.
tail_of_parts() {
    local bytes=$1 total=0 i
    shift
    local -a needed=()
    for ((i = $#; i >= 1 && total < bytes; i--)); do
        needed=("${!i}" "${needed[@]}")
        total=$((total + $(stat -c %s -- "${!i}")))
    done
    {
        tail -c "$bytes" -- "${needed[0]}"
        [[ ${#needed[@]} -eq 1 ]] || cat -- "${needed[@]:1}"
    } | tail -c "$bytes"
}

read_le() { od -An --endian=little -tu"$3" -j "$2" -N"$3" -- "$1" | tr -d ' '; }

# Prints how many volumes a zip spans, from the end-of-central-directory record
# at the end of PARTS (in order). Fails when the archive's end is not there yet.
zip_disk_count() {
    local tail size offset disk count=''
    tail=$(mktemp)
    # The record is 22 bytes plus a comment of up to 65535.
    tail_of_parts 65557 "$@" > "$tail"
    size=$(stat -c %s "$tail")
    # Latest match first; a real record's comment ends exactly at the file's end.
    for offset in $(LC_ALL=C grep -obaP 'PK\x05\x06' "$tail" | cut -d: -f1 | sort -rn); do
        (( offset + 22 <= size )) || continue
        (( offset + 22 + $(read_le "$tail" $((offset + 20)) 2) == size )) || continue
        disk=$(read_le "$tail" $((offset + 4)) 2)
        # ZIP64 moves the disk count into the locator just before the record.
        if (( disk == 0xFFFF && offset >= 20 )) &&
            [[ $(od -An -tx1 -j $((offset - 20)) -N4 -- "$tail" | tr -d ' ') == 504b0607 ]]; then
            count=$(read_le "$tail" $((offset - 4)) 4)
        else
            count=$((disk + 1))
        fi
        break
    done
    rm -f "$tail"
    [[ -n $count ]] && printf '%s\n' "$count"
}

# Prints "complete VOLUME" (the file to extract) when every part of SET is in
# DIR, otherwise "missing PART" naming the first part still needed.
zip_set_status() {
    local dir=$1 set=$2 stem=${2%.zip} file name final='' n disks
    local -A split=() span=()
    local -a volumes=()
    for file in "$dir/$stem".*; do
        [[ -f $file ]] || continue
        name=${file##*/}
        name=${name#"$stem".}
        if [[ $name =~ ^zip\.([0-9]{3,})$ ]]; then
            split[$((10#${BASH_REMATCH[1]}))]=$file
        elif [[ $name =~ ^z([0-9]{2,})$ ]]; then
            span[$((10#${BASH_REMATCH[1]}))]=$file
        elif [[ $name == zip ]]; then
            final=$file
        fi
    done
    if [[ ${#split[@]} -gt 0 ]]; then
        [[ ${#span[@]} -eq 0 ]] || { log "$set mixes .zip.NNN and .zNN parts."; return 1; }
        for ((n = 1; n <= ${#split[@]}; n++)); do
            [[ -n ${split[$n]:-} ]] || { printf 'missing %s.%03d\n' "$set" "$n"; return 0; }
            volumes+=("${split[$n]}")
        done
        if zip_disk_count "${volumes[@]}" >/dev/null; then
            printf 'complete %s\n' "${volumes[0]}"
        else
            printf 'missing %s.%03d\n' "$set" "$n"
        fi
        return 0
    fi
    for ((n = 1; n <= ${#span[@]}; n++)); do
        [[ -n ${span[$n]:-} ]] || { printf 'missing %s.z%02d\n' "$stem" "$n"; return 0; }
        volumes+=("${span[$n]}")
    done
    # Without the final NAME.zip, the span's length is unknown.
    if [[ -z $final ]]; then
        printf 'missing %s.z%02d or %s\n' "$stem" "$n" "$set"
        return 0
    fi
    disks=$(zip_disk_count "${volumes[@]}" "$final") || { log "$final has no zip directory."; return 1; }
    if (( disks > n )); then
        printf 'missing %s.z%02d\n' "$stem" "$n"
    elif (( disks == n )); then
        printf 'complete %s\n' "$final"
    else
        log "$final expects $disks volumes, but $n are present."
        return 1
    fi
}

# Copies the zip parts on a mounted disc into $DEST and sets disc_set to their
# set's name, or to '' for a disc without parts. The first disc of a set
# replaces $DEST and later discs add to it; another set must wait its turn.
copy_disc_parts() {
    local source=$1 label=$2 listing path name set pending='' has_video=''
    local -a paths=()
    local -A sets=() parts=() zips=() spans=() span_sets=() proven=()
    disc_set=''
    [[ ! -s $PENDING_FILE ]] || pending=$(<"$PENDING_FILE")
    listing=$(mktemp)
    if ! find "$source" -type f -printf '%P\0' > "$listing"; then
        rm -f "$listing"
        die "Cannot read the disc."
    fi
    mapfile -d '' -t paths < "$listing"
    rm -f "$listing"
    for path in "${paths[@]}"; do
        name=${path##*/}
        [[ $name != *$'\n'* ]] || continue
        [[ ! ${name,,} =~ $VIDEO_REGEX ]] || has_video=yes
        if ! set=$(part_set "$name"); then
            [[ $name != *.zip ]] || zips[$name]=$path
            continue
        fi
        if [[ $name =~ \.z[0-9]+$ ]]; then
            spans[$path]=$set
            span_sets[$set]=1
            continue
        fi
        sets[$set]=1
        [[ -z ${parts[$name]:-} ]] || refuse "Disc $label not imported" "It has two files named $name."
        parts[$name]=$path
    done
    # NAME.zNN is also used by other files, such as N64 ROMs (.z64), often beside
    # an ordinary NAME.zip. Count it as a span part only once its set is proven:
    # NAME.z01 opens with the spanning signature, NAME.zip spans several volumes,
    # or the set is already being collected. A disc holding nothing but one
    # unproven span (a later disc) still counts.
    local disks
    for set in "${!span_sets[@]}"; do
        if [[ $set == "$pending" ]]; then
            proven[$set]=1
        elif [[ -n ${zips[$set]:-} ]] && disks=$(zip_disk_count "$source/${zips[$set]}") &&
            (( disks > 1 )); then
            proven[$set]=1
        fi
    done
    for path in "${!spans[@]}"; do
        [[ ${path##*/} == "${spans[$path]%.zip}.z01" ]] || continue
        [[ $(head -c 4 -- "$source/$path" | od -An -tx1 | tr -d ' \n') != 504b0708 ]] ||
            proven[${spans[$path]}]=1
    done
    if [[ ${#proven[@]} -eq 0 && ${#sets[@]} -eq 0 && -z $has_video && ${#span_sets[@]} -eq 1 ]]; then
        proven[${!span_sets[*]}]=1
    fi
    for path in "${!spans[@]}"; do
        set=${spans[$path]}
        [[ -n ${proven[$set]:-} ]] || continue
        name=${path##*/}
        sets[$set]=1
        [[ -z ${parts[$name]:-} ]] || refuse "Disc $label not imported" "It has two files named $name."
        parts[$name]=$path
    done
    # A span ends in NAME.zip, which may sit alone on the set's last disc.
    for name in "${!zips[@]}"; do
        [[ -n ${sets[$name]:-} || $name == "$pending" ]] || continue
        sets[$name]=1
        parts[$name]=${zips[$name]}
    done
    [[ ${#sets[@]} -gt 0 ]] || return 0
    [[ ${#sets[@]} -eq 1 ]] || refuse "Disc $label not imported" "It holds parts of more than one zip set."
    set=${!sets[*]}
    if [[ -n $pending && $set != "$pending" ]]; then
        refuse "Disc $label not imported" "It belongs to $set, but $pending is still incomplete. Insert its next disc, or discard it with: sudo $SCRIPT_FILE --reset-disc"
    fi
    listing=$(mktemp)
    for name in "${!parts[@]}"; do
        [[ -n $pending && -e $DEST/$name ]] || printf '%s\0' "${parts[$name]}"
    done > "$listing"
    if [[ ! -s $listing ]]; then
        log "Disc $label: its parts of $set are already in $DEST."
    elif [[ -n $pending ]]; then
        add_to_destination "$source" "$listing"
    else
        import_contents "$source" "$listing"
        mkdir -p "$STATE_DIR"
        printf '%s\n' "$set" > "$PENDING_FILE"
    fi
    rm -f "$listing"
    disc_set=$set
}

# Asks for the next disc, or extracts the set and opens it in Kodi once complete.
finish_disc_parts() {
    local set=$1 label=$2 status
    status=$(zip_set_status "$DEST" "$set") ||
        refuse "Cannot use $set" "Its parts in $DEST are inconsistent (see the journal). Discard them with: sudo $SCRIPT_FILE --reset-disc"
    if [[ $status == missing\ * ]]; then
        log "Disc $label copied; still missing ${status#missing }."
        notify_user "Insert disc $((10#$label + 1))" "Disc $label is copied. Still needed: ${status#missing }."
        return 0
    fi
    notify_user "Extracting $set" "Every part is copied. Kodi opens when extraction finishes."
    extract_parts "${status#complete }"
    rm -f "$PENDING_FILE"
    show_in_kodi "$DEST"
}

# Waits for the desktop user's Kodi to start (it may take a while), then to close.
wait_for_kodi_close() {
    local attempt
    for ((attempt = 0; attempt < 60; attempt++)); do
        ! kodi_running || break
        sleep 1
    done
    while kodi_running; do sleep 5; done
}

# Unmounts the media mounted by handle_device, then powers off a USB drive or
# ejects a disc.
release_media() {
    local parent
    if [[ -n $mp ]]; then
        if mountpoint -q "$mp"; then
            umount "$mp" || { log "Could not unmount $mp; do not remove the media yet."; return 1; }
        fi
        rmdir "$mp" || true
        mp=''
    fi
    case $kind in
        disc) eject "$dev" || log "Could not eject $dev." ;;
        usb)
            parent=$(lsblk -dnro PKNAME "$dev" 2>/dev/null) || true
            [[ -n $parent ]] || parent=$name
            # UDisks refuses an unsafe power-off, e.g. with another partition mounted.
            if udisksctl power-off --no-user-interaction -b "/dev/$parent"; then
                log "Drive powered off; safe to remove."
            else
                log "Drive unmounted, but power-off failed. Check its other partitions before removal."
            fi ;;
    esac
    kind=''
}

# Mounts the drive or disc read-only and handles it as the header describes.
handle_media() {
    local label fs_type options list media
    label=$(sed -n 's/^ID_FS_LABEL=//p' <<< "$properties")
    fs_type=$(sed -n 's/^ID_FS_TYPE=//p' <<< "$properties")
    options=ro,nosuid,nodev,noexec
    if grep -qx 'ID_CDROM_MEDIA=1' <<< "$properties"; then
        # Readable by Kodi whatever modes the disc records.
        case $fs_type in
            iso9660) options+=,mode=0444,dmode=0555,overriderockperm ;;
            udf) options+=,mode=0444,dmode=0555 ;;
            *) die "Unsupported disc filesystem: ${fs_type:-unknown}" ;;
        esac
        media=disc
    else
        # A hard drive in a USB enclosure reports ID_BUS=ata (udev's ata_id wins);
        # usb_id still records the USB driver on every USB drive.
        grep -qE '^(ID_BUS=usb|ID_USB_DRIVER=.+)$' <<< "$properties" || die "Refusing a non-USB device."
        # Filesystems without Unix owners: let the desktop user's group read them.
        case $fs_type in
            vfat|exfat|ntfs|ntfs3)
                options+=",uid=0,gid=$(id -g "$USER_NAME"),fmask=0137,dmask=0027" ;;
        esac
        media=usb
    fi
    require_graphical_session
    if findmnt -rn --source "$dev" >/dev/null; then
        die "$dev is already mounted. Unmount it, then reconnect it."
    fi
    prepare_run_dir
    mp=$(mktemp -d "$RUN_DIR/media.XXXXXX")
    kind=$media
    mount -t "$fs_type" -o "$options" "$dev" "$mp"
    if [[ -f $mp/watch.txt ]]; then
        refuse_if_pending
        list=$(mktemp)
        watch_list "$mp" "$list"
        import_contents "$mp" "$list" tree
        rm -f "$list"
        show_in_kodi "$DEST"
    else
        if [[ $media == disc && $label =~ ^[0-9]+$ ]]; then copy_disc_parts "$mp" "$label"; fi
        if [[ -n $disc_set ]]; then
            # Eject now: the next disc goes in, and extraction can take a while.
            release_media
            finish_disc_parts "$disc_set" "$label"
            return 0
        fi
        if [[ ${label^^} == "${FS_LABEL^^}" ]]; then
            refuse_if_pending
            import_contents "$mp"
            show_in_kodi "$DEST"
        else
            show_in_kodi "$mp"
        fi
    fi
    # Other drives may be handled meanwhile.
    flock -u 9
    log "Releasing $dev once Kodi closes."
    wait_for_kodi_close
    release_media
}

handle_device() (
    require_root
    validate_user
    name=${1:-} dev='' properties='' mp='' kind='' disc_set=''
    [[ $name =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid block device name."
    dev="/dev/$name"
    exec 9>/run/lock/usb-autorun.lock
    flock -w 300 9 || die "Another import is still running; reconnect this media later."
    validate_destination
    [[ -b $dev ]] || die "Block device disappeared: $dev"
    properties=$(udevadm info --query=property --name="$dev")
    grep -qx 'ID_FS_USAGE=filesystem' <<< "$properties" || die "Not a filesystem."
    cleanup_mount() {
        local result=$?
        trap - EXIT
        release_media || exit 1
        # Refusals already told the user why; other failures point at the journal.
        case $result in
            0|"$REFUSED"|130|143) ;;
            *) notify_user "Media import failed" "See: sudo journalctl -u usb-autorun@$name" ;;
        esac
        exit "$result"
    }
    trap cleanup_mount EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    handle_media
)

# Sends one JSON-RPC REQUEST to Kodi on this machine and succeeds when Kodi
# answers it with a result. Kodi serves JSON-RPC on TCP while "Allow remote
# control from applications on this system" is on, which is its default.
# A subshell, so a refused connection cannot end the caller.
kodi_rpc() (
    local reply='' chunk
    exec 3<>"/dev/tcp/127.0.0.1/$KODI_RPC_PORT" || exit 1
    printf '%s' "$1" >&3
    # Replies are not newline-terminated, and notifications may precede them.
    while IFS= read -r -t 10 -d '}' -u 3 chunk; do
        reply+="$chunk}"
        [[ $reply != *'"id":1'* ]] || break
    done
    [[ $reply == *'"id":1'* && $reply == *'"result"'* ]]
)

kodi_running() { pgrep -u "$USER_ID" -x kodi.bin >/dev/null; }

# Runs as the desktop user: opens the requested folder in Kodi, starting Kodi
# if needed. Kodi is launched as a separate app, so only the user closes it.
open_kodi() {
    validate_user
    [[ $EUID -eq $USER_ID ]] || die "Kodi must run as $USER_NAME."
    [[ -n ${WAYLAND_DISPLAY:-}${DISPLAY:-} ]] || die "Missing GNOME display environment."
    [[ -s $FOLDER_FILE ]] || die "No folder recorded at $FOLDER_FILE."
    local folder request started='' attempt
    folder=$(<"$FOLDER_FILE")
    # Our folders are DEST and disc mounts; refuse anything JSON would need escaped.
    [[ $folder =~ ^/[a-zA-Z0-9_./-]+$ ]] || die "Unexpected folder: $folder"
    request='{"jsonrpc":"2.0","id":1,"method":"GUI.ActivateWindow","params":{"window":"videos","parameters":["'$folder'/","return"]}}'
    if ! kodi_running; then
        local -a options=()
        [[ $FULLSCREEN != yes ]] || options+=(-fs)
        # A short stop timeout keeps a hung Kodi from stalling logout for 90 s.
        systemd-run --user --quiet --collect --slice=app.slice --unit="$KODI_UNIT" \
            -p TimeoutStopSec=10 -- kodi "${options[@]}" || die "Cannot start Kodi."
        started=yes
    fi
    # Kodi answers once its interface is up; retry while it starts.
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if kodi_rpc "$request" 2>/dev/null; then
            log "Kodi shows $folder."
            break
        fi
        if [[ -n $started ]] && ! systemctl --user --quiet is-active "$KODI_UNIT"; then
            die "Kodi exited before it could open $folder."
        fi
        sleep 1
    done
    (( attempt <= 60 )) ||
        log "Kodi did not accept remote control; open $folder by hand, or enable Settings > Services > Control > Allow remote control from applications on this system."
}

reset_disc_set() {
    require_root
    exec 9>/run/lock/usb-autorun.lock
    flock -w 300 9 || die "An import is running. Retry after it finishes."
    if [[ -s $PENDING_FILE ]]; then
        log "Discarded the incomplete zip set $(<"$PENDING_FILE"); the next import replaces its parts in $DEST."
        rm -f "$PENDING_FILE"
    else
        log "No zip set is waiting for discs."
    fi
}

install_autorun() {
    require_root
    [[ -f /etc/fedora-release && ! -e /run/ostree-booted ]] ||
        die "This installer supports DNF-based Fedora Workstation (not Silverblue)."
    validate_user
    [[ $FS_LABEL =~ ^[a-zA-Z0-9_-]+$ ]] || die "Label must use letters, digits, underscores or hyphens."
    validate_destination
    # Fedora does not ship Kodi. RPM Fusion's build also brings its full
    # ffmpeg-libs (HEVC, E-AC3), which replaces Fedora's libavcodec-free.
    dnf repolist --enabled 2>/dev/null | grep -q '^rpmfusion-free[[:space:]]' ||
        die "Enable RPM Fusion Free first; Kodi comes from there: https://rpmfusion.org/Configuration"
    log "Installing packages..."
    dnf install -y --allowerasing kodi ffmpeg-libs \
        udisks2 rsync util-linux coreutils findutils grep procps-ng systemd-udev \
        policycoreutils policycoreutils-python-utils 7zip libnotify
    for bin in kodi rsync flock findmnt mountpoint runuser udisksctl restorecon semanage \
        7z notify-send eject pgrep; do
        command -v "$bin" >/dev/null || die "Required command missing after installation: $bin"
    done
    exec 9>/run/lock/usb-autorun.lock
    flock -w 300 9 || die "An import is running. Retry installation after it finishes."
    systemctl stop 'usb-autorun@*.service'
    install -d -m 0755 /usr/local/libexec /etc/systemd/user /etc/udev/rules.d
    install -d -m 0700 "$STATE_DIR"
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
Description=Open USB drive or disc %I in Kodi, copying it first when asked
After=local-fs.target systemd-logind.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE --handle %I
TimeoutStartSec=infinity
UMask=0077
UNIT
    cat > "$PLAYER_SERVICE" <<UNIT
[Unit]
Description=Open the USB/Blu-ray autorun folder in Kodi in the GNOME session
Requisite=graphical-session.target
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=exec
ExecStart=$SCRIPT_FILE --play
UMask=0077
Slice=app.slice
# It only waits for Kodi; stopping it never closes Kodi.
TimeoutStopSec=5
UNIT
    # Gating only USB filesystems also supports unpartitioned USB media.
    # SUBSYSTEMS matches any USB-attached drive: ID_BUS is "ata", not "usb", for
    # a hard drive in a USB enclosure.
    # UDISKS_IGNORE prevents GNOME automount from racing the private mount.
    # Inserting a disc is a "change" of an existing drive, and SYSTEMD_WANTS only
    # acts when a device first appears, so the disc rule starts the unit directly.
    # PROGRAM goes last so the seat is queried only for matching media.
    local seat_match="PROGRAM==\"$SCRIPT_FILE --owns-seat\""
    local claim='ENV{UDISKS_IGNORE}="1", ENV{UDISKS_AUTO}="0"'
    {
        printf '%s\n' "ACTION==\"add\", SUBSYSTEM==\"block\", KERNEL!=\"sr*\", SUBSYSTEMS==\"usb\", ENV{ID_FS_USAGE}==\"filesystem\", $seat_match, $claim, TAG+=\"systemd\", ENV{SYSTEMD_WANTS}+=\"usb-autorun@%k.service\""
        printf '%s\n' "ACTION==\"add|change\", SUBSYSTEM==\"block\", KERNEL==\"sr*\", ENV{ID_CDROM_MEDIA}==\"1\", ENV{ID_FS_USAGE}==\"filesystem\", $seat_match, $claim, RUN+=\"/usr/bin/systemctl --no-block start usb-autorun@%k.service\""
    } > "$UDEV_RULE"
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
    restorecon -F "$SCRIPT_FILE" "$CONFIG_FILE" "$SERVICE_FILE" "$PLAYER_SERVICE" "$UDEV_RULE" "$STATE_DIR"
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
    log "Installed for $USER_NAME: USB drives and discs open in Kodi."
    log "watch.txt, label '$FS_LABEL' or disc zip parts REPLACE $DEST with a copy first."
    log "Closing Kodi powers off the drive or ejects the disc."
    log "Log into GNOME, unlock the desktop, then reconnect the drive or insert the disc. No reboot needed."
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
    # Stop a player still opening Kodi; Kodi itself stays open.
    if USER_ID=$(id -u "$USER_NAME" 2>/dev/null) && [[ -S /run/user/$USER_ID/bus ]]; then
        user_systemctl stop usb-autorun-player.service
    fi
    systemctl stop 'usb-autorun@*.service'
    rm -f "$SERVICE_FILE" "$PLAYER_SERVICE" "$SCRIPT_FILE" "$CONFIG_FILE" /usr/local/bin/usb-autorun.sh
    rm -rf --one-file-system -- "$STATE_DIR" "$RUN_DIR"
    systemctl daemon-reload
    if [[ -n ${USER_ID:-} && -S /run/user/$USER_ID/bus ]]; then user_systemctl daemon-reload; fi
    log "Uninstalled. Kept $DEST, its SELinux file-context rule, packages, and existing logs."
    log "Reconnect drives or reinsert discs to restore GNOME's normal handling."
}

usage() {
    cat <<HELP
Usage: sudo bash $0 [--user NAME] [--label TEMP] [--dest /home/public] [--windowed]
       sudo bash $0 --delete
       sudo bash $0 --reset-disc

Installs packages, udev/systemd services, permissions, and SELinux labels for Fedora GNOME.
Default user: sudo's calling user (fallback: joao). Kodi starts fullscreen
unless --windowed, which leaves it to Kodi's own display setting.
Any USB drive or disc opens in Kodi (from RPM Fusion), the first rule that fits:
  watch.txt at its root      copies the paths it lists to the destination
  disc labeled 1, 2, ...     collects zip parts there, then extracts them
  label TEMP (--label)       copies the whole drive there
  otherwise                  Kodi browses the drive itself
WARNING: a copy replaces the destination. Drives are only read.
Closing Kodi powers off the drive or ejects the disc. VLC is never started.
--reset-disc discards a zip set that is still waiting for discs.
HELP
}

main() {
    umask 077
    case "${1:-}" in
        --help|-h) usage; return ;;
        --delete) [[ $# -eq 1 ]] || die "--delete takes no arguments."; uninstall_autorun; return ;;
        --reset-disc)
            [[ $# -eq 1 ]] || die "--reset-disc takes no arguments."
            if [[ -r $CONFIG_FILE ]]; then source "$CONFIG_FILE"; fi
            reset_disc_set
            return ;;
        --owns-seat)
            [[ -r $CONFIG_FILE ]] || return 1
            source "$CONFIG_FILE"
            owns_seat
            return ;;
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
                open_kodi
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
