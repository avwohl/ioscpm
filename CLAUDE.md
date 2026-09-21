# Claude Code Notes for iOSCPM

## NEVER change MARKETING_VERSION

`MARKETING_VERSION` in `iOSCPM.xcodeproj/project.pbxproj` is the App Store
version string (**1.6.2** at time of writing). **Do not change it unless a human
explicitly asks you to change it, or the Store has already RELEASED the version
the project names** - see the second move below - and never as a side effect of
"bumping the version" for a fix.

It has moved twice, and the two moves are not the same kind of thing:

- **1.5.1 → 1.6.1 on 2026-09-07, build 67, asked for in those words by a
  human.**  The occasion was that 1.5.1's description had stopped being true of
  the app: no ROM and no disk image ships in the bundle any more, and the user
  chooses which RomWBW release to run.  A build-number bump could not carry
  that.
- **1.6.1 → 1.6.2 on 2026-09-18, at `1a5603c`**, where the build number was 73;
  it ships as 74, because the build number moved again for the TestFlight
  upload and the version did not.  That commit's message records the reasoning
  but does NOT record a human asking in those words, so do not read it as a
  precedent for bumping at will.  What made it necessary is
  a fact anyone can re-measure: `tools/check-store-version.sh` says the Store
  RELEASED 1.6.1 on 2026-09-12, six days earlier, and **App Store Connect will
  not take another submission under a version it has already released.**  At
  that point the build number alone cannot carry the change and the version
  string has to move; that is the one circumstance in which this section's rule
  does not apply.

Recorded here because a reader who finds this file and the project disagreeing
should be able to tell an authorised bump from the accident this section exists
to prevent.

Once a release candidate exists in App Store Connect for a given version, that
version is frozen — it cannot be edited there. Changing it locally makes the
project disagree with the record on the Store and has to be undone by hand.

**Bump `CURRENT_PROJECT_VERSION` instead.** That is the build number, it is the
only thing that moves between submissions of the same version, and it is what
every CHANGELOG entry here is keyed to:

```
CURRENT_PROJECT_VERSION = 74;      <- bump this, once, for a new build
MARKETING_VERSION = 1.6.2;         <- leave alone
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

## Whether Xcode is here is a fact about the machine, not about the repo

**Measure it; do not read it from this file.**  This section has been wrong in
both directions, and the message that misleads is
`xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory ... is a command line tools instance`, which is printed whether Xcode
is merely *unselected* or genuinely *absent*.  Settle it in one command:

```bash
ls -d /Applications/Xcode.app        # present?  then it is only unselected
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -version
```

`DEVELOPER_DIR` needs no `sudo`, where `xcode-select --switch` does, so an
unselected Xcode is not an obstacle.  On 2026-09-07 that machine had **Xcode
26.6** with `xcode-select -p` still pointing at Command Line Tools, and builds
62 to 67 were built there for the iOS Simulator, for an arm64 device, and for
Mac Catalyst.  Builds 62 to 66 were written where there was no Xcode at all.
Both are ordinary.

`sh Tests/run_tests.sh` is the check that runs **everywhere**, and it is not
only unit tests: it type-checks `EmulatorViewModel.swift` against the real
bridging header, compiles the C++ core through the symlinks, and name-checks
what `ContentView.swift` asks of the view model.  **Run it after every change;
it exits non-zero on a compile error.**  Where there is no Xcode it is all you
have, and five files stay out of reach — `ContentView.swift`,
`TerminalView.swift`, `CatalystWindow.swift`, `HelpView.swift` and
`iOSCPMApp.swift` import UIKit or use a SwiftUI macro, and neither is available
on the macosx SDK.  `Tests/check_view_bindings.sh` covers the question that
matters most there, by spelling rather than by type.

Where there IS Xcode, run it as well as the build; it is faster and it catches
the C++ side, which `xcodebuild` on this project does not exercise as directly.
And run the build, because the five files above have exactly one compiler:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project iOSCPM.xcodeproj -scheme iOSCPM \
    -destination 'platform=iOS Simulator,name=iPhone 17' build
```

What is still true regardless of this machine: **nothing in this tree has ever
run on physical iOS hardware.**  Every measurement in this repository was made
on a simulator or on a Mac, and that is a different claim from "it has never
been built" — see `MANUAL_CHECKS.md` for what only a real device can answer.

## Never write down a shipped state you have not measured

The tree is always ahead of the App Store, and that gap is normal.  What is not
normal is recording the tree's build number in anything that describes what
*users* have.  A submission that is queued is not released: it can sit in
review, be rejected, or be held.

**Measure before you write it down.**  `tools/check-store-version.sh` curls the
iTunes lookup, maps the shipped version to a build through `CHANGELOG.md`, and
compares that with `CURRENT_PROJECT_VERSION`.  Exit 0 means nothing recorded in
**this tree** claims a build the Store does not serve; exit 2 means it could not
check, which is not a pass.  It reads no sibling repository any more: the
`shipped:<build>` field it used to compare against was removed from
`z80cpmw/FEATURE_PARITY.md` on 2026-09-13, along with the CI jobs that checked
it, and the script's sibling block is now a comment saying so.

```bash
sh tools/check-store-version.sh
```

Three rules follow from it, and each has been broken here at least once:

- **Do not write a "shipped" claim on the strength of a submission.**
  `z80cpmw/FEATURE_PARITY.md` used to carry an ioscpm `shipped:<build>` field
  that `check-sibling-drift.sh` failed the whole column over until the number and
  the tree agreed, and **it was right to keep failing**: recording the tree's
  build certifies every tick in the column against software nobody can install.
  The field, the check and the script were all removed on 2026-09-13, so the rule
  now has nothing enforcing it and needs stating instead.  Which build the column
  was read at is prose under that block.  Submitted is not released, released is
  not what every user has yet, and the only way to find out is
  `sh tools/check-store-version.sh` — by hand, since nothing schedules it.
- **Publishing is not shipping it.**  There is no `releaseTag` in
  `EmulatorViewModel.swift` any more — the app compiles in one index URL and
  reads everything else out of the catalog — so the shape of this rule changed
  but not its force.  Adding a ROM or a disk to an **already-published** RomWBW
  release reaches a *shipped* client with no app release at all, which is the
  point.

  **A whole new RomWBW release reaches a shipped client too, since romwbw_emu
  v1.44.**  This paragraph used to say the opposite, at length, and was right
  when it was written: `ROMWBW_SUPPORTED_RELEASES` in
  `romwbw_emu/src/romwbw_pin.h` was a compile-time list, every client filtered
  the index by asking its own core `emu_romwbw_release_supported()`, and a 3.7.0
  entry was fetched and then hidden by every binary built before somebody added
  it there.  That header, those two functions and this app's filter are all
  gone.  The picker now offers every release the index publishes, with one
  exception that is a user's choice rather than a compile-time list: an entry
  the index flags `prerelease` is a RomWBW development snapshot, never the
  index `default`, and `RomWBWIndex.offered` drops it unless Settings →
  RomWBW Release → Show Development Snapshots is ticked, which 1.6.2 added
  and which is off in a fresh install.  `CATALOG_SCHEMA.md` §2.3 requires that
  opt-in of every client.  It hides nothing a shipped binary could not run, and
  turning it on needs no app release.

  The reason the list went is worth keeping, because re-introducing it is easy.
  It gated the wrong axis.  A release number is the HBIOS-to-CBIOS pairing — a
  fact about a ROM and a disk image, which the GUEST enforces by printing
  `*** WARNING: HBIOS/CBIOS Version Mismatch ***` — and not what the emulator
  depends on.  What the emulator depends on is two I/O ports and the set of
  HBIOS functions `hbios_dispatch.cc` services, and that interface is versioned
  by the catalog's own name: everything a **v0** index publishes speaks v0, and
  a change this core could not service would be published as `index-v1.json`,
  which no v0 client reads.  The claim that somebody ran a release is now made
  where the release is published — `romwbw_disks`' `tools/boot_test.sh`, at
  publish time, against the artifact being published — instead of by a macro
  edited months earlier and never re-checked.

  What still must match is the ROM and the disks in the drives:
  `romReleaseMismatchNotice` is this app's half of that, and the index's
  `hbios.ver_byte`/`upd_byte` are what the catalog says about it.

  What still needs a release is a change to this app's own code, and it reaches
  users only through a build that carries the edit *and* that Apple has actually
  released.  `tools/check-shipped-disks.sh` inspected the built artifact as well as the
  tree for exactly this reason.  It was deleted on 2026-09-13 with the rest of
  the release-checking tooling, so the distinction it enforced is now one to
  hold in your head: the tree naming the v0 index is not the same claim as a
  shipped binary doing so.
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

## What is finished but not shipped

`tools/unreleased.sh` reports the gap between written, compiled, submitted and
released — the distinction `CLAUDE.md`'s "archiving is not uploading" rule is
about, reported rather than gated. It measures the App Store with
`check-store-version.sh` and anchors on the commit that first set
`MARKETING_VERSION` to the served value.

That anchor is the FLOOR of the builds that version covers, so **the list is an
upper bound**: if Apple served a later build of the same version, some of what
it reports has already reached users. Over-counting is the safe direction for
"what might I still owe a user", but it is over-counting. It separates
`iOSCPM/` (needs a submission) from `release_assets/` (published to the catalog,
reaches installed clients on their next fetch).

**It is not a gate and must not become one.** No exit 1: 0 even when work is
unreleased, 2 only when it could not measure.


## todo.txt: open work only, one or two lines an item

The rules, given by a human on 2026-09-19 after this file had grown to **320
lines**:

1. `todo.txt` holds **things to do**, and nothing else.
2. **Only work in THIS repository.** If another repo needs the change, file it
   in that repo's `todo.txt`, where the session that can close it will read it.
3. **One or two lines an item.** If you believe an item needs more, ask a human
   rather than writing the third line.
4. **A cleanup must leave the file SHORTER.** Preferably empty.

Rule 4 is the one that had been failing. Every previous "cleanup" re-litigated
each item in prose and the file grew: a closed item got a paragraph explaining
that it closed, a status fact got a paragraph explaining that it was not work,
and an item whose real home was another repository got a paragraph explaining
which. **A closed item is DELETED.** It is in `CHANGELOG.md` and in the commit
message that closed it, which is where finished work lives.

Where the displaced things go — none of them is a todo item:

    CHANGELOG.md       finished work, and why
    MANUAL_CHECKS.md   checks that need a person driving the app
    KNOWN_PROBLEMS.md  standing facts that will never be "done"
    WIP.md             the one open question, and longer handoff notes

Tag each item with what a machine needs to take it — `[ANY]`, `[MAC]` (Xcode),
`[DEVICE]` (real hardware), `[RELEASE]` (an Apple account) — so a session on
another machine can see at a glance what it can pick up. Cite a symbol or a
greppable string, never a file:line; every line cite this file has carried into
`EmulatorViewModel.swift` went stale inside one build.
