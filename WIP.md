# WIP — what is left after the todo sweep

`todo.txt` is down to three open items and one open question, and none is a
half-finished change. The items are "build 61 is built and not submitted", which
needs credentials this machine does not have; the rewritten help asset, which
needs an upload; and section 17's device checks, which need a finger. The
question is a design choice nothing here can settle. This file carries the
detail behind all four.

The second sweep, on 2026-09-04, closed four of the five items that were left —
the synchronous host-file open, both documentation items, and the prerelease
decision — and added the disk-freshness refresh, which was the unwritten half of
the [RELEASE] item. `CHANGELOG.md` under build 61 has the whole account.

## This machine has Xcode — read this first

**Every earlier revision of this file said it did not, and that was wrong.**
`xcodebuild -version` fails with

    xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
    directory '/Library/Developer/CommandLineTools' is a command line tools instance

which reads like "not installed" and only means `xcode-select` points elsewhere.
`/Applications/Xcode.app` is Xcode 26.6, the simulators are there, and
`~/Library/Developer/Xcode/Archives/2026-09-03/` holds two build 58 archives made
here. No `sudo` is needed to use it — set the variable per command:

    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …

**Build 61 is built.** Clean for the iOS Simulator and for
`-destination 'platform=macOS,variant=Mac Catalyst'`, no warnings on either;
launched on the iPhone 17 Pro simulator, where it comes up as `v1.5.1.61` with
the key row and the scrollback counter painting. The disk refresh was driven end
to end against a real sandbox.

**CP/M now boots here, and the Catalyst build has been run.** Verifying the
press-and-drag selection fix needed a live machine, so it got one: CP/M 2.2
boots on the simulator and takes software-keyboard input (`c`⏎, then `dir`),
scrollback moves `sb 0/12` -> `sb 12/12` on a swipe, and the Catalyst app
launches and returns real text from a pointer drag plus Cmd+C. That closed
`MANUAL_CHECKS.md` section 7, which is now a hole in the numbering on purpose.

What has **still** not happened: nothing submitted and nothing run on hardware —
every measurement above is a simulator or this Mac. `MANUAL_CHECKS.md` carries
the rest, and its new section 17 is the half of the selection gesture that needs
a finger.

`Tests/run_tests.sh` is green at **14 suites and 1051 checks**. Two things also
became checkable that this file said were not, and both are wired into it:

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
  of those is iOS 13.

**It is submitted and it is not released.** 1.5.1 build 61 went to App Store
Connect on 2026-09-04 for **both iOS and Mac** and is in review. Review is not
release: it can be approved, rejected or held. Until `tools/check-store-version.sh`
says 1.5.1 is actually being served, nothing here or in `z80cpmw` may record
build 61 as what users have — `FEATURE_PARITY.md`'s `shipped:37` stays where it
is, and its drift check is right to keep failing.

The upload was done by a person. This machine still cannot do it: the archive
signs with `Apple Development`, which cannot be exported for the App Store. See
"Releasing" in `KNOWN_PROBLEMS.md` — that entry was correct all along and
contradicted this file for three builds.

## THE ONE OPEN QUESTION — disk sizes larger than 8 MB

Unchanged by anything this session did.

`iOSCPM/Views/DiskSize.swift` currently offers **1 / 2 / 4 / 7 hd512 slices**
(N × 8,519,680 bytes). A spec agent independently proposed something different:
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

    ./Tests/run_tests.sh                       # 14 suites, 1051 checks
    sh tools/check-store-version.sh            # needs the network
    sh tools/check-disk-pins.sh                # needs the network
    xcrun --sdk macosx swiftc -parse iOSCPM/Views/*.swift iOSCPM/iOSCPMApp.swift
    plutil -lint iOSCPM.xcodeproj/project.pbxproj

`-parse` is a syntax check only, and is no longer the best available — it was
only ever the fallback for the mistaken belief that there was no Xcode. Prefer
the real thing:

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    xcodebuild -project iOSCPM.xcodeproj -scheme iOSCPM \
        -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
    xcodebuild -project iOSCPM.xcodeproj -scheme iOSCPM \
        -destination 'platform=macOS,variant=Mac Catalyst' build

and to drive it:

    xcrun simctl boot 'iPhone 17 Pro'
    xcrun simctl install booted <DerivedData>/Build/Products/Debug-iphonesimulator/iOSCPM.app
    xcrun simctl launch --console-pty booted com.awohl.cpm
    xcrun simctl get_app_container booted com.awohl.cpm data   # the sandbox

Two traps when steering the app's `UserDefaults` from outside for a test: the
ledger is stored as a **JSON string**, and both `PlistBuddy` and a
`-key value` launch argument will try to parse it as a property list — PlistBuddy
silently strips the quotes and leaves invalid JSON. Use
`plutil -replace <key> -string '<json>' <container>/Library/Preferences/com.awohl.cpm.plist`.
And `cfprefsd` caches preferences, so shut the simulator down before editing the
plist or the app will never see the change.
