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
16/32/64 MB: `emu_validate_disk_image()` accepts only four shapes and 16777216 is
none of them, so the round numbers are exactly the wrong answer.
`DiskSize.swift` carries that reasoning and `Tests/DiskSizeTests.swift`
re-derives the rule from the C header rather than trusting the numbers written
in Swift. Imported disks are still accepted up to 64 MB (`maxDiskSize`), which
is what stops the list at 7 slices.

### A created disk has no filesystem, and the core only warns about it
`createNewDisk` and `EmptyDiskDocument` lay down 0xE5 fill at the chosen size
and nothing else: no HD1K directory, no boot track, no MBR.  That is a real
limitation and the workaround below is the answer, but the entry that used to
stand here asked for "correct magic numbers for the disk format" without saying
which, so here they are, read out of `romwbw_emu/src/emu_init.cc`
(`emu_check_disk_mbr`) and `emu_init.h`:

- `data[510] == 0x55 && data[511] == 0xAA` is the MBR signature.  **A file
  without it is accepted**, on the reading that it is a raw hd1k slice - which
  is exactly what a 0xE5 image is, and why creating one produces no warning.
- `PART_TYPE_ROMWBW = 0x2E` is the partition type an hd1k image is supposed to
  carry, at `0x1BE + p*16 + 4` for one of the four entries.
- `data[0] == 0x18 || data[0] == 0xC3` - a Z80 `JR` or `JP` - is what a real
  hd1k slice starts with, and is the fallback that stops a stale MBR signature
  being reported as a bad format.

So the core's check is a *warning* path, not a gate: it can tell you an image
has an MBR naming the wrong partition type, and it deliberately says nothing
about an image with no MBR at all.  Writing a filesystem is what would close
this, and nothing in the app does it.

### Creating a formatted disk, with the tool this family uses

The app can create a blank disk in place (Settings -> Disk N -> "Create New...")
at the size the picker is set to, but all it produces is 0xE5 fill - no HD1K
directory, no boot track, no system. A multi-slice size gives several blank
drives and still no filesystem on any of them.

`cpm_disk.py` writes the image **and its directory** in one step. It is one
stdlib-only Python file, owned by cpmemu at `util/cpm_disk.py`, and it needs no
diskdefs file, no `-T logical` and no libdsk - the format is detected from the
size:

```bash
CPM=~/src/cpmemu/util/cpm_disk.py

python3 "$CPM" create newdisk.img            # 8 MB hd1k, one slice
python3 "$CPM" create --combo newdisk.img    # 49 MB combo, six slices
python3 "$CPM" add  newdisk.img file.com
python3 "$CPM" add  --slice 3 newdisk.img file.com
python3 "$CPM" list --slice 3 newdisk.img
python3 "$CPM" verify newdisk.img
```

Measured on macOS, 2026-09-15: `create` gives exactly 8,388,608 bytes and
`create --combo` exactly 51,380,224, both `verify` clean, and a file added to
**slice 3** of the combo lists and extracts back byte-for-byte. It runs wherever
Python does; there is nothing Linux-specific about any of this.

`create --sssd` exists for a 250 KB 8" floppy. Through cpmemu 4.9.0 it failed
its own post-create verify and wrote no file; 4.10.0 fixed it. The emulator
accepts no image that size in any case.

**This section used to prescribe cpmtools**, with a diskdefs file to install and
three ways to obtain a `wbw_hd1k` definition. Do not restore it. The measured
reasons are in `romwbw_emu/.claude/CLAUDE.md`: cpmtools 2.23 cannot be
configured without libdsk, its default path double-counts `boottrk` on a diskdef
carrying no `offset`, and the failure is **silent** - against the published
`hd1k_infocom`, `cpmls -f wbw_hd1k` listed nothing while `cpmcp` exited 0 having
written into the data area over a file already there. libdsk also cannot address
past 8 MB from the start of a file, which put combo slices 1-5 out of reach
entirely; the `--slice 3` line above is the case that could not be done at all.

romwbw_disks still uses cpmtools in `tools/build_disks.sh` to build the
published images. That is that repository's business and its `tools/diskdefs` is
load-bearing there; it is the one place in this family the tool is named.

### Neither "Open File..." nor "Create New..." presents anything under Mac Catalyst

Measured 2026-09-21 on a Release Mac Catalyst build of this tree - numbered 73
when it was driven, 74 as it ships - on Xcode 27
and macOS 26, with the click placed by finding the control's own pixels rather
than by guessing: pressing **Open File...** in Settings dismisses Settings and
**no picker, panel or sheet ever appears** - `every window of process "iOSCPM"`
stays `Z80CPM` for ten seconds and `every sheet of window 1` is empty.
**Create New...** does the same. Settings reopens normally afterwards, so
nothing is wedged; the file dialog simply never arrives.

**This is not new in 1.6.2 and not a reason to hold a release.** The
`presentationMode.wrappedValue.dismiss()` that sits beside
`viewModel.openLocalDisk(unit:)` arrived in `b5dac37` (2026-03-16, build 36),
in a commit whose message is "Fix macOS disk dialog freeze" - so the dismissal
was put there deliberately, to cure a freeze, and what it bought was a dialog
that does not open at all. Every build users have had since carries it.

The shape is the ordinary UIKit one: `showingOpenDisk` flips true while the
`.fullScreenCover` holding Settings is mid-dismissal, and the `.fileImporter`
bound to it lives on the root `ContentView`, which cannot present while a
dismissal is in flight. A fix presents AFTER the dismissal completes rather
than beside it. Do not just delete the `dismiss()`: the freeze it was added for
is presumably still there behind it, and nothing here has reproduced it.

**iOS is untested, and must not be assumed to match.** No session has been able
to drive an iOS simulator since Xcode 27 removed `Simulator.app` - see
`WIP.md` - so this is a Catalyst measurement and nothing more. It matters
beyond the two buttons because **"Open File..." is the only route to the
local-disk release warning** added in 1.6.2, which therefore has never been
seen on a Mac.

## User Data Persistence

### Data Loss Risk with GitHub Disks
Disks downloaded from GitHub are writable, allowing users to store data in them. However, this data can be lost at any time if a new version of the disk is released and downloaded, overwriting the user's changes.

The trigger is broader than a download, and the user does not have to do anything at all. `disks.xml` carries a `version` attribute; on every successful catalog fetch the invalidation compared it against the stored `catalogVersion` and, on any difference, cleared downloaded images and said so afterwards. So publishing a refreshed catalog reaches every installed device with no tap and no download.

**This tree no longer does any of that, and the builds users have still do.**
That split is the whole of why the entry stays.  The wipe was narrowed at build
56, replaced at build 63, deliberately reinstated against `generation` at build
64, and removed outright at build 66; `recordCatalogGeneration` is what stands
there now, and it records the number, logs a change and deletes nothing.  The
build-by-build account, including the measurement that decided it - the only
generation bump this catalog has ever had moved two ROM hashes and zero of the
twenty disk hashes - is in `CHANGELOG.md` under each of those builds and is not
repeated here.

Nothing replaces it, because something better was already running on the same
path. `reassessDiskFreshness()` is called immediately after, and it asks per
file the question the wipe was guessing at — does this image's recorded
provenance still match the catalog's hash — routing the answer through
`DiskLedger.action`. Per file, never destructive, and it stands down while the
emulator is running off the file.

The reason it is keyed on provenance and not on the file's own hash is this entry. Comparing installed bytes against the catalog classifies **every disk the user has saved work into** as stale, because `saveDownloadedDisks()` writes the running machine's image back over the file on every warm boot and every backgrounding. An automatic refresh keyed on that comparison would be precisely this entry's hazard, automated and unprompted. So an image proven pristine — its bytes still hash to the provenance recorded for it — may be refreshed automatically, and only on an unconstrained, inexpensive network. Anything else is offered as a button that says in as many words that files saved inside the disk will be lost. An install with no ledger yet cannot prove pristineness either way, and therefore never takes the automatic path.

**The version-attribute wipe no longer reaches the build the Store serves, and that changed on 2026-09-12.** Measured 2026-09-21: the Store serves 1.6.2, released 2026-09-21, which is build 74 exactly — 1.6.2 heads one CHANGELOG entry, so there is no range to bracket this time — and that is well past the build-64 migration. Build 74 is a v0 client that reads no `disks.xml` at all, so moving `<disks version="13">` cannot touch it. Until 2026-09-12 the opposite was true, and this paragraph said so: the Store served 1.5.1, at most build 61, which fetches `disks.xml` from the pinned `v1.4.12`.

**It frees nothing, because the hazard was never about the build being served.** It is about the builds people have. Anyone who has not updated is still on 1.5.x pinned to `v1.4.12` or `v1.4.5` — the pin arrived at build 42/43 and moved on 2026-09-03 with `CURRENT_PROJECT_VERSION` at 58 — and re-uploading either tag's catalog with a moved version attribute reaches those devices with no tap and no download. Older installs are worse: 1.4.9 (builds 36/37) floats on `releases/latest/download/` rather than a tag, so for those a *normal* release fires the wipe immediately. That is why `--prerelease` on an asset carrier is load-bearing rather than cosmetic, and the rules that came out of doing it are in `docs/DISK_W8FIX_RUNBOOK.md`, in the SUPERSEDED block at the top. `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md` is where the ordering was first worked out; it now opens "Historical, and nothing here is current as of 2026-09-07", so read it for the reasoning and not for the procedure. Every version number in this paragraph is a measurement with a date on it, not a constant: re-derive it with `tools/check-store-version.sh` before relying on it.

**Still open, and not foreclosed by the narrowing or by what the Store now serves:**
- Copy-on-write: create a local copy when the user first modifies a downloaded disk. This is the only one that helps a user who kept data *in* a catalog disk, which is what the paragraph at the top of this entry is about. Build 61 warns before replacing such a disk and never replaces one unasked; it still cannot preserve the contents.
- Confirm before the wipe, rather than reporting it afterwards. In this tree there is no wipe left to confirm — build 66 deletes nothing on a catalog change, and the provenance path asks first. In the builds users have, the version-attribute path is unchanged and still reports afterwards.
- How much of it a user actually has cannot be established from here. The narrowing landed in build 56 and the ledger in build 61, and the Store's 1.6.2 is build 74 exactly, so a device on the current version has both and the wipe removed outright at build 66 besides. `tools/check-store-version.sh` names that build rather than bracketing it, because 1.6.2 heads one CHANGELOG entry rather than a range of them. A device nobody has updated has whatever it had: a 1.5.x install may have the ledger, and one still on 1.4.9 has neither.

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

`docs/ROM_ATTESTATION.md` was rewritten for build 66 to match — it now opens
that the application contains no ROM of its own, and carries a "What changed
since the previous filing" section naming the claims that were withdrawn. The
rights position did not move: the same bytes are still published, as
`emu_avw-v0-3.5.1.rom`. Filing it is a submission for a person to make and is
in `todo.txt`, not a reason to put the ROM back — the premise it was kept for
was false either way.

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

### The stamp guards the second hop's BYTES, not the first hop's INSTRUCTIONS

1.6.2 stamps both cache files and, where a stamp is absent, adopts the file
and sets `catalogIsUnverified` rather than refusing it. What that flag then
does is narrower than the code comment beside it claims. The comment on
`continueFromCachedIndex` says the release list's "real power - naming the
catalog URL and the checksum the second hop is verified against - is taken away
instead, by catalogIsUnverified". It is not: `catalogIsUnverified` is read in
exactly one place, the guard at the top of `downloadDiskFromSettings`.
`fetchCatalog` and `adoptIndex` never consult it, so an unverified index still
names the URL and the SHA-256 the catalog hop is checked against — and on
success `adoptCatalog` clears the flag and `saveCatalogToCache` stamps those
bytes as this app's own.

The reachable shape: `Documents/Disks/index-v0.json` is user-writable over
`UIFileSharingEnabled`. Edit its `catalog_url` and `catalog_sha256`, then get
the index hop to fail while the catalog host stays reachable — a 5xx on that one
asset, a partial outage, a captive portal that lets the CDN through — and the
app adopts the substituted catalog, marks it verified and installs images
checked against that document's own hashes.

**What keeps this out of proportion is who can do it.** Anyone who can rewrite
`index-v0.json` can also drop a `.img` straight into `Documents/Disks`, which
is the argument the CHANGELOG already makes for booting from images already on
the device. So this is a gap between the defence and its own description, not a
new way in.

**Do not "fix" it without the controlled-network check.** The obvious repair —
`guard !catalogIsUnverified` at the top of `fetchCatalog` — is one step from the
mistake this feature already made once and recorded: the first version refused
an unstamped cache outright, and that cost the launch with no connection, which
is the only launch the cache is load-bearing on. A guard on the second hop can
leave a user whose index asset is merely flaky with a picker and no catalog.
`MANUAL_CHECKS.md` has the checks that would settle it; `todo.txt` has the item.

### The cache stamp is a boundary on iOS only

The saved catalog and the saved release list are checked against a size and a
SHA-256 recorded in `UserDefaults` when the verified fetch wrote them
(`CachedCatalog` in `CatalogDocument.swift`). That works because the two cache
files are in `Documents/Disks`, which this app publishes over
`UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, and
`UserDefaults` is in `Library/Preferences`, which it does not. On iOS those are
two different levels of access, which is the whole point: a catalog names both
the `base_url` each disk image comes from and the `sha256` it is checked
against, so an edited one is verified against its own hash and reported as good.

**On Mac Catalyst they are not.** The preferences plist sits in the same app
container as the Documents directory and anyone who can edit one can edit the
other, so on the Mac the stamp is a consistency check — it catches a truncated
or half-written file — and not a boundary. It is written down here rather than
implied away in a comment, because "verified" in a log line reads the same on
both platforms.

Not worth closing with a keychain-backed stamp or a signature. Whoever can edit
the preferences plist on a Mac can also edit the 49 MB disk images sitting beside
the catalog, and those are what the catalog's hashes exist to protect — so on
that platform the gate would be guarding a door in a wall that is already open.
The iOS case, where Documents is reachable from the Files app and preferences are
not, is the one that is worth a stamp, and it is the one it defends.

### An upgrade cannot download until the catalog has been re-fetched once

The stamp above did not exist before this build, so every install has a cache
file and no record of what it should be. That is the `unverifiable` verdict: the
saved catalog is **used**, so the device still boots offline from the images it
already has, but it is marked untrusted and no new transfer will start from it.
The first launch with a connection fetches, verifies, writes the stamp and ends
it permanently.

**This entry said the opposite until it was measured against a user.** The
verdict originally declined to adopt an unstamped cache, on the reasoning that
"declining costs one launch" where deleting could not be undone. Both halves of
that were wrong. The launch it costs is the launch with no connection — the only
launch the cache is load-bearing on at all — so a device that had been booting
offline for weeks would have taken the update and then found `diskCatalog` empty
and `start()` refusing, with every byte it needed sitting on it. Declining and
deleting differed in how long the damage lasted, not in what it was.

What an edited catalog actually buys its editor is the pair of fields a transfer
needs: the `base_url` it goes to and the `sha256` it is judged against. That is
the capability withheld, by `catalogIsUnverified`, and it is withheld only until
one fetch succeeds. Booting from images already on the device concedes nothing:
whoever can rewrite the cache can rewrite the 49 MB images beside it.

Only a stamp that is PRESENT and disagrees declines and deletes the file,
because that is the one case where the bytes can be proven not to be this app's.

## Releasing

### The Store offers this app on visionOS, and nothing here has ever met one

Measured 2026-09-21 off the storefront page for trackId `6756590871`, which is
the single record this app has: under Compatibility it lists **iPhone**, **iPad**,
**iPod touch**, **Mac** (macOS 12.0+) and **Apple Vision** (visionOS 1.0+).
The first four are intended.  The fifth is not something this repository builds
for.  `git grep -i visionos` matched NOTHING at all until 2026-09-21, when the
Store listing was read for the first time; what it matches now is this entry,
the `[RELEASE]` item in `todo.txt` asking for the checkbox to be decided, the
note beside the lookup in `tools/check-store-version.sh`, and the two places
that enumerate platforms and now say the list is short - `README.md` and
`docs/appstore.txt`.  Every one of them records the LISTING.  None of them
claims the platform, and none may start to before a person decides it.

It is not a build anyone here made.  `TARGETED_DEVICE_FAMILY` is `"1,2"` and
`SUPPORTS_MACCATALYST = YES`; no xrOS slice is produced.  What reaches Vision
Pro is the unmodified iPad app, through the "Make this app available on Apple
Vision Pro" setting in App Store Connect, which is **on by default** and which
no session can see or change.

So the platform count in this repository's own prose is wrong in the same
direction every time it is written: "iOS and Mac Catalyst" describes what is
BUILT, and one more thing than that can be installed.  Nothing about the app is
known to be broken there - a CP/M terminal in a window is close to the best case
for a compatible iPad app - and nothing about it is known to work either.

**It is one checkbox, and the decision is a person's.**  Either turn it off in
App Store Connect, or leave it on and say so where the platforms are listed.
Do not quietly start claiming visionOS support on the strength of the listing:
that is the same mistake as reading a submission as a release.

### No session can upload, whatever the toolchain here can do

Not a bug and not a task — a standing fact, re-checked at build 58, at build 61,
and again at build 67.

**Build 61 was uploaded on 2026-09-04 and that does not contradict this entry.**
It was submitted by a person with App Store Connect credentials, not from a
machine a session was running on and not by any session.

**Whether Xcode is present is a property of the machine, and it changes.**  Do
not record it here.  Builds 62 to 66 were written where there was none; build 67
was built on a Mac with Xcode 26.6, for the iOS Simulator, for an arm64 device
and for Mac Catalyst, and driven on a simulator.  Both readings were correct on
the day they were made, and this entry has flip-flopped with them twice.
`CLAUDE.md`'s "Whether Xcode is here is a fact about the machine" section has the
one command that settles it — the trap being that bare `xcodebuild` prints the
same "requires Xcode, but active developer directory ... is a command line tools
instance" line whether Xcode is merely **unselected** or genuinely **absent**,
and only `ls -d /Applications/Xcode.app` tells the two apart.

**What an archive could never do, and this half has never changed and is the
point of the entry.** `xcodebuild archive` succeeds for `generic/platform=iOS`,
but it signs with the **`Apple Development`** identity, which cannot be exported
for the App Store. An upload needs three things that have never been on any
machine a session has run on: a distribution certificate, an App Store
provisioning profile, and an App Store Connect API key.

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
