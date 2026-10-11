#!/bin/bash
# Fedora Workstation / GNOME (Wayland). Run: sudo bash "$0" --user joao
# GNOME mounts every drive and disc exactly as it always does. Once a mount
# appears under /run/media/USER, videos are copied into the user's ~/Videos:
#   watch.txt at the drive root -> the paths it lists (a folder goes whole,
#                                  but only when it holds a video somewhere);
#   an optical disc             -> every video on it;
#   the label TEMP              -> every video on it;
#   anything else               -> nothing is copied.
# Multi-part zip sets found the same way collect in ~/Videos/temp and, once
# every part has arrived, are extracted into ~/Videos; temp is then removed.
# Copies never replace anything: a name already in ~/Videos is left alone.
# Media is only ever read. Nothing is played; Kodi is installed, never started.
set -euo pipefail

USER_NAME="${SUDO_USER:-joao}"
FS_LABEL="TEMP"
# Empty means the user's XDG Videos directory, falling back to ~/Videos.
DEST=""

CONFIG_FILE="/etc/usb-autorun.conf"
SCRIPT_FILE="/usr/local/libexec/usb-autorun"
PATH_UNIT="/etc/systemd/user/usb-autorun.path"
SERVICE_UNIT="/etc/systemd/user/usb-autorun.service"
# Left behind by the Kodi-launching version; removed on install and uninstall.
LEGACY_FILES=(
    /etc/udev/rules.d/99-usb-autorun.rules
    /etc/systemd/system/usb-autorun@.service
    /etc/systemd/user/usb-autorun-player.service
    /usr/local/bin/usb-autorun.sh
)
LEGACY_DIRS=(/var/lib/usb-autorun /run/usb-autorun)

VIDEO_REGEX='.*\.(mp4|mkv|avi|mov|m4v|webm|mpg|mpeg|wmv|flv|ts|m2ts|ogv|3gp)$'
# Exit status of a refusal the user was already notified about, and of media
# this tool deliberately leaves to GNOME.
REFUSED=3
IGNORED=4

log() { printf '[usb-autorun] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die "Run with sudo."; }

validate_user() {
    USER_ID=$(id -u "$USER_NAME") || die "User '$USER_NAME' does not exist."
    [[ $USER_ID -ne 0 ]] || die "Choose a desktop user, not root (--user NAME)."
    # runuser keeps the caller's HOME, so installing from another account would
    # otherwise resolve ~ against the installer's home, not the target user's.
    USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
    [[ -n $USER_HOME && -d $USER_HOME ]] ||
        die "User '$USER_NAME' has no home directory to copy into."
}

# Runs COMMAND as the desktop user with their own home and nothing of ours.
as_user() {
    runuser -u "$USER_NAME" -- env HOME="$USER_HOME" "$@"
}

user_systemctl() {
    as_user \
        XDG_RUNTIME_DIR="/run/user/$USER_ID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        systemctl --user "$@"
}

# Arms the watcher in the desktop user's session. Installing from a different
# account is fine: with that user logged out their systemd manager is not
# running, so make the same symlink `systemctl --user enable` would have made
# and let their next login pick it up.
enable_for_user() {
    local wants="$USER_HOME/.config/systemd/user/default.target.wants"
    if [[ -S /run/user/$USER_ID/bus ]]; then
        user_systemctl stop usb-autorun-player.service 2>/dev/null || true
        user_systemctl daemon-reload
        user_systemctl enable --now usb-autorun.path ||
            die "Cannot enable the watcher in $USER_NAME's session."
        log "The watcher is armed in $USER_NAME's running session."
        return
    fi
    as_user mkdir -p -- "$wants" || die "Cannot create $wants."
    as_user ln -sfn "$PATH_UNIT" "$wants/usb-autorun.path" ||
        die "Cannot enable the watcher for $USER_NAME."
    log "$USER_NAME is not logged in; the watcher is enabled and starts at their next login."
}

disable_for_user() {
    if [[ -n ${USER_ID:-} && -S /run/user/$USER_ID/bus ]]; then
        user_systemctl disable --now usb-autorun.path 2>/dev/null || true
        return
    fi
    [[ -z ${USER_HOME:-} ]] ||
        rm -f "$USER_HOME/.config/systemd/user/default.target.wants/usb-autorun.path"
}

# Critical urgency keeps the notification on screen until it is dismissed.
notify_user() {
    notify-send --app-name="Video autorun" --urgency=critical -- "$1" "$2" ||
        log "Could not show the notification: $1"
}

# Tells the desktop user why the media was not imported, then fails.
refuse() {
    log "ERROR: $2"
    notify_user "$1" "$2"
    exit "$REFUSED"
}

# ---------------------------------------------------------------- destination

# Folds away "." and ".." so a traversal cannot dress a path outside the home up
# as one inside it. Symlinks are deliberately left alone (-s): pointing
# ~/Videos at another disk is a normal thing to do.
normalise_path() { realpath -m -s -- "$1"; }

resolve_dest() {
    if [[ -z $DEST ]]; then
        DEST=$(xdg-user-dir VIDEOS 2>/dev/null) || DEST=""
        [[ -n $DEST && $DEST != "$HOME" ]] || DEST="$HOME/Videos"
    fi
    DEST=$(normalise_path "$DEST") || die "Cannot resolve the destination: $DEST"
    TEMP_DIR="$DEST/temp"
}

# The importer runs as the desktop user and only ever adds files, so the
# destination just has to be a real directory of theirs, never the media itself.
validate_destination() {
    local home
    [[ $DEST == /* ]] || die "Destination must be an absolute path: $DEST"
    DEST=$(normalise_path "$DEST") || die "Cannot resolve the destination: $DEST"
    home=$(normalise_path "$HOME") || die "Cannot resolve the home directory: $HOME"
    TEMP_DIR="$DEST/temp"
    [[ $DEST != /run/media/* ]] || die "Destination must not be on removable media: $DEST"
    [[ $DEST != "$home" ]] || die "Destination must be a folder inside $home, not $home itself."
    [[ $DEST == "$home"/* ]] || die "Destination must live inside $home: $DEST"
    mkdir -p -- "$DEST" || die "Cannot create the destination: $DEST"
    [[ -d $DEST ]] || die "Destination is not a directory: $DEST"
}

# --------------------------------------------------------------------- copying

# Copies SOURCE (a file or a whole folder) to FOLDER/NAME and verifies it by
# checksum. An existing NAME is left untouched. A failed copy or verification
# removes only what this call created; the media is never modified.
copy_item() {
    local source=$1 name=$2 folder=$3 target="$3/$2" differences
    local -a transfer=() verify=()
    if [[ -e $target ]]; then
        log "Already in $folder: $name"
        return 0
    fi
    if [[ -d $source ]]; then
        transfer=(-r -t --fsync -- "$source/" "$target/")
        verify=(-rc -t --dry-run --itemize-changes -- "$source/" "$target/")
    else
        transfer=(-t --fsync -- "$source" "$target")
        verify=(-c -t --dry-run --itemize-changes -- "$source" "$target")
    fi
    if ! rsync "${transfer[@]}" >/dev/null; then
        rm -rf -- "$target"
        die "Copying $name failed; nothing was added for it."
    fi
    if ! differences=$(rsync "${verify[@]}"); then
        rm -rf -- "$target"
        die "Verifying $name failed; nothing was added for it."
    fi
    # Symlinks and device files are deliberately not copied; rsync notes each one.
    differences=$(grep -v '^skipping non-regular file ' <<< "$differences" || true)
    if [[ -n $differences ]]; then
        rm -rf -- "$target"
        die "Verification found differences in $name: $differences"
    fi
    log "Copied to $folder: $name"
    copied=$((copied + 1))
}

# ------------------------------------------------------------------- zip sets

# Prints the zip set (NAME.zip) a part belongs to: 7-Zip/split volumes are
# NAME.zip.001, NAME.zip.002, ...; Info-ZIP spans are NAME.z01, ..., NAME.zip.
# An ISO9660 disc may record the names in upper case, so match without regard
# to case and answer in lower case: one set then has exactly one name, whatever
# the medium each part arrived on spelled it like.
part_set() {
    local lower=${1,,}
    if [[ $lower =~ ^(.+\.zip)\.[0-9]{3,}$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    elif [[ $lower =~ ^(.+)\.z[0-9]{2,}$ ]]; then
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
    local dir=$1 set=$2 stem=${2%.zip} file name suffix final='' n disks
    local -A split=() span=()
    local -a volumes=()
    # SET is lower case by construction (see part_set); the files on disc need
    # not be, so compare folded and split the suffix off by length.
    for file in "$dir"/*; do
        [[ -f $file ]] || continue
        name=${file##*/}
        [[ ${name,,} == "$stem".* ]] || continue
        suffix=${name:${#stem}+1}
        suffix=${suffix,,}
        if [[ $suffix =~ ^zip\.([0-9]{3,})$ ]]; then
            split[$((10#${BASH_REMATCH[1]}))]=$file
        elif [[ $suffix =~ ^z([0-9]{2,})$ ]]; then
            span[$((10#${BASH_REMATCH[1]}))]=$file
        elif [[ $suffix == zip ]]; then
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

# Succeeds when $TEMP_DIR already holds a part of SET, i.e. the set is being
# collected disc by disc.
temp_has_set() {
    local set=$1 file other
    [[ -d $TEMP_DIR ]] || return 1
    for file in "$TEMP_DIR"/*; do
        [[ -f $file ]] || continue
        other=$(part_set "${file##*/}") || continue
        [[ $other != "$set" ]] || return 0
    done
    return 1
}

# Prints the already-collected final volume (NAME.zip) of SET, if it has
# arrived on an earlier disc.
collected_final_zip() {
    local set=$1 file name
    [[ -d $TEMP_DIR ]] || return 1
    for file in "$TEMP_DIR"/*; do
        [[ -f $file ]] || continue
        name=${file##*/}
        [[ ${name,,} == "$set" ]] || continue
        printf '%s\n' "$file"
        return 0
    done
    return 1
}

# Prints how many volumes SET spans, reading the record at the end of its final
# NAME.zip wherever that has got to. Fails while that volume is still missing,
# which is simply when the span's length is not knowable yet.
set_volume_count() {
    local set=$1 final=${zips[$1]:-}
    [[ -n $final ]] || final=$(collected_final_zip "$set") || return 1
    zip_disk_count "$final"
}

# Records in `collected` which volumes of which set earlier discs have already
# contributed, so a part arriving on this one can be checked against them.
note_collected_volumes() {
    local file name set
    [[ -d $TEMP_DIR ]] || return 0
    for file in "$TEMP_DIR"/*; do
        [[ -f $file ]] || continue
        name=${file##*/}
        set=$(part_set "$name") || continue
        [[ ${name,,} =~ \.z([0-9]+)$ ]] || continue
        collected[$set/$((10#${BASH_REMATCH[1]}))]=1
    done
}

# Turns the candidate names in cand_parts/cand_zips into the real part files,
# in parts. Split volumes (NAME.zip.001) are unambiguous. NAME.zNN is also used
# by other files, such as N64 ROMs (.z64), so a span counts only once its set is
# proven: NAME.z01 opens with the zip spanning signature, a NAME.zip beside it
# spans several volumes, or the set is already collecting in $TEMP_DIR. Each
# volume then has to fit the span as well (see below), because a proven set
# sitting beside a ROM of the same name would otherwise swallow it.
classify_parts() {
    local path name set index disks n
    local -A span_sets=() by_index=() indexes=() zips=() proven=() volumes=() \
        collected=() admitted=()
    local -a order=()
    parts=()
    # Keyed by the folded name, so they line up with part_set's lower-case sets.
    for path in "${cand_zips[@]}"; do
        name=${path##*/}
        zips[${name,,}]=$path
    done
    for path in "${cand_parts[@]}"; do
        name=${path##*/}
        set=$(part_set "$name")
        if [[ ${name,,} =~ \.z([0-9]+)$ ]]; then
            index=$((10#${BASH_REMATCH[1]}))
            span_sets[$set]=1
            by_index[$set/$index]=$path
            indexes[$set]+=" $index"
        else
            parts+=("$path")
        fi
    done
    note_collected_volumes
    for set in "${!span_sets[@]}" "${!zips[@]}"; do
        if disks=$(set_volume_count "$set"); then
            volumes[$set]=$disks
            if (( disks > 1 )); then proven[$set]=1; fi
        fi
        if temp_has_set "$set"; then proven[$set]=1; fi
    done
    for set in "${!span_sets[@]}"; do
        path=${by_index[$set/1]:-}
        [[ -n $path ]] || continue
        [[ $(head -c 4 -- "$path" | od -An -tx1 | tr -d ' \n') != 504b0708 ]] ||
            proven[$set]=1
    done
    # Even a proven set only takes volumes that actually fit the span, so a
    # Nintendo 64 ROM sitting beside one of the same name is not swallowed.
    # Volumes are considered in ascending order, which is what makes the
    # no-gaps test below transitive.
    for set in "${!span_sets[@]}"; do
        [[ -n ${proven[$set]:-} ]] || continue
        mapfile -t order < <(printf '%s\n' ${indexes[$set]} | sort -n -u)
        for n in "${order[@]}"; do
            path=${by_index[$set/$n]}
            if [[ -n ${volumes[$set]:-} ]]; then
                # The final NAME.zip is here, so the length is known exactly:
                # volumes .z01 ... .z(D-1), then the .zip itself as volume D.
                # Being in range is proof enough, and lets discs arrive in any
                # order. game.z64 beside a 3-volume span is not in range.
                if (( n >= volumes[$set] )); then
                    log "Not part of $set, which spans ${volumes[$set]} volumes: ${path##*/}"
                    continue
                fi
            elif (( n > 1 )) &&
                [[ -z ${collected[$set/$((n - 1))]:-}${admitted[$set/$((n - 1))]:-} ]]; then
                # Length unknown, so fall back on the one thing a span always
                # guarantees: it numbers volumes upwards from .z01 with no
                # gaps. Volume N needs N-1 collected from an earlier disc or
                # admitted just now -- a real .z64 part needs a .z63 to go with
                # it, and a lone game.z64 has none.
                printf -v name '%s.z%02d' "${set%.zip}" $((n - 1))
                log "Not part of $set, no $name to go with it: ${path##*/}"
                continue
            fi
            admitted[$set/$n]=1
            parts+=("$path")
        done
    done
    # A span ends in NAME.zip, which may sit alone on the set's last disc.
    for name in "${!zips[@]}"; do
        [[ -n ${proven[$name]:-} ]] || continue
        parts+=("${zips[$name]}")
    done
}

# Extracts the complete set whose first VOLUME is given into $DEST, then drops
# its parts. Extraction lands in a staging folder first so a hostile archive
# cannot drop devices or sockets into $DEST, and so names already in $DEST
# survive. The staging folder shares $DEST's filesystem, so each entry moves by
# rename.
extract_set() {
    local volume=$1 set=$2 stage entry name unsupported file other
    stage=$(mktemp -d "$DEST/.usb-autorun-extract.XXXXXX") ||
        die "Cannot create a staging folder in $DEST."
    if ! 7z x -y -bso0 -bsp0 -o"$stage" -- "$volume"; then
        rm -rf -- "$stage"
        die "Extracting $set failed; its parts are kept in $TEMP_DIR."
    fi
    unsupported=$(find "$stage" -mindepth 1 ! -type f ! -type d -print -quit) || unsupported=''
    if [[ -n $unsupported ]]; then
        rm -rf -- "$stage"
        die "$set holds something that is not a file or folder; its parts are kept in $TEMP_DIR."
    fi
    # find, not a glob: an archive may hold dotfiles (subtitles, .nfo), and a
    # plain * would leave them behind to be deleted with the staging folder.
    while IFS= read -r -d '' entry; do
        name=${entry##*/}
        if [[ -e $DEST/$name ]]; then
            log "Already in $DEST, not extracted: $name"
            continue
        fi
        mv -- "$entry" "$DEST/$name" || die "Cannot move $name out of the staging folder."
        log "Extracted to $DEST: $name"
    done < <(find "$stage" -mindepth 1 -maxdepth 1 -print0)
    rm -rf -- "$stage"
    for file in "$TEMP_DIR"/*; do
        [[ -f $file ]] || continue
        other=$(part_set "${file##*/}") || continue
        [[ $other == "$set" ]] || continue
        rm -f -- "$file"
    done
    rmdir "$TEMP_DIR" 2>/dev/null || true
    log "Extracted $set into $DEST; its parts are gone."
}

# Reports every set with parts in $TEMP_DIR: asks for the next disc, or extracts.
finish_sets() {
    local file set status
    local -A seen=()
    [[ -d $TEMP_DIR ]] || return 0
    for file in "$TEMP_DIR"/*; do
        [[ -f $file ]] || continue
        set=$(part_set "${file##*/}") || continue
        [[ -z ${seen[$set]:-} ]] || continue
        seen[$set]=1
        if ! status=$(zip_set_status "$TEMP_DIR" "$set"); then
            notify_user "Cannot use $set" "Its parts in $TEMP_DIR are inconsistent (see the journal). Discard them with: $SCRIPT_FILE --reset"
            continue
        fi
        if [[ $status == missing\ * ]]; then
            log "$set is still missing ${status#missing }."
            notify_user "Insert the next disc" "$set still needs ${status#missing }."
        else
            notify_user "Extracting $set" "Every part has arrived."
            extract_set "${status#complete }" "$set"
            notify_user "$set is ready" "Extracted into $DEST."
        fi
    done
}

# ------------------------------------------------------------------ selection

# Fills sel_src/sel_name from SOURCE/watch.txt: one path per line, relative to
# the drive root; blank lines and # comments are skipped. A folder is taken
# whole, but only when it holds a video somewhere inside. Zip parts named there
# go to cand_parts instead. A missing entry, or one pointing outside the drive,
# refuses the drive.
watch_selection() {
    local source=$1 line real root name found
    root=$(realpath -e -- "$source") || die "Cannot read the drive."
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n $line && $line != \#* ]] || continue
        real=$(realpath -e -- "$root/${line#/}" 2>/dev/null) ||
            refuse "watch.txt not used" "Not found on the drive: $line"
        [[ $real == "$root"/* ]] || refuse "watch.txt not used" "Not on the drive: $line"
        name=${real##*/}
        if [[ -d $real ]]; then
            found=$(find "$real" -type f -regextype posix-extended \
                -iregex "$VIDEO_REGEX" -print -quit) || found=''
            if [[ -z $found ]]; then
                log "No video inside, skipped: $line"
                continue
            fi
            sel_src+=("$real")
            sel_name+=("$name")
        elif [[ -f $real ]]; then
            if part_set "$name" >/dev/null; then
                cand_parts+=("$real")
            else
                [[ ${name,,} != *.zip ]] || cand_zips+=("$real")
                sel_src+=("$real")
                sel_name+=("$name")
            fi
        else
            refuse "watch.txt not used" "Neither a file nor a folder: $line"
        fi
    done < "$source/watch.txt"
    [[ ${#sel_src[@]} -gt 0 || ${#cand_parts[@]} -gt 0 ]] ||
        refuse "watch.txt not used" "It names nothing to copy."
}

# Fills sel_src/sel_name with every video on SOURCE, and cand_parts/cand_zips
# with everything that could be part of a multi-part zip set.
whole_media_selection() {
    local source=$1 path name
    while IFS= read -r -d '' path; do
        name=${path##*/}
        if part_set "$name" >/dev/null; then
            cand_parts+=("$path")
        elif [[ ${name,,} == *.zip ]]; then
            cand_zips+=("$path")
        elif [[ ${name,,} =~ $VIDEO_REGEX ]]; then
            sel_src+=("$path")
            sel_name+=("$name")
        fi
    done < <(find "$source" -type f -print0)
}

# ------------------------------------------------------------------- handling

# Copies what MOUNTPOINT offers, as the header describes. Runs in a subshell so
# one unusable drive cannot stop the others in the same scan. Exits with
# IGNORED when the media is none of this tool's business.
import_mount() (
    set -euo pipefail
    source=$1 label=$2 optical=$3 copied=0 videos=0 i=0 path=''
    local -a sel_src=() sel_name=() cand_parts=() cand_zips=() parts=()
    if [[ -f $source/watch.txt ]]; then
        log "$source: using watch.txt."
        watch_selection "$source"
    elif [[ $optical == yes || ${label^^} == "${FS_LABEL^^}" ]]; then
        log "$source: copying its videos."
        whole_media_selection "$source"
    else
        log "$source: no watch.txt and not labelled $FS_LABEL; left to GNOME."
        exit "$IGNORED"
    fi
    validate_destination
    classify_parts
    # watch.txt may name a NAME.zip that turns out to be a span's last volume;
    # it belongs in the set's temp folder, not loose in the destination.
    local -A is_part=()
    for path in "${parts[@]}"; do is_part[$path]=1; done
    for ((i = 0; i < ${#sel_src[@]}; i++)); do
        [[ -z ${is_part[${sel_src[$i]}]:-} ]] || continue
        copy_item "${sel_src[$i]}" "${sel_name[$i]}" "$DEST"
    done
    videos=$copied
    if [[ ${#parts[@]} -gt 0 ]]; then
        mkdir -p -- "$TEMP_DIR" || die "Cannot create $TEMP_DIR."
        for path in "${parts[@]}"; do
            copy_item "$path" "${path##*/}" "$TEMP_DIR"
        done
        # finish_sets speaks for the parts: they are not in $DEST yet, so they
        # must not be announced as copied videos.
        finish_sets
    fi
    if [[ $videos -gt 0 ]]; then
        notify_user "Videos copied" "$videos item(s) from ${source##*/} are in $DEST."
    elif [[ $copied -eq 0 ]]; then
        log "$source: nothing new to copy."
    fi
)

# Unmounts and ejects a disc so the next one of a set can go in. USB drives are
# GNOME's to eject, and are left mounted.
release_disc() {
    local dev=$1
    udisksctl unmount --no-user-interaction -b "$dev" >/dev/null 2>&1 ||
        log "Could not unmount $dev; eject it from Files."
    eject "$dev" 2>/dev/null || log "Could not eject $dev."
}

# Drops the mounts this scan already dealt with that are gone, so the same media
# is handled again only after it has been reconnected.
prune_handled() {
    local dev dir uuid
    local -a keep=()
    [[ -f $HANDLED_FILE ]] || return 0
    while IFS=$'\t' read -r dev dir uuid; do
        [[ -n $dir ]] || continue
        mountpoint -q -- "$dir" 2>/dev/null || continue
        [[ $(findmnt -no SOURCE -M "$dir" 2>/dev/null) == "$dev" ]] || continue
        keep+=("$dev"$'\t'"$dir"$'\t'"$uuid")
    done < "$HANDLED_FILE"
    if [[ ${#keep[@]} -eq 0 ]]; then
        : > "$HANDLED_FILE"
    else
        printf '%s\n' "${keep[@]}" > "$HANDLED_FILE"
    fi
}

already_handled() {
    [[ -f $HANDLED_FILE ]] && grep -qxF -- "$1" "$HANDLED_FILE"
}

# Handles every drive and disc GNOME has mounted under /run/media/USER that this
# scan has not dealt with yet.
scan_media() {
    [[ $(id -un) == "$USER_NAME" ]] || die "Run the scan as $USER_NAME."
    local root="/run/media/$USER_NAME" dir dev uuid label optical key attempt status
    resolve_dest
    mkdir -p -- "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    flock -w 300 9 || die "Another import is still running; reconnect the media later."
    prune_handled
    if [[ ! -d $root ]]; then
        log "Nothing is mounted under $root."
        return 0
    fi
    for dir in "$root"/*; do
        [[ -d $dir ]] || continue
        # udisks makes the folder just before it mounts; give the mount a moment.
        for ((attempt = 0; attempt < 5; attempt++)); do
            mountpoint -q -- "$dir" && break
            sleep 1
        done
        mountpoint -q -- "$dir" || continue
        dev=$(findmnt -no SOURCE -M "$dir") || continue
        uuid=$(lsblk -dnro UUID -- "$dev" 2>/dev/null) || uuid=''
        key="$dev"$'\t'"$dir"$'\t'"$uuid"
        ! already_handled "$key" || continue
        printf '%s\n' "$key" >> "$HANDLED_FILE"
        label=$(lsblk -dnro LABEL -- "$dev" 2>/dev/null) || label=''
        [[ $(lsblk -dnro TYPE -- "$dev" 2>/dev/null) == rom ]] && optical=yes || optical=no
        status=0
        import_mount "$dir" "$label" "$optical" || status=$?
        case $status in
            # Only media this tool actually took over is ejected, so the next
            # disc of a set can go in. Everything else stays mounted for GNOME.
            0) [[ $optical != yes ]] || release_disc "$dev" ;;
            "$IGNORED") ;;
            # A refusal has already explained itself in a notification.
            "$REFUSED") log "$dir was refused." ;;
            *)
                log "$dir was not imported (status $status)."
                notify_user "Import failed" "Nothing was copied from ${dir##*/}. See: journalctl --user -u usb-autorun.service" ;;
        esac
    done
}

reset_temp() {
    resolve_dest
    # This deletes a tree, so re-run the destination checks rather than trusting
    # whatever /etc/usb-autorun.conf happens to say.
    validate_destination
    mkdir -p -- "$STATE_DIR"
    exec 9>"$STATE_DIR/lock"
    flock -w 300 9 || die "An import is running. Retry after it finishes."
    if [[ -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR"
        log "Discarded the collected zip parts in $TEMP_DIR."
    else
        log "No zip parts are waiting: $TEMP_DIR does not exist."
    fi
}

# ------------------------------------------------------------------ installing

install_autorun() {
    require_root
    [[ -f /etc/fedora-release && ! -e /run/ostree-booted ]] ||
        die "This installer supports DNF-based Fedora Workstation (not Silverblue)."
    validate_user
    [[ $FS_LABEL =~ ^[a-zA-Z0-9_-]+$ ]] || die "Label must use letters, digits, underscores or hyphens."
    # Kodi is installed for you to open yourself; this tool never launches it.
    # RPM Fusion's build also brings its full ffmpeg-libs (HEVC, E-AC3), which
    # replaces Fedora's libavcodec-free.
    dnf repolist --enabled 2>/dev/null | grep -q '^rpmfusion-free[[:space:]]' ||
        die "Enable RPM Fusion Free first; Kodi comes from there: https://rpmfusion.org/Configuration"
    log "Installing packages..."
    dnf install -y --allowerasing kodi ffmpeg-libs \
        udisks2 rsync util-linux coreutils findutils grep systemd \
        xdg-user-dirs 7zip libnotify
    for bin in rsync flock findmnt mountpoint lsblk runuser udisksctl realpath \
        7z notify-send eject xdg-user-dir; do
        command -v "$bin" >/dev/null || die "Required command missing after installation: $bin"
    done
    # --dest is written by whoever runs the installer, who may be another user;
    # it has to name a folder in the desktop user's home, not in theirs.
    if [[ -n $DEST ]]; then
        [[ $DEST == /* ]] || die "--dest must be an absolute path: $DEST"
        DEST=$(normalise_path "$DEST") || die "Cannot resolve --dest: $DEST"
        [[ $DEST == "$USER_HOME"/* ]] ||
            die "--dest must be a folder inside $USER_NAME's home ($USER_HOME)."
    fi
    local user_dest
    user_dest=$(as_user bash -c \
        'd=$(xdg-user-dir VIDEOS 2>/dev/null) || d=""; [[ -n $d && $d != "$HOME" ]] || d="$HOME/Videos"; printf %s "$d"')
    [[ -z $DEST ]] || user_dest=$DEST
    as_user mkdir -p -- "$user_dest" || die "Cannot create the destination: $user_dest"
    install -d -m 0755 /usr/local/libexec /etc/systemd/user
    install -o root -g root -m 0755 "${BASH_SOURCE[0]}" "$SCRIPT_FILE"
    # %q produces shell-safe values; only root may edit this configuration.
    local config_tmp
    config_tmp=$(mktemp)
    printf 'USER_NAME=%q\nFS_LABEL=%q\nDEST=%q\n' "$USER_NAME" "$FS_LABEL" "$DEST" > "$config_tmp"
    install -o root -g root -m 0644 "$config_tmp" "$CONFIG_FILE"
    rm -f "$config_tmp"
    # udisks creates one folder per mount under /run/media/USER, so a change to
    # that folder is a drive or disc arriving. Edge-triggered on purpose:
    # DirectoryNotEmpty= would restart the importer the moment it finished.
    cat > "$PATH_UNIT" <<UNIT
[Unit]
Description=Watch for USB drives and discs GNOME has mounted

[Path]
PathChanged=/run/media/%u
Unit=usb-autorun.service

[Install]
WantedBy=default.target
UNIT
    cat > "$SERVICE_UNIT" <<UNIT
[Unit]
Description=Copy videos from USB drives and discs into the Videos folder

[Service]
Type=oneshot
ExecStart=$SCRIPT_FILE --scan
TimeoutStartSec=infinity
UNIT
    chown root:root "$PATH_UNIT" "$SERVICE_UNIT"
    chmod 0644 "$PATH_UNIT" "$SERVICE_UNIT"
    # The Kodi-launching version hid media from GNOME with a udev rule; dropping
    # it is what restores normal mounting.
    rm -f "${LEGACY_FILES[@]}"
    rm -rf --one-file-system -- "${LEGACY_DIRS[@]}"
    systemctl stop 'usb-autorun@*.service' 2>/dev/null || true
    systemctl daemon-reload
    udevadm control --reload-rules
    systemctl start udisks2.service
    enable_for_user
    log "Installed for $USER_NAME. GNOME mounts drives and discs as usual."
    log "Videos go to ${user_dest}; zip parts collect in ${user_dest}/temp."
    log "A disc, or a drive labelled '$FS_LABEL', has every video copied; a drive"
    log "with watch.txt has only what it lists. Nothing else is copied."
    log "Logs: journalctl --user -u usb-autorun.service -f"
}

uninstall_autorun() {
    require_root
    # Read the installed account rather than assuming the current sudo caller.
    if [[ -f $CONFIG_FILE ]]; then source "$CONFIG_FILE"; fi
    # The account may be gone, so removal must survive an unknown user.
    USER_ID=$(id -u "$USER_NAME" 2>/dev/null) || USER_ID=''
    USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6) || USER_HOME=''
    disable_for_user
    rm -f "$PATH_UNIT" "$SERVICE_UNIT" "$SCRIPT_FILE" "$CONFIG_FILE" "${LEGACY_FILES[@]}"
    rm -rf --one-file-system -- "${LEGACY_DIRS[@]}"
    systemctl stop 'usb-autorun@*.service' 2>/dev/null || true
    systemctl daemon-reload
    udevadm control --reload-rules
    if [[ -n ${USER_ID:-} && -S /run/user/$USER_ID/bus ]]; then user_systemctl daemon-reload; fi
    log "Uninstalled. Copied videos, collected zip parts, packages and logs are kept."
}

usage() {
    cat <<HELP
Usage: sudo bash $0 [--user NAME] [--label TEMP] [--dest /home/NAME/Videos]
       sudo bash $0 --delete
       $SCRIPT_FILE --reset
       $SCRIPT_FILE --scan

Installs the packages and the two user units that copy videos off USB drives
and discs on Fedora Workstation with GNOME. Default user: sudo's calling user
(fallback: joao). Default destination: that user's XDG Videos folder.
Any account may install this for any other; --user does not have to be logged
in, and --dest must then be spelled out, inside that user's home.

GNOME keeps mounting drives and discs normally. Once mounted:
  watch.txt at the drive root  copies the paths it lists; a listed folder is
                               copied whole when it holds a video somewhere
  an optical disc              copies every video on it
  label TEMP (--label)         copies every video on it
  otherwise                    nothing is copied
Videos land directly in the destination; a name already there is left alone.
Multi-part zip sets collect in DEST/temp, are extracted into DEST once every
part has arrived, and temp is then removed. Discs are ejected after import so
the next one of a set can go in. Media is only ever read.

Kodi is installed for you to open yourself; this tool never launches it.
--reset discards the zip parts collected so far.
--scan imports what is mounted right now (what the watcher runs).
HELP
}

main() {
    umask 022
    case "${1:-}" in
        --help|-h) usage; return ;;
        --delete) [[ $# -eq 1 ]] || die "--delete takes no arguments."; uninstall_autorun; return ;;
        --reset|--scan)
            local mode=$1
            [[ $# -eq 1 ]] || die "$mode takes no arguments."
            [[ -r $CONFIG_FILE ]] || die "Missing installed configuration."
            source "$CONFIG_FILE"
            if [[ $mode == --reset ]]; then reset_temp; else scan_media; fi
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
            *) die "Unknown argument: $1 (see --help)." ;;
        esac
    done
    install_autorun
}

STATE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/usb-autorun"
HANDLED_FILE="$STATE_DIR/handled"

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
