# Quick Start Guide

## First Launch

When you first launch the app, two disk images are automatically selected:
- **Disk 0**: Combo disk (CP/M 2.2 with games and utilities)
- **Disk 1**: Games disk

## Booting CP/M

1. At the boot prompt `Boot [H=Help]:`, type the unit number of the hard disk
   you want to boot and press Enter - with the default images that is `2`
2. Units 0 and 1 are the RAM and ROM memory disks and carry no operating
   system, so the first attached hard disk (Disk 0, the Combo image) is unit 2
   and the next attached disk is unit 3. Typing `0` answers
   `*** No system image on disk`. Plain `2` boots slice 0; type `2.3` for a
   specific slice
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

RomWBW hands out the letters as it boots: the slice you booted becomes **A:**,
the two memory disks follow as **B:** (RAM) and **C:** (ROM), and the slices
left over take the letters after that, the rest of the first disk before the
second disk.

This is the map CBIOS prints with the two default images, having booted Disk 0
slice 0 by typing `2`:

| Drive | Contents |
|-------|----------|
| `A:` | The slice you booted (here Disk 0, slice 0) |
| `B:` | RAM disk (temporary storage, cleared on restart) |
| `C:` | ROM disk (read-only utilities) |
| `D:-F:` | Disk 0 (Combo), slices 1-3 |
| `G:-J:` | Disk 1 (Games), slices 0-3 |

Boot a different slice and that slice becomes `A:` instead, with the others
following in the same order.

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

On Windows and macOS you type all of these on the keyboard. On iOS, iPadOS and
Android the buttons beside the terminal stand in when no hardware keyboard is
attached: **Ctrl** folds the next key you type and then turns itself off again,
and **Esc** and **Tab** send those keys directly.

The app keeps only a few keys for itself: Shift+Page Up / Shift+Page Down and
Ctrl+Home / Ctrl+End scroll the terminal history on Windows, macOS, iOS and
iPadOS; on Android you scroll by dragging the screen instead. Unmodified Page
Up, Page Down, Home and End still reach the guest.

Copy and paste are on every port, reached differently: **Cmd+C** and **Cmd+V**
on macOS, iOS and iPadOS; the **Copy** and **Paste** buttons beside the terminal
on Android; and on Windows, select with the mouse and right-click for **Copy**
and **Paste** - there Ctrl+C is a CP/M keystroke, not a copy.

## Changing Disks

Open Settings to select different disk images for each disk slot.
