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
| `fetch-subtitle.sh <movie>...` | Finds a subtitle for a movie online (OpenSubtitles.com, Podnapisi, BSPlayer, via subliminal) and syncs it to the movie's audio with ffsubsync. Saves `<movie>.pt-BR.srt` next to the file; `-l en` (repeatable) picks other languages. A subtitle that is already in sync is saved untouched; one that ffsubsync cannot align is skipped for the next candidate. OpenSubtitles.com needs a free account: see `--help`. | venv, `ffmpeg` |
| `bd-burn.sh <folder> [device] [label]` | Burns a folder to BD-R/DVD/CD. **Linux only.** | `xorriso` |
| `bd-overnight.sh <video>` | Overnight job: moves the video off an external drive into `~/Videos/temp` (then powers the drive down), and, **only if it is bigger than the Blu-ray in the drive**, shrinks it to fill the disc with two-pass 10-bit HEVC, burns it, verifies the burn by MD5 and powers the computer off. The x265 preset is chosen by test-encoding samples: the best VMAF among the presets projected to finish by `--deadline` (default 07:00), the slower one winning a tie. Audio and subtitles are copied untouched. **Linux only.** | `ffmpeg` with `libx265` + `libvmaf`, `xorriso`, `rsync`, `udisks2` |
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
├── bd-burn.sh                # bash, self-contained
├── bd-overnight.sh           # bash, self-contained
├── usb-autorun-installer.sh  # bash, self-contained
├── migrate-fedora-settings.sh # bash, self-contained (copy to a pendrive to use)
└── lib/
    ├── preflight.sh           # shared dependency check for the wrappers
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
        └── fetch-subtitle.py
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
`bd-overnight.sh` and `usb-autorun-installer.sh` are not usable on macOS.

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
