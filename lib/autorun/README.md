# USB video autorun for Fedora Workstation

`usb-autorun-installer.sh` installs a USB importer and VLC launcher for
DNF-based Fedora Workstation with GNOME. It supports a Wayland desktop;
VLC's Qt interface runs through XWayland using the real GNOME session
environment. It does not guess `DISPLAY=:0` or require `xhost` changes.

When a USB filesystem labeled `TEMP` is connected, the importer:

1. Requires the configured user to have one active, unlocked local desktop session.
2. Mounts the volume privately with `nosuid,nodev,noexec`.
3. Copies all files, including hidden files, to a staging directory and verifies
   their contents with rsync checksums.
4. Stops the previous autorun player and replaces `/home/public` with the verified copy.
5. Applies file permissions and SELinux labels, flushes writes, then **erases
   the contents of the USB volume**.
6. Unmounts the volume and asks UDisks to power off the drive.
7. Starts VLC as the desktop user, playing videos recursively in full-path
   alphabetical order (C locale), fullscreen by default.

Closing VLC or reaching the end of the playlist leaves the copied files in
`/home/public` (or the configured destination). They are removed only as part
of a successful replacement import from another matching USB flash drive or
USB-connected hard drive. Failed imports and empty drives keep the existing files.

**This is a destructive import workflow:** the previous destination contents are
replaced and the USB contents are deleted after verification. Use a dedicated
USB drive and destination. The label selects the volume; it is not device authentication.
An empty drive leaves the current destination intact and requests playback of
the existing videos. Symlinks and special files on the USB are rejected.

## Install

Copy the installer to the Fedora computer. From a terminal there:

```bash
sudo bash ./usb-autorun-installer.sh --user joao
```

Replace `joao` with the GNOME login name. Without `--user`, the installer uses
the user who invoked `sudo`. Installing directly as root defaults to `joao`.

The installer automatically installs VLC and its Fedora plugins, XWayland,
UDisks, rsync, the required command-line utilities, and SELinux management tools.
It sets up both services, the USB rule, root-owned configuration, destination
permissions, and a persistent SELinux file-context rule. SELinux remains enabled.
No extra `sudoers`, polkit, device-group, display-access, or passwordless-sudo
permissions are required: mounting and power-off run in the root service;
playback runs in the user's systemd manager.

Log into GNOME as the configured user, unlock the desktop, and reconnect the USB.
Use GNOME Disks to set the **filesystem label** to `TEMP` if necessary. No reboot
is required. Already connected drives are deliberately not processed by installation.
Matching drives are hidden from GNOME's normal automount to avoid a mount race.

Optional settings:

```bash
sudo bash ./usb-autorun-installer.sh --user joao --label VIDEOS --dest /srv/videos --windowed
```

Labels accept letters, digits, underscores, and hyphens. The destination must be
a dedicated directory directly below `/home` or `/srv`, using the same character
set. Account home directories, symlinks, mounted destinations, and destinations
containing mount points are rejected. The parent must be root-owned and not
writable by other users.

Rerun the installer to update settings, passing your desired options again;
omitted options return to their defaults. Settings are stored in
`/etc/usb-autorun.conf`. Do not edit that file to change the label or destination:
rerunning the installer also updates udev and SELinux rules.

## Permissions and failure handling

The managed media directory and imported files belong to root, with the desktop
user's primary group granted read access: directories `0750`, files `0640`.
The player can read the media, but the importer controls its replacement.
SELinux labels use a persistent `user_home_t` rule on the destination.
The installed program is `0755`; configuration and service files are root-owned
`0644`. Logs go to the journal, rather than a user-writable root log file.

A copy or checksum-verification failure preserves both the USB and previous
destination. If publication or later cleanup fails, consult the journal: the
previous destination may remain in `/home/.usb-autorun-old.*/content` (or under
`/srv` for a `/srv` destination). The importer never reports a failed erase as
successful. Do not unplug while an import is running.

The USB copy is deleted after durable local storage, **before playback is
confirmed**. A VLC/codec/display failure does not restore the USB; the verified
files remain in the destination. The machine needs enough free space for the
old destination plus the new staging copy. Other partitions on the same drive
can prevent power-off; check the log before removing such a drive.

Only codecs available from the machine's enabled repositories are installed.
Some video formats may need additional codecs from RPM Fusion; the installer
does not enable third-party repositories. Test a representative video in VLC
on the Fedora machine first. GNOME controls window focus and locking; the
installer does not change screen-lock or suspend settings. Fedora Silverblue
and Flatpak-only VLC installations are not installation targets.

## Logs and diagnostics

Importer logs (from any terminal):

```bash
sudo journalctl -u 'usb-autorun@*' -f
```

Playback logs and session checks (from the configured user's GNOME terminal):

```bash
journalctl --user -u usb-autorun-player.service -b
systemctl --user status graphical-session.target
systemctl --user show-environment | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)='
```

If GNOME has not exported its display environment, log out and back in, then
reconnect the USB. For SELinux failures, inspect `sudo ausearch -m AVC -ts recent`
and `ls -Zd /home/public`; do not disable SELinux. For filesystem errors, check
the importer journal and GNOME Disks. If a drive was already mounted, unmount
it before unplugging and reconnecting it.

The two services are event-driven; neither needs `systemctl enable`. The root
import service exits once it has requested playback, so it does not hold the
import lock for the length of a movie. A new import replaces the autorun playlist.

## Uninstall

```bash
sudo bash ./usb-autorun-installer.sh --delete
```

This removes the USB rule, both services, installed helper, and configuration.
It retains imported files, the destination's SELinux rule, installed packages,
and logs. Reconnect the USB afterward to restore GNOME's usual handling. The
uninstaller also removes the original version's `/usr/local/bin/usb-autorun.sh`.

## Validation

```bash
bash -n usb-autorun-installer.sh
python3 -m unittest discover -s tests -v
```

The tests use temporary directories for actual copies and deletion. Host services
and privileged metadata operations are substituted. They cover transfer failures,
verification mismatches, flush failures, source preservation, cleanup, and
graphical-session checks. On macOS, Linux-only flush operations are substituted;
those runs do not validate Linux durability. Full udev, systemd, SELinux, and VLC integration must be validated on
Fedora with a disposable USB containing test media.

Implementation references: [Fedora VLC packages](https://packages.fedoraproject.org/pkgs/vlc/),
[systemd desktop integration](https://github.com/systemd/systemd/blob/main/docs/DESKTOP_ENVIRONMENTS.md),
[UDisks device hints](https://storaged.org/doc/udisks2-api/latest/udisks.8.html),
and [Fedora SELinux file contexts](https://fedoraproject.org/wiki/SELinux/ManagingFileContext).
