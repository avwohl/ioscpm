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
- **Bumping a pin is not shipping it.**  Editing `releaseTag` in
  `EmulatorViewModel.swift` reaches users only through a build that carries the
  edit *and* that Apple has actually released.  `tools/check-disk-pins.sh`
  inspects the built artifact as well as the tree for exactly this reason.
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
