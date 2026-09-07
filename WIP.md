# WIP — what is left after the todo sweep

`todo.txt` is down to seven open items and one open question, and none is a
half-finished change. Three of the seven want credentials this machine does not
have — the next submission, the help-asset upload, and the ROM the bundle no
longer carries, which reaches a device only through a released build. One wants
a Mac with Xcode, in two halves: an actual `xcodebuild`, which has never been run
on anything past build 61, and the five view files nothing here can compile. One
wants a finger (section 17). One is an attestation that only a person can read
and affirm. The last is `tools/check-store-version.sh`, whose bracket on the
shipped build loosened the moment this tree was compiled. The question is a
design choice nothing here can settle. This file carries the detail behind them.

The second sweep, on 2026-09-04, closed four of the five items that were left —
the synchronous host-file open, both documentation items, and the prerelease
decision — and added the disk-freshness refresh, which was the unwritten half of
the [RELEASE] item. `CHANGELOG.md` under build 61 has the whole account.

Build 66, on 2026-09-08, closed the other question this file used to carry:
**which RomWBW release a fresh install starts on**. It is the one the index flags
`default: true`, which is 3.6.0 today. Deleting the bundled ROM left no second
candidate to weigh, so `RomWBWIndex.preferred` lost its `bundledROMRelease`
parameter and now keeps a stored choice, then takes `default: true`, then takes
the first entry offered. That was not sufficient on its own, and the first
attempt at this shipped four documents saying it was: the call site passed
`romwbwVersion` as the kept release, and on a fresh install that is already the
pre-v0 `3.5.1` seed, so rule 1 matched on every launch and `default: true` stayed
unreachable. `romWBWVersionToKeep` is what distinguishes a release somebody chose
from the value the view model happens to hold.
The argument that was still open — a first launch on a bad connection getting
further from a booting machine — went with it, because `start()` returns early
when the disk catalog is empty and the catalog is itself a download: a device
that has never had a network has no disk to boot, with or without a ROM. The doc
comment on `preferred` and `CHANGELOG.md` under build 66 are where that is
written down.

## This machine no longer has Xcode — measured 2026-09-08

**Read this before trusting any sentence in this repository about Xcode: it has
now been wrong in both directions.** Measured today, here:

- There is no `/Applications/Xcode.app` at all. `xcode-select -p` is
  `/Library/Developer/CommandLineTools`; the `DEVELOPER_DIR=…` prefix earlier
  revisions of this file recommend fails with `missing DEVELOPER_DIR path`; there
  is no iPhoneOS SDK under `/Library/Developer`; and `xcrun` cannot find
  `simctl`. Nothing here can archive, produce an `.app`, or boot a simulator.
- What is here is the Command Line Tools toolchain — Apple Swift 6.4 and
  `clang++` against the macOS SDK — which is everything `Tests/run_tests.sh`
  needs, and is the whole of how build 66 was compiled.

The trap is that bare `xcodebuild` prints

    xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
    directory '/Library/Developer/CommandLineTools' is a command line tools instance

whether Xcode is installed and merely unselected **or is not there at all**. For
three builds this file read that message as "not installed" and was wrong; from
build 62 it read it as "installed, just unselected" and by build 66 that was
wrong too. `ls -d /Applications/Xcode.app` tells the two apart and costs nothing.
Run it before writing either claim down again.

**Build 61 was built and driven on this machine, while Xcode was still on it, and
that history stands.** It built clean for the iOS Simulator and for
`-destination 'platform=macOS,variant=Mac Catalyst'`, no warnings on either;
launched on the iPhone 17 Pro simulator, where it came up as `v1.5.1.61` with
the key row and the scrollback counter painting; and the disk refresh was driven
end to end against a real sandbox. CP/M 2.2 booted there and took
software-keyboard input (`c`⏎, then `dir`), scrollback moved `sb 0/12` ->
`sb 12/12` on a swipe, and the Catalyst app returned real text from a pointer
drag plus Cmd+C. That closed `MANUAL_CHECKS.md` section 7, which is now a hole in
the numbering on purpose. `~/Library/Developer/Xcode/Archives/2026-09-02/` still
holds the two `.xcarchive`s made here, and they are what is left of that
toolchain. Read on 2026-09-08, both carry `CFBundleVersion 56` — not build 58,
which is what this file asserted without ever opening them — and both are signed
`Apple Development`, which is the measurement behind the releasing paragraph
below.

**Nothing after build 61 has been built or run anywhere.** Builds 62 through 65
were written on a Linux machine with no Swift toolchain; build 66 put them in
front of a compiler for the first time, and a compiler is all they have seen. No
build of this app has ever run on physical hardware — every measurement in this
repository was made on a simulator or on a Mac. `MANUAL_CHECKS.md` carries the
rest, and its section 17 is the half of the selection gesture that needs a
finger.

`Tests/run_tests.sh` is green at **20 suites and 1,208 assertions**, where the
run this file recorded at build 61 was 14 suites and 1,051 checks. Two things
became checkable that this file once said were not, and — contrary to what this
file claimed — only one of them is wired in:

- **`emu_io_ios.mm` compiles.** It is Foundation-only Objective-C++, so
  `xcrun --sdk macosx clang++ -fsyntax-only -fobjc-arc` builds it clean at
  `-Wall`. That is the `EmuIOBackendCompiles` suite. It is a compile, not a run —
  nothing observes behaviour. The flag that earns it is
  **`-Wundeclared-selector`**, promoted to an error: every delegate hop in that
  file is `respondsToSelector:`-guarded, so a selector that no longer exists
  fails **silently** at runtime — the message is simply never sent. Plain `-Wall`
  says nothing, because `@selector()` accepts any literal. Verified by renaming
  the protocol method and confirming the guard site is what errors.
- **The whole network API surface type-checks at the real deployment floor.**
  `xcrun --sdk macosx swiftc -target arm64-apple-ios15.0-macabi` accepts
  `allowsExpensiveNetworkAccess`, `allowsConstrainedNetworkAccess`,
  `NWPathMonitor`, `path.isConstrained` and `URLError.networkUnavailableReason`
  with no availability guard. `IPHONEOS_DEPLOYMENT_TARGET` is 15.0 and every one
  of those is iOS 13. **This one is not a suite.** `run_tests.sh` names neither
  `macabi` nor any of those symbols, so it is a measurement somebody made once,
  not a check that would notice a regression. The target still works here; wiring
  it in is a small job nobody has done.

Build 66 added two more, because the reason a hard compile error survived four
builds is that nothing in this repository compiled the file it was in. Every
suite above compiles types that were *split out* of `EmulatorViewModel`; none of
them compiled `EmulatorViewModel`:

- **`EmulatorViewModelTypechecks`** type-checks all of `EmulatorViewModel.swift`
  against the macosx SDK with `-import-objc-header` and the real
  `RomWBWEmulator.h`, so every Objective-C call is checked against the header it
  will really meet, with `Tests/ViewModelHostStubs.swift` supplying the two
  symbols that live in a UIKit-importing file. It is what catches a bridged call
  spelled the way Swift does not import it — `loadROM(fromData:)` for
  `loadROM(from:)`, on the one line that hands a fetched ROM to the core.
- **`ViewBindings`** (`Tests/check_view_bindings.sh`) checks by spelling every
  `viewModel.<member>` `ContentView.swift` asks for — 93 of them — and
  `HelpView.swift`'s four. It is a spelling check and says so; it exists because
  nothing here can type-check either file, so a member renamed out from under the
  view — which is exactly what removing `bundledROMFallbackRelease` was — stays
  invisible until somebody opens Xcode.

Five files stay outside all of it. `ContentView.swift`, `TerminalView.swift` and
`CatalystWindow.swift` import UIKit; `HelpView.swift` and `iOSCPMApp.swift` use
SwiftUI macros, and the Command Line Tools `swiftc` cannot expand one — measured,
it answers `external macro implementation type 'SwiftUIMacros.StateMacro' could
not be found for macro 'State()'`. A build on a Mac that has Xcode is still owed
before anything is submitted.

**It is released, and build 61 is what users have.** Every earlier revision of
this section said "submitted and not released"; it was approved.
`sh tools/check-store-version.sh` exits 0, reports 1.5.1 served since 2026-09-05,
and the iTunes lookup's release notes are build 61's — scrollback, select text,
copy and paste. `z80cpmw/FEATURE_PARITY.md` records `shipped:61` and its column
was re-read at `af0b9b2`, which is build 61, so that gate is answered.

The script's bracket used to need reading with care: narrowing by the
`**NOT COMPILED` marker alone, it reported "at most build 66" the moment this
tree was compiled, and followed it with "The tree and the Store agree on what
users have." It compares dates now — a heading not committed before the Store's
release date cannot be what the Store serves — and reports "at most build 61"
with that reason printed. Nothing here or in `z80cpmw` may record a build above
61 as shipped.

The upload was done by a person, and this machine cannot do it — now for two
reasons rather than one. There is no Xcode here to archive with at all; when
there was, the archive signed with `Apple Development`, which cannot be exported
for the App Store. See "Releasing" in `KNOWN_PROBLEMS.md` — that entry was
correct all along and contradicted this file for three builds.

## THE ONE OPEN QUESTION — disk sizes larger than 8 MB

Unchanged by builds 62 through 66 — `DiskSize.swift` has not been touched since
2026-09-03, and none of the interface-v0 work went near it.

`iOSCPM/Views/DiskSize.swift` currently offers **one 8 MB hd1k disk** (exactly
8,388,608 bytes) and then **2 / 4 / 7 hd512 slices** (N × 8,519,680 bytes). A
spec agent independently proposed something different:
**1 MB prefix + N × 8 MB hd1k slices** (8/17/25/33/41/49/57 MB), matching the
shipped `hd1k_combo.img`.

Both agree on the facts, which were read out of the core, not guessed:

- `emu_check_disk_size()` (`iOSCPM/Core/emu_init.cc`) accepts only: exactly
  8,388,608; `1,048,576 + N × 8,388,608`; exactly 8,519,680; any multiple of
  8,519,680. **A round 16/32/64 MB image is refused** — that is the trap a naive
  picker would have fallen into, and `Tests/DiskSizeTests.swift` asserts it.
- `HBF_EXTSLICE` (`hbios_dispatch.cc`) detects hd1k **only** from an MBR with a
  type-0x2E partition, or from a file that is exactly 8 MB. Otherwise it falls
  back to hd512 with `slice_size = 16640` sectors.

Where they differ: the agent says a 0xE5 image over 8 MB is "misdetected and its
slices run off the end of the file". That is true of the *hd1k combo* shape with
no MBR, but **not** of an exact multiple of 8,519,680: 16640 × 512 = 8,519,680,
so N slices land exactly on the file. The capacity guard is
`slice_start_sector >= disk.total_sectors()`, which that shape satisfies. I
believe the current implementation is correct and needs no MBR; the agent's
needs a hand-written 512-byte MBR.

**Not yet verified on a real machine, and cannot be here.** Decide one of:

1. Keep hd512 multi-slice (current code). No MBR to write. Verify by creating a
   2-slice disk on a device and checking two drive letters appear.
2. Switch to `1 MB + N × 8 MB` and write a type-0x2E MBR at LBA 2048. Matches
   the shipped combo images; more code, and the MBR must be exactly right.

`MANUAL_CHECKS.md` **check 12** is the one that answers it: a 2-slice disk must
show two drive letters. If it does not, the question is answered the other way
and `DiskSize.swift` needs the hd1k shape with a hand-written MBR.

## The host-file open is synchronous now — what to know if it misbehaves

The item this file used to carry as "STILL TO DO" is implemented.
`emu_host_file_open_read()` resolves, opens and reads on the emulator thread and
returns with the state already `HOST_FILE_READING`, which is the only way
`HBF_HOST_GETRNAME` can answer — it gates on that state, and R8 asks between the
open and the first read. Zero shared-core files changed; `emu_io_ios.mm` is
port-local.

The duplicate case-insensitive scan was **deleted from Swift** rather than added
to C++, so there is one resolver. That also fixed a second bug: iOS's Documents
volume is case-insensitive, so `fileExists(atPath: Imports/ESC.TXT)` succeeded
for a file stored as `esc.txt` and the path handed on carried the case the CCP
invented. The scan takes the directory entry's own spelling; `realpath()` does
not fix this, because it resolves symlinks and `.`/`..`, not case.

Traps that are now handled, each of which had bitten this code or would have:

- A zero-byte file still reaches `HOST_FILE_READING`. Guarding that on a
  non-empty read reopens the hole closed in build 53.
- `fopen` **succeeds on a directory** on Darwin — measured — and the first
  `fread` returns 0. Hence the `fstat`/`S_ISREG` guard; without it `R8 SOMEDIR`
  reported a successful open and made an empty CP/M file.
- `emu_host_path_basename(x, "")` does **not** answer `""` for a path naming no
  file. An empty fallback is itself replaced, with `"download.bin"`, so the
  degenerate case went hunting for a file of that name. The backend passes a
  one-byte sentinel instead and tests for it; `Tests/CoreHostFileTests.cc` pins
  this.
- The read is bounded at 8 MB, and a larger file **fails the open** rather than
  being truncated. The guest now blocks inside one HBIOS call with no rewind, so
  an unbounded read would hang the machine — but truncating instead would hand
  CP/M a short file under the right name with both sides reporting success, and
  R8 has no way to notice.
- `@autoreleasepool` around the Foundation work: it runs on `_emulatorQueue`,
  and `runLoop` is one `dispatch_async` block that does not return until the
  emulator stops, so there is no per-iteration pool to drain into.
- The Swift handler is failure-only now and **must not touch host-file state**.
  The open has already returned false and R8 has been told; calling
  `emu_host_file_cancel()` there would cancel a later transfer.

What is unverified: all of it, on a device. `MANUAL_CHECKS.md` sections 14 and 15
are the checks, and section 15 records the deliberate behaviour change — a file
that is not in `Imports` now fails the open, so R8 creates nothing where it used
to leave a zero-byte CP/M file behind.

## Verification available on this machine

    sh Tests/run_tests.sh                      # 20 suites, 1,208 assertions
    sh tools/check-store-version.sh            # needs the network
    sh tools/check-shipped-disks.sh            # needs the network
    xcrun --sdk macosx swiftc -parse iOSCPM/Views/*.swift iOSCPM/iOSCPMApp.swift
    plutil -lint iOSCPM.xcodeproj/project.pbxproj

All five were run on 2026-09-08 and all five exit 0 — with the caveat
`check-shipped-disks.sh` prints in as many words: it inspected no built package,
which it does not count as a pass of the artifact half, because nothing on this
machine can build one. `-parse` covers every Swift file in the app, the five
nothing can type-check included, precisely because it is a syntax check and stops
before a name has to resolve — which is also the whole of what it proves.

**The `xcodebuild` and `simctl` recipes this section carried have been removed
rather than corrected: neither tool exists here any more.** They are in this
file's history for a machine that has Xcode, and the traps below are what they
cost when they were run.

Two traps when steering the app's `UserDefaults` from outside for a test: the
ledger is stored as a **JSON string**, and both `PlistBuddy` and a
`-key value` launch argument will try to parse it as a property list — PlistBuddy
silently strips the quotes and leaves invalid JSON. Use
`plutil -replace <key> -string '<json>' <container>/Library/Preferences/com.awohl.cpm.plist`.
And `cfprefsd` caches preferences, so shut the simulator down before editing the
plist or the app will never see the change.
