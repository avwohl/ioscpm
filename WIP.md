# WIP — what is left after the todo sweep

The sweep itself is **done and on `main`**: commit `8e7587f`, numbered build 59,
six of `todo.txt`'s seven items implemented and described in `CHANGELOG.md`, and
those six now deleted from `todo.txt` as its header requires. What is left there
is the one item below. This file is no longer a branch hand-off; it carries only
what is still open, and the detailed spec `todo.txt` points at.

## Build 59 has never been compiled — read this first

`Tests/run_tests.sh` is green at 11 suites and 869 checks, and that is the *only*
verification any of it has had. There has been no Xcode on any machine that has
touched this work, only Command Line Tools, so `xcodebuild` does not run and
there is no simulator. The SwiftUI and UIKit half — `ContentView.swift`,
`TerminalView.swift`, `EmulatorViewModel.swift`, `iOSCPMApp.swift`,
`CatalystWindow.swift` — has never been through a compiler.

Every earlier CHANGELOG entry could claim a clean Catalyst build that was
launched and driven. Build 59 cannot. **Build it before submitting it.** If it
does not build, `git revert 8e7587f` backs the whole sweep out cleanly.

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


2. **`MANUAL_CHECKS.md`** needs entries for what cannot be verified here: the
   key row on a phone, the Emulator menu and window restore under Catalyst,
   applying a profile, creating a multi-slice disk and seeing the extra drive
   letters, and the bell toggle.

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
