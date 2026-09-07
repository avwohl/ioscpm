# Known Problems

## Disk Creation

### The size chooser exists, and the sizes it offers are deliberately not round
Settled, and kept here because the open request that used to stand at this spot
is what it answers. Settings carries a "New Disk Size" picker bound to
`EmulatorViewModel.newDiskSize`, and **both** halves of the write read it: the
`.fileExporter`'s `EmptyDiskDocument` takes a `sizeBytes`, and `createNewDisk`
falls back to `newDiskSize.bytes` when no caller passes a size. That pairing is
the whole of the warning this replaces - the two used to disagree, one
hardcoding 8 MB and the other taking a size nothing passed, so a picker wired to
only one of them would have looked like it worked and laid down 8 MB anyway.

The list is 8 MB and then 2, 4 and 7 hd512 slices, and it is emphatically not
16/32/64 MB: `emu_check_disk_size()` accepts only four shapes and 16777216 is
none of them, so the round numbers are exactly the wrong answer.
`DiskSize.swift` carries that reasoning and `Tests/DiskSizeTests.swift`
re-derives the rule from the C header rather than trusting the numbers written
in Swift. Imported disks are still accepted up to 64 MB (`maxDiskSize`), which
is what stops the list at 7 slices.

### Proper Disk Initialization
When creating a new disk, it should be properly initialized with:
- Correct magic numbers for the disk format

### Creating Disks on Linux (Workaround)

The app can create a blank disk in place (Settings -> Disk N -> "Create New..."), and it
now creates it at the size the picker is set to, but all it produces is 0xE5 fill - no
HD1K filesystem, no boot track, no system. A multi-slice size gives several blank drives
and still no filesystem on any of them. For a properly formatted image, build it on
Linux with cpmtools.

**Install cpmtools:**
```bash
sudo apt install cpmtools
```

**Supported disk sizes:**
- 8MB (8388608 bytes) - single slice disk
- 49MB (51380224 bytes) - 6-slice disk (6 × ~8MB)

**Create an 8MB single-slice disk:**
```bash
# Create empty file filled with E5 (CP/M empty marker)
dd if=/dev/zero bs=1 count=8388608 | tr '\000' '\345' > mydisk.img

# Format with CP/M filesystem (wbw_hd1k format)
mkfs.cpm -f wbw_hd1k mydisk.img
```

**Create a 49MB multi-slice disk:**
```bash
# Create empty file filled with E5
dd if=/dev/zero bs=1 count=51380224 | tr '\000' '\345' > mydisk.img

# Format each slice (0-5) - each slice is an independent CP/M filesystem
for slice in 0 1 2 3 4 5; do
    mkfs.cpm -f wbw_hd1k -b $slice mydisk.img
done
```

**Copy files to the disk:**
```bash
# Copy a file to slice 0 (drive A: in CP/M)
cpmcp -f wbw_hd1k mydisk.img localfile.com 0:FILENAME.COM

# List files on slice 0
cpmls -f wbw_hd1k mydisk.img
```

**Note:** The `wbw_hd1k` format is not included in standard cpmtools. You need the RomWBW diskdefs file.

**Option 1:** Use local RomWBW diskdefs (if you have RomWBW source):
```bash
# Point cpmtools to RomWBW diskdefs
export CPMTOOLS_DISKDEFS=/path/to/RomWBW/Source/Images/diskdefs

# Or use -T flag
mkfs.cpm -T /path/to/RomWBW/Source/Images/diskdefs -f wbw_hd1k mydisk.img
```

**Option 2:** Download diskdefs from RomWBW:
```bash
wget https://raw.githubusercontent.com/wwarthen/RomWBW/master/Source/Images/diskdefs
export CPMTOOLS_DISKDEFS=./diskdefs
```

**Option 3:** Add this to `/etc/cpmtools/diskdefs`:
```
diskdef wbw_hd1k
  seclen 512
  tracks 1024
  sectrk 16
  blocksize 4096
  maxdir 1024
  skew 0
  boottrk 2
  os 2.2
end
```

For multi-slice disks, use slice-specific definitions (`wbw_hd1k_0`, `wbw_hd1k_1`, etc.) which include proper offsets - see the RomWBW diskdefs file for full definitions.

## User Data Persistence

### Data Loss Risk with GitHub Disks
Disks downloaded from GitHub are writable, allowing users to store data in them. However, this data can be lost at any time if a new version of the disk is released and downloaded, overwriting the user's changes.

The trigger is broader than a download, and the user does not have to do anything at all. `disks.xml` carries a `version` attribute; on every successful catalog fetch the invalidation compared it against the stored `catalogVersion` and, on any difference, cleared downloaded images and said so afterwards. So publishing a refreshed catalog reaches every installed device with no tap and no download.

**Read the build numbers in this entry as two different kinds of thing.** Builds
up to 61 can be installed; 62 to 65 were never compiled at all, and 66 has never
been submitted. Re-measured 2026-09-08 with `tools/check-store-version.sh`: the
Store serves 1.5.1, released 2026-09-05, which is **at most build 61**, and the
script says so itself. It excludes 62 through 65 by their NOT COMPILED markers,
and 66 because its `CHANGELOG.md` heading was not committed before that release
date — a build that did not exist on the day Apple published cannot be the build
Apple published. So everything keyed below to 62 or later is this tree's history
and has never deleted a file on anybody's device.

**Build 63 narrowed the trigger to nothing on the XML catalog.** `checkCatalogGenerationAndInvalidate` (`EmulatorViewModel.swift`) replaced it and acted only on the interface-v0 catalog's `generation`, under a key scoped per (interface, RomWBW release). `disks.xml` carries no generation, so such a device would not be reachable this way at all — and the old `catalogVersion` value is deliberately not copied into the new key, because 13 ≠ 1 would have made the first v0 fetch delete the whole library. Every build in service still reads the attribute, so it is no less dangerous to move.

**Build 64 turned it back on, deliberately, against `generation`**, on the
reasoning that the v0 catalogs carry one and a bump therefore means the
release's artifacts moved — still only the images the new catalog could hand
back, still per (interface, RomWBW release), never a disk the user imported, and
with a release switch deliberately not counting as a bump.

**Build 66 removes it altogether, and the reason is a measurement rather than a
preference.** `recordCatalogGeneration` is what stands there now: it records the
number, logs a change, and deletes nothing; `deleteCatalogDisks(named:)` is gone
with the wipe that was its only caller. The only generation bump this catalog
has ever had — romwbw_disks `aab3a4f`, 1 → 2 on both releases — changed two ROM
hashes and **zero of the twenty disk hashes**. The build 64 code would therefore
have deleted twenty images and re-downloaded twenty byte-identical copies
because two ROMs were rebuilt, which on a phone on cellular is gigabytes to
arrive back where it started. `generation` says "some artifact of this release
changed", not "your copy of every artifact is stale", and acting on the first as
though it were the second is what that code did.

Nothing replaces it, because something better was already running on the same
path. `reassessDiskFreshness()` is called immediately after, and it asks per
file the question the wipe was guessing at — does this image's recorded
provenance still match the catalog's hash — routing the answer through
`DiskLedger.action`. Per file, never destructive, and it stands down while the
emulator is running off the file.

**So the publishing rule has changed shape, and
`romwbw_disks/docs/CATALOG_SCHEMA.md` §4 has not caught up.** It still opens
"iOS treats a change to this value as an instruction to delete files" and names
`checkCatalogVersionAndInvalidate` and `deleteCatalogDisks(named:)`. Neither
exists here any more; cpmdroid's `noteCatalogGeneration` logs the change and
keeps the images; z80cpmw parses `generation` and deletes nothing on it. So
advancing a generation is not currently destructive on any of the three
measured clients — but §4's reasons for computing it from content rather than by
hand stand on their own, and a client that has not been read is not a client
that keeps files. That section is in another repository and needs a human's
edit; the live index publishes `generation: 2` for both releases today, which
§4 also still reports as 1.

**Narrowed in build 56, and only for build 56 and later.** This is the shape the wipe has in the builds people are running, so it is written in the present tense on purpose even though build 66 has neither function left. `deleteCatalogDisks(named:)` deletes only the `.img` files the *new* catalog lists, which is the test for whether deleting one is recoverable: a disk the catalog does not name — one imported through Files, one `createNewDisk` made — cannot be fetched back from anywhere, and is kept. The alert says how many of each. Before that, `deleteAllDownloadedDisks()` took every `.img` in `Documents/Disks` regardless.

**The builds in service still read the version attribute, and that is the half of this entry that is still live.** Measured 2026-09-08: the Store serves 1.5.1, which is at most build 61, and build 61 fetches `disks.xml` from the pinned `v1.4.12` — so re-uploading that tag's catalog with a moved `<disks version="13">` reaches every one of those devices with no tap and no download. Earlier 1.5.1 builds are pinned to `v1.4.5` instead — the pin arrived at build 42/43 and moved to `v1.4.12` on 2026-09-03, with `CURRENT_PROJECT_VERSION` at 58 — and everything above is just as true of `v1.4.5`. Older installs are worse rather than gone: 1.4.9 (builds 36/37) is no longer *served*, but it is still on the phone of everyone who has not updated, and it floats on `releases/latest/download/` rather than a tag, so for those a *normal* release fires the wipe immediately. That is why the release order in `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md` still governs, and why `--prerelease` on an asset carrier is load-bearing rather than cosmetic. The rules that came out of doing it are in `docs/DISK_W8FIX_RUNBOOK.md`, in the SUPERSEDED block at the top. Every version number in this paragraph is a measurement with a date on it, not a constant: re-derive it with `tools/check-store-version.sh` before relying on it.

**Build 61 adds the refresh the version attribute could never safely provide, and it is deliberately narrower than a wipe.** `DiskLedger.swift` records, per filename, the catalog `<sha256>` that a *verified* download matched. "Superseded" then means *that recorded provenance differs from the catalog's current hash* — a fact about which published image the bytes came from, which local writes cannot change. That is what lets a respun image reach a device that already has the old one without the version attribute moving at all.

The reason it is keyed on provenance and not on the file's own hash is this entry. Comparing installed bytes against the catalog classifies **every disk the user has saved work into** as stale, because `saveDownloadedDisks()` writes the running machine's image back over the file on every warm boot and every backgrounding. An automatic refresh keyed on that comparison would be precisely this entry's hazard, automated and unprompted. So an image proven pristine — its bytes still hash to the provenance recorded for it — may be refreshed automatically, and only on an unconstrained, inexpensive network. Anything else is offered as a button that says in as many words that files saved inside the disk will be lost. An install with no ledger yet cannot prove pristineness either way, and therefore never takes the automatic path.

**Still open, and not foreclosed by the narrowing or by build 61:**
- Copy-on-write: create a local copy when the user first modifies a downloaded disk. This is the only one that helps a user who kept data *in* a catalog disk, which is what the paragraph at the top of this entry is about. Build 61 warns before replacing such a disk and never replaces one unasked; it still cannot preserve the contents.
- Confirm before the wipe, rather than reporting it afterwards. In this tree there is no wipe left to confirm — build 66 deletes nothing on a catalog change, and the provenance path asks first. In the builds users have, the version-attribute path is unchanged and still reports afterwards.
- How much of it a user actually has cannot be established from here. The narrowing landed in build 56 and the ledger in build 61, and the Store's 1.5.1 is at most build 61 — `tools/check-store-version.sh` cannot say which build inside that range it is, and neither can this file. A device still on 1.4.9 has neither.

## Interface v0

### No release boots with nothing downloaded, and a bundled ROM never changed that

**The decision to keep the bundled ROM has been reversed, on 2026-09-08.** What
stood here said: "Removing the bundled ROM would not simplify this and is not on
the table: an app whose only ROM is a download has nothing at all to boot on a
first offline launch." That premise was false, and it was checkable the whole
time. `start()` returns early when `diskCatalog` is empty, and the catalog and
every disk in it are downloads — so a device that has never had a network has no
disk to boot, and a ROM to boot it with buys nothing at all. What the 512 KB
actually bought was skipping the ROM download on 3.5.1, on a launch that was
fetching a 49 MB disk image anyway. That is a real saving and it is a much
smaller claim than the one it was defended with.

So `iOSCPM/Resources/emu_avw.rom` is gone, together with `bundledROMFilename`,
`bundledROMRelease`, `bundledROMURL`, `bundledROMFacts`, `bundledROMOption`,
`bundledROMFallbackRelease`, `switchToBundledROMRelease()` and the
"Use RomWBW 3.5.1" button on both ROM-problem alerts. `git ls-files` now matches
no `.rom`, `.img`, `.bin`, `.com` or `.dsk` at all. ioscpm was the last of the
three app ports to bundle one — cpmdroid and z80cpmw deleted theirs on
2026-09-07 — and being the odd one out for a benefit it did not have is the
other half of the reason.

Two consequences worth writing down rather than discovering:

- **A fresh install now starts on whichever release the index flags
  `default: true`, which is 3.6.0 today**, where it used to start on the bundled
  ROM's 3.5.1. Both releases are `status: stable`; measured against the live
  index on 2026-09-08.
- **The ROM-problem alert has one button and it says OK.** There is nothing left
  to offer: booting some other release's ROM under this release's disks is the
  `*** WARNING: HBIOS/CBIOS Version Mismatch ***` that the per-release catalog
  exists to remove, and it would produce it invisibly. `romProblemMessage`
  carries the two real ways out — a connection, or the other ROM the same
  release publishes.

Downloaded ROMs live beside the disks under their catalog filenames
(`emu_avw-v0-3.6.0.rom`), have both size and sha256 checked before every use
rather than only when downloaded, and are never deleted by the app.

**The other half of the old justification was a filing, and it has been
rewritten rather than left behind.** `docs/ROM_ATTESTATION.md` accompanies an
App Store submission, and the entry that stood here cited it as a second reason
not to remove the ROM, because it named `emu_avw.rom` specifically: it said that
512 KB file was what the application boots on a first launch and that an
installed copy was fully functional with no ROM download of any kind. It now
says the application contains no ROM of its own, carries a "What changed since
the previous filing" section that says exactly which claims were withdrawn, and
states that a first launch needs a network. The rights position did not move at
all — the same bytes are still published as `emu_avw-v0-3.5.1.rom`, and the four
sha256 values in that document were fetched from the live catalog on 2026-09-08.

What a document cannot do is reach Apple on its own. **The copy filed with the
previous submission still describes a bundled ROM**, and the rewritten one gets
in front of a reviewer only with the next build that carries it. That is a
submission to make, not a reason to put the ROM back: the premise it was kept
for was false either way.

### The first launch after the v0 upgrade, with no network, cannot boot

Real, and accepted rather than fixed on 2026-09-08. Take a device with disks
already downloaded, upgrade it to a build with the v0 catalog, and launch it
with no connection. `migrateStorageToInterfaceV0` renames the images, the four
slots, the saved profiles and the ledger to their `-v0-3.5.1` names — correctly,
and losing nothing. Then `loadCachedCatalog` looks for
`catalog-v0-<release>.json` and finds none, because this build has never fetched
one and the pre-v0 XML cache is not a v0 catalog and is not read. `diskCatalog`
is empty, so `start()` refuses with "Failed to load disk catalog. Please check
your internet connection and try again."

Every file is still there under its new name, nothing is deleted, and the first
launch with a connection fixes it permanently. It is one launch, on one upgrade,
and only for a user who is offline for it.

The alternative was to bundle a catalog snapshot so that the first offline
launch has something to resolve those names against. It was rejected. A snapshot
is a second source of truth about what is published; it is stale the moment a
release is cut or a disk is respun, and every client then has to decide which of
the two to believe. Removing exactly that is what the v0 interface is for. It
would also buy less than it looks: a device that has never had a network has no
disk images either, so the snapshot helps only the narrow upgrade case above,
and it would pay for it with the thing the interface was built to deliver.

### `tools/check-shipped-disks.sh` answers for this port again

What stood here said the script found no `vX.Y.Z` pin in a migrated client, so
it reported `MIGRATED` for iOSCPM, skipped it and exited 2 (`CANNOT VERIFY`).
That has been fixed and re-measured on 2026-09-08. The script now carries a
`kind` per port and asks migrated ports the v0 form of the question instead:
does the source still name the v0 index, is the legacy pin really gone, does the
index still publish the release a bundled ROM declares, and does the built
artifact name `index-v0.json`. `sh tools/check-shipped-disks.sh` exits 0 and
prints, for all three:

    ioscpm     v0 index, no bundled ROM - every ROM comes from the catalog
    cpmdroid   v0 index, no bundled ROM - every ROM comes from the catalog
    z80cpmw    v0 index, no bundled ROM - every ROM comes from the catalog

Two things about that run are worth knowing before it is quoted as a pass. The
ROM arm now has nothing to compare in any of the three ports, so that part of
the gate covers nothing until some port bundles a ROM again — which is why the
path is still listed in `bundled_rom_of` rather than deleted. And no artifact
was inspected: the script globs local build outputs, this machine has none for
any port, and it says so in as many words rather than reporting the artifact
half as passed.

`CLAUDE.md` no longer tells a reader that bumping the pin means editing
`releaseTag` in `EmulatorViewModel.swift`; it says there is no `releaseTag` any
more, that publishing to `romwbw_disks` reaches a shipped client with no app
release at all, and that what still needs a release is a change to this app's
own code. The request for a human's edit that stood here is discharged.

## Releasing

### This machine cannot upload, and as of 2026-09-08 it cannot archive either

Not a bug and not a task — a standing fact about the toolchain, re-checked at
build 58, at build 61, and again on 2026-09-08.

**Build 61 was uploaded on 2026-09-04 and that does not contradict this entry.**
It was submitted by a person with App Store Connect credentials, not from this
machine and not by any session. The rest of this entry is about what the
toolchain *here* can do.

**The archive half of this entry has expired: there is no Xcode on this machine
any more.** Measured 2026-09-08: `ls -d /Applications/Xcode.app` finds nothing,
`xcode-select -p` is `/Library/Developer/CommandLineTools`, and the
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` prefix this entry used
to recommend fails with `missing DEVELOPER_DIR path`. Nothing here archives,
produces an `.app`, or boots a simulator. What is left is the Command Line Tools
toolchain — Swift and `clang++` against the macOS SDK — which is everything
`sh Tests/run_tests.sh` needs, and is the whole of how build 66 was compiled.

The reason this entry and `CHANGELOG.md`, `WIP.md` and `todo.txt` have
contradicted each other for several builds is that bare `xcodebuild` prints the
same "requires Xcode, but active developer directory ... is a command line tools
instance" line whether Xcode is installed and merely unselected **or is not there
at all**. `ls -d /Applications/Xcode.app` tells the two apart and costs nothing;
run it before writing either claim down again. `WIP.md`'s "This machine no longer
has Xcode" section carries the full measurement, and
`~/Library/Developer/Xcode/Archives/2026-09-02/` still holds the two build 58
`.xcarchive`s — which is all that is left of the toolchain that made them.

**What an archive could never do, and that half is unchanged.** While Xcode was
here, `xcodebuild archive` succeeded for `generic/platform=iOS`, but it signed
with the **`Apple Development`** identity, which cannot be exported for the App
Store. An upload needs three things that were never on this machine: a
distribution certificate, an App Store provisioning profile, and an App Store
Connect API key.

So a clean archive is evidence that the code builds and evidence of nothing
else. Do not report a build as submitted, shipped or released on the strength of
one, and do not infer from a submission that anything reached a user — run
`tools/check-store-version.sh`, which measures what the Store actually serves.
See "Never write down a shipped state you have not measured" in `CLAUDE.md`.

## Keyboard

Decisions from the ^R sweep (a Windows user reported "Ctrl R exits me from
CP/M"; ioscpm turned out to be clean). These are settled behaviours, not open
problems, apart from the one open item marked as such - recorded here so the
next audit does not re-flag the rest. All of it lives in
`iOSCPM/Views/TerminalView.swift` unless noted.

### Alt/Option is not a meta key, on purpose
Option is absent from the modifier guard in `pressesBegan`, so an Option combo
falls through to `key.characters` and is treated as ordinary text. What happens
next depends on the layout:

- the layout composes a non-ASCII glyph (US Option+R -> "®"): it reaches
  `EmulatorViewModel.sendKey`, where `guard let code = char.asciiValue` drops it;
- the layout has a dead key there (US Option+E/U/I/N/`): `key.characters` is
  empty and nothing is sent;
- the layout output is plain ASCII (German Mac Option+L -> "@"): it passes
  through to the guest, which is exactly right.

We are deliberately not adding a meta convention on top of that. Setting bit 7
is wrong because CP/M console input is 7-bit and WordStar uses bit 7 as its own
end-of-word marker inside text. ESC-prefixing is a Unix/Meta convention with no
meaning to CP/M, and it would collide with the VT100/VT52 dialect handling.
z80cpmw maps Alt nowhere either: it has no `WM_SYSCHAR` handler at all, and its
`WM_SYSKEYDOWN` case handles only a bound F10 before falling through to
`DefWindowProc`, so every Alt combo lands there. Pass-through of an
ASCII-composing Option combo is the correct behaviour for a 7-bit guest.

### Nav keys other than the arrows still ignore their modifiers
Build 53 gave the four arrows a modified slot; nothing else has one. Shift+Up,
Alt+Right and Shift+Insert still resolve through `specialKey(for:)`, which
switches on the HID usage alone, and emit the bare key's bytes. That is the same
shape z80cpmw has - its `Keymap.h` accepts `Shift+` and `Alt+` prefixes but its
defaults bind none of them - so this is a gap in the *defaults*, not in the
schema, and a Custom profile still cannot express those combinations here
because the enum has no cases for them.

**The convention Ctrl+arrow uses, and why.** Ctrl+Up / Down / Right / Left send
the xterm modified forms `\E[1;5A` / `B` / `C` / `D` - CSI 1 ; 5 *final*, where
the 5 is the Ctrl modifier - byte for byte what `z80cpmw/Keymap.h` binds. The
alternative was `cpmemu`'s, which translates the same four keys to `^A` / `^F` /
`^W` / `^Z` (WordStar word left, word right, scroll up, scroll down) in the
`extended_keys` table of `src/os/windows/platform.cc`. The xterm form won for
three reasons: it is the one with a cross-terminal meaning, so a map written for
one port means the same thing in another - the whole point of sharing the
termcap schema; the four WordStar bytes are already reachable by typing
Ctrl+A / Ctrl+F / Ctrl+W / Ctrl+Z, so nothing became unreachable; and z80cpmw
had already shipped it, so choosing WordStar would have created a divergence
rather than closed one. A user who wants `^A`/`^F` has them one edit away in the
Custom profile, which is exactly the escape hatch z80cpmw's own comment offers.

The bindings live in all three preset profiles. VT52 is the deliberate
exception: it binds Ctrl+arrow to the *plain* VT52 arrow (`\EA`..`\ED`), because
a VT52 has no parameterised CSI to put a modifier in, and giving it one would be
the same lie as giving it F5-F12. An absent binding falls back to the unmodified
key, so a Custom profile saved before build 53 keeps behaving exactly as it did
rather than going silent; an explicitly empty one means "send nothing" and does
not fall back. `Tests/KeyMapTests.swift` asserts all of that.

### Ctrl+Home / Ctrl+End and Shift+PageUp / Shift+PageDown belong to the host
Those four are consumed for scrollback navigation and never forwarded to the
guest. Intended. Plain PageUp/PageDown are untouched and still send ^R/^C under
the WordStar profile, so nothing the guest needs is lost, and it matches
z80cpmw, which tests the same four combinations ahead of its keymap lookup.

### Ctrl+arrow never arrives on Mac Catalyst
macOS binds Ctrl+arrow to Mission Control (move left/right a space, Mission
Control, application windows) at the WindowServer level, so the presses are
consumed before any app sees them; no app-side flag recovers them.
`wantsPriorityOverSystemBehavior` works on `UIKeyCommand`s, and these are not
key commands - they arrive, or fail to arrive, through `pressesBegan`. Nothing
in the app rejects them: the nav branch excludes only Command, and since build
53 it resolves a held Ctrl to the modified binding. So the `\E[1;5A`..`D`
sequences above are iPadOS-only in practice. They are still defined on Catalyst,
and the code says so rather than pretending otherwise - if a future macOS lets
the press through, or the user turns the Mission Control shortcuts off in
System Settings > Keyboard > Keyboard Shortcuts, it works there with no change.

### A dialog drawn over the terminal has to be listed in `modalHasKeyboard`
`TerminalUIView.keyCommands` returns nil while `captureKeyboard` is false, and
that flag follows `modalHasKeyboard` (`ContentView.swift`), which names the four
dialogs drawn over the terminal: the disk-overwrite warning, the error alert,
the ROM-problem alert and the reset confirmation. While one of them is up,
Escape and Return reach the dialog instead of the guest, which is the point.
Sheets are deliberately not in it - they cover the terminal and present their
own responder. **A new dialog added over the terminal and not added there loses
Escape and Return to the guest**, silently and only while it is on screen. This
entry said three when it was written; the ROM-problem alert is the one that has
been added since, and it was added to `modalHasKeyboard` as well - which is
evidence that the trap is avoidable, not that it is not there.

The 26 Ctrl+letter `UIKeyCommand`s in the same `keyCommands` (the
`"abcdefghijklmnopqrstuvwxyz"` loop) are also what is expected to keep AppKit
emacs `StandardKeyBinding` bindings away from the guest under Mac Catalyst:
`TerminalUIView` is a plain `UIView` + `UIKeyInput`, not a `UITextInput`
responder, so those bindings should not apply to it at all, and the key
commands sit on the first responder UIKit consults first. Reasoned, never
watched - `MANUAL_CHECKS.md` has the WordStar pass that would settle it.
