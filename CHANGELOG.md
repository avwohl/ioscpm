# Changelog

## Version 1.5.1 (Build 52)

### W8 could delete the user's disk library

`W8 ANYFILE.TXT ..` destroyed the entire `Documents` folder — `Disks`,
`Imports` and `Exports`, so every disk image the user had downloaded — and
reported success to the guest.

Three things lined up. `W8` takes an optional host path and sends it verbatim.
`emu_host_file_open_write()` stored it unsanitised as the export *filename*.
And `saveToExportsFolder` then built a destination with
`exportsDir.appendingPathComponent(name)` followed by
`try? fm.removeItem(at: destURL)` — where `appendingPathComponent` does **not**
escape `..`, so the URL resolved to `Documents`, and `removeItem` on it
succeeds and deletes recursively. The `try?` swallowed the error; the guest was
told the export succeeded because `emu_host_file_close_write()` returns before
the Swift layer ever runs.

Reproduced against the shipped logic on a scratch tree, and again after the
fix: `Documents: GONE` became `Documents: present, disk image intact`.

Fixed in three places, deliberately overlapping, because a check that only
holds while another layer behaves is not a check:

- **The core reduces the string first.** `emu_host_file_open_write()` now runs
  it through the shared `emu_host_path_basename()` (new upstream in
  romwbw_emu v1.36), which takes both separators and never returns `""`, `"."`
  or `".."`. This alone closes it, and closes it for any future UI layer.
- **`ExportPath`** (new, `iOSCPM/Views/ExportPath.swift`) owns reducing a guest
  string to a leaf and proving the result lands directly inside `Exports`. Split
  out for the reason `TerminalDialect`, `ControlKey` and `KeyMap` were — it
  touches no UIKit, so it is testable, and this is the one that most needed to
  be. `Tests/ExportPathTests.swift`, 24 checks, including the ten traversal
  strings and the two Foundation behaviours that made the old version
  destructive.
- **`saveToExportsFolder` no longer calls `removeItem` at all.**
  `Data.write(to:)` already replaces an existing file; the remove was pure
  downside.

### R8 imported the wrong file and said nothing

The same unsanitised path on the read side. `R8 /USERS/ME/FOO.COM` built
`Imports/USERS/ME/FOO.COM`, missed, and then fell back to **the first file in
the folder** — loading unrelated contents into CP/M under the requested name,
with a success message on both sides. `../SOMETHING` could also address files
outside `Imports`.

The core reduces the path to a leaf before the delegate sees it, the lookup
reduces again, and a miss is now reported instead of substituted. A file whose
name differs only in case is still found: CP/M's CCP uppercases the whole
command line, so the guest asks for `FOO.COM` when the file is `foo.com`, and
the native backend has always resolved that case-insensitively. This now does
too, which matters on a case-sensitive volume.

### W8 says where the file went

`emu_host_file_get_write_name()` answers with the real `Exports` path rather
than an echo of the guest's string, so the new upstream `HBF_HOST_GETNAME`
(0xE8) gives the CP/M user something they can act on — previously `To host:`
named a path that does not exist anywhere on the device. The Swift layer takes
the leaf through a separate accessor, `emu_host_file_get_write_leaf_c()`,
because it joins to `Exports` itself.

### Not in this build, on purpose

`releaseTag` still points at **v1.4.5**. Refreshing the disk-image catalog is
what puts a path-capable `W8` in front of every user, so it must not happen in
the same step as, or before, this fix reaching them. The order is written down
in romwbw_emu's `docs/RELEASE_ORDER_2026-08-25.md`; this build is step 1 of it,
and the catalog bump is step 5.

That order guards the `W8` path. It does not guard the other destructive thing
the catalog bump does, which is new to `todo.txt` in this build and not fixed
here: `disks.xml` carries a `version` attribute, and on any change to it
`checkCatalogVersionAndInvalidate` calls `deleteAllDownloadedDisks()`, which
removes **every** `.img` in `Documents/Disks` — including disks the user
imported through Files and disks the app itself created, neither of which the
catalog can give back — and tells the user afterwards. The attribute has moved
on essentially every catalog change to date, so step 5 fires it. What should
happen instead is a product decision, so it is written down rather than guessed
at. `KNOWN_PROBLEMS.md`'s "Data Loss Risk with GitHub Disks" entry, which
described only the download-over-the-top case, now names this trigger too, and
`docs/DISK_DISTRIBUTION.md`'s "Version Attribute" section — which had it as
disks that "may be invalidated if checksums changed", with users "notified of
available updates", none of which the code does — now describes what actually
happens.

### Downloads are not checksum-verified on this port

Found while checking the above and also only written down, not fixed.
`EmulatorViewModel` has two download implementations. `downloadDiskWithRetry()`
hashes the installed file against the manifest's `sha256`, deletes it and
retries on a mismatch — and is dead: its only callers are its own four retry
arms. Every real download goes through `downloadDiskFromSettings()`, which
moves the temp file into place without hashing it. The catalog hash survives as
the coloured digest in `DiskDownloadRow`, computed after the file is installed
and acted on by nothing.

`docs/DISK_DISTRIBUTION.md` asserted the opposite in three places ("SHA256
checksum is verified", "All downloads are verified against the manifest's SHA256
checksum", "No disk is used without passing verification"). Its "Integrity
Verification" section is now marked intended-not-shipped and describes the live
path, and `todo.txt` carries the choice — delete the dead path, or move its
check into the live one.

Two smaller facts that had sat only in `KNOWN_PROBLEMS.md` are now in `todo.txt`
as well, re-verified against the source and otherwise unchanged: a new disk is
always 8 MB (`createNewDisk(at:size:)` has a `size:`, the single call site in
`ContentView` passes none, and there is no size picker, while an import is
accepted up to `maxDiskSize`, 64 MB), and a created disk is `0xE5` fill with no
HD1K filesystem laid down, so it is unusable until something formats it.

### Stale claims in the docs

`docs/notes_to_windos.md` warned about siblings on topic branches with a dated
example: `../cpmemu` on `posix-console` (`55cc13f`) rather than `main`. That
branch has since landed — `55cc13f` is dated 2026-08-23 and is an ancestor of
`main`, and `posix-console` is no longer a local branch there — and a warning
whose one concrete example is stale invites being dismissed. The hazard is
unchanged, so the anecdote is replaced by what the tests do and do not prove:
`Tests/run_tests.sh` (`=== CoreSymlinks ===`) asserts that all 21 entries under
`iOSCPM/Core/` are still mode 120000 in the index and that none dangle, then
compiles through them — but a symlink into a sibling parked on a topic branch
resolves, compiles and passes exactly as a correct one does, so which commit is
behind the link is not something any test here can see.

`KNOWN_PROBLEMS.md` still described `SpecialKey` as "a flat 10-case enum".
Build 51 made it twenty-two. The point it was supporting — that the binding
schema has no slot for a modified arrow — is unaffected.

The same entry said z80cpmw "does the same thing" with modifiers and elsewhere
that it "has no equivalent" for Ctrl+arrow. Both are now false: z80cpmw's
`TerminalView.cpp` passes a modifier mask to `m_keymap.find()`, and its
`Keymap.h` defaults bind Ctrl+Up/Down/Right/Left to `\E[1;5A`..`D`. Corrected
to say so. No convention is picked for ioscpm here — cpmemu sends the WordStar
bytes `^A ^F ^W ^Z` and z80cpmw sends the xterm forms, and choosing between them
is the open item in `todo.txt`, unchanged by this.

## Version 1.5.1 (Build 51)

### Three parity gaps closed

- **F1-F12 are bindable.** `SpecialKey` was ten cases; it is twenty-two now, the
  same set `z80cpmw/Keymap.h` defines, with the same VT220/xterm sequences byte
  for byte - `\EOP` through `\EOS` for F1-F4, then `\E[15~`, `\E[17~` and up,
  skipping 16 and 22 as a real VT220 does. That was the reason key maps were not
  interchangeable between the ports. The VT52 profile is the exception on
  purpose: a VT52 has four keypad function keys as `ESC P`..`ESC S` and no
  others, so F5-F12 send nothing there rather than borrowing a VT100 sequence a
  VT52 program cannot be expecting.
- **The terminal gained the editing finals it was missing** - `@` ICH, `P` DCH,
  `X` ECH, `S` SU, `T` SD - and now acts on two DEC private modes it previously
  only parsed: DECAWM (`?7`), so a guest can turn autowrap off and have the last
  column overwrite instead of wrapping, and DECTCEM (`?25`), so a full-screen
  program can hide the cursor while it redraws. Both reset to their power-on
  state on cold boot, so a guest that hides the cursor and then dies does not
  leave it hidden for the next session. SU sends lines to scrollback only when
  the region is the whole screen, matching what LF already did - lines pushed out
  of a status-line window were never history.
- **Help works offline.** The index and all seven topics now ship inside the app.
  The download still comes first and the cache second, so a correction published
  to a release still reaches users without an app update - but a first run with
  no network, or a release whose help assets were not attached, no longer leaves
  the user with nothing. That second case is not hypothetical: `cpmdroid` shipped
  this exact arrangement with no bundled copy, its assets stopped being attached
  after v1.11, and every build from then on had no help at all with nothing
  failing anywhere to say so.

### Also

- `KeyMap.swift` is split out of `TerminalView.swift`. None of it touches UIKit,
  and that made it testable - `Tests/KeyMapTests.swift` adds 34 checks, which
  assert the F-key bytes against z80cpmw's table rather than against "something
  reasonable", since a plausible but different sequence is exactly what would
  make maps silently non-portable again.
- The root `disks.xml` is deleted. It was byte-identical to
  `release_assets/disks.xml` and had no consumer - the app builds its catalog URL
  from the pinned release tag.
- The test suite is 150 checks, from 116.

## Version 1.5.1 (Build 50)

### The VDA keyboard works, and there are tests that say so

A cross-port audit of this repo against `romwbw_emu`, `cpmemu` and `z80cpmw`
found the core current — the 21 symlinks in `iOSCPM/Core/` were already
resolving to `romwbw_emu` v1.36 and every item on its migration checklist was
done — and turned up two bugs in the shared HBIOS dispatcher instead. Both are
fixed upstream in `romwbw_emu` `bf03758` and arrive here through the symlinks;
this build is the one that carries them.

- **`VDAKST` said "no key" however much was queued.** It set the pending count
  in `E` but left the status byte in `A` at zero, and `A` is what a caller
  tests. Its `CIO` twin, `CIOIST`, has always set both.
- **`VDAKRD` handed the guest a stale byte.** With no key pending it flagged the
  wait and returned *without rewinding PC*. Dispatch is a two-byte
  `OUT (0xEF),A` followed by the Z80 proxy's own `RET`, so skipping the rewind
  let that `RET` fire immediately with `E` still holding whatever the previous
  call left there — the guest read it as a keystroke and never came back for the
  real one. `CIOIN` has rewound since the non-blocking path was added, and this
  port runs non-blocking (`hbios_core.cc` calls `setBlockingAllowed(false)`,
  because the UI thread cannot stop for a key), which is exactly the arm where
  it mattered.

Neither is reached by the normal serial-console boot, which is why nothing had
been reported. But `SYSGET_VDACNT` reports one VDA to every port, so any guest
that used the video keyboard hit both.

### Tests

`Tests/run_tests.sh` grew from 40 checks to 116, in three suites plus a
structural check:

- **CoreSymlinks** — asserts all 21 entries under `iOSCPM/Core/` are still
  symlinks and still resolve. They have been flattened into stale copies once
  before (`docs/notes_to_windos.md`), and a flattened copy compiles and passes
  every behavioural test; it just quietly stops tracking upstream.
- **CoreKeyboardTests** (new, C++, 24 checks) — compiles the shared core
  *through those symlinks* and drives HBIOS the way the Z80 proxy does, in the
  non-blocking mode this app uses. Covers `CIOIN`/`CIOIST`/`VDAKRD`/`VDAKST`,
  the PC rewind, the whole WordStar diamond surviving `CIOIN` unchanged, and
  `CIOOUT` buffering rather than writing behind the UI thread's back. This is
  the first test in the repo that touches the emulator at all.
- **ControlKeyTests** (new, Swift, 50 checks) — the Ctrl fold build 49 added.
  The arithmetic moved out of `TerminalUIView` into `ControlKey.swift` so it
  could be tested at all, the same split that made `TerminalDialect` testable;
  `controlByte(for: UIKey)` still does the UIKit half. Covers every letter in
  both cases, the non-letter combinations build 49 added, and the hazard that
  commit called out by name and nothing verified: `uppercased()` maps a German
  `ß` to `SS`, so a full Unicode fold would hand the guest `^S` — WordStar
  cursor-left — from a key that used to send nothing.
- **TerminalDialectTests** — unchanged, 40 checks.

No user-visible change beyond the two fixes above.

## Version 1.5.1 (Build 49)

### Synced to the romwbw_emu v1.36 core - control keys belong to the guest

Takes the v1.35 -> v1.36 migration notice
(`romwbw_emu/docs/DOWNSTREAM_2026-08-23.md`). The sweep behind it started with a
Windows user reporting "Ctrl R exits me from CPM"; `^R` was already clean here,
but the same shape of bug was not.

- **Ctrl with anything that is not a letter now reaches CP/M.** The only Ctrl
  keys that ever arrived were `a`-`z`, because 26 `UIKeyCommand`s were the whole
  mechanism and every other Ctrl press was dropped on the floor. `Ctrl+[` (ESC),
  `Ctrl+\`, `Ctrl+]`, `Ctrl+^`, `Ctrl+_`, `Ctrl+@` and `Ctrl+Space` (NUL),
  `Ctrl+?` and `Ctrl+Backspace` (DEL), and every `Ctrl+Shift+letter` now fold to
  their ASCII control byte in one place. The 26 key commands are kept for Mac
  Catalyst, where claiming a key explicitly is the reliable way to keep AppKit's
  own Ctrl-letter bindings away from the WordStar diamond.
- **`Ctrl+J` was indistinguishable from Enter.** Two separate LF -> CR rewrites
  sat on the input path, one in `queueInput` and one in `emu_console_queue_char`.
  Nothing needed them: every key that means Enter already sends CR. They ate the
  only 0x0A a user could produce - `Ctrl+J`, and a key map binding spelled
  `\n` - so both are gone and the mapping now happens once, in `insertText`,
  where the software keyboard's Return genuinely does arrive as LF. This is the
  same audit v1.36 ran on its own tty read path.
- **Escape claims priority over system behaviour on Mac Catalyst**, where ESC is
  also the leave-full-screen gesture. `keyCommands` now returns nothing while a
  dialog has the keyboard, so a priority Escape cannot outrank the alert it is
  meant to dismiss.
- **A dialog now really does hold the keyboard.** The terminal stays first
  responder underneath a dialog and its key commands are the first UIKit
  consults, so Escape and Return were reaching CP/M instead of dismissing.
  Only the disk-overwrite warning ever suppressed capture; the error alert -
  including the ROM-failure alert added below - never did. All three dialogs
  drawn over the terminal now do.
- **Reset asks first.** The toolbar Reset button sits next to Play/Stop, and a
  cold boot drops the running program and the entire scrollback. It is now
  behind a confirmation, whether or not the machine is running - the history is
  wiped either way. This is the fourth bullet of the new upstream contract,
  "Platform Contract: Ctrl-A..Ctrl-Z Belong to the Guest", reached by a tap
  rather than by a key.
- **The dead `emu_console_check_ctrl_c_exit()` stub is deleted.** Upstream
  removed the declaration in v1.36; nothing ever called it in any port, and a
  dead function that looks like a live `^C` interception is a trap for the next
  person auditing exactly that question. `emu_console_check_escape()` stays - it
  is still declared and still live for the CLI - and its comment now records
  that iOSCPM reserves no key, which is what the contract asks of the
  `escape_char == 0` case.
- `keyboard.ctrlRToCpm` from the Windows port is deliberately **not** ported:
  there is nothing here to switch off.

### A ROM that fails to load no longer starts the CPU

- **`loadSelectedResources()` reported a failed ROM and returned anyway**, so
  `start()` ran the Z80 over whatever bank 0 happened to hold and the status
  line said "Running". It now returns a result and Start honours it. A disk that
  fails to load is still non-fatal - booting with no disk is legitimate.
- **The reason survives.** All three failure modes - not in the app bundle,
  unreadable, or rejected by the core's HCB validation - reported "not found",
  which sends people hunting for a file that is right there. The bridge now
  validates with `emu_validate_rom_hcb()` before loading and keeps the message,
  so a corrupt or wrong-release ROM says so.

### Terminal fixes

- **`ESC[nM` (Delete Line) could crash the app.** With `n` larger than the
  distance from the cursor to the bottom of the scrolling region, the loop bound
  fell below its start and the Swift `Range` trapped. `n` is now clamped to the
  region for both DL and IL - deleting more lines than exist just clears it.
- **Reverse video was destructive.** `SGR 7` swapped the colour nibbles in
  place with no record that it had, so a second `SGR 7` swapped back, and
  `SGR 27` gave up and reset to white-on-black - throwing away whatever colours
  were set. Reverse is now a flag, and the swap happens on the way to a cell
  rather than being stored, so it is a clean toggle and the colours underneath
  are never disturbed. That also fixes a loss the in-place swap could not avoid:
  the background nibble is three bits, so a bright foreground did not survive a
  round trip through it. The flag is cleared wherever the whole attribute byte
  is replaced, including the HBIOS `VDASetAttr` path. `SGR 22` (bold off) is
  implemented.
- **CSI parsing is bounded.** Digit and parameter counts are capped and parsed
  values clamped, matching the Windows port, so a runaway guest cannot grow the
  parser's state without limit.

### Build and housekeeping

- **The Z80 decoder no longer pays for tracing it never uses.** `QKZ80_NO_TRACE`
  is defined for both configurations; nothing in this port ever calls
  `set_trace()`. Follows `cpmemu` `06262ff`.
- **About shows the RomWBW pin** (`3.5.1`) beside the app version. A disk slice
  built by a different release prints an HBIOS/CBIOS mismatch, so it is the
  first thing worth asking for in a bug report.
- Documentation audit against the sibling ports: the README credited RomWBW as
  MIT where the attestation filed with Apple says GPL-3.0-or-later; the stated
  minimum OS predated the iOS 15 deployment target; `docs/DISK_CATALOG_PINNING.md`
  still described iOS as the unpinned outlier three weeks after the pin shipped;
  the root `disks.xml` was three catalog versions stale and carried the
  pre-W8-fix combo hash. `KNOWN_PROBLEMS.md` gains a Keyboard section recording
  the decisions from this sweep that are deliberate and must not be re-flagged.

## Version 1.5.1 (Build 48)

### Disk capacity is no longer narrowed silently (shared core)

- **`disk.size / 512` was truncated into a 32-bit sector count** at two points
  in the HBIOS dispatcher, which the compiler reported as
  "implicit conversion loses integer precision". A truncating conversion keeps
  the remainder, so an image just past 2 TiB would have reported as nearly
  empty rather than as huge, and `DIOCAP` would have handed the guest a
  capacity unrelated to the disk. `HBDisk` now has a `total_sectors()`
  accessor - matching `MemDiskState::total_sectors()` beside it - which clamps
  at the largest sector count HBIOS can express instead of wrapping.
- No behaviour change for any disk that can exist today; a 49 MB six-slice
  hd1k image still mounts and reports 8176 KB per slice under `STAT DSK:`.
- Fixed in the shared `romwbw_emu` core (`5667a34`), so it reaches the other
  ports too.

## Version 1.5.1 (Build 47)

### An erase no longer decides we are a VT52 (issue #2)

- **A single `ESC K` switched the terminal for the rest of the session.** The
  VT52 choice was inferred from ordinary output, applied globally, and never
  expired. `ESC J` and `ESC K` - erase to end of screen, erase to end of line -
  counted as proof of VT52, but they are the erase commands of the ADM-3A,
  Televideo, Hazeltine and Heath families too, so a CP/M program installed for
  any of those emits them constantly while meaning nothing about VT52. Measured
  on build 46: `ESC Z` answered `<27>[?1;0c` at the MBASIC prompt, an unrelated
  statement printed `ESC K`, and the same `ESC Z` then answered `<27>/Z`.
- **Why all three terminal settings failed the same way.** The dialect is
  global, so once it was wrong, reinstalling WordStar for vt100, ansi or vt52
  made no difference - which is what issue #2 reported.
- **What changed.** `ESC J` and `ESC K` no longer switch the dialect. What still
  does is what a VT100-configured program has no reason to emit: it spells
  cursor movement `CSI A/B/C`, not `ESC A/B/C`. `ESC Y` direct cursor addressing
  is unmistakable and is the sequence a real VT52 program cannot avoid, so
  genuine VT52 still works, and `ESC <` still returns to ANSI.
- **Why erring toward ANSI is safe.** The VT52 action sequences never consult
  the dialect - `ESC A/B/C/I/J/K` and `ESC Y` are carried out either way. Only
  `ESC D`, `ESC E`, `ESC H` and the `ESC Z` reply depend on it, and guessing
  VT52 wrongly is the destructive direction: it turns `ESC E` from Next Line
  into clear-the-screen.

### First tests in the repo

- `Tests/run_tests.sh` compiles and runs host-side unit tests with `swiftc` - no
  Xcode test target, no simulator, no display. `Tests/TerminalDialectTests.swift`
  covers the above in 40 checks.

## Version 1.5.1 (Build 45)

### Synced to the romwbw_emu v1.35 core

- **The bundled ROM is refreshed.** `emu_avw.rom` was intact but predated the
  upstream rebuild; the app now ships the ROM that reproduces from
  `src/emu_hbios.asm`. Verified with `romwbw_emu/roms/verify_romwbw_pin.sh`,
  which passes this tree with no warnings.
- **A corrupt file was being shipped inside the app bundle.**
  `iOSCPM/Resources/emu_hbios.bin` had a damaged HBIOS configuration block
  (`57 b8 36 2b` — bad marker, nonsense version) and was copied into the app by
  the Resources build phase, while no Swift or Objective-C++ referenced it. It
  was a stale build intermediate riding along in every release. Removed, with
  its four `project.pbxproj` entries.
- The core now pins the RomWBW release it emulates (v3.5.1) in
  `romwbw_pin.h` and refuses a ROM built for a different release, or one whose
  configuration block is corrupt, instead of starting a CPU that produces no
  output. `Core/romwbw_pin.h` is symlinked alongside the other core files —
  without it the build fails with `'romwbw_pin.h' file not found`.
- Inherited by recompiling: `emu_file_load()` no longer terminates the process
  on an unseekable path (a document handed over by a file picker is exactly
  that case), `emu_file_save()` is atomic instead of truncating its target
  before writing, and the disk read/write paths check their seeks.

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
