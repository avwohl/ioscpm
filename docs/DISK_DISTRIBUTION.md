# Disk Distribution System

This document explains how disk images are managed, distributed, and consumed by the iOSCPM family of clients (iOS, macOS, Windows, CLI).

## Overview

**The migration has reached users, and this document's emphasis flipped with
it.** Read "Interface v0" first: it is what the current tree does *and* what the
binary the App Store is serving does. Everything before it describes the older
scheme, which is still live on devices nobody has updated.

`sh tools/check-store-version.sh` is what settles that, and it is a measurement
rather than a constant. On 2026-09-15 it reports **1.6.1, released 2026-09-12,
at most build 70** — and 1.6.1 heads builds 67-72, so the shipping binary is at
*least* 67. Build 64 is the v0 migration, so every build it could be reads the
interface-v0 catalog: one compiled-in index URL at `avwohl/romwbw_disks`, one
catalog per RomWBW release, asset URLs taken from the catalog's own `base_url`.
No `release_assets/disks.xml`, no `avwohl/ioscpm` release tag, no `releaseTag`
constant. On 2026-09-08 the same script said 1.5.1 at most build 61, which is
pre-v0 — that is the sentence that changed.

The disk images are **not** in this repo; they exist only as release assets
(removed from `release_assets/` in f570676).

> **The older scheme is still a live system, not history.** Builds up to 63
> fetch `release_assets/disks.xml` and download from a **pinned** release tag —
> since build 42; builds 36/37 predate the pin and float on `latest` for disks
> too. An installed 1.4.9 or 1.5.x binary is hardwired to those URLs and GitHub
> release assets cannot be redirected, so the tags must stay live for as long as
> one of those builds is installed. Nothing in the migration frees a tag.

## Repository Structure

```
release_assets/
├── disks.xml              # Disk catalog manifest — FROZEN, do not edit
├── help_index.json        # Help system index
└── help_*.md              # Help topic markdown files
```

`disks.xml` is frozen and read by nothing in this tree; it is byte-identical to
what `releases/latest/download/disks.xml` serves, and `docs/DISK_W8FIX_RUNBOOK.md`
rests on that being so. The help assets are no longer fetched by this tree
either — **build 70 moved help to the catalog** — but they are still reachable
and must stay so; see "The help system" below. `release_assets/help_index.json`
and the topics beside it are the copy bundled into the app and compiled into
z80cpmw, which is why they are still here. `docs/HELP_SYSTEM.md` is the detail.

## The Disk Manifest (`disks.xml`)

This is the pre-v0 interface. It is what installs predating 1.6.1 read — not
what the shipping binary reads, which has been a v0 client since 2026-09-12.
The manifest is an XML file listing all available disk images:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<disks version="13">
    <disk>
        <filename>hd1k_combo.img</filename>
        <name>Combo (Recommended)</name>
        <description>49MB multi-slice disk with CP/M 2.2, games, utilities...</description>
        <size>51380224</size>
        <license>Mixed</license>
        <sha256>89b8ae1aaa6867dc515c3511b34c4f0c311a77e99ff71066f5a774bef99cde1d</sha256>
        <defaultSlot>0</defaultSlot>
    </disk>
    <!-- more disks... -->
</disks>
```

### Manifest Fields

| Field | Required | Description |
|-------|----------|-------------|
| `filename` | Yes | Disk image filename (e.g., `hd1k_combo.img`) |
| `name` | Yes | Display name shown to users |
| `description` | Yes | Human-readable description |
| `size` | Yes | File size in bytes |
| `license` | Yes | License type: Mixed, Abandonware, Open Source, Freeware |
| `sha256` | Yes | SHA256 checksum, verified on install since build 55 — see Integrity Verification |
| `defaultSlot` | No | The slice to boot inside a multi-slice image. **Not a drive number** — see below |

`defaultSlot` is published only on `hd1k_combo`, and its only published value
is `0`. It says which of that image's six slices a client should boot from when
it mounts it with no other instruction (romwbw_disks `docs/CATALOG_SCHEMA.md`
§3.3) — it says nothing about which of the four drives an image belongs in. This
row said "default disk slot (0-3) for auto-mounting", and the app read it that
way: a release that started publishing `3` on the combo would have filled drive
3 and left a first launch with nothing to boot in drive 0. Which disks a first
launch mounts is `RomWBWCatalogDocument.defaultDiskIDs`, keyed on the catalog's
`id`, because `disks[]` carries no `default` flag the way `roms[]` does.

### Version Attribute

The `<disks version="N">` attribute tracks catalog changes, and changing it
deletes files on every installed device. On each successful catalog fetch the
invalidation compared the attribute against the stored `catalogVersion` default,
and on **any** difference cleared downloaded images. No checksum was consulted —
the comparison was on the version attribute alone — and it needed no tap and no
download.

> **Never move `<disks version>`, and never edit `release_assets/disks.xml`.**
> It is at `version="13"` and it stays there. There is no longer any reason to
> touch it — a new disk is published in `romwbw_disks`, where that release's own
> `generation` advances instead — and what moving it would still do to installed
> 1.4.x devices is the rest of this section. The file is off limits for a second
> reason as well: `docs/DISK_W8FIX_RUNBOOK.md` records the measurement that it is
> byte-identical to what `releases/latest/download/disks.xml` serves, and any
> edit, a comment included, breaks that. A warning about this belongs in prose
> like this paragraph, never in the XML.

**Build 63 stopped consulting the attribute, and the tree now deletes nothing at
all.** What acts on the interface-v0 catalog's `generation` is
`recordCatalogGeneration` (`EmulatorViewModel.swift`), which stores it under a
key scoped to the (interface, RomWBW release) pair and stops there. It was
`checkCatalogGenerationAndInvalidate` and it did delete; why that was retired
rather than narrowed again is under "What replaced the wipe" below. The XML
carries no generation either way, so a v0 device deletes nothing on a catalog
fetch on either count. **None of that makes the attribute safe to move.** Every
build in service still reads it, and the two numbers are not interchangeable:
the XML is at `version="13"` while the v0 catalogs started at `generation: 1`
and are at 2 today, which is exactly why the old value is never copied into the
new key.

**Build 56 had narrowed what "downloaded images" meant**, and while a wipe
existed that narrowing was the whole safety property: `deleteCatalogDisks(named:)`
deleted only the `.img` files the **new** catalog listed. That is the test for
whether deleting one is recoverable — an image the new catalog does not name
cannot be fetched back from it, so a disk the user imported through Files, one
`createNewDisk` made, and one dropped from the catalog in the same bump were all
kept, and the alert afterwards gave both counts. Before build 56,
`deleteAllDownloadedDisks()` took every `.img` in `Documents/Disks` regardless of
where it came from. Both functions are gone from the tree; the note stays,
because that test is what any future deletion would have to satisfy, and because
the builds in the field still behave exactly as it describes.

### What replaced the wipe

Nothing did, and that is the point: something better was already running.
`reassessDiskFreshness()` is called immediately after `recordCatalogGeneration`
on the same path, and it asks the question the wipe was guessing at.
`DiskLedger.swift` records which published image each installed file came from
— the catalog `sha256` a verified download matched — so `DiskLedger.action`
answers per file: `.refreshAutomatically` for an unmodified superseded image,
`.offerUpdate(lossy: true)` for one the user has written to, and nothing at all
for one that is already current. It never destroys work, and it stands down
while the emulator is running off the file. That is how a respun
`hd1k_combo.img` reaches a device that already holds the old one, with no
version attribute and no generation moved on its account.

Deliberately *not* keyed on hashing the installed file against the catalog: a
downloaded disk is a writable CP/M volume and `saveDownloadedDisks()` rewrites
it, so that comparison marks every disk a user has saved work into as stale. See
"User Data Persistence" in `KNOWN_PROBLEMS.md`.

The wipe was wrong in fact and not only in principle, which is why it is gone
rather than narrowed a second time. The only `generation` bump this catalog has
ever had — `romwbw_disks` commit `aab3a4f`, 1 → 2 on both releases — changed two
ROM hashes and **zero of the twenty disk hashes**. A device holding the whole
3.5.1 set would have deleted all twenty images and re-downloaded twenty
byte-identical copies because two ROMs were rebuilt: on a phone, on cellular,
gigabytes to arrive back where it started, and the direct cost of publishing a
new ROM, which is the thing `romwbw_disks` exists to make cheap.

### What moving it would still do to a device in the field

On the version-attribute path there is no confirmation beforehand and nothing
offered as an update: the user is told after the fact. So do not think of that
attribute as metadata. Moving it clears the catalog half of an installed
device's disk library, unprompted, on its next launch — and on a 1.4.9 install
(builds 36/37), which predates both the narrowing and the catalog pin, it still
clears **all** of it, imported and created disks included. Those builds are no
longer what the App Store serves, but an install nobody has updated is still an
install. What that means for the order a release has to go out in is in
`docs/DISK_W8FIX_RUNBOOK.md`; what is still open about it — copy-on-write, and
confirming before a deletion rather than after — is under "User Data
Persistence" in `KNOWN_PROBLEMS.md`.

## GitHub Releases Distribution

### Release URLs

Clients up to build 63 read the catalog and the images from an explicit, pinned
release tag — `releaseTag` in `EmulatorViewModel.swift`. It read `v1.4.5`
through build 58 and `v1.4.12` from build 61, and the constant is deleted in
build 64. **Both** tags have to stay live for as long as one build reading
either is installed — which is no longer the build the Store serves, but is
still every install nobody has updated:
```
Catalog:  https://github.com/avwohl/ioscpm/releases/download/v1.4.12/disks.xml
Base URL: https://github.com/avwohl/ioscpm/releases/download/v1.4.12
```

Individual disk downloads append `/` plus the filename to the base URL:
```
https://github.com/avwohl/ioscpm/releases/download/v1.4.12/hd1k_combo.img
```

### The help system

Help was never pinned — `HelpView.swift` fetched `help_index.json` and the
`help_*.md` topics from
`https://github.com/avwohl/ioscpm/releases/latest/download/`, floating on
`latest` while the disks sat on a tag. Help content is not version-locked to the
ROM; disk images are. See `docs/DISK_CATALOG_PINNING.md`.

**Build 70 ended that**, and it was the last ioscpm URL compiled into the app.
`HelpView.indexURL` is `CatalogMigration.indexURL` now — the same catalog index
that names the ROMs and the disks, carrying a `help` block whose `base_url`
points at `avwohl/romwbw_disks`' `help-v0` tag. `docs/HELP_SYSTEM.md` has the
shape and the three offline tiers.

**That URL still has to answer, and for the same reason the disk tags do.** The
Store serves at most build 70 and at least 67, and 70 is precisely the build
that moved help — so whether the currently shipping binary fetches help from
`avwohl/ioscpm/releases/latest/download/` is *not knowable from this tree*.
Re-measured 2026-09-15: `help_index.json` and the topics there answer 200, and
the bytes are byte-identical to what `romwbw_disks/help/` holds. Nothing new
will be attached there; nothing may be taken away either.

### Creating a Release

**This is the frozen record of a procedure, not a recipe to run.** Disks are
published in `romwbw_disks` now — see "Adding a New Disk" — and these tags exist
only to keep serving builds already installed. It is kept because somebody
reading a 1.4.x device's traffic needs to know how those assets got there.
Anything that does touch these releases goes through `docs/DISK_W8FIX_RUNBOOK.md`
and its SUPERSEDED block first, never through this list.

1. Update `release_assets/disks.xml` if adding/modifying disks — **this step is
   closed.** The file is frozen: it is byte-identical to what
   `releases/latest/download/disks.xml` serves, and `docs/DISK_W8FIX_RUNBOOK.md`
   rests on that measurement. What this step used to say next was "update the
   `version` attribute", and that instruction was wrong: it is the one act that
   reaches into an installed 1.4.x device and deletes disks no catalog can give
   back. See "Version Attribute" above.
   - Generate SHA256 checksums over the built images, wherever they were staged:
     `shasum -a 256 hd1k_*.img`

2. Create the GitHub release and attach:
   - `disks.xml` and `help_index.json` from `/release_assets/`
   - All `help_*.md` files from `/release_assets/`
   - All `hd1k_*.img` files from your disk-build output — these are not repo
     files, so they have to come from wherever the images were built or
     downloaded

3. The disk catalog does not follow `/latest/`. The help system did, up to
   build 69; build 70 moved it to the catalog too.
   Clients from build 42 to build 63 read a pinned tag — `v1.4.5` through build
   58, `v1.4.12` from build 61 (the repin is `0010591`) — and a new release tag
   reached none of them until `releaseTag` in `EmulatorViewModel.swift` was
   bumped and a new app build shipped. **Build 64 onwards reads none of this** —
   a new disk reaches those builds by being published in `romwbw_disks` and does
   not need an app release at all, which is the point of the migration.

   **A release published here still reaches installed devices, by two routes.**
   What the App Store serves is a measurement, not a constant: run
   `sh tools/check-store-version.sh` and read the number it gives rather than
   deriving one.

   On 2026-09-15 it says **1.6.1, released 2026-09-12, at most build 70**.
   1.6.1 heads builds 67-72, so the shipping binary is at least 67 — past the
   build-64 migration, and therefore a v0 client that reads none of the tags
   below. **That is new.** On 2026-09-08 the same script said 1.5.1, released
   2026-09-05, at most build 61, which is pre-v0; the pinned scheme was what
   users were on, and it no longer is.

   It changes nothing about keeping the tags live. Older installs nobody has
   updated are still out there: 1.5.x reads a pin, and 1.4.9 (builds 36/37)
   predates the pin entirely and fetches from `releases/latest/download/`.
   Neither can be redirected. Since `v1.4.12` became `releases/latest` on
   2026-09-04 those two routes resolve to the same tag, so uploading to it — or
   publishing a newer release that is *not* marked `--prerelease` — reaches
   both fleets at once, with nothing installed and nothing submitted.
   Re-measured 2026-09-08: `v1.4.5` is still `prerelease=true` and stays that
   way, `v1.4.12` is `prerelease=false`, and `releases/latest` resolves to
   `v1.4.12`. See `docs/DISK_W8FIX_RUNBOOK.md` under "2026-09-04" for why that
   was traded, and `docs/DISK_CATALOG_PINNING.md` for what it changed about the
   two layers.

## Interface v0 (build 64 onwards)

**This is what the current tree does, and what the shipping binary does.** The
sections above describe the scheme that installs predating 1.6.1 still use.

One URL is compiled in, and it is the only one — `CatalogMigration.defaultIndexURL`:

```
https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json
```

**And it names no release tag.** It was
`releases/download/catalog-v0/index-v0.json` until 2026-09-10, which pinned one:
adding a RomWBW version was always free, because a version is an entry *inside*
the index, but romwbw_disks could never rename that release, move the index, or
publish a v1 anywhere a shipped client would look. `INTERFACE_V0.md`'s own
migration plan was "a v1 lives alongside v0: new release tags, a new index URL",
which is unreachable from a constant naming the old tag — so that plan silently
meant "and release Windows, Android, iOS and Linux at once", the exact coupling
this catalog exists to remove.

`releases/latest/download/` is resolved by GitHub to whichever release carries
the Latest flag, so *where* the index lives belongs to romwbw_disks. A v1 ships
as `index-v1.json` beside `index-v0.json` on that same release: v0 clients keep
reading v0, v1 clients read v1, nobody rebuilds anything.

That also makes the Latest flag load-bearing, which is why romwbw_disks'
`help/README.md` forbids cutting a mutable tag as Latest and
`tools/check_latest.py` fails the repository if one lands there. All three GUI
clients compile in this same string — `CatalogMigration.swift:97`,
`SettingsRepository.kt:131`, `CatalogV0.cpp:52`.

Two hops from there:

1. **The index.** `romwbw_versions[]`, one entry per published RomWBW release,
   each with `hbios.ver_byte`/`upd_byte` (hex *strings*), a `status`, a
   `default` flag, a `generation`, a `prerelease` boolean that is emitted only
   when true, and an absolute `catalog_url` with that catalog's
   `catalog_sha256` and `catalog_size`.
2. **That release's catalog**, verified against those two values *before* it is
   parsed. It carries `base_url` (ending in `/`), `roms[]` and `disks[]`.

Fetched and checked on 2026-09-08: the index lists two releases, both
`"status": "stable"`, and **3.6.0 is the one flagged `"default": true`**. Each
catalog's bytes hash to the `catalog_sha256` the index publishes for it. 3.5.1
is `generation` 2 with 2 ROMs and 20 disks; 3.6.0 is `generation` 2 with 2 ROMs
and 24 disks.

An asset URL is `base_url + filename`, concatenated. The `"/"` this client used
to insert is gone — under v0 the separator is in the document, and reproducing
the fixup would double it.

Which release is in play is a user choice among **every** entry the index
publishes that has a `catalog_url` and that upstream calls a release. The one
filter left is the `prerelease` flag: since 2026-09-18 the index may carry a
RomWBW development snapshot marked with it, and `CATALOG_SCHEMA.md` §2.3
requires every client to keep such an entry behind an explicit opt-in, so
`RomWBWIndex.offered` drops it unless Settings → RomWBW Release → Show
Development Snapshots is on. That is a switch in front of the user rather than
a list compiled into the binary, which is the distinction the rest of this
section is about: it hides nothing this core could not run, and turning it on
costs a tick rather than an App Store submission.

There used to be a filter of the other kind. Until romwbw_emu v1.44 each
entry's version bytes went to the core through
`RomWBWEmulator.supportsRomWBW(ver:upd:)`, which wrapped
`emu_romwbw_release_supported()` and compared them against a compile-time
`ROMWBW_SUPPORTED_RELEASES`, so a release published after a binary shipped was
fetched and then hidden from its user. That header and both functions are gone,
and so are the bridge method and `RomWBWIndex.offered`'s release half. The core
now loads any ROM with a readable HBIOS configuration block, because what it
depends on — two I/O ports and the set of HBIOS functions `hbios_dispatch.cc`
services — is versioned by the catalog's own name rather than by a release
number: a v0 index publishes only v0.

`hbios.ver_byte`/`upd_byte` stay in every index entry, and `RomWBWHBIOS` still
decodes them. They stopped being an emulator gate and remain what they always
described, the ROM-to-disk-image pairing. Nothing in this app reads them today:
its one pairing check, `romReleaseMismatchNotice`, compares release STRINGS.
Everything whose validity depends
on the release is keyed per (interface, release): the disk slots, the NVRAM
blob, the last-seen generation, the on-disk filenames, and the catalog cache.
Switching releases deletes nothing.

The documents are decoded by `CatalogDocument.swift` and the rules it has to
obey are in `romwbw_disks/docs/CATALOG_SCHEMA.md` §6.1 — unknown fields ignored,
entries keyed on `id`, `roms[]` neither assumed present nor assumed to contain
`emu_avw`, optional fields absent, `generation` compared and never computed.

The ROM comes from the catalog too, from build 65. Which one is the `roms[]`
entry flagged `default: true`, or the first entry when a catalog flags none —
never by array position and never by looking for `emu_avw`. It is stored beside
the disks under its catalog filename (`emu_avw-v0-3.6.0.rom`), so two releases'
ROMs coexist as their disks do, and its `size` and `sha256` are checked against
the catalog **every time it is used**, not only when it is downloaded. A copy
that fails is fetched again once and then reported; nothing here deletes a ROM.

**There is no bundled ROM any more.** `iOSCPM/Resources/emu_avw.rom` is deleted
and its four `project.pbxproj` references with it; `git ls-files` now matches no
`.rom`, `.img`, `.bin`, `.com` or `.dsk` at all. ioscpm was the last of the five
repositories to carry one — cpmdroid and z80cpmw deleted theirs on 2026-09-07 —
and `sh tools/check-shipped-disks.sh` read "v0 index, no bundled ROM - every ROM
comes from the catalog" for all three ports, exit 0 — the last such run before
that script was deleted on 2026-09-13.

**The reason it was kept was not true, and this document was one of the places
that repeated it.** The claim was that the bundled ROM is what makes the app
work with no network at all. It is not. `start()` returns early when
`diskCatalog` is empty, and the catalog and every disk in it are downloads: a
device that has never had a network has no disk to boot, so a ROM to boot it
with buys nothing. What the 512 KB actually bought was skipping the ROM download
on 3.5.1, and that is the only thing it should ever have been credited with.

What changes for a user is where a fresh install starts. It used to start on the
bundled ROM's release, 3.5.1; it now starts on the index's `default: true` entry,
which is **3.6.0** today. Nothing else moves — a device that already holds a
3.5.1 ROM keeps it, because the ROM is stored beside the disks under its catalog
filename and two releases' ROMs coexist exactly as their disks do.

A release whose ROM cannot be fetched or cannot be verified **does not start**:
the app names the release, the file and the reason, and points at a connection
or at the other ROM the same release publishes. There is no longer a "use the
bundled one instead" way out, and there should not be: substituting it would
mean booting a release the user did not pick, which produces
`*** WARNING: HBIOS/CBIOS Version Mismatch ***` part-way through a boot — the
pairing this whole scheme exists to prevent.

## Client Implementation

### Fetching the Catalog

Builds up to 63 fetch `disks.xml` on app launch and cache it locally at:
```
Documents/Disks/disks_catalog.xml
```

Build 64 fetches the two v0 documents instead and caches them per release:
```
Documents/Disks/index-v0.json
Documents/Disks/catalog-v0-3.6.0.json
Documents/Disks/catalog-v0-3.5.1.json
```

The filename carries the release rather than a `UserDefaults` stamp beside it: a
stamp can drift from the file it describes, and two releases' caches have to
coexist. The old `disks_catalog.xml` and the `catalogCacheTag` key are left in
place, unread, so a downgrade finds them.

If offline, the cached version is used as fallback — and under v0 a cached
catalog is self-consistent, because it holds its own `base_url`. That is what
retired the salvage branch that used to throw away every entry whose file was
not already downloaded.

### Parsing (iOS/macOS)

Up to build 63, the `DiskCatalogXMLParser` class in `EmulatorViewModel.swift`
parsed the XML:
- Extracts the version attribute
- Creates `DownloadableDisk` objects for each entry
- Constructs full download URLs

Build 64 deletes that class. `CatalogDocument.swift` decodes both v0 documents
as `Codable` structs, and `Tests/CatalogDocumentTests.swift` covers them.

### Download Flow

1. User selects a disk in Settings
2. Client downloads from GitHub Releases to a temp file — under v0 from
   `base_url + filename`, taken from the catalog rather than built from a tag
3. The catalog's `filename` is checked to be a plain name, not a path
4. The **temp file** is hashed and compared against the catalog's `sha256`
   (`<sha256>` in the XML the field builds read; the same value either way)
5. Only on a match is the temp file moved into `Documents/Disks/`
6. Download state is updated in UI

### Integrity Verification

**Landed 2026-09-01, in build 55.** Every download is verified before it is
installed. Whether a given user's copy has it is a separate question and a
measured one — `sh tools/check-store-version.sh` bounds what the Store serves,
and it cannot say which build inside that bound it is.

The only download path is `downloadDiskFromSettings` in
`EmulatorViewModel.swift`, reached from `downloadDisk` (the Settings button),
from `downloadDiskWithCompletion` (the first-run fetch), and from `fetchROM`
(build 65, the ROM described above, which is handed to it as a
`DownloadableDisk`). It hashes the temp file and, on a mismatch, retries up to
three times before failing with `Checksum mismatch - not saved`.

**The order is the point.** Verification happens on the temp file, before the
destination is touched. A corrupt or truncated download therefore costs a retry
and nothing else — the copy the user already had is still in place and still
usable. The earlier dead implementation, `downloadDiskWithRetry`, hashed only
*after* `removeItem` + `moveItem`, so a bad download would have destroyed a good
disk and left nothing behind. `Documents/Disks/` also holds disks the user
imported and disks the app created, neither of which any catalog can restore.
That dead path is deleted; there is one download path and it verifies.

Two entries are refused rather than installed:

- **No hash in the catalog entry.** Not "assume ok" — all 20 entries in the
  pinned `v1.4.12` XML carry one, and so does every entry in both v0 catalogs
  (checked 2026-09-08: 20 disks under 3.5.1, 24 under 3.6.0, plus 2 ROMs each,
  none missing `sha256`), so an entry without one is a degraded or hostile
  catalog. Accepting it would have made the check optional at the catalog's
  choosing.
- **A filename that is not a plain name.** The catalog is downloaded
  content and its filename reaches `removeItem`; `appendingPathComponent` does
  not escape `..`. Refused rather than silently reduced, because rewriting the
  name would desync it from `refreshAvailableDisks`.

`DiskDownloadRow` (`ContentView.swift`) still shows the installed file's first
eight hash digits, green on a match. That display is now confirmation of a check
that already happened, not the only check — and it no longer paints green when
the catalog carries no hash to compare against.

## Adding a New Disk

**It is published in `romwbw_disks`, and no app release is involved.** That is
the whole point of the migration: a client that compiles in one index URL and
takes every other URL out of the documents behind it needs no edit, no rebuild
and no review to offer a disk it has never heard of. The set of catalog stems
this app recognises is *observed* from the catalogs it fetches rather than
compiled in, so a new id is a system disk on arrival — five ids already exist
under 3.6.0 and not 3.5.1 (`hd1k_cobol`, `hd1k_dos65`, `hd1k_infocom`,
`hd1k_msx`, `hd1k_wp`), all bootable.

The steps live in `romwbw_disks`, and `romwbw_disks/docs/CATALOG_SCHEMA.md` is
the authority for them. What matters from this side is what the client will and
will not accept:

1. Build the image and attach it to that RomWBW release's `romwbw_disks`
   release, so that the catalog's `base_url` + `filename` resolves.
2. Add its entry to that release's catalog with `id`, `filename`, `size` and
   `sha256`. **An entry carrying no `sha256` is refused, not installed**, and a
   `filename` that is not a plain leaf name is refused too — see "Integrity
   Verification".
3. Advance that catalog's `generation`, and republish the index with the
   catalog's new `catalog_sha256` and `catalog_size`. The catalog is verified
   against those two before it is parsed, so a catalog republished without them
   is a catalog no client will read.
4. Nothing here touches `release_assets/disks.xml`, the `<disks version>`
   attribute, or any `avwohl/ioscpm` tag, and advancing `generation` deletes
   nothing on any device — `reassessDiskFreshness()` decides per file.

**What this section used to say** was: create the image, attach it to an
`avwohl/ioscpm` release, add a `<disk>` entry to `release_assets/disks.xml`,
**increment the `version` attribute in `<disks>`**, and upload the XML alongside
the image. That is the procedure the builds in the field were fed by, and its
fourth step is the one act `docs/DISK_W8FIX_RUNBOOK.md` forbids absolutely. It
is written out here so that nobody reconstructs it from the shape of the release
assets and runs it.

## Generating SHA256 Checksums

The images are not in the repo, so run this against your disk-build output
directory (or a directory you have downloaded the release assets into):

```bash
shasum -a 256 hd1k_*.img
```

Or for a single file:
```bash
shasum -a 256 hd1k_newdisk.img
```

## Disk Inventory

**A snapshot, not a fact about the app.** What a build offers is whatever the
catalog it fetched lists; no client carries a disk list any more, so a table
here goes stale by construction. Checked against the live catalogs on
2026-09-08.

RomWBW 3.5.1 publishes these twenty — the same set `release_assets/disks.xml`
carries, and the same twenty a **pre-1.6.1** install downloads. The Filename
column is the XML's spelling, which is what those builds fetch; 3.5.1's own v0
catalog publishes the same images under v0 names (`hd1k_combo-v0-3.5.1.img`),
and that is what the shipping binary fetches:

| Filename | Name | License | Size |
|----------|------|---------|------|
| hd1k_combo.img | Combo (Recommended) | Mixed | 49MB |
| hd1k_cpm22.img | CP/M 2.2 | Mixed | 8MB |
| hd1k_zsdos.img | ZSDOS | Mixed | 8MB |
| hd1k_zpm3.img | ZPM3 | Mixed | 8MB |
| hd1k_cpm3.img | CP/M 3 | Mixed | 8MB |
| hd1k_nzcom.img | NZCOM | Mixed | 8MB |
| hd1k_qpm.img | QPM | Mixed | 8MB |
| hd1k_games.img | Games | Abandonware | 8MB |
| hd1k_aztecc.img | Aztec C | Abandonware | 8MB |
| hd1k_bascomp.img | BASIC Compilers | Abandonware | 8MB |
| hd1k_cowgol.img | Cowgol | Open Source | 8MB |
| hd1k_fortran.img | Fortran | Abandonware | 8MB |
| hd1k_hitechc.img | Hi-Tech C | Freeware | 8MB |
| hd1k_tpascal.img | Turbo Pascal | Freeware | 8MB |
| hd1k_z80asm.img | Z80 Assemblers | Mixed | 8MB |
| hd1k_ws4.img | WordStar 4 | Abandonware | 8MB |
| hd1k_z3plus.img | Z3Plus | Mixed | 8MB |
| hd1k_bp.img | B/P Bios | Mixed | 8MB |
| hd1k_msxroms1.img | MSX ROMs 1 | Abandonware | 8MB |
| hd1k_msxroms2.img | MSX ROMs 2 | Abandonware | 8MB |

RomWBW 3.6.0 publishes twenty-four. It adds `hd1k_cobol` (COBOL), `hd1k_dos65`
(DOS/65), `hd1k_infocom` (Infocom Adventures), `hd1k_msx` (MSX) and `hd1k_wp`
(Word Processing), all 8MB and all bootable, and it drops `hd1k_ws4`, which does
not exist in that release. Under v0 the filenames carry the release —
`hd1k_combo-v0-3.6.0.img`, not `hd1k_combo.img` — which is what lets two
releases' sets sit in `Documents/Disks` together.

## Privacy

No user data is sent to GitHub. Clients only download:
- The disk catalog manifest
- Disk image files (user-initiated)
- Help content files

See `PRIVACY.md` for full privacy policy.
