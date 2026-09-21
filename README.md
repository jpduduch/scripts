# scripts

Personal command-line scripts, consolidated from what used to be six separate
repositories (`tvbox-autorun`, `bd-burn`, `md-to-epub`, `font-fetcher`,
`url-to-md`, `dotfiles`).

Everything at the top level is meant to be called directly from the terminal
once this folder is on your `PATH`.

## Setup

```sh
./bootstrap.sh                                   # creates the shared Python venv
export PATH="$HOME/Documents/dev/personal/misc/scripts:$PATH"   # add to ~/.zshrc
```

## Commands

| Command | What it does | Needs |
| --- | --- | --- |
| `url-to-md.sh <url>` | Converts an online article to Markdown or RTF. Consolidates same-prefix deeplinks into one file. | venv, `pandoc` (RTF only) |
| `fetch-fonts.sh <url>` | Downloads the `@font-face` fonts a page uses, one folder per family. `--convert` decompresses woff/woff2 to `.otf`/`.ttf`. | venv |
| `md-to-epub.sh` | Interactive Markdown to Kindle-friendly EPUB, with JetBrains Mono embedded and Mermaid blocks rendered to images. | `pandoc`, `magick` |
| `bd-burn.sh <folder> [device] [label]` | Burns a folder to BD-R/DVD/CD. **Linux only.** | `xorriso` |
| `usb-autorun-installer.sh` | Imports content from a labelled USB volume into a Fedora tvbox. **Linux only, needs `sudo`. Erases the USB volume on success.** | Fedora, GNOME/Wayland |

Run any of them with `--help` where supported.

## Layout

```
scripts/
├── bootstrap.sh              # one-time venv setup
├── url-to-md.sh              # wrapper -> lib/python/convert-url-to-md.py
├── fetch-fonts.sh            # wrapper -> lib/python/fetch-fonts.py
├── md-to-epub.sh             # bash, self-contained
├── bd-burn.sh                # bash, self-contained
├── usb-autorun-installer.sh  # bash, self-contained
└── lib/
    ├── fonts/                # JetBrains Mono, embedded by md-to-epub.sh
    ├── autorun/              # usb-autorun docs + test suite
    └── python/
        ├── .venv/            # shared virtualenv (git-ignored)
        ├── requirements.txt  # union of both scripts' dependencies
        ├── convert-url-to-md.py
        ├── x_extract.py      # X/Twitter extractor, imported by the above
        └── fetch-fonts.py
```

The two Python scripts keep their PEP 723 inline metadata, so they still run
standalone under `uv run --script` if you ever need them outside this folder.

## Tests

```sh
lib/python/.venv/bin/python -m unittest discover -s lib/autorun/tests -v
```

## External tools

`pandoc` and `imagemagick` come from `brew install pandoc imagemagick`.
`xorriso` is Linux-only (`sudo dnf install xorriso`) — `bd-burn.sh` and
`usb-autorun-installer.sh` are not usable on macOS.
