#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = ["guessit", "babelfish", "requests"]
# ///
"""Prints the original language of a movie (or series), looked up on Wikidata.

    original-language.py FILE [--alt TITLE]   look the movie up
    original-language.py --code CODE          just normalize a language code

The title and year come from the file name (and its folder) via guessit; when
that has no year, --alt (e.g. the MKV's title tag) is tried as well.

Output: one line per language, "<codes><TAB><name>", where <codes> are the
space-separated ISO 639 forms a Matroska track may use (e.g. "fra fre fr").
Exit 1 if nothing was found, 2 on a network error.
"""
import argparse
import re
import sys
import time
import unicodedata

import requests
from babelfish import Language
from guessit import guessit

API = "https://www.wikidata.org/w/api.php"
SESSION = requests.Session()
SESSION.headers["User-Agent"] = "misc-scripts-mkv-strip-tracks/1.0 (personal script)"


def eprint(*a):
    print(*a, file=sys.stderr)


def api(**params):
    params.update(format="json", formatversion=2)
    for attempt in range(6):
        r = SESSION.get(API, params=params, timeout=30)
        # Wikidata throttles bursts (429) and sheds load (503); both say
        # how long to wait.
        if r.status_code not in (429, 503) or attempt == 5:
            break
        try:
            wait = min(int(r.headers.get("Retry-After", "")), 120)
        except ValueError:
            wait = 5 * 2 ** attempt
        eprint(f"wikidata is rate limiting, waiting {wait}s...")
        time.sleep(max(wait, 1))
    r.raise_for_status()
    return r.json()


def values(entity, prop):
    """The plain values of a property, skipping 'no value'/'unknown' claims."""
    out = []
    for c in entity.get("claims", {}).get(prop, []):
        dv = c.get("mainsnak", {}).get("datavalue")
        if dv:
            out.append(dv["value"])
    return out


def years(entity):
    out = set()
    for v in values(entity, "P577"):  # publication date, "+2019-05-30T00:00:00Z"
        m = re.match(r"[+-](\d+)-", v["time"])
        if m:
            out.add(int(m.group(1)))
    return out


def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", " ", s).strip()


def names(entity):
    out = {norm(v["value"]) for v in entity.get("labels", {}).values()}
    for al in entity.get("aliases", {}).values():
        out |= {norm(a["value"]) for a in al}
    return out


# "Instance of" values that are a single film or series rather than a
# franchise, collection or making-of.
WORKS = {
    "Q11424",     # film
    "Q202866",    # animated film
    "Q24862",     # short film
    "Q93204",     # documentary film
    "Q506240",    # television film
    "Q226730",    # silent film
    "Q5398426",   # television series
    "Q581714",    # animated television series
    "Q1259759",   # miniseries
    "Q63952888",  # anime television series
}


def label(entity):
    labels = entity.get("labels", {})
    for lang in ("en", "mul"):
        if lang in labels:
            return labels[lang]["value"]
    return next((v["value"] for v in labels.values()), entity.get("id", "?"))


def entities(ids, props):
    if not ids:
        return {}
    return api(action="wbgetentities", ids="|".join(ids), props=props)["entities"]


def find_work(title, year):
    """Best Wikidata item for title/year that has an original language (P364)."""
    hits = api(action="query", list="search", srnamespace=0, srlimit=15,
               srsearch=f"{title} haswbstatement:P364")["query"]["search"]
    ids = [h["title"] for h in hits]
    ents = entities(ids, "claims|labels|aliases")
    want = norm(title)
    ranked = []
    for rank, qid in enumerate(ids):
        e = ents.get(qid, {})
        if not values(e, "P364"):
            continue
        # Festival premieres often come a year before the release.
        if year and not any(abs(y - year) <= 1 for y in years(e)):
            continue
        exact = want in names(e)
        if not year and not exact:
            continue  # without a year, only an exact title is trusted
        is_work = any(v.get("id") in WORKS for v in values(e, "P31"))
        # An exact title beats a mere year match, and a film beats a
        # franchise or collection sharing its name ("The Matrix" vs "The
        # Matrix series"); otherwise keep the search order.
        ranked.append((not exact, not is_work, rank, e))
    return min(ranked, key=lambda t: t[:3])[3] if ranked else None


# Individual languages that Matroska files usually tag with their
# macrolanguage's code (a Mandarin track is "chi"/"zh", not "cmn").
MACRO = {
    "cmn": "zho", "yue": "zho", "wuu": "zho", "nan": "zho", "hak": "zho",
    "arb": "ara", "arz": "ara", "apc": "ara", "ary": "ara", "acm": "ara",
    "pes": "fas", "prs": "fas", "nob": "nor", "nno": "nor",
    "zsm": "msa", "ind": "ind", "ekk": "est", "lvs": "lav", "swh": "swa",
}


def codes(lang):
    out = [lang.alpha3]
    macro = MACRO.get(lang.alpha3)
    if macro and macro != lang.alpha3:
        out += [c for c in codes(Language(macro)) if c not in out]
    for conv in ("alpha3b", "alpha2"):
        try:
            c = getattr(lang, conv)
        except Exception:  # no such code for this language
            continue
        if c not in out:
            out.append(c)
    return out


def from_code(code):
    code = code.strip().lower()
    for make in (Language.fromalpha2, Language, Language.fromalpha3b, Language.fromietf):
        try:
            return make(code)
        except Exception:
            pass
    return None


def language_of(item):
    """babelfish Language for a Wikidata language item."""
    for prop in ("P220", "P219", "P218"):  # ISO 639-3, 639-2, 639-1
        for v in values(item, prop):
            lang = from_code(v)
            if lang:
                return lang
    return None


def emit(lang, name=None):
    print(" ".join(codes(lang)) + "\t" + (name or lang.name))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--alt", help="another title to try, e.g. the MKV title tag")
    ap.add_argument("--code", help="only normalize this language code")
    args = ap.parse_args()

    if args.code:
        lang = from_code(args.code)
        if not lang:
            eprint(f"unknown language code: {args.code}")
            return 1
        emit(lang)
        return 0
    if not args.file:
        ap.error("FILE or --code is required")

    guesses = [guessit(args.file)]
    if args.alt:
        guesses.append(guessit(args.alt))
    # Prefer a guess that carries a year: it makes the match far safer.
    guesses.sort(key=lambda g: "year" not in g)

    try:
        for g in guesses:
            title = g.get("title")
            if not title:
                continue
            year = g.get("year") if g.get("type") == "movie" else None
            work = find_work(title, year)
            if not work:
                continue
            eprint(f"wikidata: {label(work)} ({', '.join(map(str, sorted(years(work)))) or '?'}) "
                   f"https://www.wikidata.org/wiki/{work['id']}")
            lang_ids = [v["id"] for v in values(work, "P364")]
            seen = set()
            for item in entities(lang_ids, "claims|labels").values():
                lang = language_of(item)
                if lang and tuple(codes(lang)) not in seen:
                    seen.add(tuple(codes(lang)))
                    emit(lang, label(item))
            if seen:
                return 0
        searched = "; ".join(f"{g.get('title')!r} {g.get('year', '')}".strip()
                             for g in guesses if g.get("title"))
        eprint(f"not found on wikidata (searched: {searched or 'nothing usable in the name'})")
        return 1
    except requests.RequestException as e:
        eprint(f"wikidata lookup failed: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
