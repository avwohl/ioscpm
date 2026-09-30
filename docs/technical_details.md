# Technical details

## Architecture

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

## Dependencies

Most of `iOSCPM/Core/` is symlinks into sibling checkouts:

- `../cpmemu/src/` - the qkz80 Z80 CPU core
- `../romwbw_emu/src/` - HBIOS dispatch and memory banking

`emu_io_ios.mm`, `hbios_core.cc` and `hbios_core.h` are this repository's own.

## Terminal Emulation

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

## Disk Format

RomWBW hd1k: 8 MB per slice, up to 8 slices per disk, 1024 directory entries
per slice.
