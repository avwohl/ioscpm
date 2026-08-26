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

The trigger is broader than a download, and the user does not have to do anything at all. `disks.xml` carries a `version` attribute; on every successful catalog fetch, `checkCatalogVersionAndInvalidate` (`EmulatorViewModel.swift`) compares it against the stored `catalogVersion` and, on any difference, calls `deleteAllDownloadedDisks()` - which removes every `.img` in `Documents/Disks` and then shows an alert saying it has happened. That loop is not restricted to catalog filenames, so it also takes disks the user imported through Files and disks `createNewDisk` made in the app, neither of which can be re-downloaded. Publishing a refreshed catalog is therefore destructive on every installed device, with no confirmation beforehand. See `todo.txt`: this is the second data-loss path on the same release step the `releaseTag` block guards, and deciding what should happen instead is what blocks it.

**Potential solutions to consider:**
- Copy-on-write: Create a local copy when user first modifies a downloaded disk
- Separate user disks from system/downloaded disks
- Confirm before the version-change wipe, and spare anything the catalog does not name

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

### Nav keys ignore their modifiers
`pressesBegan` excludes only Command before resolving `specialKey(for:)`, which
switches on the HID usage alone, so Ctrl+Left and Shift+Up emit the same bytes
as the bare key. This was cross-port behaviour when the entry was written; it is
not any more. z80cpmw's key map grew modifiers - `TerminalView.cpp` builds a
modifier mask and calls `m_keymap.find(wParam, mods)`, and `Keymap.h`'s defaults
bind Ctrl+Up / Down / Right / Left to the xterm forms `\E[1;5A`..`D`. ioscpm is
now the port without it.

The binding schema here has no slot for a modified variant: `SpecialKey` is a
flat 22-case enum - ten nav keys and F1-F12, every one of them unmodified - and
`KeyMap.bindings` is `[SpecialKey: String]`, and none of the WordStar / VT100 /
VT52 profiles defines a modified arrow. Adding one is a schema change.

Open, small, and a choice rather than a gap, because the two siblings disagree
on what these keys should send. `cpmemu`'s Windows console translates
Ctrl+Left/Right/Up/Down to ^A / ^F / ^W / ^Z - WordStar word left, word right,
scroll up, scroll down - in the `extended_keys` table of
`src/os/windows/platform.cc`. z80cpmw sends the xterm modified forms above,
though its own comment offers `"Ctrl+Left": "^A", "Ctrl+Right": "^F"` as one
line of config. All four WordStar bytes are already reachable here by typing
Ctrl+A / Ctrl+F / Ctrl+W / Ctrl+Z, so nothing is unreachable. If a binding is
ever wanted, it is four more `SpecialKey` cases plus defaults for stored custom
profiles, after picking a convention - worth doing only the next time the
keyboard settings screen is open, and on iPadOS only, per the Mac Catalyst note
below. See `todo.txt`.

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
in the app rejects them: the nav branch excludes only Command. On iPadOS, where
the system does not claim them, they resolve to the plain arrow binding as
described above.
