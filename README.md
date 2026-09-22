# iOSCPM - CP/M Emulator for iOS and macOS

A Z80/CP/M emulator for iPhone, iPad and Mac, built on the
[RomWBW](https://github.com/wwarthen/RomWBW) HBIOS platform. It ships on the App
Store as **Z80CPM**; `iOSCPM` is the name of this repository and the Xcode
target. Those three are what this repository builds for. The single App Store
record also offers the app on Apple Vision (visionOS 1.0+), where what installs
is the unmodified iPad app - no xrOS slice is built here and none has been run.
See `KNOWN_PROBLEMS.md`, "The Store offers this app on visionOS".

## Features

- **Z80 emulation** with the RomWBW HBIOS interface, for an authentic CP/M
- **VT100/ANSI and VT52 terminal** with escape sequence support (runs Zork,
  WordStar, Turbo Pascal)
- **Terminal scrollback** - off, or 500 to 10000 lines; drag the screen,
  two-finger trackpad drag or mouse wheel, or Shift+PageUp/PageDown and
  Ctrl+Home/End on a hardware keyboard
- **Configurable key map** - WordStar, VT100/ANSI and VT52 profiles for the
  navigation keys, or per-key custom bindings
- **Multiple disks** - up to 4 units in hd1k format, 8 MB slices
- **No ROM and no disk image is bundled.** Both are downloaded on demand from
  the [romwbw_disks](https://github.com/avwohl/romwbw_disks) catalog and checked
  against the SHA-256 it publishes
- **Pick your RomWBW release** - the app offers every release the published
  index lists, except a development snapshot, which is behind a Settings
  opt-in; a corrected or newly published ROM or disk reaches you without an app
  update
- **Host file transfer** - `R8` and `W8` move files between CP/M and the app's
  Imports and Exports folders; "Import File… (for R8)" stages host files there
- **Local file support** - open, create and save disk images
- **NVRAM boot configuration** - auto-boot settings persist across sessions
- **Built-in help** - topics published by the catalog, with a bundled set as
  fallback, covering quick start, R8/W8 transfer and the CP/M 2.2, ZSDOS,
  NZCOM, ZPM3 and QPM disks
- **Mac Catalyst** - runs natively on macOS

## What Runs On It

- CP/M 2.2, CP/M 3, ZSDOS, ZPM3, NZCOM, QPM
- Text adventures: Zork, Adventure, Hitchhiker's Guide
- Productivity software: WordStar, Turbo Pascal
- Language toolchains: Aztec C, BASIC compilers, COBOL

## Getting Started

1. **Open Settings** (gear icon) before starting
2. **Pick a RomWBW release** - optional; the app preselects the one the
   published index marks as default
3. **Download disk images** - scroll to "Download Disk Images"
4. **Select a disk** - a first launch assigns two: the Combo image to drive 0
   and the games image to drive 1. Combo is the catalog's recommended starter
   and the only image carrying `R8`/`W8`
5. **Press Play** - the release's ROM is fetched first if it is not on the
   device already
6. At the boot menu, type `2` and Enter to boot the first hard disk

### Boot Menu Keys

Every command is read as a line, so nothing happens until you press Enter.

- `2` - boot the first hard disk, slice 0; `2.3` for slice 3
- `C` - boot CP/M 2.2 from ROM
- `D` - list the disk devices
- `W` - **SYSCONF**, to configure auto-boot
- `H` - the full menu

Units 0 and 1 are the on-board RAM and ROM memory disks and carry no operating
system, so booting `0` answers `*** No boot record` on RomWBW 3.6.0 and
`*** No system image on disk` on 3.5.1.

### Auto-Boot Configuration

Press `W` at the boot menu for SYSCONF, choose a boot device and timeout, and
the setting persists across app restarts. Settings has a "Clear Auto-Boot"
button to undo it.

## Disk Images

ROMs and disk images come from
[romwbw_disks](https://github.com/avwohl/romwbw_disks), which publishes one
catalog per RomWBW release. The app compiles in a single index URL: the index
lists the releases, Settings' **RomWBW Release** picker chooses among them, and
every download URL comes from the chosen release's own catalog. Settings' **Catalog**
section points the app at a different index entirely; each index keeps its own
downloads and settings.

Every download is checked against the SHA-256 the catalog gives, and the
catalog itself against the index's before it is read. The ROM is re-verified
every time it is loaded, which is a check no disk could survive once the guest
has written to it. A release whose ROM cannot be fetched does not start: an
alert names the release and the file rather than quietly substituting another
release's ROM, which is what leaves RomWBW printing an HBIOS/CBIOS version
mismatch part-way through a boot.

Each release publishes more than one ROM, and which of them boots is a choice in
Settings. A release flagged `preview` is marked as one in the picker. When a ROM
cannot be fetched the app names the release and the file and says what would fix
it - a connection, or the other ROM that release publishes - rather than falling
back to another release's ROM, which is what leaves RomWBW printing a version
mismatch part-way through a boot.

**A new RomWBW release does NOT need a new build**, and neither do new disks or
ROMs within one. The picker offers every release the published index lists -
with one exception that is a choice and not a compile-time list: an entry the
index flags `prerelease` is a RomWBW development snapshot, and the picker drops
it unless Settings -> RomWBW Release -> Show Development Snapshots is ticked,
which is off in a fresh install.

That is a change: until romwbw_emu v1.44 this app filtered the index against a
compile-time list of releases its core had been checked against, so 3.7.0 would
have been fetched and then hidden. The list gated the wrong axis. A release
number is the pairing between HBIOS and a disk image's CBIOS - which the guest
itself enforces, by printing *** WARNING: HBIOS/CBIOS Version Mismatch *** on a
mismatched pair - and not what the emulator depends on. What the emulator
depends on is two I/O ports and the set of HBIOS functions it services, and that
interface is versioned by the catalog's own name: everything a **v0** index
publishes speaks v0, and a change this core could not service would be published
as `index-v1.json`, which this app does not read.

Which releases exist, which is the default, and what each one carries are
questions for the published index, not for this file - the app shows what it
finds, and [romwbw_disks](https://github.com/avwohl/romwbw_disks) is where it is
published. Each disk entry carries its own `license` field, which the app
displays; that field is the authority on what an image is under.

Downloaded images live in the app's `Documents/Disks` folder (a custom index
gets its own `Disks@<hash>` beside it, so two catalogs' identically-named
images cannot collide) and work offline. Filenames carry the release -
`hd1k_combo-v0-3.5.1.img` - so two RomWBW releases' disks sit side by side, and
so do the slot selections and boot settings that go with them. Switching
release deletes nothing.

## Technical Details

### Architecture

```
┌─────────────────────────────────────┐
│         SwiftUI Interface           │
├─────────────────────────────────────┤
│      EmulatorViewModel (Swift)      │
├─────────────────────────────────────┤
│    RomWBWEmulator (Obj-C++ Bridge)  │
├─────────────────────────────────────┤
│       HBIOSEmulator (C++)           │
│  ┌─────────────┬─────────────────┐  │
│  │   qkz80     │  HBIOSDispatch  │  │
│  │  (Z80 CPU)  │  (HBIOS calls)  │  │
│  └─────────────┴─────────────────┘  │
└─────────────────────────────────────┘
```

### Dependencies

Most of `iOSCPM/Core/` is symlinks into sibling checkouts:

- `../cpmemu/src/` - the qkz80 Z80 CPU core
- `../romwbw_emu/src/` - HBIOS dispatch and memory banking

`emu_io_ios.mm`, `hbios_core.cc` and `hbios_core.h` are this repository's own.

### Terminal Emulation

ANSI/VT100 escape sequences: cursor positioning (`ESC[row;colH`), screen and
line clearing (`ESC[2J`, `ESC[K`), text attributes (`ESC[7m` reverse video) and
cursor save/restore (`ESC 7`, `ESC 8`) - enough for programs like Zork that use
cursor positioning for a status line.

The VT52 dialect is implemented too. A session starts in ANSI and follows
DECANM (`ESC[?2h` ANSI, `ESC[?2l` VT52) when a program asks explicitly.
Otherwise VT52 is inferred only from `ESC A/B/C/F/G/I/Y`, which a
VT100-configured program has no reason to emit - and deliberately not from
`ESC J` or `ESC K`, the ordinary erase commands of the ADM-3A, Televideo,
Hazeltine and Heath families.

### Disk Format

RomWBW hd1k: 8 MB per slice, up to 8 slices per disk, 1024 directory entries
per slice.

## Building

**Requirements:** iOS 15+ / macOS 12+ (Mac Catalyst). The project records
`LastUpgradeCheck = 2620`; no older Xcode has been tried, so the real floor is
unmeasured. Which Xcode any given build was made with is a fact about a machine
and belongs in `CHANGELOG.md` against that build, not here.

1. Check out `cpmemu` and `romwbw_emu` next to this repo, so all three share a
   parent directory - `iOSCPM/Core/` symlinks into both and the build cannot
   find its sources otherwise
2. Open `iOSCPM.xcodeproj`
3. Select a target device
4. Build and run

## License

GPLv3.

### Third-Party Licenses
- **CP/M**: released by Lineo for non-commercial use
- **RomWBW**: GNU General Public License v3.0 (GPL-3.0-or-later)
- **qkz80**: GPL v3

## Related Projects

- [80un](https://github.com/avwohl/80un) - Unpacker for the CP/M archive and compression formats LBR, ARC, squeeze, crunch, and CrLZH.
- [cpmdroid](https://github.com/avwohl/cpmdroid) - Z80/CP/M emulator for Android phones and tablets. It emulates the RomWBW HBIOS interface and a VT100 terminal.
- [cpmemu](https://github.com/avwohl/cpmemu) - Z80/CP/M emulator for Linux and Windows, with Z80 and 8080 CPU cores. It translates the BDOS and BIOS calls of CP/M 2.2 programs to the host file system.
- [learn-ada-z80](https://github.com/avwohl/learn-ada-z80) - Collection of more than 90 Ada example programs for uada80, the Ada compiler for the Z80 processor and CP/M.
- [mbasic](https://github.com/avwohl/mbasic) - Python interpreter for MBASIC 5.21, the Microsoft BASIC-80 for CP/M. Two compiler backends compile the programs to CP/M .COM files or to JavaScript.
- [mbasic2025](https://github.com/avwohl/mbasic2025) - Reconstruction of the lost source code of MBASIC 5.21, the Microsoft BASIC-80 for CP/M. The MACRO-80 source code assembles to a binary that matches mbasic.com byte for byte.
- [mbasicc](https://github.com/avwohl/mbasicc) - C++17 interpreter for MBASIC 5.21, the Microsoft BASIC-80 for CP/M. It runs on Linux and macOS.
- [mbasicc_web](https://github.com/avwohl/mbasicc_web) - Web browser interpreter for MBASIC 5.21, the Microsoft BASIC-80 for CP/M. Emscripten compiles the mbasicc interpreter to WebAssembly.
- [mpm2](https://github.com/avwohl/mpm2) - Z80 emulator for MP/M II, the multi-user CP/M operating system. Users connect over SSH, and SFTP clients transfer files.
- [romwbw_emu](https://github.com/avwohl/romwbw_emu) - Hardware-level Z80/CP/M emulator for Linux and macOS. It emulates the RomWBW HBIOS interface and switches banks in 512 KB of ROM and 512 KB of RAM.
- [scelbal](https://github.com/avwohl/scelbal) - Floating-point BASIC interpreter for the 8080 processor and CP/M. A translator converts the original 8008 source code to 8080 source code.
- [uada80](https://github.com/avwohl/uada80) - Ada compiler for the Z80 processor and CP/M 2.2. It compiles a subset of Ada 2012 to CP/M .COM files.
- [uc80](https://github.com/avwohl/uc80) - C compiler for the Z80 processor and CP/M. It optimizes for small code size.
- [ucow](https://github.com/avwohl/ucow) - Cowgol compiler for the Z80 processor and CP/M. It runs on Linux in Python.
- [um80_and_friends](https://github.com/avwohl/um80_and_friends) - Linux toolchain that is compatible with Microsoft MACRO-80. It has an assembler, a linker, a librarian, and a disassembler.
- [upeepz80](https://github.com/avwohl/upeepz80) - Peephole optimizer for Z80 compilers that write lowercase Z80 assembly language. It shortens jumps to jr, builds djnz loops, and removes dead stores.
- [uplm80](https://github.com/avwohl/uplm80) - PL/M-80 compiler for the Z80 processor and CP/M. It writes Intel 8080 and Zilog Z80 assembly language.
- [z80cpmw](https://github.com/avwohl/z80cpmw) - Z80/CP/M emulator for Windows. It emulates the RomWBW HBIOS interface and boots CP/M from disk images.


## See Also

- [RomWBW](https://github.com/wwarthen/RomWBW) - The original RomWBW project by Wayne Warthen
