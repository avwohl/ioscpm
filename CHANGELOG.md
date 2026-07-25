# Changelog

## Version 1.5.1 (Build 43)

### Terminal Scrollback: keyboard navigation + configurable size

Brings iOS/macOS scrollback to full parity with the Windows (z80cpmw) port.

- **Hardware-keyboard navigation** (new): **Shift+PageUp / Shift+PageDown** page
  through history one screen at a time; **Ctrl+Home / Ctrl+End** jump to the
  oldest retained line / live bottom. Plain PageUp/PageDown/Home/End still go to
  CP/M as before. Touch drag and trackpad / mouse-wheel scrolling are unchanged.
- **Configurable capacity** (new): Settings → Preferences → **Scrollback** sets
  the history size (Off / 500 / 1000 / 2000 / 5000 / 10000 lines); 0 disables
  capture. Persisted as `scrollbackLines`. The default is now **1000 lines**
  (matching the other ports), down from the previous fixed 2000.

### Disk catalog pinned to an explicit release

- The downloadable disk catalog is now pinned to ioscpm release **v1.4.5**
  instead of floating on `releases/latest`, matching the Windows/Android ports.
  This guarantees downloaded disks match the embedded RomWBW v3.5.1 ROM (no
  HBIOS/CBIOS version-mismatch warning at boot). Help content still floats.

## Version 1.4.11 (Build 41)

### Emulator Core Sync (romwbw_emu v1.34)

Brings the iOS/macOS port up to the v1.34 platform contract so it builds and
runs against the current shared core. See romwbw_emu `DOWNSTREAM.md` and
`docs/DOWNSTREAM_2026-07-21.md`.

- **Platform API (required):** `emu_host_file_close_write()` now returns `bool`.
  iOS buffers the W8 export and hands it to the OS asynchronously (Exports
  folder / share sheet), so the synchronous close reports success like the
  browser backend; a late write failure is surfaced in the Swift layer.
- **Platform API (required):** added `emu_console_input_exhausted()` and
  `emu_console_input_eof()` (both return `false` — only a CLI reading a closed
  pipe can exhaust input). Without these the port would not link against v1.34.
- **R8 host-file read:** verified against v1.34's new behavior — the core now
  rewinds PC and waits for the host file to be provided or cancelled instead of
  importing a 0-byte file. The port's folder-based reader already resolves the
  wait on every path (`emu_host_file_load` on success, `emu_host_file_cancel`
  on missing/unreadable file), so no code change was required.

Inherited automatically from the shared core (no port changes needed): 64-bit
disk offsets, `HBR_IO` on host disk-write failures instead of silent data loss,
bounded writes to in-memory disk images, and the `emu_file_load_to_mem` /
`emu_load_romldr_rom` hardening. Disk persistence on background, the manifest
write warning, the NVRAM string API, and unified RAM-bank init were already in
place and remain compatible.

### New: Terminal Scrollback

- Scroll back through output history by dragging the terminal (or trackpad /
  mouse-wheel on Mac). A ring buffer keeps the last 2000 lines that scroll off
  the top. A "Live" pill appears while viewing history; tap it — or type any
  key — to snap back to the bottom. The cursor is hidden while scrolled back.
  History is preserved across screen clears (CLS) and dropped on a cold boot.

### New: Configurable Keyboard Mapping

- The navigation keys (arrows, Home/End, Page Up/Down, Insert, Forward Delete)
  on a hardware/external keyboard can be remapped to arbitrary byte sequences,
  using the same termcap-style escape schema as the z80cpmw / romwbw_emu family
  (`\E`, `^X`, `^?`, `\NNN` octal, `\n \r \t \b \s`). Preset profiles:
  **WordStar** (the historical default — arrows send Ctrl-E/S/D/X, unchanged),
  **VT100/ANSI**, and **VT52**; plus per-key customization in Settings. The
  selection persists.

### New: Import File… (stage arbitrary host files for R8)

- R8/W8 transfers always use the sandbox Documents/Imports and Documents/Exports
  folders, so a batch or scripted build (e.g. one that ends in several W8s)
  never triggers a file dialog. To bring in a file from anywhere, **Import
  File…** copies the picked file(s) into Imports (a later `R8` reads them), and
  **Open Exports Folder** surfaces W8 output for sharing. The file picker only
  appears when you invoke Import File… — it is never driven by the guest, so it
  can neither interrupt a batch transfer nor stall the emulator.

## Version 1.4.10 (Build 39)

### Terminal Emulation (fixes GitHub #2)
- Deferred autowrap (VT100 "last column" behavior): writing the rightmost column no longer immediately wraps and scrolls the screen, so full-screen layouts (WordStar, Zork status lines, the TERMDEF border test) render correctly. Also removes a spurious blank line after a full 80-column line.
- VT52 terminal support: direct cursor addressing (`ESC Y`), cursor moves (`ESC A/B/C/D`), home (`ESC H`), reverse line feed (`ESC I`), erase to end of screen/line (`ESC J`/`ESC K`), Heath/Zenith clear (`ESC E`), identify (`ESC Z`), and ANSI exit (`ESC <`). Mode auto-detects from VT52-exclusive sequences (or `ESC[?2l`); ANSI/VT100 behavior is unchanged until a VT52 sequence appears.
- Terminal query answerback: responds to cursor-position report (`ESC[6n`), status (`ESC[5n`), and device attributes (`ESC[c`, `ESC Z`).
- Robustness: charset/line-size designators (`ESC (`, `ESC )`, `ESC #`, …) are now consumed instead of leaking a stray glyph; added absolute cursor positioning (`ESC[G`, `ESC[d`).

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
