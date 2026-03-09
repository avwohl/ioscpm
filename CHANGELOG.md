# Changelog

## Version 1.4.8 (Build 35)

### Power Management
- Console idle detection: emulator sleeps 10ms instead of 0.1ms when guest is polling keyboard with no input, reducing CPU/battery drain at the CP/M prompt

## Version 1.4.7 (Build 34)

Mac catch-up release: brings Mac to parity with iOS v1.4.6.

### Boot & NVRAM
- NVRAM persistence: Boot settings from ROM's SYSCONF ('W' menu) now survive app restarts
- Simplified boot configuration — removed boot string text field, use ROM's SYSCONF menu instead
- Read-only display of current auto-boot setting with Clear Auto-Boot safety button
- Fixed autoboot clearing via legacy boot_string mechanism
- Boot setting now correctly applied on both start and reset

### Disk Management
- Write protection warning when modifying auto-downloaded disk images ("Don't Warn Again" option)
- Removed per-disk slice limits — all slices now accessible to OS tools
- Removed duplicate Infocom disk (already included in Games)
- Fixed duplicate Games entry in disk manifest

### UI Improvements
- Build date and number shown in status bar and About box
- Font size options consolidated into submenu to reduce menu clutter
- Help menu (Cmd+?) now works properly on Mac Catalyst
- Better error diagnostics in Help system with HTTP status checking and cache fallback
- Keyboard handling fix for manifest warning dialog

### Emulator Core
- Unified RAM bank initialization using shared HBIOSDispatch bitmap
- Boot disk correctly assigned as A: via upstream CB_BOOTVOL
- Manifest disk write detection in emulator I/O layer

## Version 1.4.5 (Build 32)
- NVRAM boot configuration persists across sessions
- Simplified boot options UI - configure via ROM's SYSCONF ('W' menu)
- Clear Auto-Boot button to reset stuck boot settings
- Manifest disk write warning when modifying auto-downloaded disks
- Fixed autoboot clearing (legacy boot_string mechanism)

## Version 1.4.4 (Build 31)
- Add auto-start feature with countdown
- Fix boot option NVRAM integration
- Add build number to About box

## Version 1.4.3 (Build 29)
- Unify RAM bank initialization to use shared HBIOSDispatch bitmap
- Remove Infocom disk (duplicate of Games)
- Fix duplicate Games entry in disk manifest
- Add distribution documentation

## Version 1.4.2 (Build 24)
- Remove per-disk slice limits UI and settings
- Move control key stripe from horizontal to left side vertical
- Connect Help menu bar item to show Help view
- Add better error diagnostics to Help system
- Add Auto slice option
- Fix boot disk as A: via upstream CB_BOOTVOL

## Version 1.4.1 (Build 18)
- Auto-calculate disk slice count based on number of loaded disks
- Update CP/M 3 description - now working with bank config fixes
- Add export compliance key to suppress App Store encryption dialog

## Version 1.4.0 (Build 15)
- Add remote help system with platform-specific examples
- Add menu items to open Imports/Exports folders
- Fix W8/R8 file transfer for Mac Catalyst
- Integrate upstream emu_init shared initialization
- Add Ctrl key toolbar for control character input
- Fix input handling and remove debug output
- Working bank config changes

## Version 1.3.7
- Refactor to use qkz80 subclassing for I/O and halt handling

## Version 1.3.6
- Update disk catalog to v6 with 21 RomWBW 3.5.1 disk images
- Fix license display from MIT to GPL v3 in About boxes
- Add KNOWN_PROBLEMS.md documenting disk creation and data persistence issues

## Version 1.3.5
- Fix auto-download using same path as settings download

## Version 1.3.3
- Fix sequential download bug
- Update menu bar name

## Version 1.3.1
- Version bump for TestFlight

## Version 1.3.0
- Add automatic retry for disk downloads
- Add ROM attestation for App Store review

## Version 1.2.0
- Catalog versioning
- Error handling improvements
- Debug flag support

## Version 1.1.0
- Add R8/W8 host file transfer utilities
- Add VT100 terminal emulation for Infocom games
- Add privacy policy and license

## Version 1.0.0
- Initial release
- Full Z80 emulation with accurate instruction timing
- RomWBW HBIOS compatibility
- VT100/ANSI terminal with escape sequence support
- Multiple disk support (up to 4 units, hd1k format)
- Download disk images from RomWBW project
- Local file support for disk images
- Mac Catalyst support
- Copy/paste support
- Auto-save downloaded disk images
- Remote disk catalog with caching
