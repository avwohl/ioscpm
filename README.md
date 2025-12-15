# iOSCPM - CP/M Emulator for iOS and macOS

A Z80/CP/M emulator for iPhone, iPad, and Mac, built on the [RomWBW](https://github.com/wwarthen/RomWBW) HBIOS platform.

## Features

- **Full Z80 emulation** with accurate instruction timing
- **RomWBW HBIOS** compatibility for authentic CP/M experience
- **VT100/ANSI terminal** with escape sequence support (runs Zork, WordStar, etc.)
- **Multiple disk support** - up to 4 disk units with hd1k format (8MB slices)
- **Download disk images** from RomWBW project - no bundled copyrighted content
- **Local file support** - open, create, and save disk images
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
- `h` - Help
- `l` - List ROM applications
- `d` - List disk devices
- `0-9` - Boot from device number

## Disk Images

Disk images are downloaded from the official [RomWBW](https://github.com/wwarthen/RomWBW) project:

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

### VT100 Terminal Emulation

The terminal supports ANSI/VT100 escape sequences:
- Cursor positioning (`ESC[row;colH`)
- Screen/line clearing (`ESC[2J`, `ESC[K`)
- Text attributes (`ESC[7m` reverse video)
- Cursor save/restore (`ESC 7`, `ESC 8`)

This enables proper display for applications like Zork that use cursor positioning for status lines.

### Disk Format

Uses RomWBW hd1k format:
- 8MB per slice
- Up to 8 slices per disk (64MB total)
- 1024 directory entries per slice
- Compatible with all RomWBW disk images

## Building

### Requirements
- Xcode 15+
- iOS 14+ / macOS 11+ (Mac Catalyst)

### Build Steps
1. Clone sibling projects (cpmemu, romwbw_emu)
2. Open `iOSCPM.xcodeproj`
3. Select target device
4. Build and run

## License

MIT License

### Third-Party Licenses
- **CP/M**: Released by Lineo for non-commercial use
- **RomWBW**: MIT License
- **qkz80**: MIT License

## Links

- [RomWBW Project](https://github.com/wwarthen/RomWBW) - HBIOS and disk images
- [iOS/Mac Source](https://github.com/avwohl/ioscpm) - This project

## Acknowledgments

- Wayne Warthen for RomWBW
- The CP/M and retrocomputing community
