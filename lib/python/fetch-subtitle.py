#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "subliminal>=2.3",
#     "ffsubsync>=0.4.29",
#     "pysubs2>=1.7",
# ]
# ///
"""Finds a subtitle for a movie online and syncs it to the movie's audio.

1. Checks the movie: it must have an audio track (ffsubsync listens to it).
   Lists embedded subtitle tracks and any subtitle file already next to it.
2. Identifies the movie (file hash, name, IMDb/TMDb metadata) and searches the
   subliminal providers (OpenSubtitles.com, Podnapisi, Gestdown, ...).
   Candidates are ranked by subliminal's score; a hash match means the
   subtitle was made for this exact file.
3. Downloads the best candidate and runs ffsubsync on it against the audio.
   - offset below --tolerance and no framerate change: already in sync,
     saved untouched;
   - otherwise the corrected version is saved;
   - ffsubsync cannot align it: the next candidate is tried (--tries).

The result is saved as <movie>.<lang>.srt next to the movie, which Jellyfin,
Plex, Kodi and VLC all pick up automatically.

OpenSubtitles.com (by far the biggest source) needs a free account to
download. Credentials come from OPENSUBTITLES_USERNAME/OPENSUBTITLES_PASSWORD,
or from ~/.config/fetch-subtitle/opensubtitles.conf (chmod 600):

    username = me
    password = secret
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import subprocess
import sys
import tempfile
from datetime import timedelta
from pathlib import Path

import pysubs2
from babelfish import Language
from subliminal import (
    ProviderPool,
    compute_score,
    refine,
    region,
    scan_video,
)
from subliminal.score import get_scores

DEFAULT_LANGUAGE = "pt-BR"
# Providers that serve movies. Left out: the legacy XML-RPC OpenSubtitles API
# (shut down), and addic7ed/gestdown/tvsubtitles/subtitulamos (TV only).
DEFAULT_PROVIDERS = ["opensubtitlescom", "podnapisi", "bsplayer"]
# omdb needs an API key and tvdb is TV only; hash + guessit + TMDb are enough.
REFINERS = ["hash", "metadata", "tmdb"]
CREDENTIALS_FILE = (Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
                    / "fetch-subtitle" / "opensubtitles.conf")
CACHE_FILE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "subliminal" / "cache.dbm"


def eprint(*args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)


class Fail(Exception):
    pass


# ---------------------------------------------------------------- 1. the movie

def probe(movie: Path) -> dict:
    """ffprobe the file; return its audio and subtitle streams."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-print_format", "json",
             "-show_streams", "-show_format", str(movie)],
            check=True, capture_output=True, text=True,
        ).stdout
    except subprocess.CalledProcessError as exc:
        raise Fail(f"ffprobe cannot read {movie.name}: {exc.stderr.strip()}") from exc
    info = json.loads(out)
    streams = info.get("streams", [])
    return {
        "audio": [s for s in streams if s.get("codec_type") == "audio"],
        "subs": [s for s in streams if s.get("codec_type") == "subtitle"],
        "duration": float(info.get("format", {}).get("duration") or 0),
    }


def check_movie(movie: Path, languages: list[Language]) -> None:
    info = probe(movie)
    if not info["audio"]:
        raise Fail(f"{movie.name} has no audio track, so there is nothing to sync against.")

    mins = int(info["duration"] // 60)
    eprint(f"  {len(info['audio'])} audio track(s), {mins} min")

    for s in info["subs"]:
        tag = (s.get("tags") or {}).get("language", "und")
        try:
            lang = Language.fromcode(tag, "alpha3b") if tag != "und" else None
        except ValueError:
            lang = None
        hit = lang is not None and any(lang.alpha3 == want.alpha3 for want in languages)
        mark = "  <- same language" if hit else ""
        eprint(f"  embedded subtitle: {tag} ({s.get('codec_name')}){mark}")


def output_path(movie: Path, lang: Language) -> Path:
    return movie.with_name(f"{movie.stem}.{lang}.srt")


# ------------------------------------------------------- 2. search and ranking

def identify(movie: Path):
    video = scan_video(str(movie))
    refine(video, refiners=REFINERS)  # failures are just logged
    what = getattr(video, "title", None) or getattr(video, "series", None) or movie.stem
    year = getattr(video, "year", None)
    eprint(f"  identified as: {what}{f' ({year})' if year else ''}")
    return video


def ranked_candidates(pool: ProviderPool, video, lang: Language) -> list:
    subs = pool.list_subtitles(video, {lang})
    scored = [(compute_score(s, video, hearing_impaired=False), s) for s in subs]
    scored.sort(key=lambda pair: pair[0], reverse=True)
    return scored


# ----------------------------------------------------------------- 3. syncing

def sync(movie: Path, srt_in: Path, srt_out: Path) -> dict:
    """Run ffsubsync with the movie's audio as reference."""
    from ffsubsync.ffsubsync import make_parser, run

    args = make_parser().parse_args([str(movie), "-i", str(srt_in), "-o", str(srt_out)])
    return run(args)


def max_shift(srt: Path, offset: float, scale: float) -> float:
    """Largest distance, in seconds, any line moves under ffsubsync's fix.

    The fix is linear (t -> t*scale + offset), so the extremes are the first
    and the last line. A tiny framerate factor on a short clip moves nothing;
    the same factor over two hours can drift several seconds.
    """
    events = pysubs2.load(str(srt), encoding="utf-8").events
    if not events:
        return abs(offset)
    ends = (min(e.start for e in events) / 1000, max(e.end for e in events) / 1000)
    return max(abs(t * scale + offset - t) for t in ends)


def process(movie: Path, video, pool: ProviderPool, lang: Language, opts) -> bool:
    dest = output_path(movie, lang)
    if dest.exists() and not opts.force:
        eprint(f"  {dest.name} already exists; use --force to replace it.")
        return True

    eprint(f"\n> [{lang}] searching...")
    candidates = ranked_candidates(pool, video, lang)
    if not candidates:
        eprint(f"  no {lang} subtitle found.")
        return False

    max_score = get_scores(video)["hash"]
    eprint(f"  {len(candidates)} candidate(s); trying up to {opts.tries}")

    best_unsynced: bytes | None = None
    with tempfile.TemporaryDirectory(prefix="fetch-subtitle-") as tmp:
        tmpdir = Path(tmp)
        tried = 0
        for score, sub in candidates:
            if tried >= opts.tries:
                break
            # The pool drops a provider after an error (bad login, quota...);
            # its remaining candidates can no longer be downloaded.
            if sub.provider_name in pool.discarded_providers:
                continue
            label = f"{sub.provider_name}:{sub.id}"
            if not pool.download_subtitle(sub) or not sub.is_valid():
                eprint(f"  - {label}: download failed or invalid, skipping")
                continue
            # Some providers serve .ass/.sub; normalise to UTF-8 SRT.
            try:
                sub.convert(output_format="srt", output_encoding="utf-8", fps=video.frame_rate)
            except Exception as exc:  # noqa: BLE001 - malformed files from providers
                eprint(f"  - {label}: cannot convert to SRT ({exc}), skipping")
                continue
            tried += 1

            hash_note = ", hash match" if "hash" in sub.get_matches(video) else ""
            eprint(f"  - {label} (score {score}/{max_score}{hash_note})")

            raw = tmpdir / f"cand{tried}.srt"
            fixed = tmpdir / f"cand{tried}.synced.srt"
            raw.write_bytes(sub.content)
            if best_unsynced is None:
                best_unsynced = sub.content

            eprint("    checking sync against the audio...")
            result = sync(movie, raw, fixed)
            if result.get("retval") or not result.get("sync_was_successful"):
                eprint("    ffsubsync could not align it; trying the next one")
                continue

            offset = result.get("offset_seconds") or 0.0
            scale = result.get("framerate_scale_factor") or 1.0
            shift = max_shift(raw, offset, scale)
            if shift < opts.tolerance:
                eprint(f"    already in sync (lines move at most {shift:.3f}s)")
                dest.write_bytes(sub.content)
            else:
                scale_note = f", framerate x{scale:.5f}" if abs(scale - 1.0) >= 1e-4 else ""
                eprint(f"    corrected: offset {offset:+.3f}s{scale_note} "
                       f"(lines moved up to {shift:.2f}s)")
                dest.write_bytes(fixed.read_bytes())
            eprint(f"  saved {dest}")
            print(dest)  # stdout: the saved path, for piping
            return True

    if best_unsynced is not None and opts.keep_unsynced:
        dest.write_bytes(best_unsynced)
        eprint(f"  no candidate could be synced; saved the best one UNSYNCED: {dest}")
        print(dest)
        return False
    eprint(f"  no {lang} candidate could be synced; nothing saved (see --keep-unsynced).")
    return False


# ---------------------------------------------------------------------- main

def opensubtitles_credentials() -> tuple[str, str] | None:
    user = os.environ.get("OPENSUBTITLES_USERNAME")
    password = os.environ.get("OPENSUBTITLES_PASSWORD")
    if user and password:
        return user, password
    if CREDENTIALS_FILE.is_file():
        conf = {}
        for line in CREDENTIALS_FILE.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not line.lstrip().startswith("#"):
                conf[key.strip().lower()] = value.strip()
        if conf.get("username") and conf.get("password"):
            return conf["username"], conf["password"]
    return None


def parse_language(code: str) -> Language:
    try:
        return Language.fromietf(code)
    except ValueError:
        raise argparse.ArgumentTypeError(f"unknown language code: {code!r} (use e.g. pt-BR, pt, en, es)")


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="fetch-subtitle.sh",
        description="Download a subtitle for a movie and sync it to the movie's audio.",
        epilog=f"OpenSubtitles.com needs a free account to download. Set "
               f"OPENSUBTITLES_USERNAME and OPENSUBTITLES_PASSWORD, or write "
               f"'username = ...' and 'password = ...' lines to {CREDENTIALS_FILE} "
               f"(chmod 600).",
    )
    ap.add_argument("movie", type=Path, nargs="+", help="movie file(s)")
    ap.add_argument("-l", "--language", type=parse_language, action="append", dest="languages",
                    help=f"subtitle language as an IETF code (pt-BR, pt, en, es...). "
                         f"Repeat for several. Default: {DEFAULT_LANGUAGE}")
    ap.add_argument("-f", "--force", action="store_true",
                    help="replace an existing <movie>.<lang>.srt")
    ap.add_argument("-n", "--tries", type=int, default=3,
                    help="how many candidates to try before giving up (default: 3)")
    ap.add_argument("-t", "--tolerance", type=float, default=0.15,
                    help="largest shift, in seconds, still considered in sync (default: 0.15)")
    ap.add_argument("--keep-unsynced", action="store_true",
                    help="if no candidate can be synced, save the best one anyway")
    ap.add_argument("-p", "--provider", action="append", dest="providers",
                    help=f"subtitle provider to use; repeat for several "
                         f"(default: {', '.join(DEFAULT_PROVIDERS)})")
    ap.add_argument("-v", "--verbose", action="store_true", help="show library logs")
    opts = ap.parse_args()
    languages = opts.languages or [Language.fromietf(DEFAULT_LANGUAGE)]

    # Unreachable providers are expected and skipped; their tracebacks are noise.
    logging.basicConfig(level=logging.INFO if opts.verbose else logging.CRITICAL,
                        format="    %(name)s: %(message)s")

    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    region.configure("dogpile.cache.dbm", expiration_time=timedelta(days=30),
                     arguments={"filename": str(CACHE_FILE)})

    # A title search for a popular movie can run to 20+ pages; the best matches
    # (hash, IMDb id) come first anyway.
    provider_configs = {"opensubtitlescom": {"max_result_pages": 3}}
    providers = opts.providers or DEFAULT_PROVIDERS
    creds = opensubtitles_credentials()
    if creds:
        provider_configs["opensubtitlescom"].update(username=creds[0], password=creds[1])
    elif "opensubtitlescom" in providers:
        eprint("warning: no OpenSubtitles.com account configured; it can search but not\n"
               "         download. Create a free one at opensubtitles.com and put it in\n"
               f"         {CREDENTIALS_FILE} (see --help).")
        providers = [p for p in providers if p != "opensubtitlescom"]

    ok = True
    with ProviderPool(providers=providers,
                      provider_configs=provider_configs) as pool:
        for movie in opts.movie:
            # absolute(), not resolve(): a symlinked movie gets its subtitle next to
            # the link the user passed, not next to the link target.
            movie = movie.expanduser().absolute()
            eprint(f"\n== {movie.name}")
            try:
                if not movie.is_file():
                    raise Fail(f"not a file: {movie}")
                check_movie(movie, languages)
                video = identify(movie)
                for lang in languages:
                    ok &= process(movie, video, pool, lang, opts)
            except (Fail, ValueError) as exc:
                eprint(f"  error: {exc}")
                ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
