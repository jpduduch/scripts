# USB video autorun for Fedora Workstation

`usb-autorun-installer.sh` installs a USB importer and Kodi launcher for
DNF-based Fedora Workstation with GNOME. Kodi runs in the real GNOME session
environment (Wayland or X11). It does not guess `DISPLAY=:0` or require
`xhost` changes. Nothing plays automatically, and VLC is never started.

Any USB drive (flash drive or external hard drive) or disc in the optical
drive is handled by the first rule that fits:

| The drive has… | What happens | Kodi opens |
|---|---|---|
| `watch.txt` at its root | the paths it lists are copied to `/home/public` | `/home/public` |
| a numeric disc label (`1`, `2`, …) and zip parts | the parts collect disc by disc, then are extracted (below) | `/home/public` |
| the label `TEMP` (any case) | the whole drive is copied to `/home/public` | `/home/public` |
| anything else | nothing is copied | the drive itself |

**When you close Kodi**, the drive is unmounted and powered off (a hard drive
spins down), or the disc tray opens. If Kodi was already open when the drive
arrived, closing that Kodi counts. A Kodi crash counts as closing too. Discs
with zip parts are ejected right after copying instead, so the next disc can go in.

Drives are mounted read-only (`ro,nosuid,nodev,noexec`) and are never
modified. Every copy goes to a staging directory, is verified with rsync
checksums, and then **replaces `/home/public`**. Symlinks and device files on
the drive are not copied. An empty `TEMP` drive keeps the current
`/home/public`. Kodi opens on the Videos view, starting fullscreen by default,
or reuses the Kodi that is already open.

`watch.txt` holds one path per line, relative to the drive root; folders are
copied whole and keep their structure. Blank lines and `#` comments are
skipped, and Windows line endings are fine:

```text
# Tonight
Movies/The Film (2024).mkv
Series/Show/Season 1
```

If an entry is missing or points outside the drive (`..`, a symlink), nothing
is copied and a notification names the entry.

## Discs with zip sets

A disc labelled with an integer (`1`, `2`, `3`, … as set by `bd-burn.sh`) may
carry one multi-disc zip set; the label is the disc's number in the set.

- **Zip parts** — 7-Zip/split volumes (`name.zip.001`, `name.zip.002`, …) or
  Info-ZIP spans (`name.z01`, `name.z02`, …, `name.zip`): the first disc of a
  set **replaces `/home/public`** with its verified parts, and later discs add
  theirs. After each disc, a notification asks for disc *label + 1* and names
  the part still needed. Discs may be inserted in any order; reinserting a disc
  copies nothing new. The set is complete once every part is present and the
  zip's end-of-central-directory record has arrived; that record also gives
  the span's volume count. Other files named like spans, such as N64 ROMs
  (`game.z64`), are not parts: a `.zNN` file counts only when its set's `.z01`
  starts with the zip spanning signature, its `.zip` spans several volumes, the
  set is already being collected, or the disc holds nothing else.
  Once the set is complete, `7z` extracts it, the extracted files replace
  `/home/public` (deleting the parts), and Kodi opens on it.

While a set is incomplete, discs from another set and other copies (which would
wipe the collected parts) are refused with a notification. Browsing a drive is
still allowed. To give up on the
set, run `sudo /usr/local/libexec/usb-autorun --reset-disc`; the next import
then replaces its parts. Parts must have unique names across the set, and a
disc may hold parts of only one set. Extraction needs room for the parts and
the extracted files at the same time.

## Install

Copy the installer to the Fedora computer. From a terminal there:

```bash
sudo bash ./usb-autorun-installer.sh --user joao
```

Replace `joao` with the GNOME login name. Without `--user`, the installer uses
the user who invoked `sudo`. Installing directly as root defaults to `joao`.

The installer automatically installs Kodi and RPM Fusion's `ffmpeg-libs`,
UDisks, rsync, 7-Zip, libnotify, the required command-line utilities, and
SELinux management tools. Fedora does not ship Kodi, so
[RPM Fusion Free](https://rpmfusion.org/Configuration) must be enabled first;
the installer stops if it is not and does not enable it itself.
It sets up both services, the USB rule, root-owned configuration, destination
permissions, and a persistent SELinux file-context rule. SELinux remains enabled.
No extra `sudoers`, polkit, device-group, display-access, or passwordless-sudo
permissions are required: mounting and power-off run in the root service;
Kodi runs in the user's systemd manager.

Log into GNOME as the configured user, unlock the desktop, and reconnect the drive.
Use GNOME Disks to set a **filesystem label** of `TEMP` if necessary. No reboot
is required. Already connected drives are deliberately not processed by installation.
USB drives and discs are hidden from GNOME's normal automount to avoid a mount race,
but only while the configured user holds the active desktop session. When any
other user is at the desktop, USB drives and discs are left to GNOME as usual;
after switching users, reconnect the drive or reinsert the disc.

Optional settings:

```bash
sudo bash ./usb-autorun-installer.sh --user joao --label VIDEOS --dest /srv/videos --windowed
```

`--windowed` stops forcing Kodi fullscreen, leaving it to Kodi's own display
setting. Labels accept letters, digits, underscores, and hyphens. The destination must be
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

A copy or checksum-verification failure keeps the previous destination. If publication or later cleanup fails, consult the journal: the
previous destination may remain in `/home/.usb-autorun-old.*/content` (or under
`/srv` for a `/srv` destination). Do not unplug while a copy is running.
The machine needs enough free space for the old destination plus the new
staging copy. Each partition of a drive is handled separately; the drive powers
off once Kodi closes and every partition is unmounted; check the log before
removing such a drive.

FAT, exFAT and NTFS drives are mounted readable by the desktop user's group.
On Linux filesystems (ext4, Btrfs, …), Kodi sees only what the files'
permissions allow the desktop user to read.

Fedora's own codec library cannot decode HEVC (H.265) video or E-AC3 audio,
which most 4K files use; RPM Fusion's full `ffmpeg-libs` replaces it. Test a
representative video in Kodi on the Fedora machine first. GNOME controls window
focus and locking; the installer does not change screen-lock or suspend
settings. Fedora Silverblue and the Flatpak Kodi are not installation targets.

The player points Kodi at the folder through Kodi's local JSON-RPC
(`127.0.0.1:9090`), which needs **Settings → Services → Control → Allow remote
control from applications on this system** (on by default). With it off, Kodi
still opens, and the player journal says to browse to the folder by hand.

## Logs and diagnostics

Importer logs (from any terminal):

```bash
sudo journalctl -u 'usb-autorun@*' -f
```

Kodi player logs and session checks (from the configured user's GNOME terminal):

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

The two services are event-driven; neither needs `systemctl enable`. Kodi
runs as its own app (`app-usb-autorun-kodi.service`), so the scripts never
close it: only you do. A new drive just points the open Kodi at its folder.
Logging out still ends Kodi like any app, but a hung Kodi gets 10 seconds, not
systemd's default 90, so it cannot stall the logout. Each drive's root service
(`usb-autorun@sdX1`) stays running until Kodi closes so it can release the
drive; it gives up the import lock first, so other drives are handled
meanwhile. Stopping that service (or shutting down) releases the drive at once.
Disc insertion is a
`change` event on an already present drive, and `SYSTEMD_WANTS` only acts when a
device first appears, so the disc rules start the service with `systemctl --no-block`.
Failures other than notified refusals raise a "Media import failed" notification
pointing at the journal.

## Uninstall

```bash
sudo bash ./usb-autorun-installer.sh --delete
```

This removes the USB and disc rules, both services, installed helper,
configuration, and any pending zip-set state.
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
graphical-session checks. Disc tests use directories as discs with real zip,
split and span archives, and real `7z` extraction when installed. On macOS, Linux-only flush operations are substituted;
those runs do not validate Linux durability. Kodi is substituted too. Full udev, systemd, SELinux, and Kodi integration must be validated on
Fedora with a disposable USB containing test media.

Implementation references: [Kodi JSON-RPC API](https://kodi.wiki/view/JSON-RPC_API),
[systemd desktop integration](https://github.com/systemd/systemd/blob/main/docs/DESKTOP_ENVIRONMENTS.md),
[UDisks device hints](https://storaged.org/doc/udisks2-api/latest/udisks.8.html),
and [Fedora SELinux file contexts](https://fedoraproject.org/wiki/SELinux/ManagingFileContext).
