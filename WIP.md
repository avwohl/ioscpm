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

## THERE IS A LARGE UNCOMMITTED CHANGE SET IN THE TREE — 2026-09-19

**Read `git status` before anything else.** Twenty-one files are modified and
nothing is committed. A reboot does not lose it, but `git stash`, a branch
switch or a "let me start clean" will, and it is roughly 3,500 added lines.
`CHANGELOG.md`'s `## Unreleased` section describes every change and is the index
to it; the commit that carries it has not been written.

What it is, in two halves:

- **Fifteen findings closed.** Every code item that was in `todo.txt`, plus the
  three things the sibling repositories had moved ahead on — `BF_VDASCR`'s
  signed line count reaching `TerminalScreen.vdaScrollUp` and being discarded, a
  Start that neither refused a live machine nor said what it was starting, and
  three documents still claiming the picker offers every release the index
  publishes. `iOSCPM/Core/` is symlinked into `romwbw_emu` and `cpmemu`, so the
  RTC `long long` fix and the 44-divergence HBIOS audit arrive by rebuild and
  needed nothing here; that was checked rather than assumed.

- **Five defects found by reviewing that change set**, none of which the suite
  or the build could see. Two are worth naming because they were regressions
  introduced by the work itself: first-launch drives moving to `defaultDiskIDs`
  filled two drives where `defaultSlot` had filled one, and
  `downloadDisksAndStart` was all-or-nothing, so the optional games image became
  a precondition for a fresh install's first boot; and the new cache stamp
  declined every unstamped cache, which is every install that predates it, so an
  offline launch after the update had an empty `diskCatalog` and `start()`
  refused. Both are fixed — a failed download is now fatal only in drive 0, and
  an unstamped cache is adopted but marked `catalogIsUnverified`, which withholds
  transfers rather than boots.

**What was measured, on this tree, after the last edit:** `sh Tests/run_tests.sh`
exits 0 with no FAIL lines and no SKIPs; `xcodebuild` Release succeeds for both
`platform=iOS Simulator,name=iPhone 17` and `platform=macOS,variant=Mac Catalyst`
with 0 errors; `sh tools/check-store-version.sh` and `python3
tools/check-help-assets.py` both exit 0.

**What was NOT measured, and is the first thing to do next:** none of it has
been driven in the running app. Every new user-visible path — the start banner,
the three pickers going inactive during a catalog fetch, the local-disk release
warning in its Settings row and on the status line, the message when a transfer
is refused because the catalog could not be verified, and the first-launch drive
choice — has been type-checked and compiled and never once seen on a screen.
`MANUAL_CHECKS.md` is where the results go.

One smaller honesty note: the review ran three independent verifiers against
each finding, except one — that the local-disk notice promised an HBIOS/CBIOS
warning the guest does not always print — where the verifiers could not run. It
was checked once, by hand, and the wording softened to "can print". It has had
one pair of eyes on it and not three.

Nothing under `iOSCPM/Core/` was touched (those are symlinks into sibling
repositories, and editing one edits a sibling), and neither `MARKETING_VERSION`
nor `CURRENT_PROJECT_VERSION` moved.

`todo.txt` went from 320 lines to 24 in the same pass, and the rules that keep it
that way are now in `CLAUDE.md` rather than nowhere.

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
