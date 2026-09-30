# Boot menu and auto-boot

What to type at the RomWBW boot menu after pressing Play.

## Boot Menu Keys

Every command is read as a line, so nothing happens until you press Enter.

- `2` - boot the first hard disk, slice 0; `2.3` for slice 3
- `C` - boot CP/M 2.2 from ROM
- `D` - list the disk devices
- `W` - **SYSCONF**, to configure auto-boot
- `H` - the full menu

Units 0 and 1 are the on-board RAM and ROM memory disks and carry no operating
system, so booting `0` answers `*** No boot record` on RomWBW 3.6.0 and
`*** No system image on disk` on 3.5.1.

## Auto-Boot Configuration

Press `W` at the boot menu for SYSCONF, choose a boot device and timeout, and
the setting persists across app restarts. Settings has a "Clear Auto-Boot"
button to undo it.
