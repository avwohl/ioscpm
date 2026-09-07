# Claude Code Notes for iOSCPM

## NEVER change MARKETING_VERSION

`MARKETING_VERSION` in `iOSCPM.xcodeproj/project.pbxproj` is the App Store
version string (1.5.1 at time of writing). **Do not change it unless a human
explicitly asks you to change it**, and do not change it as a side effect of
"bumping the version" for a fix.

Once a release candidate exists in App Store Connect for a given version, that
version is frozen — it cannot be edited there. Changing it locally makes the
project disagree with the record on the Store and has to be undone by hand.

**Bump `CURRENT_PROJECT_VERSION` instead.** That is the build number, it is the
only thing that moves between submissions of the same version, and it is what
every CHANGELOG entry here is keyed to:

```
CURRENT_PROJECT_VERSION = 52;      <- bump this, once, for a new build
MARKETING_VERSION = 1.5.1;         <- leave alone
```

Both appear twice in the pbxproj (Debug and Release); change both occurrences of
the build number and neither of the version.

Several CHANGELOG headings therefore share one version with different build
numbers — `## Version 1.5.1 (Build 51)` and `## Version 1.5.1 (Build 52)` — and
that is correct, not a mistake to tidy up.

## No ROM and no disk image belongs in this repository

`git ls-files` matches no `.rom`, `.img`, `.bin`, `.com` or `.dsk`, and that is
a property to preserve, not a coincidence.  Every ROM and every disk image comes
from the `romwbw_disks` catalog at runtime, verified by size and SHA-256 against
what the catalog publishes, every time it is used.  The other four repositories
in the family reached the same state; ioscpm was the last, on 2026-09-08.

The bundled `iOSCPM/Resources/emu_avw.rom` that used to be here was defended for
a year as "what a first offline launch boots".  It was not, and could not be:
`start()` returns early when the disk catalog is empty, and the catalog and
every disk in it are downloads, so a device that has never had a network has no
disk to boot either.  If you find yourself about to add a ROM back, that is the
argument to answer first — and answering it means changing `start()`, not adding
a file.

The practical rule: **a second source of truth about what RomWBW release is in
play is the bug.**  A bundled ROM is one.  So is a hardcoded version string on a
decision path, a hardcoded catalog filename, and `roms[0]` by array position
instead of the entry flagged `default: true`.

## Only Xcode can build this, and Xcode is not on this machine

There is no `Xcode.app` here, only Command Line Tools, so `xcodebuild` and the
iOS Simulator are unavailable.  `sh Tests/run_tests.sh` is the build check, and
it does more than run unit tests — it type-checks `EmulatorViewModel.swift`
against the real bridging header, compiles the C++ core through the symlinks,
and name-checks what `ContentView.swift` asks of the view model.  **Run it after
every change; it exits non-zero on a compile error.**

What it still cannot reach: `ContentView.swift`, `TerminalView.swift`,
`CatalystWindow.swift`, `HelpView.swift` and `iOSCPMApp.swift` all import UIKit
or use a SwiftUI macro, and neither is available on the macosx SDK.
`Tests/check_view_bindings.sh` covers the one question that matters most there —
does a member `ContentView` asks for still exist — but it is a spelling check,
not a type check.  A build on a Mac with Xcode is still required before any
submission, and nothing in this tree has ever run on a device or a simulator.

## Never write down a shipped state you have not measured

The tree is always ahead of the App Store, and that gap is normal.  What is not
normal is recording the tree's build number in anything that describes what
*users* have.  A submission that is queued is not released: it can sit in
review, be rejected, or be held.

**Measure before you write it down.**  `tools/check-store-version.sh` curls the
iTunes lookup, maps the shipped version to a build through `CHANGELOG.md`, and
compares that with `CURRENT_PROJECT_VERSION`.  Exit 0 means nothing recorded in
this tree or its siblings claims a build the Store does not serve; exit 2 means
it could not check, which is not a pass.

```bash
sh tools/check-store-version.sh
```

Three rules follow from it, and each has been broken here at least once:

- **Do not move a "shipped" field on the strength of a submission.**
  `z80cpmw/FEATURE_PARITY.md` carries an ioscpm `shipped:<build>` in its
  `sibling-readings` block, and `z80cpmw/tools/check-sibling-drift.sh` fails the
  whole ioscpm column until that number and the tree agree.  **It is right to
  keep failing.**  Setting it to the tree's build certifies every tick in the
  column against software nobody can install.  That field is hand-maintained
  precisely because no tree knows what a store is serving.
- **Publishing is not shipping it.**  There is no `releaseTag` in
  `EmulatorViewModel.swift` any more — the app compiles in one index URL and
  reads everything else out of the catalog — so the shape of this rule changed
  but not its force.  Adding a ROM or a disk to an **already-supported** RomWBW
  release reaches a *shipped* client with no app release at all, which is the
  point.

  A whole new RomWBW release does **not**, and saying otherwise is the easy
  mistake to make here.  `ROMWBW_SUPPORTED_RELEASES` in
  `romwbw_emu/src/romwbw_pin.h` is a compile-time list — 3.5.1 and 3.6.0 today —
  and a client filters the index by asking its own core
  (`emu_romwbw_release_supported`), so a 3.7.0 entry is simply not offered by any
  binary built before somebody added it there and booted it.  That is deliberate:
  bank 0 of an `emu_*.rom` is ours, and a release whose CBIOS calls something the
  dispatcher does not implement would load and then misbehave.  Adding a release
  is a claim that somebody ran it.

  What still needs a release is a change to this app's own code, and it reaches
  users only through a build that carries the edit *and* that Apple has actually
  released.  `tools/check-shipped-disks.sh` inspects the
  built artifact as well as the tree for exactly this reason, and it now checks
  that the tree names the v0 index rather than grepping for a version pin that
  no longer exists.
- **Archiving is not uploading.**  Do not report a build as submitted, shipped
  or released on the strength of a clean archive.  See "Releasing" in
  `KNOWN_PROBLEMS.md` for what this machine cannot do.

## Releasing disk images: read the runbook first

Anything that publishes, re-uploads or re-pins a disk image goes through
`docs/DISK_W8FIX_RUNBOOK.md`, and specifically its **SUPERSEDED** block at the
top, which is the corrected recipe.  Its rules are absolute and each is one
command away from being broken: new tag always; `--prerelease` always; never
`--clobber` and never upload to `v1.4.5`; never move the `<disks version>`
attribute; never republish `hd1k_combo_ioscpm_w8fixed.img`.  That list is an
index, not a substitute — the runbook says why each one is fatal and what to
run instead.  Do not reconstruct these from memory or from an older revision of
that file: the revision that was superseded told you to do two of the forbidden
things.

**Two of them were deliberately exercised on 2026-09-04, and that is recorded
rather than hidden.**  `v1.4.12`'s help assets were replaced with `--clobber`
and its `--prerelease` flag was cleared, so `releases/latest` is now `v1.4.12`.
The runbook's **2026-09-04** section says what was traded and why.  The rules
still govern everything else: `v1.4.5` was not touched, no disk asset moved, and
the `<disks version>` attribute did not change.  Read that section before
concluding the repository violates its own rules and trying to "fix" it.

## Fixing "Simulator Busy" Errors

When the iOS Simulator reports busy/failed preflight, run ALL these steps in a SINGLE command:

```bash
pkill -9 -f "Simulator" 2>/dev/null; pkill -9 -f "simctl" 2>/dev/null; xcrun simctl shutdown all 2>/dev/null; launchctl kickstart -k gui/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true; rm -rf ~/Library/Developer/Xcode/DerivedData/iOSCPM-* 2>/dev/null; echo "Done"
```

Do NOT run these as separate steps - always run as one combined command.
