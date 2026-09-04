# iOSCPM - CP/M Emulator for iOS and macOS

A Z80/CP/M emulator for iPhone, iPad, and Mac, built on the [RomWBW](https://github.com/wwarthen/RomWBW) HBIOS platform.

## Features

- **Full Z80 emulation** with accurate instruction timing
- **RomWBW HBIOS** compatibility for authentic CP/M experience
- **VT100/ANSI and VT52 terminal** with escape sequence support (runs Zork, WordStar, etc.)
- **Terminal scrollback** - configurable history (off, or 500, 1000, 2000, 5000, 10000 lines); drag the screen, two-finger trackpad drag or mouse wheel, or Shift+PageUp/PageDown and Ctrl+Home/End on a hardware keyboard
- **Configurable key map** - WordStar, VT100/ANSI and VT52 profiles for the navigation keys, or per-key custom bindings
- **Multiple disk support** - up to 4 disk units with hd1k format (8MB slices)
- **Download disk images** on demand, SHA-256 verified - no bundled copyrighted content
- **Host file transfer** - R8 and W8 move files between CP/M and the app's Imports and Exports folders; "Import File… (for R8)" stages host files there
- **Local file support** - open, create, and save disk images
- **NVRAM boot configuration** - auto-boot settings persist across sessions
- **Built-in help** - 7 topics covering quick start, R8/W8 file transfer, and the CP/M 2.2, ZSDOS, NZCOM, ZPM3 and QPM disks
- **Mac Catalyst** - runs natively on macOS

## Screenshots

The emulator provides a classic 80x25 terminal display with support for:
- CP/M 2.2, CP/M 3, ZSDOS, ZPM3, NZCOM
- Text adventures (Zork, Adventure, Hitchhiker's Guide)
- Productivity software (WordStar, dBASE, Turbo Pascal)

## Getting Started

1. **Open Settings** (gear icon) before starting
2. **Download disk images** - scroll to "Download Disk Images" section
3. **Select a disk** - CP/M 2.2 recommended for first boot
4. **Press Play** to start the emulator
5. At boot menu, press `0` to boot from disk

### Boot Menu Keys
- `h` - Help (shows full menu)
- `l` - List ROM applications
- `d` - List disk devices
- `w` - **SYSCONF** - Configure auto-boot settings
- `0-9` - Boot from device number
- `C` - Boot CP/M 2.2 from ROM

### Auto-Boot Configuration

Use the ROM's **SYSCONF** utility to configure auto-boot:

1. At boot menu, press `W`
2. Select boot device and timeout
3. Settings persist across app restarts

To clear auto-boot settings, go to Settings and tap "Clear Auto-Boot".

## Disk Images

Disk images are built from [RomWBW](https://github.com/wwarthen/RomWBW) v3.5.1 material and
distributed from this repository's own GitHub release. The catalog and the images are fetched
from the tag `v1.4.12`, pinned on purpose: the core's HBIOS identifies as RomWBW v3.5.1, and
disks from a different RomWBW release print an HBIOS/CBIOS mismatch at boot. Every download is
checked against the SHA-256 in `disks.xml`. The catalog carries 20 images; a selection:

| Disk | Description | License |
|------|-------------|---------|
| CP/M 2.2 | Classic Digital Research OS | Free (Lineo) |
| ZSDOS | Enhanced CP/M with timestamps | Free |
| NZCOM | ZCPR3 command processor | Free |
| CP/M 3 (Plus) | Banked memory support | Free |
| ZPM3 | Z-System CP/M 3 | Free |
| WordStar 4 | Word processor | Abandonware |

Downloaded images are stored in the app's Documents folder and work offline.

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

This project uses code from sibling directories:
- `../cpmemu/src/` - qkz80 Z80 CPU emulator
- `../romwbw_emu/src/` - HBIOS dispatch, memory banking

### Terminal Emulation

The terminal supports ANSI/VT100 escape sequences:
- Cursor positioning (`ESC[row;colH`)
- Screen/line clearing (`ESC[2J`, `ESC[K`)
- Text attributes (`ESC[7m` reverse video)
- Cursor save/restore (`ESC 7`, `ESC 8`)

This enables proper display for applications like Zork that use cursor positioning for status lines.

The VT52 dialect is implemented as well. A session starts in ANSI at power-on and follows DECANM
(`ESC[?2h` selects ANSI, `ESC[?2l` selects VT52) whenever a program asks explicitly. Otherwise VT52
is inferred only from `ESC A/B/C/F/G/I/Y`, sequences a VT100-configured program has no reason to
emit - and deliberately not from `ESC J` or `ESC K`, which are the ordinary erase commands of the
ADM-3A, Televideo, Hazeltine and Heath families too.

### Disk Format

Uses RomWBW hd1k format:
- 8MB per slice
- Up to 8 slices per disk (64MB total)
- 1024 directory entries per slice
- Compatible with all RomWBW disk images

## Building

### Requirements
- Xcode 15+
- iOS 15+ / macOS 12+ (Mac Catalyst)

### Build Steps
1. Check out the sibling projects `cpmemu` and `romwbw_emu` next to this repo, so all three
   share a parent directory - the files in `iOSCPM/Core/` are symlinks into `../cpmemu/src/`
   and `../romwbw_emu/src/`, and the build cannot find its sources without them
2. Open `iOSCPM.xcodeproj`
3. Select target device
4. Build and run

## License

GPLv3 License

### Third-Party Licenses
- **CP/M**: Released by Lineo for non-commercial use
- **RomWBW**: GNU General Public License v3.0 (GPL-3.0-or-later)
- **qkz80**: GPL v3 License

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

