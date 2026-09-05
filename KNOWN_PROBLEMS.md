# Known Problems

## Disk Creation

### Limited Disk Size Support
New disks created in the app are always 8 MB (`EmulatorViewModel.defaultDiskSize`).
`createNewDisk(at:size:)` takes a `size:` argument, but no caller passes one and there
is no size picker in the UI. Imported disks are accepted up to 64 MB (`maxDiskSize`).
Need a size chooser so disks of arbitrary/correct sizes can be created.

A size chooser is not enough on its own, because the size is hardcoded in **two**
places and `defaultDiskSize` is only one of them. Creating a disk runs a
`.fileExporter` whose document is `EmptyDiskDocument` (`ContentView.swift`), and
its `fileWrapper` writes its own `Data(repeating: 0xE5, count: 8 * 1024 * 1024)`
with no reference to `defaultDiskSize` at all; `createNewDisk` then overwrites
that file with a second 8 MB buffer. Whoever adds the picker has to feed both, or
the exporter will lay down 8 MB and only the rewrite will honour the choice.

### Proper Disk Initialization
When creating a new disk, it should be properly initialized with:
- Correct magic numbers for the disk format

### Creating Disks on Linux (Workaround)

The app can create a blank disk in place (Settings -> Disk N -> "Create New..."), but all
it produces is an 8 MB image filled with 0xE5 - it does not lay down an HD1K filesystem.
For a properly formatted image, or a multi-slice one, build it on Linux with cpmtools.

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

**Build 63 narrowed the trigger again, to nothing on the XML catalog.** `checkCatalogGenerationAndInvalidate` (`EmulatorViewModel.swift`) replaces it and acts only on the interface-v0 catalog's `generation`, under a key scoped per (interface, RomWBW release). `disks.xml` carries no generation, so a build 63 device is not reachable this way at all — and the old `catalogVersion` value is deliberately not copied into the new key, because 13 ≠ 1 would have made the first v0 fetch delete the whole library. Every build in service still reads the attribute, so it is no less dangerous to move.

**Build 64 turns it back on, deliberately, against `generation`.** The v0
catalogs do carry one, so a generation bump in `romwbw_disks` now clears the
images that release names on every migrated device — still only the ones the new
catalog can hand back, still per (interface, RomWBW release), and still never a
disk the user imported. Switching releases is not a bump and clears nothing: the
stored generation is per release, so 3.5.1 → 3.6.0 → 3.5.1 deletes nothing,
which the single `catalogVersion` key could not manage. The publishing rule is
now upstream's: advancing a `generation` is a destructive act on installed
devices, and `romwbw_disks/docs/CATALOG_SCHEMA.md` §4 is where it is defined.

**Narrowed in build 56, and only for build 56 and later.** `deleteCatalogDisks(named:)` now deletes only the `.img` files the *new* catalog lists, which is the test for whether deleting one is recoverable: a disk the catalog does not name — one imported through Files, one `createNewDisk` made — cannot be fetched back from anywhere, and is kept. The alert says how many of each. Before that, `deleteAllDownloadedDisks()` took every `.img` in `Documents/Disks` regardless.

**The builds in service still have the old loop.** The App Store serves 1.4.9 (builds 36/37); those also fetch the catalog from `releases/latest/download/` rather than from the pinned tag, so for them a *normal* release fires the old wipe immediately. That is why the release order in `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md` still governs, and why `--prerelease` on an asset carrier is load-bearing rather than cosmetic. The rules that came out of doing it are in `docs/DISK_W8FIX_RUNBOOK.md`, in the SUPERSEDED block at the top. The "1.4.9" in this paragraph is a measurement with a date on it, not a constant: re-derive it with `tools/check-store-version.sh` before relying on it.

**Build 61 adds the refresh the version attribute could never safely provide, and it is deliberately narrower than a wipe.** `DiskLedger.swift` records, per filename, the catalog `<sha256>` that a *verified* download matched. "Superseded" then means *that recorded provenance differs from the catalog's current hash* — a fact about which published image the bytes came from, which local writes cannot change. That is what lets a respun image reach a device that already has the old one without the version attribute moving at all.

The reason it is keyed on provenance and not on the file's own hash is this entry. Comparing installed bytes against the catalog classifies **every disk the user has saved work into** as stale, because `saveDownloadedDisks()` writes the running machine's image back over the file on every warm boot and every backgrounding. An automatic refresh keyed on that comparison would be precisely this entry's hazard, automated and unprompted. So an image proven pristine — its bytes still hash to the provenance recorded for it — may be refreshed automatically, and only on an unconstrained, inexpensive network. Anything else is offered as a button that says in as many words that files saved inside the disk will be lost. An install with no ledger yet cannot prove pristineness either way, and therefore never takes the automatic path.

**Still open, and not foreclosed by the narrowing or by build 61:**
- Copy-on-write: create a local copy when the user first modifies a downloaded disk. This is the only one that helps a user who kept data *in* a catalog disk, which is what the paragraph at the top of this entry is about. Build 61 warns before replacing such a disk and never replaces one unasked; it still cannot preserve the contents.
- Confirm before the wipe, rather than reporting it afterwards. The version-attribute path is unchanged and still reports afterwards; only the new provenance path asks first.
- None of it reaches the builds in service. 1.4.9 has neither the narrowing nor the ledger.

## Interface v0

### The release picker offers a release this build has no ROM for

Build 64 offers every RomWBW release the emulator core can run — 3.5.1 and
3.6.0 today. The app still boots the ROM in its **bundle**, which is 3.5.1's, so
choosing 3.6.0 gives a machine whose disks and ROM disagree and whose guest
prints `*** WARNING: HBIOS/CBIOS Version Mismatch ***` at boot. The picker says
so, naming the ROM the selected release publishes, and nothing is lost by trying
it: every store is per release and switching back restores everything.

The fix is downloading the release's own ROM, and it is deliberately not in this
build. `loadROMFromPath:` and `loadROMFromData:` already exist on the bridge and
are already on the live path, so what is missing is a caller that hands them a
downloaded path, the UI to fetch one, and a decision about
`docs/ROM_ATTESTATION.md` — an App Store filing that names `emu_avw.rom`
specifically. Removing the bundled ROM is not an option on its own: an app whose
only ROM is a download cannot boot on a first offline launch.

### `tools/check-disk-pins.sh` no longer answers for this port

Its question — does the disk image users download carry the current R8/W8 — was
asked by finding a `vX.Y.Z` pin in each client's source and fetching that tag's
`disks.xml` from `avwohl/ioscpm`. A migrated client has no pin and does not read
that repository at all, so for iOSCPM the script now reports `MIGRATED`, skips
it, and exits 2 (`CANNOT VERIFY`) rather than either failing a correct tree or
passing quietly. **It still answers for cpmdroid and z80cpmw**, and it must be
taught the v0 index before either of them migrates, or it will be answering for
none of them. The v0 form of the question is "does the `generation` the index
publishes match what this build would download", against `avwohl/romwbw_disks`.

`CLAUDE.md` still tells a reader that bumping the pin means editing `releaseTag`
in `EmulatorViewModel.swift`. That constant is gone. The sentence needs a
human's edit; no session made it.

## Releasing

### This machine can archive but cannot upload

Not a bug and not a task — a standing fact about the toolchain, re-checked at
build 58 and again at build 61.

**Build 61 was uploaded on 2026-09-04 and that does not contradict this entry.**
It was submitted by a person with App Store Connect credentials, not from this
machine and not by any session. The sentence below is about what the toolchain
*here* can do, and it is unchanged.

**This entry was the only one in the repository that was right about the
toolchain.** `CHANGELOG.md`, `WIP.md` and `todo.txt` all claimed for three builds
that there was no Xcode here and nothing could be compiled, which contradicted
the sentence below and was false — `xcode-select` merely points at the Command
Line Tools. Prefix with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; no `sudo` required. `xcodebuild archive` succeeds for `generic/platform=iOS`, but it signs
with the **`Apple Development`** identity, which cannot be exported for the App
Store. An upload needs three things that are not on this machine: a distribution
certificate, an App Store provisioning profile, and an App Store Connect API key.

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
that flag follows `modalHasKeyboard` (`ContentView.swift`), which names the
three dialogs drawn over the terminal: the disk-overwrite warning, the error
alert and the reset confirmation. While one of them is up, Escape and Return
reach the dialog instead of the guest, which is the point. Sheets are
deliberately not in it - they cover the terminal and present their own
responder. **A fourth dialog added over the terminal and not added there loses
Escape and Return to the guest**, silently and only while it is on screen.

The 26 Ctrl+letter `UIKeyCommand`s in the same `keyCommands` (the
`"abcdefghijklmnopqrstuvwxyz"` loop) are also what is expected to keep AppKit
emacs `StandardKeyBinding` bindings away from the guest under Mac Catalyst:
`TerminalUIView` is a plain `UIView` + `UIKeyInput`, not a `UITextInput`
responder, so those bindings should not apply to it at all, and the key
commands sit on the first responder UIKit consults first. Reasoned, never
watched - `MANUAL_CHECKS.md` has the WordStar pass that would settle it.
