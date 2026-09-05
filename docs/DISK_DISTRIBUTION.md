# Disk Distribution System

This document explains how disk images are managed, distributed, and consumed by the iOSCPM family of clients (iOS, macOS, Windows, CLI).

## Overview

The manifest and the help content are stored in this repository under
`/release_assets/`. The disk images themselves are **not** in the repo — they
exist only as GitHub Release assets (they were removed from `release_assets/` in
f570676). Clients fetch the manifest and download disks on-demand from a
**pinned** release tag, not from the "latest" endpoint; only the help system
still floats on `latest`.

> **Build 64 moved this app off all of it.** iOSCPM no longer reads
> `release_assets/disks.xml`, no longer downloads from an `avwohl/ioscpm`
> release tag, and no longer has a `releaseTag` constant. It reads the
> interface-v0 catalog published by `avwohl/romwbw_disks` — one compiled-in
> index URL, one catalog per RomWBW release, and asset URLs taken from the
> catalog's own `base_url`. See "Interface v0" below.
>
> Everything else in this document still describes what **builds already in
> service** do, and those tags must stay live: an installed 1.4.9 or 1.5.x
> binary is hardwired to its URLs and GitHub release assets cannot be
> redirected. Read the rest as the record of a live system, not a plan.

## Repository Structure

```
release_assets/
├── disks.xml              # Disk catalog manifest
├── help_index.json        # Help system index
└── help_*.md              # Help topic markdown files
```

## The Disk Manifest (`disks.xml`)

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
| `defaultSlot` | No | Optional default disk slot (0-3) for auto-mounting |

### Version Attribute

The `<disks version="N">` attribute tracks catalog changes, and changing it
deletes files on every installed device. On each successful catalog fetch the
invalidation compared the attribute against the stored `catalogVersion` default,
and on **any** difference cleared downloaded images. No checksum was consulted —
the comparison was on the version attribute alone — and it needed no tap and no
download.

**Build 63 stopped consulting the attribute.** Its successor,
`checkCatalogGenerationAndInvalidate` (`EmulatorViewModel.swift`), acts on the
interface-v0 catalog's `generation` field, stored under a key scoped to the
(interface, RomWBW release) pair; the XML carries no generation, so a build 63
device deletes nothing on a catalog fetch at all. **This does not make the
attribute safe to move.** Every build in service still reads it, and the two
numbers are not interchangeable: the XML is at `version="13"` and the v0
catalogs start at `generation: 1`, which is exactly why the old value is never
copied into the new key.

**Build 56 narrowed what "downloaded images" means**, and the narrowing is the
whole safety property: `deleteCatalogDisks(named:)` deletes only the `.img` files
the **new** catalog lists. That is the test for whether deleting one is
recoverable — an image the new catalog does not name cannot be fetched back from
it, so a disk the user imported through Files, one `createNewDisk` made, and one
dropped from the catalog in the same bump are all kept. The alert afterwards
gives both counts. Before build 56, `deleteAllDownloadedDisks()` took every `.img`
in `Documents/Disks` regardless of where it came from.

**Since build 61 the attribute is no longer the only thing that can refresh an
image, and it should not be the thing you reach for.** `DiskLedger.swift` records
which published image each installed file came from — the catalog `<sha256>` a
verified download matched — so a respun image can be replaced on that evidence
alone, per file, with the version attribute left exactly where it is. That is how
the `hd1k_combo.img` respin reaches a device that already held the old one.
Deliberately *not* keyed on hashing the file against the catalog: a downloaded
disk is a writable CP/M volume and `saveDownloadedDisks()` rewrites it, so that
comparison marks every disk a user has saved work into as stale. See
"User Data Persistence" in `KNOWN_PROBLEMS.md`.

There is still no confirmation beforehand on the version-attribute path, and it
offers nothing as an update: the user is told after the fact. So do not think of
this attribute as metadata.
Bumping it clears the catalog half of everyone's disk library, unprompted, on
their next launch — and for the builds actually in service (1.4.9, builds 36/37,
which predate both the narrowing and the catalog pin) it still clears **all** of
it. What that means for the order a release has to go out in is in
`docs/DISK_W8FIX_RUNBOOK.md`; what is still open about it — copy-on-write, and
confirming before the wipe rather than after — is under "User Data Persistence"
in `KNOWN_PROBLEMS.md`.

## GitHub Releases Distribution

### Release URLs

Clients up to build 63 read the catalog and the images from an explicit, pinned
release tag — `releaseTag` in `EmulatorViewModel.swift`, `v1.4.12`. That
constant is deleted in build 64; this is what every shipped build still does,
and the tag has to stay live for as long as one of them is installed:
```
Catalog:  https://github.com/avwohl/ioscpm/releases/download/v1.4.12/disks.xml
Base URL: https://github.com/avwohl/ioscpm/releases/download/v1.4.12
```

Individual disk downloads append `/` plus the filename to the base URL:
```
https://github.com/avwohl/ioscpm/releases/download/v1.4.12/hd1k_combo.img
```

The help system is deliberately *not* pinned: `indexURL` and `baseURL` in
`HelpView.swift` still
fetches `help_index.json` and the `help_*.md` topics from
`https://github.com/avwohl/ioscpm/releases/latest/download/`. Help content is not
version-locked to the ROM; disk images are. See `docs/DISK_CATALOG_PINNING.md`.

### Creating a Release

When creating a new GitHub release:

1. Update `release_assets/disks.xml` if adding/modifying disks:
   - Add new `<disk>` entries
   - Update the `version` attribute
   - Generate SHA256 checksums over the built images, wherever they were staged:
     `shasum -a 256 hd1k_*.img`

2. Create the GitHub release and attach:
   - `disks.xml` and `help_index.json` from `/release_assets/`
   - All `help_*.md` files from `/release_assets/`
   - All `hd1k_*.img` files from your disk-build output — these are not repo
     files, so they have to come from wherever the images were built or
     downloaded

3. The disk catalog does not follow `/latest/` (only the help system does).
   Clients from build 42 to build 63 read the pinned tag `v1.4.12`; a new
   release tag reaches none of them until `releaseTag` in
   `EmulatorViewModel.swift` is bumped and a new app build ships. **Build 64
   onwards reads none of this** — a new disk reaches those builds by being
   published in `romwbw_disks` and does not need an app release at all, which
   is the point of the migration.

   **The builds actually in service are not among them.** The App Store serves
   1.4.9 (builds 36/37), which predates the pin and still fetches from
   `releases/latest/download/`. So a release that is *not* marked `--prerelease`
   reaches those devices immediately, with nothing installed and nothing
   submitted. `v1.4.5` is still marked prerelease and stays that way. `v1.4.12`
   was deliberately un-marked on 2026-09-04 and is now `releases/latest` — see
   `docs/DISK_W8FIX_RUNBOOK.md` under "2026-09-04" for why, and
   `docs/DISK_CATALOG_PINNING.md` for what it changed about the two layers.

## Interface v0 (build 64 onwards)

**This is what the current tree does.** The sections above describe the scheme
every *shipped* build still uses.

One URL is compiled in, and it is the only one:

```
https://github.com/avwohl/romwbw_disks/releases/download/catalog-v0/index-v0.json
```

That tag carries one small file and nothing else, which is what makes a floating
entry point safe: re-cutting it costs a few kilobytes, and the assets clients
cache never move.

Two hops from there:

1. **The index.** `romwbw_versions[]`, one entry per published RomWBW release,
   each with `hbios.ver_byte`/`upd_byte` (hex *strings*), a `status`, a
   `default` flag, a `generation`, and an absolute `catalog_url` with that
   catalog's `catalog_sha256` and `catalog_size`.
2. **That release's catalog**, verified against those two values *before* it is
   parsed. It carries `base_url` (ending in `/`), `roms[]` and `disks[]`.

An asset URL is `base_url + filename`, concatenated. The `"/"` this client used
to insert is gone — under v0 the separator is in the document, and reproducing
the fixup would double it.

Which release is in play is a user choice, filtered by asking the emulator core
about each entry's version bytes (`RomWBWEmulator.supportsRomWBW(ver:upd:)`,
which wraps `emu_romwbw_release_supported`). Everything whose validity depends
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

`iOSCPM/Resources/emu_avw.rom` still ships, and still boots. It is a reviewed
App Store asset named in `docs/ROM_ATTESTATION.md`, and it is what makes the
release it declares work with no network at all: its bytes ARE
`emu_avw-v0-3.5.1.rom`, which the app proves by hash rather than by assuming,
so on 3.5.1 there is no ROM download.

What the bundled ROM is not is a substitute. A release whose ROM cannot be
fetched or cannot be verified **does not start**: the app names the release, the
file and the reason, and offers either to try again or to switch back to the
release it carries a ROM for. Booting the bundled ROM under another release
would produce `*** WARNING: HBIOS/CBIOS Version Mismatch ***` part-way through a
boot, which is the pairing this whole scheme exists to prevent.

## Client Implementation

### Fetching the Catalog

Builds up to 63 fetch `disks.xml` on app launch and cache it locally at:
```
Documents/Disks/disks_catalog.xml
```

Build 64 fetches the two v0 documents instead and caches them per release:
```
Documents/Disks/index-v0.json
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
2. Client downloads from GitHub Releases to a temp file
3. The catalog `<filename>` is checked to be a plain name, not a path
4. The **temp file** is hashed and compared against the manifest's `sha256`
5. Only on a match is the temp file moved into `Documents/Disks/`
6. Download state is updated in UI

### Integrity Verification

**Shipped 2026-09-01.** Every download is verified before it is installed.

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

- **No `<sha256>` in the catalog entry.** Not "assume ok" — all 20 entries in
  the pinned `v1.4.12` catalog carry a hash, so an entry without one is a
  degraded or hostile catalog. Accepting it would have made the check optional
  at the catalog's choosing.
- **A `<filename>` that is not a plain name.** The catalog is downloaded
  content and its filename reaches `removeItem`; `appendingPathComponent` does
  not escape `..`. Refused rather than silently reduced, because rewriting the
  name would desync it from `refreshAvailableDisks`.

`DiskDownloadRow` (`ContentView.swift`) still shows the installed file's first
eight hash digits, green on a match. That display is now confirmation of a check
that already happened, not the only check — and it no longer paints green when
the catalog carries no hash to compare against.

## Adding a New Disk

1. Create the disk image with proper format (8MB or 49MB multislice)
2. Name it following the pattern: `hd1k_<name>.img`
3. Attach it to the GitHub release — do **not** commit the image to the repo
4. Add entry to `disks.xml`:
   ```xml
   <disk>
       <filename>hd1k_newdisk.img</filename>
       <name>New Disk Name</name>
       <description>Description of contents</description>
       <size>8388608</size>
       <license>Abandonware</license>
       <sha256>YOUR_SHA256_HERE</sha256>
   </disk>
   ```
5. Increment the `version` attribute in `<disks>`
6. Upload the updated `disks.xml` alongside the image (see "Creating a Release")

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

## Current Disk Inventory

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

## Privacy

No user data is sent to GitHub. Clients only download:
- The disk catalog manifest
- Disk image files (user-initiated)
- Help content files

See `PRIVACY.md` for full privacy policy.
