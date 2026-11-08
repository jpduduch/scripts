# scripts

Personal command-line scripts, consolidated from what used to be six separate
repositories (`tvbox-autorun`, `bd-burn`, `md-to-epub`, `font-fetcher`,
`url-to-md`, `dotfiles`).

Everything at the top level is meant to be called directly from the terminal
once this folder is on your `PATH`.

## Setup

```sh
./bootstrap.sh    # creates the shared Python venv and adds this folder to PATH
```

`bootstrap.sh` appends an `export PATH=...` line to `~/.zshrc` (zsh) or
`~/.bashrc` (bash; `~/.bash_profile` on macOS), unless one is already there.
If that file is a symlink (e.g. into a dotfiles repo), the line goes into the
real file and the link is kept. Other shells get the line printed to add by
hand. It is safe to re-run.

## Commands

| Command | What it does | Needs |
| --- | --- | --- |
| `url-to-md.sh <url>` | Converts an online article to Markdown or RTF. Consolidates same-prefix deeplinks into one file. | venv, `pandoc` (RTF only) |
| `fetch-fonts.sh <url>` | Downloads the `@font-face` fonts a page uses, one folder per family. `--convert` decompresses woff/woff2 to `.otf`/`.ttf`. | venv |
| `md-to-epub.sh` | Interactive Markdown to Kindle-friendly EPUB, with JetBrains Mono embedded and Mermaid blocks rendered to images. | `pandoc`, `magick` |
| `fetch-subtitle.sh <movie>...` | Finds a subtitle for a movie online (OpenSubtitles.com, Podnapisi, BSPlayer, via subliminal), syncs it with ffsubsync (against the movie's own Blu-ray PGS subtitle timings when it has any, otherwise its audio) and **embeds it in the file** as a selectable, default track; nothing is re-encoded. An OCR text track of the same language left by `dvd-to-mkv.sh` is replaced. The rewritten file is checked (duration, track counts, size) before it replaces the original, which needs free space for one copy of the movie. MKV goes through `mkvmerge` (keeps Dolby Vision, chapters, attachments), MP4/M4V/MOV through ffmpeg; other formats, or `--no-embed`, keep `<movie>.<lang>.srt` beside the file instead. Default language pt-BR; `-l en` (repeatable) picks others. OpenSubtitles.com needs a free account: see `--help`. | venv, `ffmpeg`, `mkvtoolnix` (MKV) |
| `dvd-to-mkv.sh [ORIGIN [DEST]]` | Converts DVDs (an `.iso`, a folder of them, a `VIDEO_TS` folder or `/dev/sr0`) into MKVs with every audio and subtitle track, their languages and the chapters, without re-encoding (DVD LPCM audio becomes lossless FLAC). Asks for the origin and the destination (default `~/Videos`) when not given. Converts the main (longest) title; `--title N` picks another, `--all` every title of `--min` minutes or more, leaving out a series disc's "play all" title. Each DVD subtitle (a picture) is also read with OCR (subtile-ocr + Tesseract) into a text track named `<Language> (OCR)`, kept beside the original picture track; `fetch-subtitle.sh` later replaces it with a downloaded subtitle. The OCR step is not tested yet. Nothing is overwritten; an interrupted run leaves no half-made file. Encrypted discs are not decrypted. Needs an ffmpeg with DVD support, which Fedora's lacks: `--help` shows how to install one for this script only. **Linux only.** | ffmpeg with `libdvdnav`, `mkvtoolnix`, `jq`, `tesseract` + language packs, `subtile-ocr` |
| `mkv-strip-tracks.sh <file.mkv>...` | Keeps only the movie's **original-language audio** and the **English subtitles** in MKV files, in place; video, chapters and attachments are kept and nothing is re-encoded. The original language comes from `--lang`, else the tracks the file flags as original, else a Wikidata lookup by the title and year in the file name (no account needed). Files whose audio is all one language skip the lookup. The result is checked (track counts, duration) before it replaces the original, which needs free space for one copy. A file whose language is unknown, or that has no audio in it, is left untouched; `--keep-und` also keeps tracks with no language set; `-n` only shows what would change. | venv, `mkvtoolnix`, `jq` |
| `bd-burn.sh <file-or-folder> [device] [label]` | Burns a file or a folder's contents to BD-R/DVD/CD, then reads the disc back and checks every file against the MD5 recorded with it. Checks the fit first (filesystem overhead included); a used disc gets a new session and nothing on it is overwritten. `--yes` asks nothing, `--name` renames a file on the disc, `--speed 4` caps the burn speed (safer on USB drives), `--free`/`--check` only report. `--each FILE...` burns one file per disc (the `bd-split.sh` volumes), waiting for each next blank disc: it asks, or with `--yes` watches the drive and sends a notification; labels end in the volume number. Exit 3 means it does not fit. Messages in Portuguese. **Linux only.** | `xorriso` |
| `bd-encode.sh <video>` | Shrinks a video just enough to fill the disc in the drive, as 10-bit HEVC, and prints the encode's path. Audio and subtitles are copied untouched. Picks the least destructive encoder whose encode plus burn fits in `--hours` (default 8): x265 *slow*, else NVENC (GPU), each timed on a short clip first; `--estimate` shows the timing, `--preset` forces one. A video that takes several discs as it is is shrunk onto one disc fewer (76 GB: 4 discs → 3), ready for `bd-split.sh`; `--discs N` picks the count. Before encoding it shows the plan: what each disc count would give (size, video bitrate) and the chosen one disc by disc. A video that already fits is left alone (exit 3); an encode left by an earlier run is reused. **Linux only.** | `ffmpeg` with `libx265` (NVENC optional), `bd-burn.sh`, `bd-split.sh` |
| `bd-split.sh <file>` | Splits a file too big for one disc into stored zip volumes (`NAME.zip.001`, `.002`, ...), each one filling the disc in the drive, the set `usb-autorun` collects and extracts. They land, tested, in a folder `NAME.discs` of their own (so `usb-autorun`, which collects parts in `~/Videos/temp`, never mistakes them for an incoming set). Every disc is taken to be blank and the same size as the one in the drive. The volumes are tested before their paths are printed; the file is kept. `--name` sets the file's name inside the zip (default: `movie.bd.mkv` goes in as `movie.mkv`); `--payload N` prints how much fits on N discs, zip headers included, which is what `bd-encode.sh` asks. A file that fits on one disc is left alone (exit 3). **Linux only.** | `7z`, `bd-burn.sh` |
| `bd-pack.sh [folder]` | Sorts the files and subfolders of a folder (default: the current one) into numbered folders, one per Blu-ray disc, ready for `bd-burn.sh`. Asks the disc size (25 GB single layer, 50 GB dual layer, 100 GB BDXL) and the first folder's number. Each disc gets the items that fill it the most (a subset-sum search); `--keep-order` fills them in name order instead. A subfolder is one item and moves whole. Shows the plan and asks before moving anything; `-n` only shows it. When numbered folders already exist, it asks whether to pack or to **undo** (move their contents back up one level and remove them); undo only runs when chosen. Nothing is overwritten. |  |
| `bd-overnight.sh <video>` | The overnight job, wrapping the two above: asks the disc label, moves the video off an external drive into `~/Videos/temp` (then powers the drive down), runs `bd-encode.sh` within 8 hours, burns with `bd-burn.sh`, deletes the encode once the burn is verified and powers the computer off. A video that already fits is not burned, and the computer stays on. After a failed burn the encode is kept and the next run burns it without encoding again. A video that takes several discs is shrunk onto one fewer, split with `bd-split.sh` and burned with `bd-burn.sh --each`: the first disc overnight, the rest as blank discs go in (a notification asks); each volume is deleted once its disc is verified, and a rerun carries on with the discs still to burn. **Linux only.** | `bd-encode.sh`, `bd-split.sh`, `bd-burn.sh`, `rsync`, `udisks2` |
| `bd-catalog.sh` | Adds every file on the disc in the drive to one shared CSV catalog (default `~/Documents/bd-catalog.csv`, `--output` to change): one row per file, `id,path`, the disc label and the file's path relative to the disc. Mounts the disc if needed; a disc whose id is already in the catalog is refused (exit 4, with a desktop notification) and nothing is written. Ejects the disc when done (`--no-eject` keeps it in); `--label` overrides the id. **Linux only.** | `udisks2` |
| `usb-mount.sh [DEVICE...]` | Mounts every removable drive (USB hard drives, flash drives, card readers, optical drives) through UDisks, closing an empty optical tray and waiting for the disc. `--off` unmounts everything, locks encrypted volumes and powers the drives off, ready to unplug; the next plain run powers them back on by switching their USB port off and on (sudo). `--rescan` does that to every empty port, for a drive powered off some other way. `--list` shows the drives, `-n` only shows what it would do. The system's own disk is never touched. **Linux only.** | `udisks2` |
| `copy-videos.sh [FOLDER...]` | Copies every video on the removable drives (mounting them first with `usb-mount.sh`) straight into `~/Videos`, with no subfolders, whatever folder each video sat in on the drive. Never overwrites: a video copied before is skipped, a different one with the same name gets ` (2)`; free space is checked first. Copies with `cp` straight under the final name, so Kodi can play a video while it is still copying; a copy that fails or is interrupted is deleted (after a crash or power loss, on the next run) and copied again. `-n` lists, `-d DIR` copies elsewhere, `--off` powers the drives off when every copy worked. Folders given are searched instead of the drives. **Linux only.** | `udisks2` |
| `usb-autorun-installer.sh` | Copies videos off USB drives and discs into `~/Videos` after GNOME mounts them normally. Triggered by a `watch.txt` at the drive root, the label `TEMP`, or any disc; multi-part zip sets collect in `~/Videos/temp` and are extracted once complete. Ejects the disc or powers the drive down afterwards. **Linux only, needs `sudo`. Never replaces existing files.** | Fedora, GNOME/Wayland |
| `migrate-fedora-settings.sh` | Exports dnf packages, flatpaks, GNOME extensions and dconf settings from one Fedora box and reinstalls them on another. **Linux only. Must be run from a pendrive** — it refuses to run from disk, and writes its export next to itself. | Fedora, `util-linux` |

Run any of them with `--help` where supported.

## Layout

```
scripts/
├── bootstrap.sh              # one-time venv setup
├── url-to-md.sh              # wrapper -> lib/python/convert-url-to-md.py
├── fetch-fonts.sh            # wrapper -> lib/python/fetch-fonts.py
├── fetch-subtitle.sh         # wrapper -> lib/python/fetch-subtitle.py
├── md-to-epub.sh             # bash, self-contained
├── mkv-strip-tracks.sh       # bash; asks lib/python/original-language.py
├── dvd-to-mkv.sh             # bash, self-contained (own DVD-capable ffmpeg)
├── bd-burn.sh                # bash, self-contained
├── bd-encode.sh              # bash; asks bd-burn.sh and bd-split.sh about the discs
├── bd-split.sh               # bash; asks bd-burn.sh about the disc
├── bd-catalog.sh             # bash, self-contained
├── bd-pack.sh                # bash, self-contained
├── bd-overnight.sh           # bash; wraps bd-encode.sh + bd-split.sh + bd-burn.sh
├── usb-mount.sh              # bash; uses lib/removable.sh
├── copy-videos.sh            # bash; uses lib/removable.sh and usb-mount.sh
├── usb-autorun-installer.sh  # bash, self-contained
├── migrate-fedora-settings.sh # bash, self-contained (copy to a pendrive to use)
└── lib/
    ├── preflight.sh           # shared dependency check for the wrappers
    ├── removable.sh          # finds removable drives, for usb-mount/copy-videos
    ├── fonts/                # JetBrains Mono, embedded by md-to-epub.sh
    ├── autorun/              # usb-autorun docs + test suite
    ├── font-fetcher/         # fetch-fonts reference docs
    └── python/
        ├── .venv/            # shared virtualenv (git-ignored)
        ├── requirements.txt  # declared deps (human-edited)
        ├── requirements.lock # exact versions + hashes (what bootstrap installs)
        ├── convert-url-to-md.py
        ├── x_extract.py      # X/Twitter extractor, imported by the above
        ├── fetch-fonts.py
        ├── fetch-subtitle.py
        └── original-language.py # movie's original language via Wikidata
```

The Python scripts keep their PEP 723 inline metadata, so they still run
standalone under `uv run --script` if you ever need them outside this folder.

## Tests

```sh
lib/python/.venv/bin/python -m unittest discover -s lib/autorun/tests -v
```

## External tools

`pandoc` and `imagemagick` come from `brew install pandoc imagemagick`.
`xorriso` is Linux-only (`sudo dnf install xorriso`) — `bd-burn.sh`,
`bd-encode.sh`, `bd-overnight.sh` and `usb-autorun-installer.sh` are not usable
on macOS.

## Dependency locking

`bootstrap.sh` installs from `lib/python/requirements.lock` with
`--require-hashes`, so rebuilding the venv always reproduces the exact set that
was tested — it can never silently pull a newer, broken library. The venv is
pinned to Python 3.12.

`requirements.txt` holds the loose, human-edited declarations. To take new
versions deliberately:

```sh
cd lib/python
uv pip compile requirements.txt --generate-hashes \
    --python-version 3.12 --output-file requirements.lock
cd ../.. && ./bootstrap.sh          # then re-test before committing
```
