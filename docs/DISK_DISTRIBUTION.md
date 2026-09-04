# Disk Distribution System

This document explains how disk images are managed, distributed, and consumed by the iOSCPM family of clients (iOS, macOS, Windows, CLI).

## Overview

The manifest and the help content are stored in this repository under
`/release_assets/`. The disk images themselves are **not** in the repo — they
exist only as GitHub Release assets (they were removed from `release_assets/` in
f570676). Clients fetch the manifest and download disks on-demand from a
**pinned** release tag, not from the "latest" endpoint; only the help system
still floats on `latest`.

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
deletes files on every installed device. On each successful catalog fetch
`checkCatalogVersionAndInvalidate` (`EmulatorViewModel.swift`) compares the
attribute against the stored `catalogVersion` default, and on **any** difference
clears downloaded images. No checksum is consulted — the comparison is on the
version attribute alone — and it needs no tap and no download.

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

Clients read the catalog and the images from an explicit, pinned release tag —
`releaseTag` in `EmulatorViewModel.swift`, currently `v1.4.12`:
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
   Clients from build 42 on read the pinned tag `v1.4.12`; a new release tag
   reaches none of them until `releaseTag` in `EmulatorViewModel.swift` is bumped
   and a new app build ships.

   **The builds actually in service are not among them.** The App Store serves
   1.4.9 (builds 36/37), which predates the pin and still fetches from
   `releases/latest/download/`. So a release that is *not* marked `--prerelease`
   reaches those devices immediately, with nothing installed and nothing
   submitted. `v1.4.5` is still marked prerelease and stays that way. `v1.4.12`
   was deliberately un-marked on 2026-09-04 and is now `releases/latest` — see
   `docs/DISK_W8FIX_RUNBOOK.md` under "2026-09-04" for why, and
   `docs/DISK_CATALOG_PINNING.md` for what it changed about the two layers.

## Client Implementation

### Fetching the Catalog

Clients fetch `disks.xml` on app launch and cache it locally at:
```
Documents/Disks/disks_catalog.xml
```

If offline, the cached version is used as fallback.

### Parsing (iOS/macOS)

The `DiskCatalogXMLParser` class in `EmulatorViewModel.swift` parses the XML:
- Extracts the version attribute
- Creates `DownloadableDisk` objects for each entry
- Constructs full download URLs

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
`EmulatorViewModel.swift`, reached from `downloadDisk` (the Settings button) and
from `downloadDiskWithCompletion` (the first-run fetch). It hashes the temp file
and, on a mismatch, retries up to three times before failing with
`Checksum mismatch - not saved`.

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
