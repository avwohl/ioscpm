# WIP — the handoff

**This file does not say which build the tree is on.** It said "Build 67" until
2026-09-15, by which point the tree was on 72 — the same way it once announced
"seven open items" against a `todo.txt` holding nine. `CURRENT_PROJECT_VERSION`
in `iOSCPM.xcodeproj/project.pbxproj` is the answer and cannot drift from
itself; `CHANGELOG.md`'s top heading says what that build did.

What has not changed, and is the part worth writing down: **nothing in this tree
has ever run on physical hardware.** Simulators and `xcodebuild` only.

**The open work is in `todo.txt` and is deliberately not counted here.** A tally
of another file is the first thing to go stale, and this file's opening
paragraph went stale that way twice — it was still announcing "seven open items"
against a `todo.txt` holding nine, and still calling for an `xcodebuild` that
had already been run. Read `todo.txt` itself; it is next door.

What this file is for is the few things with nowhere better to live: the open
question `todo.txt` delegates here, one measurement nobody has wired into a
suite, and the commands that verify the tree.

**Whether the machine you are reading this on has Xcode is not recorded here, on
purpose.** That is a fact about the machine, it changes, and this file has
asserted it in both directions and been wrong both times — most recently a
section headed "This machine no longer has Xcode" that sat in the same commit as
a CHANGELOG entry describing the Xcode 26.6 build of build 67. `CLAUDE.md` has
the one command that settles it and the trap that makes the obvious reading
wrong. Measure it; do not read it from here.

## Build 74 has been driven, and what that found — 2026-09-21

**The change set this section used to warn about is committed.** It said
"twenty-one files are modified and nothing is committed" and told the reader to
run `git status` before anything else; that work is `795d286`, the tree is
clean, and the warning outlived its subject by two days. What follows replaces
it.

`CHANGELOG.md`'s heading for this build is the index to what it contains.

**It has now been run, which it never had been.** On 2026-09-21, on a Mac with
Xcode 27.0, the Release configuration was built for the iOS Simulator and for
Mac Catalyst — 0 errors, and no warning either build raises about this code —
and the Catalyst build was driven by hand. What that settled:

- A **first launch on a wiped container** fetches the index and the catalog,
  fills TWO drives from `defaultDiskIDs`, downloads both images, and boots. The
  banner reads `Starting RomWBW 3.6.0 - emu_avw-v0-3.6.0.rom` with
  `  Disk 0: hd1k_combo-v0-3.6.0.img` and `  Disk 1: hd1k_games-v0-3.6.0.img`
  under it; `C<ret>` reaches `CP/M-80 v2.2, 54.0K TPA` with ten drive letters,
  `C:`-`F:` off HDSK0 and `G:`-`J:` off HDSK1. CBIOS prints `v3.6.0 [WBW]`
  against HBIOS 3.6.0, so no mismatch warning — which is the pairing working,
  not the notice being broken.
- The **boot loader prints BELOW the banner** rather than clearing it, which is
  what cpmdroid predicted from a Galaxy Tab and what this repository could not
  check for itself.
- **Play is disabled for the whole download window.** The overlay reads
  `Downloading 19% / Combo (Recommended)` with the toolbar button greyed.
- Settings puts **RomWBW Release first**, above ROM and the slots.
  **Show Development Snapshots is off** in a fresh install; ticking it adds
  `RomWBW 3.7.0-dev.14 (development snapshot)` to a list that otherwise holds
  3.6.0 and 3.5.1; selecting it moves the ROM row to
  `emu_avw-v0-3.7.0-dev.14.rom - 512 KB to download`; **unticking it moves the
  selection back to 3.6.0** and the ROM row with it.
- **The status line claim was wrong** and the CHANGELOG entry now says so. See
  that entry; the short version is that `emu_status()` in the shared core writes
  to the same line and fires after `startEmulator()` returns.
- **"Open File..." and "Create New..." present nothing on Mac Catalyst.** See
  `KNOWN_PROBLEMS.md`. This is not new in 1.6.2 and is not a reason to hold
  it, but it is the route the new local-disk release warning is reached by, so
  that feature is unverified on this platform.

- **On iOS, one measurement and no taps.** The same build was installed on an
  iPhone 17 Pro simulator (iOS 26.5) onto an UPGRADED container — pre-v0
  `disks_catalog.xml`, 3.5.1 images, a legacy `catalogCacheTag` — and it
  launched, fetched the index and the 3.6.0 catalog, and wrote stamps equal to
  what the live catalog publishes. Nothing was tapped; see the gesture note
  below.

**What is still not driven:** anything needing a slow transfer (the picker
gating during a catalog fetch, and pressing Play twice inside the download
window) and everything in the cache-stamp path. `MANUAL_CHECKS.md` keeps those.

**Driving a SIMULATOR is no longer possible on an Xcode 27 machine, and that is
a toolchain fact rather than a bug here.** Xcode 27 ships no `Simulator.app`;
the device screen is drawn inside `DeviceHub`, whose mirror accepts no synthetic
mouse event — measured against `kCGHIDEventTap`, `kCGSessionEventTap` and
`kCGAnnotatedSessionEventTap`, and with `CGEventSource`s for all three source
states, while a click on DeviceHub's OWN toolbar in the same run worked.
`tools/simdrive.py` has been taught to find that window and to calibrate inside
it — it no longer assumes the screen is centred, because DeviceHub's is not —
and its calibration verifies at ~98% and tracks the rect when the window's
layout changes. So `calibrate`, `shot` and `where` work; `tap`, `press` and
`swipe` post events nothing receives. **Mac Catalyst is the way to drive this
app now**: it is an ordinary Mac app, it takes synthetic clicks and
`System Events` keystrokes, and it runs the same views.

## THE ONE OPEN QUESTION — disk sizes larger than 8 MB

Unchanged in substance since 2026-09-03. `DiskSize.swift` has been edited once
since, in build 68 (`0bcf21b`), and it was two comment lines renaming
`emu_check_disk_size()` to `emu_validate_disk_image()` — the symbol never
existed under the old name. No offered size, no validation rule and no test
moved, and none of the interface-v0 work went near it.

(This paragraph read "Unchanged by builds 62 through 67 — `DiskSize.swift` has
not been touched since 2026-09-03". The file *had* been touched, four builds
back. Harmless here because the edit was a comment, but it is the claim that
would have been checked and believed.)

`iOSCPM/Views/DiskSize.swift` currently offers **one 8 MB hd1k disk** (exactly
8,388,608 bytes) and then **2 / 4 / 7 hd512 slices** (N × 8,519,680 bytes). A
spec agent independently proposed something different:
**1 MB prefix + N × 8 MB hd1k slices** (8/17/25/33/41/49/57 MB), matching the
shipped `hd1k_combo.img`.

Both agree on the facts, which were read out of the core, not guessed:

- `emu_validate_disk_image()` (`iOSCPM/Core/emu_init.cc`) accepts only: exactly
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

**Not yet verified on a real machine.** Decide one of:

1. Keep hd512 multi-slice (current code). No MBR to write. Verify by creating a
   2-slice disk on a device and checking two drive letters appear.
2. Switch to `1 MB + N × 8 MB` and write a type-0x2E MBR at LBA 2048. Matches
   the shipped combo images; more code, and the MBR must be exactly right.

`MANUAL_CHECKS.md` **check 12** is the one that answers it: a 2-slice disk must
show two drive letters. If it does not, the question is answered the other way
and `DiskSize.swift` needs the hd1k shape with a hand-written MBR.

## The deployment floor is a check now, not a measurement

The whole network API surface type-checks at the real deployment floor:
`allowsExpensiveNetworkAccess`, `allowsConstrainedNetworkAccess`,
`NWPathMonitor`, `path.isConstrained` and `URLError.networkUnavailableReason`
are used with no availability guard, and `IPHONEOS_DEPLOYMENT_TARGET` is 15.0
where every one of those is iOS 13.

**This used to be a measurement somebody had run once.** It is the
`=== DeploymentFloorTypechecks ===` stage in `Tests/run_tests.sh`, which
compiles the same files as `EmulatorViewModelTypechecks` at
`arm64-apple-ios$FLOOR-macabi`, with `$FLOOR` read out of the pbxproj so raising
the floor moves the check. The stage before it compiles for the host macOS,
where nothing in the SDK is too new, so an iOS 16 API added to
`EmulatorViewModel.swift` passes there and fails here - measured with a probe
using `Duration`, which does exactly that.

Two arms report SKIP rather than FAIL, both deliberate: a tree with no pbxproj
has no floor to check against, and Mac Catalyst's own floor rises, so the day it
passes `IPHONEOS_DEPLOYMENT_TARGET` the toolchain rejects the target string
outright (`ios13.0-macabi` is refused today; 14.0 is the lowest it accepts) and
that is not the app using a too-new API.

## Five files have exactly one compiler

`ContentView.swift`, `TerminalView.swift` and `CatalystWindow.swift` import
UIKit; `HelpView.swift` and `iOSCPMApp.swift` use SwiftUI macros, and a Command
Line Tools `swiftc` cannot expand one — measured, it answers `external macro
implementation type 'SwiftUIMacros.StateMacro' could not be found for macro
'State()'`. So the suites in `Tests/run_tests.sh` reach everything except those
five, and only `xcodebuild` reaches them. They compiled for the first time in
build 67 and needed no change.

`Tests/check_view_bindings.sh` is what covers the gap in between, and it covers
it by spelling rather than by type: every `viewModel.<member>` that
`ContentView.swift` asks for must be declared. That is the only reason removing
a view model member is safe to do without opening Xcode.

## Nothing here has run on physical hardware

Every measurement in this repository was made on a simulator or on a Mac, and
build 67 having been built and driven does not change it: a simulator is not a
device. `MANUAL_CHECKS.md` section 17 and its `[DEVICE]` items are what a
synthetic event cannot answer — a hand that does not hold still, a haptic, real
cellular data, and a real APFS container under memory pressure.

## Verifying the tree

These four need no Xcode and are the floor:

    sh Tests/run_tests.sh
    sh tools/check-store-version.sh            # needs the network
    xcrun --sdk macosx swiftc -parse iOSCPM/Views/*.swift iOSCPM/iOSCPMApp.swift
    plutil -lint iOSCPM.xcodeproj/project.pbxproj

`-parse` covers every Swift file, the four above included, precisely because it
is a syntax check and stops before a name has to resolve — which is also the
whole of what it proves.

`check-shipped-disks.sh` was a fifth until 2026-09-13, and this said "five"
until 2026-09-15, counting a command that is not in the list. It reported the tree half
and the artifact half separately and said in as many words when it had inspected
no built package. It is deleted; whether the image a user downloads carries the
fixed `r8.com` is now something a person establishes by fetching it.

Where Xcode is present, these reach what the five cannot:

    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    xcodebuild -project iOSCPM.xcodeproj -scheme iOSCPM \
        -destination 'platform=iOS Simulator,name=iPhone 17' build
    xcodebuild -project iOSCPM.xcodeproj -scheme iOSCPM \
        -destination 'platform=macOS,variant=Mac Catalyst' build

`tools/simdrive.py` drives a booted simulator with synthetic touches and refuses
to guess where the device screen is; its header carries the two traps that cost
an hour each. `MANUAL_CHECKS.md` §16 has the `plutil` / `cfprefsd` recipe for
steering the app's `UserDefaults` from outside a test, which is the other thing
that has to be right before a staged container means anything.
