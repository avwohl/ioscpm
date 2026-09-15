# In-app help

The Help window's topics are fetched at runtime, so a correction reaches a
reader without an App Store release. This describes what this app does with
them. **The topics themselves are not edited here** - they are
[romwbw_disks/help/](https://github.com/avwohl/romwbw_disks/tree/main/help),
and that directory's README is the authoring procedure.

## No help URL is compiled into this app

It used to be `avwohl/ioscpm/releases/latest/download/help_index.json` - a
second index, in this app's own release area, in a shape of its own. That kept
whichever ioscpm release carried the Latest flag load-bearing for every port,
and it meant a typo fix in a topic needed a release here. It went in build 70.

What the app reads now is the catalog index, `CatalogMigration.indexURL`, the
same document that names the ROMs and the disks. It carries a `help` block:

```json
"help": {
  "base_url": "https://github.com/avwohl/romwbw_disks/releases/download/help-v0/",
  "topics": [
    { "id": "quick_start", "name": "Quick Start Guide",
      "description": "Getting started with the emulator",
      "filename": "help_quick_start.md", "size": 4711, "sha256": "..." }
  ]
}
```

`base_url` comes out of the document rather than being compiled in, so the
topics can be re-tagged or moved to another host with no release on any
platform - and `ROMWBW_INDEX_URL` or the catalog index setting moves help along
with everything else, so a device pointed at a test catalog reads that
catalog's help.

`size` and `sha256` are measured by romwbw_disks' generator, and the app checks
a downloaded topic against them. A topic that does not match is discarded in
favour of the offline copy, which is why a re-cut `help-v0` with a stale index
means every reader silently gets the version in their bundle.

## Three tiers, in this order

Download, then cache, then the shipped copy - never the shipped copy first, or
corrections would stop reaching anyone.

| Tier | Where |
|---|---|
| Network | the `help` block's `base_url` |
| Cache | `Caches/help<indexScope>/` - per catalog, since two catalogs publish different bytes under the same filenames |
| Bundle | `release_assets/` in this tree, copied into the app by the Xcode target |

The bundle tier is not belt-and-braces. cpmdroid shipped this arrangement with
no bundled copy, the assets stopped being attached after v1.11, and every build
from then on had no help at all with nothing failing anywhere to say so. The
cache is no defence against that: it only helps someone who already loaded help
once. It got a second demonstration on 2026-09-10, when `help-v0` was cut with
the Latest flag and `releases/latest/download/index-v0.json` answered 404 for
every client in the world until the flag was moved back.

## Two index shapes, on purpose

`HelpViewModel.parse` tries the catalog document first and the standalone
`help_index.json` second. The second shape is what this app published through
build 69, and it is what every install of one of those has sitting in its cache
and what `release_assets/help_index.json` still is. Refusing it would take help
away from exactly the reader the offline tiers exist for. It carries no `size`
or `sha256`, so the check is skipped rather than failed - the same degradation a
catalog document gets when the index publishes no hash.

That bundled copy named `avwohl/ioscpm/releases/latest/download/` as its
`base_url` until 2026-09-15. Nothing has been attached there since the
migration and nothing ever will be, so in the one case the bundled index is in
play with a working network - the catalog unreachable, which is precisely the
2026-09-10 incident - it pointed topic fetches at a release frozen in the past.
It names `help-v0` now.

## Keeping the copy in step

`release_assets/` is the offline floor for **two** ports: the Xcode target
bundles it, and z80cpmw's `z80cpmw.rc` compiles the same eight files in from
this checkout by relative path. A drift here is a drift in both.

`tools/check-help-assets.py` is what answers it, against the live catalog
rather than against a sibling checkout - the bytes to compare against are not
in either tree:

```sh
tools/check-help-assets.py --check    # report drift, change nothing
tools/check-help-assets.py            # refresh from the live catalog
```

**Nothing schedules it.** It ran daily from `.github/workflows/help-assets.yml`
until 2026-09-13, when that workflow went with every other job that reached a
published release. Run it before cutting a build that ships help. It has
already gone stale once: romwbw_disks rewrote all seven topics and these copies
stayed as they were until somebody noticed.

It checks the seven `.md` files and **not** `help_index.json`, which is not a
topic the catalog names - the catalog's `help` block *is* the published index.
So the bundled index is covered by nothing, and that is how it went on naming a
dead `base_url` for as long as it did.

cpmdroid keeps a third copy under `app/src/main/assets/help/` that this script
does not touch and nothing else does either.
