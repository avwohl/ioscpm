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

## Fixing "Simulator Busy" Errors

When the iOS Simulator reports busy/failed preflight, run ALL these steps in a SINGLE command:

```bash
pkill -9 -f "Simulator" 2>/dev/null; pkill -9 -f "simctl" 2>/dev/null; xcrun simctl shutdown all 2>/dev/null; launchctl kickstart -k gui/$(id -u)/com.apple.CoreSimulator.CoreSimulatorService 2>/dev/null || true; rm -rf ~/Library/Developer/Xcode/DerivedData/iOSCPM-* 2>/dev/null; echo "Done"
```

Do NOT run these as separate steps - always run as one combined command.
