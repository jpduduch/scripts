# USB video autorun for Fedora Workstation

`usb-autorun-installer.sh` installs a background importer for DNF-based Fedora
Workstation with GNOME. **GNOME mounts drives and discs exactly as it always
does** — they appear in Files like anything else. The importer notices the new
mount, copies videos out of it into your `~/Videos`, and then releases the
media so you can unplug it.

Nothing is played. Kodi is installed so you can open it yourself; this tool
never starts it, and never starts VLC either.

Once GNOME has mounted the media, the first rule that fits decides what is
copied:

| The media has… | What is copied |
|---|---|
| `watch.txt` at its root | only the paths it lists (see below) |
| an optical disc (any label) | every video on it |
| the filesystem label `TEMP` (any case) | every video on it |
| anything else | nothing — it is left to GNOME |

Videos land **directly in `~/Videos`**, with no subfolders: `Movies/a/film.mkv`
on the drive becomes `~/Videos/film.mkv`. **A name already in `~/Videos` is left
alone** — nothing is ever replaced or deleted. Every copy is verified with an
rsync checksum pass, and the media is only ever read.

## Releasing the media

Media the importer took over is released as soon as it is done with it, so you
can simply unplug it:

| The media is… | What happens when the import finishes |
|---|---|
| a disc in the optical drive | unmounted, then the tray opens — which also frees the reader for the next disc of a set |
| any other drive | unmounted, then **powered down**, so an external hard drive spins down before you pull the cable |
| one this tool ignored | nothing — it stays mounted, exactly as GNOME left it |

There is no reliable way to tell a flash drive from an external hard drive, so
both are treated as a hard drive and powered down. Power-off targets the whole
disk, not the partition that was imported from, and only ever a drive UDisks
reports as USB-attached, removable, or hotpluggable — an internal disk mounted
under `/run/media` is unmounted but left powered on.

Releasing is best-effort and never fails an import that already succeeded. If
the unmount is refused — a file still open on the drive, say — nothing further
is attempted and the log says so. A drive with a **second partition still
mounted** unmounts cleanly but cannot power down, because UDisks refuses an
unsafe power-off; the log names the drive so you can check it before
unplugging. Media whose import was refused or failed is deliberately left
mounted so you can look at it.

## `watch.txt`

A drive with `watch.txt` at its root copies only what that file names: one path
per line, relative to the drive root. Blank lines and `#` comments are skipped,
and Windows line endings are fine:

```text
# Tonight
Movies/The Film (2024).mkv
Series/Show/Season 1
```

- A **file** entry is copied to `~/Videos/<its name>`, whatever its extension.
- A **folder** entry is copied whole, keeping its structure, to
  `~/Videos/<its name>` — but only when it holds a video somewhere inside
  (checked recursively). A folder with no video in it is skipped with a note in
  the log.
- An entry that is **missing**, or that points outside the drive (`..`, a
  symlink), refuses the whole drive and a notification names the entry.

There is no attempt to tell a flash drive from an external hard drive: every
non-optical device is treated the same way.

## Multi-part zip sets

Zip parts found by the rules above are not copied flat. They collect in
**`~/Videos/temp`**, and once every part has arrived the set is extracted into
`~/Videos` and `temp` is removed.

- **Part naming** — 7-Zip/split volumes (`name.zip.001`, `name.zip.002`, …) or
  Info-ZIP spans (`name.z01`, `name.z02`, …, `name.zip`). Case is ignored, so a
  disc that recorded `SET.ZIP.001` joins the same set as `set.zip.002` from
  another; the parts keep their own spelling, and messages name the set in
  lower case.
- **Several discs** — put in disc 1, then disc 2, and so on, in any order. After
  each disc a notification names the part still needed, and the disc is ejected.
  Reinserting a disc copies nothing new.
- **Completeness** — the set is complete once every part is present and the
  zip's end-of-central-directory record has arrived; that record also gives a
  span's volume count.
- **Lookalikes** — other files named like span parts, such as N64 ROMs
  (`game.z64`), are not parts. Two things must both hold.

  First the *set* has to be credible: its `.z01` starts with the zip spanning
  signature, its `.zip` spans several volumes, or parts of that set are already
  collected in `~/Videos/temp`.

  Then each *volume* has to fit the span. When the final `NAME.zip` has
  arrived, its record gives the exact volume count `D`, and only `.z01` …
  `.z(D-1)` are accepted — so `game.z64` beside a three-volume `game.zip` is
  refused outright, and discs may still arrive in any order. Until that final
  volume turns up the length is unknown, so the fallback is the one thing a
  span always guarantees: volumes run upwards from `.z01` with no gaps. A
  `.z64` is then taken only if `.z63` is on the same medium or already
  collected, and a volume refused this way also disqualifies everything above
  it. A lone `game.z64` is never a part. Refusals are named in the log.
- **Extraction** — files are extracted into a hidden staging folder on the same
  filesystem, checked, then moved into `~/Videos` one by one, dotfiles
  (subtitles, `.nfo`) included; a name already there is left alone. The set's
  parts are then deleted, and `temp` is removed once it holds no other set's
  parts.

Several sets can collect in `temp` at once; each is extracted as it completes.
To give up on what has been collected, run
`/usr/local/libexec/usb-autorun --reset`, which deletes `~/Videos/temp`.
Extraction needs room for the parts and the extracted files at the same time.

## Install

Copy the installer to the Fedora computer. From a terminal there:

```bash
sudo bash ./usb-autorun-installer.sh --user joao
```

Replace `joao` with the GNOME login name. Without `--user`, the installer uses
the user who invoked `sudo`.

**You do not have to be logged in as the target user.** Any account with `sudo`
can install this for any other, logged in or not. When the target user has no
running session, the installer writes the enablement symlink into their
`~/.config/systemd/user/default.target.wants/` itself — exactly what
`systemctl --user enable` would have written — and the watcher starts at their
next login. When they *are* logged in (including via fast user switching), the
watcher is armed immediately and no logout is needed.

One caveat when installing across accounts: `--dest` is expanded by *your*
shell, so `~/Videos` would mean *your* home. Spell the path out
(`--dest /home/joao/Films`); the installer refuses a destination outside the
target user's home.

The installer installs Kodi and RPM Fusion's `ffmpeg-libs`, UDisks, rsync,
7-Zip, libnotify, `xdg-user-dirs` and the required command-line utilities.
Fedora does not ship Kodi, so [RPM Fusion
Free](https://rpmfusion.org/Configuration) must be enabled first; the installer
stops if it is not and does not enable it itself.

It then installs two **user** units and enables them in the GNOME session:

- `usb-autorun.path` watches `/run/media/<user>`, the folder UDisks creates one
  entry in per mount.
- `usb-autorun.service` runs the importer once per change there.

No root service, no udev rule, no SELinux rule, and nothing privileged at
runtime: the import runs as the desktop user, into their own home.

Reconnect the drive or reinsert the disc. No reboot is required. Media that was
already mounted when the watcher started is deliberately not processed — the
watcher is edge-triggered, so unplug and replug it (or run
`/usr/local/libexec/usb-autorun --scan`). Use GNOME Disks to set a **filesystem
label** of `TEMP` if necessary.

Optional settings:

```bash
sudo bash ./usb-autorun-installer.sh --user joao --label VIDEOS --dest /home/joao/Films
```

Labels accept letters, digits, underscores, and hyphens. Without `--dest`, the
destination is the target user's XDG Videos folder, falling back to
`~/Videos`. A destination must be a folder inside that user's home — not the
home itself, and not on removable media. `.` and `..` are folded away before
that check, so a path cannot traverse out of the home; symlinks are left
alone, so pointing `~/Videos` at another disk works as you would expect.

Rerun the installer to update settings, passing your desired options again;
omitted options return to their defaults. Settings are stored in
`/etc/usb-autorun.conf`.

### Upgrading from the Kodi version

The previous version hid drives and discs from GNOME with a udev rule, mounted
them itself as root, replaced `/home/public` with each copy, and opened Kodi.
Installing this version removes that udev rule, both old services, and the old
pending-disc state, which is what restores GNOME's normal mounting. Files
already in `/home/public` are left where they are; move what you want to keep
into `~/Videos` yourself.

## Failure handling

A copy or checksum-verification failure removes only the partial copy it made
and raises a notification; whatever was already in `~/Videos` is untouched, and
the media is never modified. Symlinks and device files on the media are not
copied. Do not unplug while a copy is running — the service logs when it starts
and finishes.

Each mount is handled once; it is handled again only after the media has been
unmounted and reconnected. Imports are serialised with a lock in
`$XDG_RUNTIME_DIR/usb-autorun`, so two drives arriving together are copied one
after the other.

Fedora's own codec library cannot decode HEVC (H.265) video or E-AC3 audio,
which most 4K files use; RPM Fusion's full `ffmpeg-libs` replaces it. Fedora
Silverblue and the Flatpak Kodi are not installation targets.

## Logs and diagnostics

```bash
journalctl --user -u usb-autorun.service -f      # what was copied, and why not
systemctl --user status usb-autorun.path         # is the watcher armed?
/usr/local/libexec/usb-autorun --scan            # import what is mounted now
/usr/local/libexec/usb-autorun --reset           # discard ~/Videos/temp
```

If nothing happens when a drive is plugged in, check that GNOME actually
mounted it (it should be in Files, under `/run/media/<user>/<label>`) and that
`usb-autorun.path` is active. GNOME automounts removable media only when
`org.gnome.desktop.media-handling automount` is `true`.

## Uninstall

```bash
sudo bash ./usb-autorun-installer.sh --delete
```

This disables and removes both user units, the installed helper, and the
configuration, plus any leftovers from the Kodi version. Copied videos,
collected zip parts, installed packages, and logs are kept.

## Validation

```bash
bash -n usb-autorun-installer.sh
python3 -m unittest discover -s tests -v
```

The tests use temporary directories for real copies, deletions and extractions;
only the desktop notification bus and the block-device tools are substituted.
They cover flat copying with skip-on-existing, whole-folder copying, checksum
mismatches, partial-copy cleanup, media preservation, symlink escapes,
`watch.txt` parsing and refusals, span/split part detection including ROM
lookalikes, multi-disc collection, extraction, and releasing media — eject for
a disc, power-off of the whole disk for a drive, neither for an internal one
or after a refused unmount. Disc tests use directories as discs with real zip, split and span
archives, and real `7z` extraction when installed. GNU `find -regextype` is
required, so media-scanning tests are skipped off Linux. Full systemd-path,
UDisks and GNOME integration must be validated on Fedora with a disposable USB
containing test media.

Implementation references:
[systemd.path](https://www.freedesktop.org/software/systemd/man/systemd.path.html),
[systemd desktop integration](https://github.com/systemd/systemd/blob/main/docs/DESKTOP_ENVIRONMENTS.md),
and [UDisks mount points](https://storaged.org/doc/udisks2-api/latest/udisks.8.html).
