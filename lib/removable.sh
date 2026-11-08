# Removable drives: finds the USB hard drives and SSDs, flash drives, card
# readers and optical drives plugged into the computer, and the filesystems
# on them. Shared by usb-mount.sh and copy-videos.sh.
# Sourced, never executed. Linux only (lsblk, findmnt, sysfs).

# A disk holding any of these is the system's own and is never touched,
# even when it sits on USB (a live system, an external boot disk).
_RM_SYSTEM_MOUNTS=' / /boot /boot/efi /efi /home /usr /var '

# _rm_kv KEY LINE: the value of KEY="..." in an `lsblk -P` line.
_rm_kv() {
    local re="(^| )$1=\"([^\"]*)\""
    [[ $2 =~ $re ]] || return 0
    printf '%b' "${BASH_REMATCH[2]}"     # lsblk writes odd bytes as \xNN
}

# rm_is_system_disk DISK: true when DISK (or anything on it) holds a system
# mount point or active swap.
rm_is_system_disk() {
    local src tgt dev
    local -A sys=()
    while read -r src tgt; do
        src=${src%%\[*}                   # btrfs: /dev/sda3[/home]
        [[ $_RM_SYSTEM_MOUNTS == *" $tgt "* ]] && sys[$src]=1
    done < <(findmnt -rn -o SOURCE,TARGET 2>/dev/null)
    while read -r src; do
        [[ -n $src ]] && sys[$src]=1
    done < <(swapon --show=NAME --noheadings 2>/dev/null)
    while read -r dev; do
        [[ -n ${sys[$dev]:-} ]] && return 0
    done < <(lsblk -nrpo PATH -- "$1" 2>/dev/null)
    return 1
}

# rm_disks: the removable whole disks and optical drives, one path per line.
# Removable = on USB, or flagged removable or hot-pluggable by the kernel
# (SD card slots, internal optical drives, eSATA/Thunderbolt).
rm_disks() {
    local line path type tran rm hp
    while IFS= read -r line; do
        path=$(_rm_kv PATH "$line"); type=$(_rm_kv TYPE "$line")
        tran=$(_rm_kv TRAN "$line"); rm=$(_rm_kv RM "$line"); hp=$(_rm_kv HOTPLUG "$line")
        [[ $type == disk || $type == rom ]] || continue
        [[ $tran == usb || $rm == 1 || $hp == 1 ]] || continue
        rm_is_system_disk "$path" && continue
        printf '%s\n' "$path"
    done < <(lsblk -dnpP -o PATH,TYPE,TRAN,RM,HOTPLUG 2>/dev/null)
}

# rm_volumes DISK: "PATH<TAB>FSTYPE" for every filesystem or encrypted
# container on DISK, the disk itself included (unpartitioned sticks, discs)
# and unlocked LUKS volumes below it. Parents come before their children.
rm_volumes() {
    local line path fs
    while IFS= read -r line; do
        path=$(_rm_kv PATH "$line"); fs=$(_rm_kv FSTYPE "$line")
        case $fs in
            ''|swap|LVM2_member|linux_raid_member|zfs_member|isw_raid_member) continue ;;
        esac
        printf '%s\t%s\n' "$path" "$fs"
    done < <(lsblk -npP -o PATH,FSTYPE -- "$1" 2>/dev/null)
}

# rm_mountpoint DEV: where DEV is mounted (first mount point), or nothing.
rm_mountpoint() {
    findmnt -nf -o TARGET --source "$1" 2>/dev/null || true
}

# rm_field DEV COLUMN: one lsblk column of DEV itself, trimmed.
rm_field() {
    local v
    v=$(lsblk -dno "$2" -- "$1" 2>/dev/null || true)
    v=${v#"${v%%[![:space:]]*}"}
    printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# rm_describe DISK: "Model (size)" for messages.
rm_describe() {
    local model size
    model=$(rm_field "$1" MODEL); size=$(rm_field "$1" SIZE)
    [[ -n $model ]] || model=$(rm_field "$1" VENDOR)
    [[ -n $model ]] || model=${1##*/}
    if [[ -n $size && $size != 0B ]]; then
        printf '%s (%s)' "$model" "$size"
    else
        printf '%s' "$model"
    fi
}

# rm_has_medium DISK: false for an optical drive with no disc in it or a
# card reader with no card.
rm_has_medium() {
    if [[ $(rm_field "$1" TYPE) == rom ]]; then
        udevadm info -q property -n "$1" 2>/dev/null | grep -qx 'ID_CDROM_MEDIA=1'
    else
        [[ $(lsblk -dnbo SIZE -- "$1" 2>/dev/null | tr -d ' ') != 0 ]]
    fi
}

# rm_usb_port DISK: the sysfs path of the USB hub port the drive hangs off
# (…/usbN-portM), or fails when it is not a USB drive. Read it before the
# drive is powered off: afterwards the device is gone from sysfs.
rm_usb_port() {
    local d
    d=$(readlink -f "/sys/class/block/${1##*/}/device" 2>/dev/null) || return 1
    while [[ $d == /sys/devices/* ]]; do
        if [[ -e $d/idVendor && -L $d/port ]]; then
            readlink -f "$d/port"
            return 0
        fi
        d=${d%/*}
    done
    return 1
}
