# Quick Start Guide

## First Launch

When you first launch the app, two disk images are automatically selected:
- **Disk 0**: Combo disk (CP/M 2.2 with games and utilities)
- **Disk 1**: Games disk

## Booting CP/M

1. At the boot prompt `Boot [H=Help]:`, type `2` and press Enter
2. This boots CP/M 2.2 from slice 2 of the Combo disk
3. You'll see the `A>` prompt when ready

## Basic Commands

| Command | Description |
|---------|-------------|
| `DIR` | List files in current drive |
| `DIR B:` | List files on drive B |
| `TYPE filename` | Display text file contents |
| `ERA filename` | Delete a file |
| `REN new=old` | Rename a file |
| `B:` | Switch to drive B |

## Drive Letters

- **A:** RAM disk (temporary storage, cleared on restart)
- **B:** ROM disk (read-only utilities)
- **C:-F:** Slices from Disk 0 (Combo)
- **G:-J:** Slices from Disk 1 (Games)

## Running Programs

Just type the program name without .COM extension:
```
A>MBASIC
A>WS
A>ZORK1
```

## Console Escape

Press **Ctrl+E** to access the emulator console for debugging.

## Changing Disks

Use the Settings panel to select different disk images for each slot.
