#!/usr/bin/env python3
#
# check-help-assets.py - do the bundled help topics still match the ones the
# catalog publishes, and refresh them when they do not.
#
# WHY THIS EXISTS.  release_assets/*.md is the offline floor under the help
# system: the Xcode project bundles this directory into the app, and z80cpmw's
# .rc compiles the same files in from this checkout at build time.  One
# directory, two ports.  Nothing in either tree can tell whether those bytes
# still match what romwbw_disks publishes, because the answer is not in either
# tree.
#
# It has already gone stale once.  romwbw_disks 5ac4afe rewrote all seven
# topics; these copies stayed as they were until somebody noticed and restored
# them by hand in 83d68b1, which recorded that it had "checked rather than
# assumed" - by hand, once.  That is the gap this closes.  The catalog moves
# without anybody committing here, which is the same reason store-version.yml
# runs on a schedule rather than only on push.
#
# It does NOT check what the app fetches at run time.  HelpView reads the
# catalog directly and verifies each topic's sha256 itself (9fd1841), so the
# downloaded path is already checked.  This is about the copy that ships.
#
# Usage:  tools/check-help-assets.py            refresh from the live catalog
#         tools/check-help-assets.py --check    report drift, change nothing
#
# EXIT CODES, matching tools/check-store-version.sh so the workflow needs no
# translation table:
#   0  in sync (or refreshed)
#   1  the bundled copy contradicts the catalog        -> RED with --check
#   2  could not verify - network, rate limit, a shape -> warn, do not fail
import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

INDEX_URL = "https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(ROOT, "release_assets")
EX_OK, EX_CONTRADICTION, EX_UNVERIFIED = 0, 1, 2


def unverified(msg):
    print("CANNOT VERIFY: %s" % msg, file=sys.stderr)
    sys.exit(EX_UNVERIFIED)


def get(url, limit=8 << 20):
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            body = r.read(limit + 1)
    except (urllib.error.URLError, OSError) as e:
        unverified("%s: %s" % (url, getattr(e, "reason", e)))
    if len(body) > limit:
        # A help topic is a few kilobytes.  Bounded before it is read so a
        # wrong URL cannot stream a disk image into memory.
        print("%s is larger than %d bytes - is that really the catalog?"
              % (url, limit), file=sys.stderr)
        sys.exit(EX_CONTRADICTION)
    return body


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="report drift instead of fixing it")
    ap.add_argument("--index-url",
                    default=os.environ.get("ROMWBW_INDEX_URL", INDEX_URL))
    args = ap.parse_args()

    try:
        index = json.loads(get(args.index_url).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        unverified("the index is not valid JSON: %s" % e)

    block = index.get("help") or {}
    base = (block.get("base_url") or "").strip().rstrip("/")
    topics = block.get("topics") or []
    if not base or not topics:
        # The client treats a missing help block as "fall back", not as an
        # error, and so does this: it is a statement about the catalog, not a
        # contradiction with anything here.
        unverified("the catalog publishes no help block")

    stale, written = [], []
    for t in sorted(topics, key=lambda x: x.get("filename", "")):
        fn = (t.get("filename") or "").strip()
        want = (t.get("sha256") or "").lower()
        if not fn or "/" in fn or fn.startswith("."):
            print("the catalog names a filename this will not write: %r" % fn,
                  file=sys.stderr)
            return EX_CONTRADICTION
        if not want:
            print("%s: the catalog publishes no sha256 for it" % fn,
                  file=sys.stderr)
            return EX_CONTRADICTION

        dest = os.path.join(DEST, fn)
        have = None
        if os.path.exists(dest):
            with open(dest, "rb") as f:
                have = hashlib.sha256(f.read()).hexdigest()
        if have == want:
            continue

        stale.append(fn)
        if args.check:
            continue

        body = get("%s/%s" % (base, fn))
        got = hashlib.sha256(body).hexdigest()
        if got != want:
            # The catalog contradicting itself, not this repository being
            # behind.  Nothing is written.
            print("%s: sha256 %s, the catalog's own index says %s"
                  % (fn, got[:12], want[:12]), file=sys.stderr)
            return EX_CONTRADICTION
        tmp = dest + ".tmp"
        with open(tmp, "wb") as f:
            f.write(body)
        os.replace(tmp, dest)
        written.append(fn)

    if args.check:
        if stale:
            print("STALE against the catalog: %s" % ", ".join(stale))
            print("Run tools/check-help-assets.py to refresh them.")
            return EX_CONTRADICTION
        print("PASS: release_assets/ matches all %d help topic(s) the catalog "
              "publishes" % len(topics))
        return EX_OK

    if written:
        print("refreshed: %s" % ", ".join(written))
    else:
        print("already in sync with the catalog (%d topic(s))" % len(topics))
    return EX_OK


if __name__ == "__main__":
    sys.exit(main())
