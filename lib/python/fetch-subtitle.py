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

4. Embeds the subtitles into the movie as selectable tracks (MKV with
   mkvmerge, MP4/M4V/MOV with ffmpeg). Nothing is re-encoded. The new file is
   written next to the movie, checked (duration, track count, size) and only
   then swapped in; on any failure the original is left untouched and the
   subtitle stays beside it as <movie>.<lang>.srt.
   With --no-embed, only <movie>.<lang>.srt is written, which Jellyfin, Plex,
   Kodi and VLC also pick up automatically.

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
import shutil
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
MKV_EXTS = {".mkv"}
FFMPEG_EXTS = {".mp4", ".m4v", ".mov"}  # subtitles go in as mov_text
# Room left over after writing a copy of the movie.
SPACE_MARGIN = 512 * 1024 * 1024
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
        "video": [s for s in streams if s.get("codec_type") == "video"],
        "audio": [s for s in streams if s.get("codec_type") == "audio"],
        "subs": [s for s in streams if s.get("codec_type") == "subtitle"],
        "duration": float(info.get("format", {}).get("duration") or 0),
    }


def check_movie(movie: Path, languages: list[Language]) -> set[str]:
    """Print what the movie has; return the alpha3 codes of its embedded subtitles."""
    info = probe(movie)
    if not info["audio"]:
        raise Fail(f"{movie.name} has no audio track, so there is nothing to sync against.")

    embedded: set[str] = set()
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
        if lang is not None:
            embedded.add(lang.alpha3)
    return embedded


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


def process(movie: Path, video, pool: ProviderPool, lang: Language, opts,
            embedded: set[str]) -> tuple[bool, Path | None]:
    """Find, download and sync one language.

    Returns (ok, path of a synced .srt ready to embed, or None).
    """
    dest = output_path(movie, lang)
    if not opts.force:
        if dest.exists():
            eprint(f"\n> [{lang}] {dest.name} already exists; use --force to replace it.")
            return True, None
        if opts.embed and lang.alpha3 in embedded:
            eprint(f"\n> [{lang}] the movie already has an embedded {lang.name} subtitle; "
                   f"use --force to add another.")
            return True, None

    eprint(f"\n> [{lang}] searching...")
    candidates = ranked_candidates(pool, video, lang)
    if not candidates:
        eprint(f"  no {lang} subtitle found.")
        return False, None

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
            return True, dest

    if best_unsynced is not None and opts.keep_unsynced:
        dest.write_bytes(best_unsynced)
        # Kept beside the movie, never embedded: an unsynced subtitle should be
        # easy to delete.
        eprint(f"  no candidate could be synced; saved the best one UNSYNCED: {dest}")
        print(dest)
        return False, None
    eprint(f"  no {lang} candidate could be synced; nothing saved (see --keep-unsynced).")
    return False, None


# ---------------------------------------------------------------- 4. embedding

def track_title(lang: Language) -> str:
    country = getattr(lang, "country", None)
    return f"{lang.name} ({country.name.title()})" if country else lang.name


def mkvmerge_cmd(src: Path, out: Path, subs: list[tuple[Language, Path]]) -> list[str]:
    cmd = ["mkvmerge", "--quiet", "-o", str(out)]
    # Only the new subtitle should be shown by default.
    info = json.loads(subprocess.run(["mkvmerge", "-J", str(src)], check=True,
                                     capture_output=True, text=True).stdout)
    for track in info.get("tracks", []):
        if track.get("type") == "subtitles":
            cmd += ["--default-track-flag", f"{track['id']}:no"]
    cmd.append(str(src))
    for i, (lang, srt) in enumerate(subs):
        cmd += ["--language", f"0:{lang}", "--track-name", f"0:{track_title(lang)}",
                "--default-track-flag", f"0:{'yes' if i == 0 else 'no'}",
                "--sub-charset", "0:UTF-8", str(srt)]
    return cmd


def ffmpeg_cmd(src: Path, out: Path, subs: list[tuple[Language, Path]],
               existing_subs: int) -> list[str]:
    cmd = ["ffmpeg", "-v", "error", "-nostdin", "-i", str(src)]
    for _, srt in subs:
        cmd += ["-sub_charenc", "UTF-8", "-i", str(srt)]
    cmd += ["-map", "0"]
    for i in range(len(subs)):
        cmd += ["-map", str(i + 1)]
    cmd += ["-c", "copy", "-c:s", "mov_text", "-disposition:s", "0"]
    for i, (lang, _) in enumerate(subs):
        k = existing_subs + i
        cmd += [f"-metadata:s:s:{k}", f"language={lang.alpha3}",  # MP4 takes ISO 639-2/T
                f"-metadata:s:s:{k}", f"title={track_title(lang)}"]
    cmd += ["-disposition:s:" + str(existing_subs), "default", str(out)]
    return cmd


def embed(movie: Path, subs: list[tuple[Language, Path]]) -> bool:
    """Mux the subtitles into the movie in place. False leaves everything as it was."""
    # Rewrite the real file, so a symlink to it keeps working.
    target = movie.resolve()
    ext = target.suffix.lower()
    if ext not in MKV_EXTS | FFMPEG_EXTS:
        eprint(f"  cannot embed subtitles in a {ext} file; keeping them beside it.")
        return False
    if ext in MKV_EXTS and not shutil.which("mkvmerge"):
        eprint("  mkvmerge not found (sudo dnf install mkvtoolnix); keeping the subtitles beside it.")
        return False

    size = target.stat().st_size
    free = shutil.disk_usage(target.parent).free
    if free < size + SPACE_MARGIN:
        eprint(f"  not enough free space to rewrite the movie ({free / 2**30:.1f} GiB free, "
               f"{(size + SPACE_MARGIN) / 2**30:.1f} GiB needed); keeping the subtitles beside it.")
        return False

    before = probe(target)
    tmp = target.with_name(f".{target.stem}.embedding{target.suffix}")
    names = ", ".join(str(lang) for lang, _ in subs)
    eprint(f"\n> embedding {names} into {target.name} ({size / 2**30:.1f} GiB, nothing re-encoded)...")
    try:
        if ext in MKV_EXTS:
            proc = subprocess.run(mkvmerge_cmd(target, tmp, subs), capture_output=True, text=True)
            failed = proc.returncode >= 2  # 1 = warnings only
        else:
            proc = subprocess.run(ffmpeg_cmd(target, tmp, subs, len(before["subs"])),
                                  capture_output=True, text=True)
            failed = proc.returncode != 0
        if failed:
            eprint(f"  muxing failed: {(proc.stdout + proc.stderr).strip()[-500:]}")
            return False

        after = probe(tmp)
        problems = []
        if len(after["subs"]) != len(before["subs"]) + len(subs):
            problems.append(f"{len(after['subs'])} subtitle tracks, expected "
                            f"{len(before['subs']) + len(subs)}")
        if abs(after["duration"] - before["duration"]) > 1:
            problems.append(f"duration {after['duration']:.1f}s, was {before['duration']:.1f}s")
        if len(after["audio"]) != len(before["audio"]):
            problems.append(f"{len(after['audio'])} audio tracks, was {len(before['audio'])}")
        if len(after["video"]) != len(before["video"]):
            problems.append(f"{len(after['video'])} video tracks, was {len(before['video'])}")
        # Muxers pack differently, so a few % either way is normal; a truncated
        # file is caught by the duration check, this only catches lost streams.
        if tmp.stat().st_size < size * 0.9:
            problems.append(f"the new file is {tmp.stat().st_size / size:.0%} of the original's size")
        if problems:
            eprint("  the new file does not check out (" + "; ".join(problems) +
                   "); the original was not touched.")
            return False

        shutil.copymode(target, tmp)
        os.replace(tmp, target)
    finally:
        tmp.unlink(missing_ok=True)
    eprint(f"  done: {len(after['subs'])} subtitle track(s) in {target.name}")
    return True


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
        description="Download a subtitle for a movie, sync it to the movie's audio "
                    "and embed it in the file as a selectable track.",
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
                    help="fetch even if the movie already has a subtitle in that language "
                         "(embedded or <movie>.<lang>.srt)")
    ap.add_argument("--no-embed", dest="embed", action="store_false",
                    help="leave the movie untouched; only save <movie>.<lang>.srt beside it")
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
                embedded = check_movie(movie, languages)
                video = identify(movie)
                ready: list[tuple[Language, Path]] = []
                for lang in languages:
                    lang_ok, srt = process(movie, video, pool, lang, opts, embedded)
                    ok &= lang_ok
                    if srt:
                        ready.append((lang, srt))
                # All languages in one pass: rewriting a 50 GB remux once is enough.
                if ready and opts.embed and embed(movie, ready):
                    for _, srt in ready:
                        srt.unlink()  # now inside the movie; a copy beside it would show twice
                    print(movie)  # stdout: what was written, for piping
                else:
                    for _, srt in ready:
                        print(srt)
            except (Fail, ValueError) as exc:
                eprint(f"  error: {exc}")
                ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
