# ROM Attestation for Apple App Store Review

## Summary

I, the developer of this application, hereby affirm that I have the appropriate
rights and licenses to use the ROM files this application includes and the ROM
files it downloads, and I authorize Apple to use these ROMs for testing purposes
during App Store review.

Every ROM this application can load — the one inside the app bundle and every
one it can fetch — has the same two-part construction, the same two copyright
holders and the same licence. The distinction that follows is about *delivery*,
not about rights.

## The ROM included in the application

**File:** `emu_avw.rom` (512 KB), in the application bundle
**RomWBW release:** 3.5.1

This is what the application boots on a first launch, and it is what it boots
whenever the user has selected RomWBW 3.5.1. It requires no network. An
installed copy of this application is fully functional with no ROM download of
any kind.

## The ROMs the application can download

As of build 65 the application can also fetch a ROM at runtime, so that a new
RomWBW release can be offered without an application update. It downloads from
this project's own published catalog and from nowhere else:

    https://github.com/avwohl/romwbw_disks/releases/

The user chooses a RomWBW release; the application fetches that release's ROM,
verifies it against the SHA-256 published in the catalog, and refuses it if the
hash does not match. The files it can fetch today, each 524288 bytes, and the
SHA-256 the catalog publishes for each, are:

- `emu_avw-v0-3.5.1.rom`, RomWBW 3.5.1, banks 1-15 from `SBC_simh_std`
  `4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258`
- `emu_rcz80-v0-3.5.1.rom`, RomWBW 3.5.1, banks 1-15 from `RCZ80_std`
  `03e646914628aea507eb8db560497292c728d26a127965b5b3cff6270af5feee`
- `emu_avw-v0-3.6.0.rom`, RomWBW 3.6.0, banks 1-15 from `SBC_simh_std`
  `01d1ca6d142e9b757d4fd98c2229f2e506dd8c3253839391c8f5d4f6263c6557`
- `emu_rcz80-v0-3.6.0.rom`, RomWBW 3.6.0, banks 1-15 from `RCZ80_std`
  `9b204cd71d1064d7f4a46d4403f106250e0e53f2239931a6f81aa7bc7dba5fc5`

`emu_avw-v0-3.5.1.rom` is byte-identical to the `emu_avw.rom` included in the
bundle: `iOSCPM/Resources/emu_avw.rom` is 524288 bytes and hashes to the first
of the four above.

Further RomWBW releases may be published to that same catalog later. They are
built by the same scripts, from the same two sources, under the same licence;
nothing about the rights position below changes when one is added.

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
**Versions:** 3.5.1 and 3.6.0
**Copyright:** Wayne Warthen and contributors
**License:** GNU General Public License v3.0
**SPDX Identifier:** GPL-3.0-or-later

RomWBW is open-source system software for Z80/Z180 retro-computing platforms.
The GPLv3 license explicitly grants the right to:
- Use the software for any purpose
- Distribute copies of the software
- Modify and distribute modified versions

Source code is publicly available at: https://github.com/wwarthen/RomWBW

These banks are taken verbatim from the official RomWBW release packages, which
are downloaded and verified by SHA-256 during the build.

## License Compliance

This application complies with GPLv3 requirements for both the included ROM and
the downloadable ones:

- Corresponding source for every ROM listed above is published at:
  https://github.com/avwohl/romwbw_disks — that repository holds
  `src/emu_hbios.asm`, the build scripts that assemble it, and the manifests
  pinning each upstream RomWBW package by SHA-256, so every published ROM can be
  rebuilt from source.
- Source for the emulator itself is published at:
  https://github.com/avwohl/romwbw_emu
- The LICENSE file (GPLv3) is included in both repositories.
- Each published ROM's SHA-256 is recorded in the public catalog alongside it,
  so a downloaded ROM can be checked against the source it was built from.

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

That is the ROM included in this application bundle, reproduced from source. It
covers RomWBW 3.5.1 only, because that copy of `src/emu_hbios.asm` hardcodes its
version stamp; the parameterised copy in romwbw_disks builds bank 0 for any
release, and romwbw_disks' `tools/check_source_drift.sh` asserts the two trees'
copies have not diverged.

## Authorization for Apple

I hereby grant Apple Inc. permission to use the ROM file included with this
application (`emu_avw.rom`), and any ROM the application downloads from
https://github.com/avwohl/romwbw_disks/releases/, for the purpose of testing and
reviewing this application for the App Store.

## Contact

Developer: Aaron Wohl
Repositories:
  https://github.com/avwohl/romwbw_disks (ROM and disk images, and their source)
  https://github.com/avwohl/romwbw_emu (emulator)
Date: 2026-09-07

---

**Digital Signature:** This attestation is submitted as part of App Store review
for iOSCPM (CP/M Emulator).
