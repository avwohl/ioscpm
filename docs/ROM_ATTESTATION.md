# ROM Attestation for Apple App Store Review

## Summary

I, the developer of this application, hereby affirm that I have the appropriate
rights and licenses to use the ROM files this application downloads, and I
authorize Apple to use these ROMs for testing purposes during App Store review.

This application contains no ROM of its own. Every ROM it can load is fetched at
runtime from the one repository named below, checked against the SHA-256 that
repository publishes for it, and refused if the two disagree. All of them have
the same two-part construction, the same two copyright holders and the same
licence; they differ only in which RomWBW release they carry and which machine
configuration banks 1-15 were taken from.

## What changed since the previous filing

Earlier revisions of this document had a section headed "The ROM included in
the application", describing a 512 KB `emu_avw.rom` for RomWBW 3.5.1 inside the
application bundle, and said that an installed copy was fully functional with
no ROM download of any kind. That second claim was already too strong when it
was made: this application had stopped bundling disk images months earlier, and
a ROM with no disk to boot does not make an installed copy functional. That
file has been removed. `git ls-files` in this application's repository now
matches no `.rom`, `.img`, `.bin`, `.com` or `.dsk` at all, and the four
`project.pbxproj` entries that copied the ROM into the bundle went with it in
build 66 (`7b9feb3`, 2026-09-07).

That sentence used to end "the version the App Store serves today still
contains it". It no longer does: `sh tools/check-store-version.sh` on
2026-09-21 reports 1.6.2, released 2026-09-21, and 1.6.2 heads exactly one
build — 74 — so the shipping binary is build 74, well past the removal in
build 66. Every copy Apple can currently download fetches its ROM from the
catalog below.

Nothing about the rights position changed when it went. The same bytes are still
available, as `emu_avw-v0-3.5.1.rom`, from the catalog below — that download is
byte-identical to the ROM that used to be bundled.

## The ROMs the application downloads

The application fetches every ROM it runs, from this project's own published
catalog and from nowhere else:

    https://github.com/avwohl/romwbw_disks/releases/

The user chooses a RomWBW release; the application fetches that release's ROM,
verifies its byte count and its SHA-256 against the values published in the
catalog, and refuses to run it if either disagrees. That check happens every time
the ROM is used, not only when it is downloaded, because a file that verified
when it landed can be truncated afterwards by a restore or a full volume. There
is no fallback: a release whose ROM cannot be fetched or cannot be verified does
not start, and the application names the release, the file and the reason. The
files it can fetch today, each 524288 bytes, and the SHA-256 the catalog
publishes for each, are:

- `emu_avw-v0-3.5.1.rom`, RomWBW 3.5.1, banks 1-15 from `SBC_simh_std`
  `4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258`
- `emu_rcz80-v0-3.5.1.rom`, RomWBW 3.5.1, banks 1-15 from `RCZ80_std`
  `03e646914628aea507eb8db560497292c728d26a127965b5b3cff6270af5feee`
- `emu_avw-v0-3.6.0.rom`, RomWBW 3.6.0, banks 1-15 from `SBC_simh_std`
  `01d1ca6d142e9b757d4fd98c2229f2e506dd8c3253839391c8f5d4f6263c6557`
- `emu_rcz80-v0-3.6.0.rom`, RomWBW 3.6.0, banks 1-15 from `RCZ80_std`
  `9b204cd71d1064d7f4a46d4403f106250e0e53f2239931a6f81aa7bc7dba5fc5`
- `emu_avw-v0-3.7.0-dev.14.rom`, RomWBW 3.7.0-dev.14, banks 1-15 from
  `SBC_simh_std`
  `abdc615a8e30dcba9cca4a472007e0d800cf80f439e5fd2c907ee0a59dfc7ddf`
- `emu_rcz80-v0-3.7.0-dev.14.rom`, RomWBW 3.7.0-dev.14, banks 1-15 from
  `RCZ80_std`
  `19d946cf36c66643137f60addfd8dbe4c6a9e54eac12d90b6575da5344210c08`

The last two are a RomWBW **development snapshot**, which is not something
upstream calls a release. The catalog flags that entry `prerelease: true` and
never flags it `default`, and this application does not offer it unless the
user ticks Settings → RomWBW Release → Show Development Snapshots, which is off
in a fresh install. A reviewer reaches those two ROMs only deliberately. Their
rights position is the one described below, unchanged: the same two components,
the same two copyright holders, the same licence.

**All six were re-verified on 2026-09-21, and for the first time by fetching
the ROM files themselves.** Earlier revisions verified the first four against
the catalog's published values and read the two 3.7.0-dev.14 values out of
`catalog-v0-3.7.0-dev.14.json` without fetching those two ROMs at all. On
2026-09-21 the index at
`https://github.com/avwohl/romwbw_disks/releases/latest/download/index-v0.json`
was fetched; each of the three catalogs it names was fetched and its own bytes
checked against the `catalog_size` and `catalog_sha256` the index publishes
(11826/`942803d1…`, 15062/`4b4de296…`, 13262/`127e6095…` — all three agreed);
and then every one of the six ROM files above was downloaded from the URL its
catalog gives and hashed. All six are present, all six are exactly 524288
bytes, and all six SHA-256 values match the ones printed above and the ones the
catalogs publish.

**Whoever files this document re-verifies all six against the live catalog on
the day they file**, and sets the Date line at the end to that day. The
verification above is not a filing: no session has App Store Connect
credentials, so this document has still never been filed.

Further RomWBW releases may be published to that same catalog later. They are
built by the same scripts, from the same two sources, under the same licence;
nothing about the rights position below changes when one is added.

## A first launch needs a network

Because the application bundles no ROM, and because its disk catalog and every
disk image in it are downloads as well, a first launch requires a network
connection. That was already true of the disks — no build has bundled a disk
image since December 2025, and with an empty catalog the application declines
to start rather than pretending to boot — and it is now true of the ROM too. A
reviewer testing this build needs the device to be able to reach github.com.
Everything the application fetches, ROM and disk alike, comes from the one host
named above.

## What every one of these ROMs contains

### Component 1: emu_hbios (Bank 0, 32 KB)

**Source:** `src/emu_hbios.asm` in
https://github.com/avwohl/romwbw_disks (and in
https://github.com/avwohl/romwbw_emu)
**Copyright:** Original work created by the application developer
**License:** GNU General Public License v3.0
**Rights:** Full copyright ownership — I am the author of this code

This is a minimal HBIOS (Hardware BIOS) proxy that enables the emulator to
intercept hardware calls. It contains no third-party code. It is identical in
every ROM listed above; only the RomWBW release it declares differs.

### Component 2: RomWBW System Software (Banks 1-15, 480 KB)

**Source:** [RomWBW Project](https://github.com/wwarthen/RomWBW)
**Versions:** 3.5.1, 3.6.0 and 3.7.0-dev.14
**Copyright:** Wayne Warthen and contributors
**License:** GNU General Public License v3.0
**SPDX Identifier:** GPL-3.0-or-later

RomWBW is open-source system software for Z80/Z180 retro-computing platforms.
The GPLv3 license explicitly grants the right to:
- Use the software for any purpose
- Distribute copies of the software
- Modify and distribute modified versions

Source code is publicly available at: https://github.com/wwarthen/RomWBW

These banks are taken verbatim from the official RomWBW packages, which are
downloaded and verified by SHA-256 during the build. For 3.5.1 and 3.6.0 that
package is an upstream release; for 3.7.0-dev.14 it is an upstream
*prerelease*, tagged `v3.7.0-dev.14`, pinned by SHA-256 in the same manifests
and published by the same project under the same licence. Nothing about the
licence or the copyright depends on which of the two it is.

## License Compliance

This application complies with GPLv3 requirements for every ROM it downloads:

- Corresponding source for every ROM listed above is published at:
  https://github.com/avwohl/romwbw_disks — that repository holds
  `src/emu_hbios.asm`, the build scripts that assemble it, and the manifests
  pinning each upstream RomWBW package by SHA-256, so every published ROM can be
  rebuilt from source.
- Source for the emulator itself is published at:
  https://github.com/avwohl/romwbw_emu
- The LICENSE file (GPLv3) is included in both repositories.
- Each published ROM's SHA-256 is recorded in the public catalog alongside it,
  so a downloaded ROM can be checked against the source it was built from — and
  that is exactly the check the application itself performs before it runs one.

That last point is checkable rather than merely stated. `roms/build_emu_rom.sh`
in https://github.com/avwohl/romwbw_emu assembles `src/emu_hbios.asm` into bank
0, overlays it on banks 1-15 taken from the upstream RomWBW package, hashes the
result, and compares that against the SHA-256 the catalog publishes for the same
ROM. Run on 2026-09-07 it ends:

```
PASS: byte-identical to the published emu_avw for RomWBW 3.5.1
      sha256 4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258
      The ROM users download is reproducible from the source in this
      repository.  That is what docs/ROM_ATTESTATION.md asserts.
```

That is the first of the six files above — the one the application downloads
when the user selects RomWBW 3.5.1 — rebuilt from source and matching the
published bytes. It is a statement about what users fetch, which is now the only
kind of ROM this application has. The run covers that one ROM because that copy
of `src/emu_hbios.asm` hardcodes its version stamp; the parameterised copy in
romwbw_disks builds bank 0 for any release, and romwbw_disks'
`tools/check_source_drift.sh` asserts the two trees' copies have not diverged.

## Authorization for Apple

I hereby grant Apple Inc. permission to use any ROM this application downloads
from https://github.com/avwohl/romwbw_disks/releases/ — the six files listed
above, and any later RomWBW release published to that same catalog — for the
purpose of testing and reviewing this application for the App Store. The
application ships no ROM file of its own, so there is nothing further to
authorize.

## Contact

Developer: Aaron Wohl
Repositories:
  https://github.com/avwohl/romwbw_disks (ROM and disk images, and their source)
  https://github.com/avwohl/romwbw_emu (emulator)
Date: 2026-09-21 (the date this text was last revised and the six ROMs above
were last fetched and hashed; **the filer replaces it with the day they file**,
having re-verified them again)

---

**Digital Signature:** This attestation is submitted as part of App Store review
for iOSCPM (CP/M Emulator).
