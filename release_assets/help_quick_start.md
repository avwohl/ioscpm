# Quick Start Guide

## First Launch

When you first launch the app, two disk images are automatically selected:
- **Disk 0**: Combo disk (CP/M 2.2 with games and utilities)
- **Disk 1**: Games disk

## Booting CP/M

1. At the boot prompt `Boot [H=Help]:`, type `2` and press Enter
2. This boots CP/M 2.2 from disk **unit 2** - units 0 and 1 are the RAM and
   ROM memory disks, so the first attached hard disk (Disk 0, the Combo image)
   is unit 2. Plain `2` boots slice 0; type `2.3` for a specific slice
3. You'll see the `A>` prompt when ready

Press `D` at the boot prompt for the Device Inventory, which lists the disk
units that are actually attached.

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

## Control Keys

Every Ctrl keystroke is folded to its ASCII control byte and passed straight to
CP/M: Ctrl+A through Ctrl+Z give 0x01-0x1A, Ctrl+@ and Ctrl+Space give NUL,
Ctrl+[ \ ] ^ and _ give 0x1B-0x1F, and Ctrl+? or Ctrl+Backspace give DEL.
There is no emulator console - **Ctrl+E** is WordStar cursor-up, not a debugger.

Without a hardware keyboard, use the buttons beside the terminal: **Ctrl** folds
the next key you type and then turns itself off again, and **Esc** and **Tab**
send those keys directly.

The app keeps only a few keys for itself: Shift+Page Up / Shift+Page Down and
Ctrl+Home / Ctrl+End scroll the terminal history, Cmd+C copies the screen text
and Cmd+V pastes the clipboard as keystrokes. Unmodified Page Up, Page Down,
Home and End still reach the guest.

## Changing Disks

Use the Settings panel to select different disk images for each slot.
