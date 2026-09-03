# WIP — emptying todo.txt (session of 2026-09-03)

**Status: work in progress, committed to the branch `todo-sweep-2026-09-03`.**
`./Tests/run_tests.sh` is green: 11 suites, 869 checks, 0 failures. It has NOT
been built as an iOS app — see the last section for why that matters.

Task, in the user's words: *"Tackle this project's todo.txt, make it be empty.
Fix what needs fixing. Implement what needs implementing. Stop declaring victory
with a bigger todo.txt than when you started."*

There is **no Xcode on this machine**, only Command Line Tools — `xcodebuild`
does not run and there is no simulator. `xcrun --sdk macosx swiftc` does work,
which is why every piece of new logic below was deliberately put in a
UIKit-free type with a command-line suite behind it. Nothing here has been
compiled as an iOS app.

## Resume by reading

- This file. Seven implementation specs were produced by a research workflow;
  their conclusions are folded in below, so **nothing outside this repo is
  needed to resume**. (The raw specs are in a gitignored `.wip/` on the machine
  that ran them and are not worth carrying — they are reproducible.)
- The open question below, and item 1 under STILL TO DO, are the only things
  between here and an empty `todo.txt`.

## THE ONE OPEN QUESTION — disk sizes larger than 8 MB

`iOSCPM/Views/DiskSize.swift` currently offers **1 / 2 / 4 / 7 hd512 slices**
(N × 8,519,680 bytes). A spec agent independently proposed something different:
**1 MB prefix + N × 8 MB hd1k slices** (8/17/25/33/41/49/57 MB), matching the
shipped `hd1k_combo.img`.

Both agree on the facts, which were read out of the core, not guessed:

- `emu_check_disk_size()` (`iOSCPM/Core/emu_init.cc`) accepts only: exactly
  8,388,608; `1,048,576 + N × 8,388,608`; exactly 8,519,680; any multiple of
  8,519,680. **A round 16/32/64 MB image is refused** — that is the trap a naive
  picker would have fallen into, and `Tests/DiskSizeTests.swift` asserts it.
- `HBF_EXTSLICE` (`hbios_dispatch.cc`, ~line 2390) detects hd1k **only** from an
  MBR with a type-0x2E partition, or from a file that is exactly 8 MB.
  Otherwise it falls back to hd512 with `slice_size = 16640` sectors.

Where they differ: the agent says a 0xE5 image over 8 MB is "misdetected and its
slices run off the end of the file". That is true of the *hd1k combo* shape with
no MBR, but **not** of an exact multiple of 8,519,680: 16640 × 512 = 8,519,680,
so N slices land exactly on the file. The capacity guard is
`slice_start_sector >= disk.total_sectors()` (hbios_dispatch.cc ~2433), which
that shape satisfies. I believe the current implementation is correct and needs
no MBR; the agent's needs a hand-written 512-byte MBR.

**Not yet verified on a real machine, and cannot be here.** Decide one of:

1. Keep hd512 multi-slice (current code). No MBR to write. Verify by creating a
   2-slice disk on a device and checking two drive letters appear.
2. Switch to `1 MB + N × 8 MB` and write a type-0x2E MBR at LBA 2048. Matches
   the shipped combo images; more code, and the MBR must be exactly right.

Either way this belongs in `MANUAL_CHECKS.md` before the todo item is called
closed.

## Done — closed todo items

### 1. "[MAC] the CSI parser still has no unit tests OUTSIDE SGR" — CLOSED
- **NEW `iOSCPM/Views/TerminalScreen.swift`** (~1100 lines). The whole screen
  model and escape parser extracted out of `EmulatorViewModel`: the cell grid,
  cursor, saved cursor, scrolling region, autowrap, scrollback, the VT100/ANSI/
  VT52 state machine, `TerminalCell`. Imports Foundation and nothing else.
  - Side effects became drained queues instead of direct calls, which is what
    made it testable: `pendingResponses` / `takeResponses()` for device reports
    (CPR, DSR, DA, ESC Z), `pendingBells` / `takeBells()` for BEL.
  - `EmulatorViewModel` keeps `@Published var screen` and forwards
    `terminalCells`, `cursorRow/Col`, `cursorVisible`, `displayCells`,
    `scrollback*`, `eraseScreen()`, `clearTerminal()`. `drainTerminalEffects()`
    is the one place the queues are emptied.
  - `reset()`'s power-on block became `screen.resetToPowerOn()`.
- **NEW `Tests/TerminalScreenTests.swift` — 261 checks**, all through the public
  `receive(_:)` byte path: cursor motion and clamping, ED/EL/ECH, ICH/DCH,
  IL/DL (including the clamp that used to trap), DECSTBM, SU/SD, deferred
  autowrap, save/restore cursor, answerbacks, private markers and intermediate
  bytes, VT52, background-colour erase, scrollback capture/cap/anchoring, and
  the three different clears.

### 2. "[MAC] new disks are always 8 MB and the size is hardcoded twice" — CLOSED (see open question)
- **NEW `iOSCPM/Views/DiskSize.swift`** + **`Tests/DiskSizeTests.swift` (63
  checks)**, which re-read `HD1K_SINGLE_SIZE` / `HD1K_PREFIX_SIZE` /
  `HD512_SINGLE_SIZE` out of `iOSCPM/Core/emu_init.h` so an upstream change
  fails a test rather than a user's file picker.
  - Gotcha found and worked around: the shared core is CRLF, and Swift folds
    `\r\n` into one grapheme, so `split(separator: "\n")` returns the whole file
    as one line. Use `split(whereSeparator: \.isNewline)`.
- `EmptyDiskDocument(sizeBytes:)` and `createNewDisk(at:size:)` both read
  `viewModel.newDiskSize` now — that was the actual bug: the exporter wrote the
  file first with its own hardcoded 8 MB.
- Settings gained a "New Disk Size" picker.

### 3. "[MAC] parity gap: no on-screen navigation/function key row" — CLOSED
- `KeyRowLayout` and `SpecialKey.shortLabel` added to `KeyMap.swift`
  (UIKit-free); `SpecialKeyRow` / `SpecialKeyButton` added to `TerminalView.swift`,
  drawn under the terminal in `TerminalWithToolbar`.
- Three pages: Nav / Fn / Ctrl. The Ctrl page matters on Catalyst, where
  WindowServer eats Ctrl+arrow before the app sees it.
- `showKeyRow` setting (default on) + Settings toggle.
- `Tests/KeyMapTests.swift` grew to 143 checks; the load-bearing one asserts
  **every** `SpecialKey` case is reachable from some page.

### 4. "[MAC] parity gap: the bell is not a setting" — CLOSED
- `bellEnabled` lives on `TerminalScreen` next to the counter it gates (where
  z80cpmw 480edcb put it, for the same reason), persisted by the view model,
  Settings toggle. `resetToPowerOn()` deliberately does not touch it — the
  setting is the user's, not the guest's — and a test asserts that.

### 5. "[MAC] parity gap: no Catalyst window-state persistence and no Emulator menu" — CLOSED
- **NEW `iOSCPM/Views/WindowFrame.swift`** (pure, CoreGraphics only) +
  **`Tests/WindowFrameTests.swift` (34 checks)**: what a remembered frame is
  refused for — too small, larger than the display, off every display.
- **NEW `iOSCPM/Views/CatalystWindow.swift`**, `#if targetEnvironment(macCatalyst)`
  only: `sizeRestrictions.minimumSize` always, and
  `requestGeometryUpdate(.Mac(systemFrame:))` behind `#available(iOS 16)`. Below
  iOS 16 there is no supported way to place the window and the file says so
  rather than reaching for a private API.
- `iOSCPMApp.swift` gained a real **Emulator menu** (`EmulatorMenuCommand`)
  reaching `ContentView` by the same NotificationCenter hop the Help item
  already used: Start/Stop ⌘R, Reset ⌘⇧R, Clear Screen ⌘K, Jump to Live ⌘L,
  Save All Disks ⌘S, Open Imports/Exports, Settings ⌘,.
  - A spec agent argues for hoisting the view model to `@StateObject` in the App
    instead of the notification hop, and for size-only restore with a
    `min == max` pulse. Both are worth reading in `.wip/spec-journal.jsonl`
    before this is called finished.

### 6. "[MAC] parity gap: no configuration profiles" — CLOSED
- **NEW `iOSCPM/Views/EmulatorProfile.swift`**: `EmulatorProfile` (ROM, four
  disk slots, boot string, key profile + custom bindings, scrollback, bell,
  manifest warning, key row, new-disk size) and `ProfileStore`
  (save/rename/delete/apply/last-used/unique-name), all pure values.
- `EmulatorViewModel` gained `currentProfile(named:)`, `saveCurrentProfile`,
  `updateProfile`, `deleteProfile`, `renameProfile`, `applyProfile` (which
  reports what it could not resolve rather than failing whole).
- `ProfileSection` / `ProfileRow` in `ContentView.swift`.
- **`Tests/EmulatorProfileTests.swift` — 62 checks**, mostly about profiles
  arriving from an older version or a hand-edited plist.
- Bug fixed on the way: `isRestoringSelections` was declared "to prevent didSet
  during restore" and **was never consulted**, so the restore loop rewrote the
  `selectedDisks` defaults key three times with half-applied state. The `didSet`
  now honours it and both restore and profile-apply persist once at the end.

### 7. Both `[RELEASE]` items and the "Needs a person at the app" pointer — CLOSED
A research agent triaged these sentence by sentence. Almost all of it was
already carried in `KNOWN_PROBLEMS.md`, `docs/DISK_W8FIX_RUNBOOK.md`,
`docs/DISK_CATALOG_PINNING.md` or `CHANGELOG.md`, or was narration of finished
work. Two findings mattered:

- **"do not bump releaseTag (still v1.4.5)" is factually false.** Commit
  `0010591` already set `releaseTag = "v1.4.12"`. Carrying it forward as a rule
  would have invited an agent to revert an R8 data-loss fix. Deleted, not moved.
- **"archiving works, distribution signing is missing" was carried nowhere.**
  That is the load-bearing sentence in the whole item and is now a standing fact
  in `KNOWN_PROBLEMS.md`.

Applied:
- **NEW `tools/check-store-version.sh`** (companion to `check-disk-pins.sh`).
  Measures what the Store serves, brackets it to a build through `CHANGELOG.md`,
  compares with `CURRENT_PROJECT_VERSION`, and checks z80cpmw's
  `FEATURE_PARITY.md` `shipped:` field. **Run and verified today: exit 0** —
  Store serves 1.4.9 (2026-03-19, 168 days ago), tree is 1.5.1 build 58,
  `shipped:37` agrees. Being ahead of the Store is not a failure.
- `CLAUDE.md`: two new sections — "Never write down a shipped state you have not
  measured" and "Releasing disk images: read the runbook first".
- `KNOWN_PROBLEMS.md`: new "Releasing" section (archive ≠ upload), and its
  dangling `See the [RELEASE] item in todo.txt` reference repaired.
- Dangling `todo.txt` pointers repaired in `docs/DISK_DISTRIBUTION.md`,
  `docs/DISK_CATALOG_PINNING.md`, `EmulatorViewModel.swift` and
  `Tests/CGAColorTests.swift`.
- The "Needs a person at the app" pointer carried nothing `MANUAL_CHECKS.md`
  does not already say in more detail — delete it, move nothing.

## STILL TO DO

1. **The last todo item: `emu_host_file_get_read_name()` / R8's `Reading:` line.**
   Not started. Traced fully, and the fix is settled — **make this port's open
   synchronous**, which is what the CLI and Windows backends already do.

   - **The gap.** `emu_host_file_open_read()` (`iOSCPM/Core/emu_io_ios.mm`
     ~line 402) basenames the guest path, sets `HOST_FILE_WAITING_READ`,
     `dispatch_async`es `emuHostFileRequestRead:` to the main queue and returns.
     The Swift layer does the Imports lookup on the main queue and only then
     calls `emu_host_file_load_named()`, which is what moves the state to
     `HOST_FILE_READING`. The emulator runs on `_emulatorQueue`, and R8 emits
     `H_OPEN_R` (0xE1) and `H_GETRNAME` (0xEA) about ten Z80 instructions apart,
     so the main queue has essentially never run in between.

   - **An earlier idea in this session was wrong; do not spend time on it.**
     "Resolve the name in the backend at open, keep the data async, and relax
     the getter's gate" cannot work: `HBF_HOST_GETRNAME` in `hbios_dispatch.cc`
     itself gates on `emu_host_file_get_state() == HOST_FILE_READING`, so it
     never calls the getter at all. Relaxing *that* gate is a shared-core and
     `emu_io.h` contract change touching cpmemu, romwbw_emu, z80cpmw and
     cpmdroid — and it would have the backend answer with a name for a file it
     has not opened, which is the exact "claim about the open" the contract says
     this call exists to replace. It is dominated anyway: a backend that can
     resolve the name synchronously can read the bytes synchronously too.

   - **The fix.** In `emu_host_file_open_read()`, on the emulator thread: keep
     the `emu_host_path_basename(filename, "")` reduction (it is the containment
     guard — without it `R8 ../SOMETHING` escapes Imports again), scan the
     Imports directory, `fopen`/`fread` the file, record the absolute resolved
     path in `g_host_read_filename`, and return with the state already
     `HOST_FILE_READING`. **Zero shared-core files change** — `emu_io_ios.mm` is
     port-local. The duplicate case-insensitive scan is *deleted from Swift*
     rather than added to C++, so there is one resolver, not two.

   - **A second, separate bug falls out of the same edit.** iOS's Documents
     volume is case-INsensitive, so Swift's current
     `fileExists(atPath: Imports/ESC.TXT)` fast path *succeeds* for a file
     stored as `esc.txt`, and the path handed to `emu_host_file_load_named()`
     then carries the case the CCP invented rather than the case the file has.
     So even when the race lands the right way the answer is dishonest.
     `realpath()` does not fix this on iOS — it resolves symlinks and `.`/`..`,
     not case. **Always scan the directory and take the entry's own spelling**;
     the fast path has to go, not be kept "for speed". z80cpmw's
     `resolveRealPathExisting()` arrived at the same correction independently.

   - **Traps, each of which has bitten this code before:**
     - `fopen` succeeding with size 0 **must still** set `HOST_FILE_READING`.
       Guarding the state change on `size > 0` reopens the zero-byte hole closed
       in build 53 (romwbw_emu v1.36, cpmdroid c06fa58).
     - Use `stringWithFileSystemRepresentation:length:`, not
       `stringWithUTF8String:` — a CP/M command line is arbitrary 8-bit and the
       latter returns nil, which silently becomes "No filename given".
     - `@autoreleasepool` around the Foundation work: it now runs on
       `_emulatorQueue`, not the main thread.
     - Bound the read size (8 MB). Today's Swift `Data(contentsOf:)` is
       unbounded too, so this is new protection rather than a regression fix,
       but the guest now blocks inside one HBIOS call with no rewind.
     - Any new optional delegate selector must be spelled identically in
       `emu_io_ios.mm`, `RomWBWEmulator.h/.mm` and Swift — every hop is
       `respondsToSelector:`-guarded, so a typo fails **silently**.
     - Leave `emu_host_file_load` / `load_named` / `cancel` defined but
       unreferenced from Swift. Do not wire them into a new async path: after
       this change the R8 path touches `g_host_read_*` only on the emulator
       thread, which also removes an existing unsynchronised cross-thread write.

   - **Deliberate behaviour change to record in MANUAL_CHECKS.md:** a file that
     is not in Imports now makes the open fail, so R8 prints `Cannot open host
     file` and creates nothing. Today the open succeeds, R8 prints `Creating:`,
     and the first read hits instant EOF — leaving a zero-byte CP/M file behind.

   - **Testable here, and worth it.** `run_core_suite` compiles a `.cc` suite
     against the symlinked core with plain `c++` and lets the *test* supply the
     backend — `Tests/CoreKeyboardTests.cc` already stubs the whole host-file
     API this way. So `Tests/CoreHostFileTests.cc` can implement two backend
     shapes, synchronous and parking, and drive R8's real sequence
     (0xE1 → 0xEA → 0xE3) through `HBIOSDispatch::handlePortDispatch()` with
     `setBlockingAllowed(false)`, the mode this port runs in. That covers the
     thing that was broken — whether GETRNAME can answer when R8 asks — plus
     `storeHostName`'s clamping and the PC-rewind arm, neither of which has a
     test today. Anchor the new block on the existing `run_core_suite
     CoreKeyboardTests` line, not a line number.
     `emu_io_ios.mm` itself stays untestable here (Objective-C++ over
     NSFileManager; pulling a `.mm` into `run_core_suite` would break its
     non-Mac fallback).

   - **The whole item, as one manual check:** on a device, against an image
     whose `r8.com` calls 0xEA (`romwbw_emu/disks/hd1k_combo.img` — the
     catalog's v1.4.5 image has no such R8), `R8 ESC.TXT` for a file stored as
     `esc.txt` must print `Reading: /.../Documents/Imports/esc.txt`, lowercase.


2. **Empty `todo.txt`.** Not done yet — deliberately, because item 1 above is
   still open and the file must not be emptied while something is genuinely
   open. When it is: keep the header (it explains what the file is for and
   `MANUAL_CHECKS.md` points at it) and leave no items under it.

3. **`MANUAL_CHECKS.md`** needs entries for what cannot be verified here: the
   key row on a phone, the Emulator menu and window restore under Catalyst,
   applying a profile, creating a multi-slice disk and seeing the extra drive
   letters, and the bell toggle.

4. **`CHANGELOG.md`** entry, and **bump `CURRENT_PROJECT_VERSION` 58 → 59** in
   both places in the pbxproj. **Do not touch `MARKETING_VERSION`** (CLAUDE.md).

5. **This is on a branch, not `main`.** The repo normally commits to `main`
   directly, but none of the SwiftUI/UIKit half has ever been compiled, so it
   goes on `todo-sweep-2026-09-03` until a machine with Xcode has built it.
   Merge it to `main` only after `xcodebuild` succeeds.

## New files (all registered in project.pbxproj and Tests/run_tests.sh)

    iOSCPM/Views/TerminalScreen.swift      Tests/TerminalScreenTests.swift    261
    iOSCPM/Views/DiskSize.swift            Tests/DiskSizeTests.swift           63
    iOSCPM/Views/WindowFrame.swift         Tests/WindowFrameTests.swift        34
    iOSCPM/Views/CatalystWindow.swift      (Catalyst-only, cannot be tested here)
    iOSCPM/Views/EmulatorProfile.swift     Tests/EmulatorProfileTests.swift    62
    tools/check-store-version.sh           (standalone, needs the network)

## Verification available on this machine

    ./Tests/run_tests.sh                       # 11 suites, 869 checks
    sh tools/check-store-version.sh            # needs the network
    sh tools/check-disk-pins.sh                # needs the network
    xcrun --sdk macosx swiftc -parse iOSCPM/Views/*.swift iOSCPM/iOSCPMApp.swift
    plutil -lint iOSCPM.xcodeproj/project.pbxproj

`-parse` is a syntax check only. The SwiftUI and UIKit files
(`ContentView.swift`, `TerminalView.swift`, `EmulatorViewModel.swift`,
`iOSCPMApp.swift`, `CatalystWindow.swift`) have **never been type-checked**,
because that needs the iOS SDK. They are the highest-risk part of this change.
