# Disk Distribution System

This document explains how disk images are managed, distributed, and consumed by the iOSCPM family of clients (iOS, macOS, Windows, CLI).

## Overview

Disk images and manifests are stored in this repository under `/release_assets/` and distributed via GitHub Releases. Clients fetch the manifest and download disks on-demand from the GitHub Releases "latest" endpoint.

## Repository Structure

```
release_assets/
├── disks.xml              # Disk catalog manifest
├── help_index.json        # Help system index
├── hd1k_*.img             # Disk image files (28 disks)
└── help_*.md              # Help topic markdown files
```

## The Disk Manifest (`disks.xml`)

The manifest is an XML file listing all available disk images:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<disks version="10">
    <disk>
        <filename>hd1k_combo.img</filename>
        <name>Combo (Recommended)</name>
        <description>49MB multi-slice disk with CP/M 2.2, games, utilities...</description>
        <size>51380224</size>
        <license>Mixed</license>
        <sha256>c14b9bef3eca03523c059b6c5eb4921e66323921dc481ebf5f84fb378627fb0f</sha256>
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
| `sha256` | Yes | SHA256 checksum for integrity verification |
| `defaultSlot` | No | Optional default disk slot (0-3) for auto-mounting |

### Version Attribute

The `<disks version="N">` attribute tracks catalog changes. When the version changes:
- Clients detect the update on next catalog fetch
- Previously downloaded disks may be invalidated if checksums changed
- Users are notified of available updates

## GitHub Releases Distribution

### Release URLs

Clients use these hardcoded URLs:
```
Catalog:  https://github.com/avwohl/ioscpm/releases/latest/download/disks.xml
Base URL: https://github.com/avwohl/ioscpm/releases/latest/download/
```

Individual disk downloads append the filename to the base URL:
```
https://github.com/avwohl/ioscpm/releases/latest/download/hd1k_combo.img
```

### Creating a Release

When creating a new GitHub release:

1. Update `release_assets/disks.xml` if adding/modifying disks:
   - Add new `<disk>` entries
   - Update the `version` attribute
   - Generate SHA256 checksums: `shasum -a 256 hd1k_*.img`

2. Create the GitHub release and attach all files from `/release_assets/`:
   - `disks.xml`
   - `help_index.json`
   - All `hd1k_*.img` files
   - All `help_*.md` files

3. The release should be tagged appropriately (clients use `/latest/`)

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
2. Client downloads from GitHub Releases
3. SHA256 checksum is verified
4. File is stored in `Documents/Disks/`
5. Download state is updated in UI

### Integrity Verification

All downloads are verified against the manifest's SHA256 checksum:
- Failed verification triggers automatic retry (up to 3 attempts)
- Persistent failures show error to user
- No disk is used without passing verification

## Adding a New Disk

1. Create the disk image with proper format (8MB or 49MB multislice)
2. Name it following the pattern: `hd1k_<name>.img`
3. Place it in `/release_assets/`
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
6. Create a new GitHub release with all assets

## Generating SHA256 Checksums

```bash
cd release_assets
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
