# Changelog

## Version 1.5.1 (Build 57)

Scrollback has been in the app since build 42 and has never captured a line of
ordinary output. Found by instrumenting a Catalyst build and driving it: boot
CP/M 2.2, run `DIR` six times, watch the screen scroll seven lines - and watch
`scrollUp()` get called zero times.

`Tests/run_tests.sh`: 350 checks, all passing. `xcodebuild` clean for Mac
Catalyst, and this time the app was launched, booted and scrolled rather than
merely built.

### The line feed threw history away

`scrollRegion()` shifts rows and blanks the bottom of a region. `scrollUp()` does
that *and* pushes the departing lines into `scrollbackLines`. The escape-sequence
scroll handler chose between them correctly - whole screen to `scrollUp`, partial
region to `scrollRegion` - but the LF handler (`case 0x0A`) called
`scrollRegion(scrollTop, scrollBottom, 1)` unconditionally. With the default
region of the whole screen, which is the state the terminal is in essentially
always, every newline-driven scroll discarded its top line. That is nearly every
scroll there is, so the buffer stayed empty, `adjustScrollback` clamped every
gesture to an offset of 0, and the feature was invisible from the outside.

The test now lives in `scrollRegion()` instead of at the call sites: a region
that *is* the whole screen delegates to `scrollUp()`. One rule, and a third call
site cannot reintroduce the bug. The two implementations were otherwise
identical for the full-screen case, so nothing else changes.

### The wheel could not scroll either

Two independent defects in `handlePan`, both of which would have kept the wheel
dead even with a full buffer:

- It converted the gesture's pixel translation to whole lines with
  `Int(translationY / rowHeight)` and reset its bookkeeping on `.ended`. A scroll
  wheel arrives on Mac Catalyst as an indirect-scroll pan, one short gesture per
  notch, and a notch is a fraction of a row - so the truncation yielded 0 and the
  remainder died with the gesture. The remainder now survives, and indirect
  scrolls get 3 lines per notch, matching the Windows port's `WM_MOUSEWHEEL`
  (`z80cpmw/TerminalView.cpp:604-611`). A finger or pointer drag stays 1:1.
- `rowHeight` was `bounds.height / rows`, but `draw(_:)` letterboxes the grid
  with a uniform `min(scaleX, scaleY)`. Where width binds - every portrait
  layout, any tall Mac window - the pan step exceeded the row actually drawn.
  `drawnRowPitch` is now the pitch on screen.

### The status bar says how much history there is

`sb <offset>/<available>`. `sb 0/0` after a boot and a couple of `DIR`s is the
symptom of this bug, and there was previously no way to tell it apart from the
scroll input being broken - which is what made the diagnosis take three passes.

### Selection, and a copy that copies what you selected

There was no selection at all: `copyText()` copied the entire visible screen and
nothing less - no anchor, no drag, no highlight - while z80cpmw has had real
click-drag selection since the beginning (`TerminalView.cpp:913-967`). A pointer
drag now selects, the highlight is drawn under the glyphs so guest colours stay
readable, and Cmd+C (and the long-press menu's new **Copy**) copies the
selection when there is one, falling back to **Copy All** when there is not.

The span is linear rather than rectangular - anchor cell to focus cell, wrapping
at the row end - so copying a wrapped line gives you the line. Because the
selection reads the cells that are *on screen*, it copies out of scrollback when
the view is scrolled back. A click clears it, and so does scrolling: the
selection is in screen coordinates and the content underneath is about to move.

Telling a drag from a wheel turned out to be the hard part. `allowedTouchTypes`
does not separate them - a Catalyst pointer drag matches neither `.direct` nor
`.indirectPointer` - and neither does `numberOfTouches`, which is 0 for a
pointer drag there, exactly as it is for the wheel. What does separate them is
that a scroll never delivers a `UITouch` at all, so
`TouchAwarePanGestureRecognizer` records whether `touchesBegan` ever fired. On
iOS a finger drag is the only way to scroll, so it keeps that job; the split is
Mac-only.

### Still missing, and not Mac regressions

- **No scrollbar,** in any of the three GUI ports.
- **The Settings gear is `.disabled(viewModel.isRunning)`** (`ContentView.swift:149`),
  so the Scrollback picker cannot be reached while the machine is running.

### Why the parity table said this was done

`z80cpmw/FEATURE_PARITY.md:1085` scores scrollback ✅ for ioscpm. The cell was
flipped in `d630619`, twelve minutes after ioscpm's `b703acf`, from a paraphrase
of that commit message - no ioscpm symbol was ever read. The check compares
commits, never artifacts and never behaviour, so "the code exists" and "the
feature works" were the same statement to it. All three gaps above - capture,
wheel, selection - are visible in a side-by-side source reading, and none of them
needed a device to find.

## Version 1.5.1 (Build 56)

The `[DECISION]` item that has been sitting on the release order since build 52,
taken. Also the bug that would have made taking it pointless.

`Tests/run_tests.sh`: 348 checks, unchanged and all passing - none of this is
reachable from a suite with no app around it. `xcodebuild` clean for the iPhone
17 Pro simulator and for Mac Catalyst.

### A catalog bump no longer deletes disks the catalog cannot give back

`disks.xml` carries a `version` attribute. On any change to it,
`checkCatalogVersionAndInvalidate` called `deleteAllDownloadedDisks()`, which
removed **every** `.img` in `Documents/Disks` - including disks the user imported
through Files and disks `createNewDisk` made in the app, neither of which any
catalog can restore - and said so afterwards. It needs no tap and no download, so
publishing a refreshed catalog was destructive on every installed device at once.

`deleteCatalogDisks(named:)` deletes only the images the **new** catalog lists.
That set is the whole safety property, and it is the right test rather than a
convenient one: "can this be fetched back" is a question about the catalog that
is about to be in force. So an imported disk is kept, an app-created disk is
kept, and an image *dropped* from the catalog in the same bump is kept - nothing
can re-fetch that one either. The match is case-insensitive, because `Documents`
is published to the Files app on a case-insensitive volume and a user's
`HD1K_COMBO.IMG` must not be a catalog disk on one device and their own on
another.

`todo.txt` listed four options and this is the least destructive of them. It
forecloses none of the others - a confirmation step or copy-on-write can still go
in front of it - and copy-on-write stays open in `KNOWN_PROBLEMS.md` as the only
one that helps a user who kept data *inside* a catalog disk.

**What this cannot fix.** The App Store serves **1.4.9**, which is builds 36/37.
Those predate the catalog pin (build 42) *and* this narrowing, and they fetch the
catalog from `releases/latest/download/` rather than from a tag, so for every
device actually in service a normal release still fires the old whole-library
loop. The release order and the `--prerelease` flag it depends on are unchanged;
`docs/DISK_W8FIX_RUNBOOK.md`, `docs/DISK_DISTRIBUTION.md` and
`KNOWN_PROBLEMS.md` all now say which builds have which behaviour.

### The alert saying so had never once appeared

Found while watching the change above work: the disks were cleared and **no
alert came up**, and the status line read "Ready - Press Play to start".

- **Two `alert(isPresented:)` modifiers were chained on the same view** - the
  error alert and the manifest write warning - and only one per view is ever
  honoured, so the later modifier replaced the earlier and `showError()` put up
  nothing at all. Every error this app has ever raised through that path went to
  the screen the manifest warning was already using. Both pairs (`ContentView`
  and the settings sheet) move to the iOS 15 `alert(_:isPresented:actions:message:)`
  API, which stacks. The deployment target has been 15.0 throughout.
- **`statusText` was overwritten a few lines later.** `restoreDiskSelections()`
  ends by setting it to "Ready - Press Play to start", and it runs immediately
  after the invalidation check. The check now returns its notice to the caller,
  which applies it afterwards.
- **The alert is no longer headed "Error"**, because nothing went wrong. A
  `showError(_:title:)` parameter defaulting to `"Error"` lets this one say
  "Disk Catalog Updated"; every other caller is unchanged and really is an error.

The message gives both counts and gets the singular right: *"The disk catalog has
been updated. 1 downloaded disk was cleared and needs to be downloaded again. 2
disks that are not in the catalog — ones you imported or created — were left
alone."* When nothing was cleared it says nothing at all, rather than telling a
user who has only ever imported their own disks that something happened to them.

### Verified

Driven on the iPhone 17 Pro simulator by editing the stored `catalogVersion` in
the app container's preferences and relaunching against the live `v1.4.5`
catalog, with four files in `Documents/Disks`: `hd1k_combo.img` and
`hd1k_zsdos.img`, which the catalog names, and `myown.img` and `scratch2.img`,
which it does not. The two catalog disks were deleted, the two others survived,
the alert appeared with the right heading and the right counts, and the status
line kept its message. Repeated with one of each to check the singular.

Not verified: no device, and Catalyst was built but not launched. Nothing has run
this against a catalog whose `version` genuinely moved rather than a stored
default edited from underneath the app, and nothing has cleared a disk that was
selected in a slot or running at the time. `MANUAL_CHECKS.md` gains a section.

### The published help is current again — all eight files, not two

This was done twice, and the first attempt is worth recording because it is the
failure mode of working from a stale checkout.

Two files - `help_quick_start.md` and `help_file_transfer.md` - were uploaded to
`v1.4.11` from `release_assets/` after checking them against the live release.
They were an improvement and they were **not current**: `7569745` ("The shared
help assets stop being written for iOS only", 2026-08-28) had rewritten all eight
on `origin/main`, which this checkout did not have. The published set then held
two files at one vintage and six at another.

All eight - `help_index.json` and the seven topics - are now uploaded from the
post-rebase tree and confirmed byte-identical through the release API. The topic
set is unchanged, so no file was added or orphaned. `releases/latest` is still
`v1.4.11` and `v1.4.12` is still a prerelease; both were checked afterwards.

The text is worth having: a networked user no longer reads "Press Ctrl+E to
access the emulator console" for a console that does not exist, or the old app
name and bundle id, and the drive-letter table now describes what RomWBW actually
prints - which is the map this build watched it print. Note that
`releases/latest/download/` serves these through a CDN that was still handing
back the old bytes minutes after the upload; verify through
`repos/.../releases/tags/v1.4.11` rather than the redirect.

`--clobber` is correct for help text on the Latest release and remains forbidden
for disk images; the runbook says which is which. These assets are shared with
the sibling ports, which fetch help from this repo's release, so the upload
reaches `cpmdroid` and `z80cpmw` users too - which is what `7569745` was for.

### The branch had moved, and this build is the first to compile what was on it

`origin/main` had six commits this checkout did not, written on another machine
today. Two of them fixed things this build had also fixed - the download checksum
and the runbook - and theirs are the ones in the tree; build 55's entry above says
where and why. What this build adds is that they now have a compiler and a
simulator behind them.

`066d00c` says "NOT COMPILED - there is no Swift toolchain on the machine this
was written on". It compiles, for the simulator and for Mac Catalyst, with no new
warnings, and it was driven end to end: `Documents/Disks` emptied, the app
launched, Play pressed, and the 49 MB combo downloaded, verified and installed.
The installed file hashes `be19984e…`, which is what the pinned `v1.4.5`
`disks.xml` names for it, and it booted to `Boot [H=Help]:` and on to CP/M 2.2.
Under that implementation an image only reaches `Documents/Disks` after the
**temp** file's hash matches, so an installed disk is a passed check.

## Version 1.5.1 (Build 55)

A cross-port sync. Four of the five sibling repositories moved between
2026-08-27 and 2026-09-01 - `romwbw_emu` to 1.38, `cpmemu` to 4.7.2, `cpmdroid`
to 1.24, `z80cpmw` through its per-cell attribute work - and this build takes
what those turned up, closes two `todo.txt` items outright, and corrects two
documents that were telling a reader to do something forbidden.

**Two of these had already been fixed on `origin/main` while this was being
written**, from another machine and in a session this one could not see: the
download checksum (`066d00c`) and the runbook's forbidden upload recipe
(`55acbb5`). Both of those are theirs in the tree - they landed first and are
better - and this entry says so where it used to claim them. The rest below is
this build's.

**The shared core needed nothing.** `iOSCPM/Core/` is 21 symlinks into
`../romwbw_emu/src` and `../cpmemu/src`, so the core moved under this repo on its
own; `qkz80` has not changed since 2026-08-26, and the `romwbw_emu` commits since
build 54 are a narrowing-cast sweep, CI, and documentation. The tree builds clean
against 1.38 with no port-side change, which is what `Tests/run_tests.sh`'s
`CoreSymlinks` and `CoreKeyboardTests` pair exists to prove.

`Tests/run_tests.sh`: 348 checks across seven suites plus the two `CoreSymlinks`
shape checks, all passing. 253 before, and build 54's entry below says 251 -
that entry undercounted `CGAColorTests` by two, which was checked by compiling
that suite at `0dbab43` and running it: 73, not 71. `TerminalRenditionTests` is
new and contributes 95. `xcodebuild` clean for the iPhone 17 Pro simulator with
no new warnings. Installed on that simulator, booted the Combo disk to CP/M 2.2, and
drove every sequence below through `R8` + `TYPE`.

### The terminal was the last port without the bright half

`ESC[91m` did nothing at all. `applySGR`'s whole switch was `0`, `1`, `22`, `7`,
`27`, `30...37`, `40...47` and `default: break`, so the bright ranges fell
through and the text drew in whatever was current - from a fresh reset, CGA 7,
which is indistinguishable from asking for no colour. `z80cpmw` closed this on
2026-08-28 with a suite that reads pixels, `cpmdroid` has carried `90-97` since
its own ANSI fix, and `z80cpmw`'s `FEATURE_PARITY.md` named this port as the one
without it.

- **`90-97` set the ANSI colour and the intensity bit**, masking with `0xF0`
  rather than `0xF8`: the bright bit *is* the intensity bit, so a bright colour
  sets what `SGR 1` would have set. Preserving bit 3 instead would leave `ESC[22m`
  unable to dim a colour that was asked for bright.
- **`100-107` fold onto the plain background.** The background nibble is three
  bits and the fourth is blink on real CGA hardware, so a bright background can
  only be stored by borrowing it. A wrong shade beats a cell that starts
  strobing. `z80cpmw` folds them the same way; `cpmdroid` keeps them bright
  because a cell there is a full ARGB value with no blink bit to borrow.

### `ESC[38;5;44m` was setting a red background

The SGR loop acted on every parsed parameter in turn, so the sub-parameters of
the extended-colour forms were read as colour codes in their own right: the `44`
of `ESC[38;5;44m` landed as `SGR 44`. Both forms - `;5;<index>` and
`;2;<r>;<g>;<b>` - are now stepped over. The value is discarded rather than
approximated onto the CGA palette, because both siblings discard it and a port
that guessed a nearest entry would put a colour on screen that no other port
shows for the same bytes.

`SGR 39` and `SGR 49` also arrive, which `cpmdroid` has and `z80cpmw` does not.
Both preserve the intensity bit, for the same reason `30-37` do: bold and bright
are one bit inside a packed byte, and the alternative would make `ESC[1m ESC[39m`
silently drop the bold.

### A cell can hold a face now

`SGR 1`, `4`, `5` and `7` were parsed into a single intensity bit and nothing
else, so underline and blink were accepted and dropped. `TerminalCell` gains a
`flags` byte carrying `CellFlags.bold` / `.underline` / `.blink` - z80cpmw's
`TCELL_*` values byte for byte, and `cpmdroid`'s, so a cell from any of the three
ports can be compared with another's.

- **Bold draws in a second `UIFont`**, because that is the only way UIKit can
  vary weight for a single `draw(at:)` - z80cpmw keeps four `HFONT`s for exactly
  the same reason. The grid is still measured from the plain face alone, so a
  wider bold face cannot move it, and every glyph is positioned individually, so
  it cannot smear either.
- **Underline is the attributed string's own rule, in the glyph's colour.**
  Without `.underlineColor` it draws in the label colour, which is near-white on
  this black view whatever the text is.
- **Blink shares one phase, and the phase only exists while something asks for
  it.** There was nothing to hang it on: this port's cursor is a solid block and
  does not blink, where z80cpmw shares the cursor's 500 ms timer. `syncBlinkTimer`
  creates a timer when a blinking cell is on screen and tears it down when the
  last one goes, so an ordinary CP/M session costs exactly what it did before -
  no timer, no repaint. The off phase keeps the cell's background and loses the
  glyph, and loses the underline with it, which is what z80cpmw's rendering suite
  pins.
- **An erase zeroes the flags and keeps the colours.** Underline and blink are
  visible on a space, so carrying them through `ESC[4m ESC[2J` would underline
  all 2000 cells. `blankCell` is the one site and z80cpmw zeroes at the same one.
- **Reverse video stays out of the byte.** It is resolved into the two nibbles at
  the write, which is what makes `SGR 7` and `27` exact inverses; the bold flag is
  also the only record of bold that survives that swap, since the intensity bit
  falls off the end of a three-bit background.

### Three CSI sequences ended early and printed their own tails

`processCSIChar` treated every non-digit, non-`;`, non-`?` byte as a FINAL
character. So:

- **`<`, `=` and `>`** - the secondary and tertiary device-attribute forms and
  xterm's `modifyOtherKeys` - ended the sequence at the marker. `ESC[>c` printed
  `c`; `ESC[>4;2m` printed `4;2m`. They are private-parameter markers now, the
  same set `z80cpmw` learned when `?` had the identical bug there, and the `n`
  and `c` answerbacks were already guarded on `escapePrivateMode` so the private
  forms stay deliberately silent.
- **Intermediate bytes, space through `/`**, did the same. `ESC[!p` (DECSTR) and
  `ESC[<n> q` (DECSCUSR, which is what a program sends to choose a cursor shape)
  both terminated at the intermediate and left their final byte to print as a
  glyph.
- **`m` under a private marker** now does nothing. Without the guard, a bare
  `ESC[>4m` reached SGR as `ESC[m` and reset the whole rendition.

### The SGR half of the parser has tests

`todo.txt` has carried "the CSI parser has no unit tests" since build 51, and
build 54's colour bug was found by looking at a simulator. `TerminalRendition` is
split out of `EmulatorViewModel` for the reason `TerminalDialect`, `ControlKey`,
`ExportPath` and `CGAColor` were: it is a pure value with no screen behind it, so
`Tests/TerminalRenditionTests.swift` can drive the whole of `CSI ... m` with 95
checks and no display. The rest of the parser - the cursor, the scrolling region,
the erase family - is still untested, and the item stays open for that half; the
private-marker fixes above are in it and were checked with a screenshot.

### Downloads are verified, and that fix came from the other machine

`066d00c` landed the SHA256 work on `origin/main` while this build was being
written here, and it is the better of the two. It went in first and this build
carries it unchanged; what was written here is discarded. Three things it does
that the version drafted here did not, all of them mattering:

- **It hashes the temp file *before* the destination is touched.** The version
  here moved the file in and hashed it afterwards, so a corrupt or truncated
  download deleted the good disk the user already had and left nothing in its
  place. `Documents/Disks` holds disks the user imported and disks the app
  created, and a downloaded disk is where their CP/M work lives.
- **A catalog entry with no `<sha256>` is refused, not accepted.** Treating a
  missing hash as "assume ok" - which is what was written here, on the grounds
  that the field has always been optional - makes the whole check optional at
  the catalog's choosing. All 20 entries in the pinned `v1.4.5` catalog carry
  one, so an entry without is degraded or hostile.
- **The catalog's `<filename>` is checked for being a plain leaf.** It reaches
  `appendingPathComponent` and then `removeItem`, and that does not escape
  `..` - the same shape as the `W8` export bug this app shipped in build 51.
  That one was missed here entirely.

What this build adds to it is the thing its commit message asked for: **it is
compiled and run.** `066d00c` says "NOT COMPILED - there is no Swift toolchain on
the machine this was written on". It builds clean for the simulator and for Mac
Catalyst with no new warnings, and the app installs, launches, fetches the live
`v1.4.5` catalog and boots a downloaded disk. The rejection arms - a bad hash, a
missing hash, a non-leaf filename - are still unexercised and are in
`MANUAL_CHECKS.md`.

### R8 can be told which file it really read

`emu_host_file_get_read_name()` returned `""` unconditionally. The resolved path
was known only in Swift - `emu_host_file_open_read` hands a leaf to the delegate,
the Swift layer resolves it against `Imports` case-insensitively, and
`emu_host_file_load()` carried bytes and no name - so `R8`'s `Reading:` line
echoed the name the CCP shouted, which is a claim about the open assembled out of
the request. `cpmdroid` closed the identical gap in `167acbe`.

`emu_host_file_load_named()` carries the path down beside the bytes, absolute, as
the CLI's `realpath()` answer and the Windows port's are and as this port's write
side already was. It is stored in `g_host_read_filename`, returned while
`HOST_FILE_READING`, and cleared on open, close and cancel - none of which it was
before, so a name could have outlived its transfer.

**Measured, and recorded in the source rather than left to be discovered:** with
today's `R8` this usually still answers `""`, and that is correct rather than
broken. `R8` prints `Reading:` between the open and the first read, and an open
here only parks the request for the Swift layer's next main-queue turn - the
guest is rewound on `HBF_HOST_READ`, not on the open - so at the moment `R8` asks,
the state is `WAITING_READ` and `""` is the truth. Watched against a Combo image
whose `R8` does call `0xEA`: `R8 ESC.TXT` for a file stored as `esc.txt` printed
`Reading: ESC.TXT`. `cpmdroid` reaches the same answer through the same
asynchrony. Closing it properly means resolving at open time, which is a new
`todo.txt` item rather than a guess.

### A zero-byte file in Imports

`R8` on an empty file skipped the hand-off entirely: `baseAddress` is nil for an
empty `Data`, and the call was inside `if let ptr`. The backend stayed parked in
`WAITING_READ`. This is the read side of the hole the write side closed in build
53 (`romwbw_emu` v1.36, `cpmdroid` `c06fa58`) - an empty CP/M file is a real file.
`emu_host_file_provide_data` now guards the null pointer itself rather than
relying on every caller to, because `assign(null, null)` is undefined rather than
merely empty.

### Two documents were telling a reader to do the one forbidden thing

`romwbw_emu`'s `fce8f87` finished step 4 of the release order - the refreshed
images are published as **`v1.4.12`**, a prerelease, 29 assets, with the catalog
`version` attribute deliberately left at `13` so the invalidation wipe never
fired - and flagged this repo's `docs/DISK_W8FIX_RUNBOOK.md` as a live footgun
while doing it.

- **`docs/DISK_W8FIX_RUNBOOK.md`** said `gh release upload <tag> --clobber`,
  under a paragraph arguing against cutting a fresh tag, with its download step
  pulling from `v1.4.5`. Read together that is an instruction to overwrite the
  assets every installed client fetches. It was never run. **That correction is
  `55acbb5`'s**, which landed on `origin/main` first and is the fuller of the two
  - it carries the `--prerelease` rule, the post-publish gates, the
  `rebuild_disk_utils.sh` / `verify_disk_utils.sh` recipe and the
  `hd1k_combo_ioscpm_w8fixed.img` warning. Only one line written here survives
  alongside it: the download step no longer hardcodes `v1.4.5` as the tag to
  refresh from.
- **`todo.txt`**'s release item is rewritten around the correction that came with
  step 4, which matters more than the completion: the App Store serves **1.4.9,
  released 2026-03-19**, which is builds 36/37. Those predate the catalog pin
  (build 42) and fetch from `releases/latest/download/`, so for every device in
  service a *normal* release is fetched immediately and `--prerelease` is what
  actually protects them - load-bearing, not cosmetic. Step 5 stays blocked, and
  the blocker is the six-month gap between what the Store serves and what carries
  the sanitiser, not the pin.

### Also

- The two stale published help files were re-checked against
  `releases/latest`, and the finding stands: `help_quick_start.md` and
  `help_file_transfer.md` still differ from `release_assets/`, and the other five
  topics plus `help_index.json` are byte-identical. `todo.txt` now carries the
  exact command, and why `--clobber` is right for help text and forbidden for
  disk images.
- `z80cpmw`'s `FEATURE_PARITY.md` says `ioscpm`'s `clearTerminal()` resets the
  scrolling region on `ESC[2J`. That reading is stale: build 53's `0165dac` split
  `eraseScreen()` out of `clearTerminal()`, and `ESC[2J` has gone through
  `eraseScreen()` since - which does not touch the region. Nothing to fix here;
  noted so the next sweep does not re-file it.
- The bell is still not a setting. `cpmdroid` made it one and `z80cpmw` followed
  in `480edcb`; this port is now the only one without it, and it is a new
  `todo.txt` line rather than part of this build.

### Not verified

Nothing here has been run on a device, or under Mac Catalyst - the Catalyst
target was *built* clean (`-destination 'platform=macOS,variant=Mac Catalyst'`)
and not launched. The bold face,
the underline rule and the blink phase were watched on the iPhone 17 Pro
simulator only, where the font metrics and the timer are not a device's;
`MANUAL_CHECKS.md` gains a section for them. The SHA256 rejection arm has never
been driven against a genuinely bad download - only the passing arm, which is
every ordinary one - and that has its own section there too. `executeCSI` and
`processCSIChar` still have no tests of their own.

## Version 1.5.1 (Build 54)

One terminal bug, seen and filed during build 53's simulator pass and fixed
here, plus the second bug that was hiding inside the same expression.

`Tests/run_tests.sh`: 251 checks across six suites plus the two `CoreSymlinks`
shape checks, all passing (180 before; `CGAColorTests` is new and contributes
71). `xcodebuild` clean for the iPhone 17 Pro simulator with no new warnings.
Installed and run on that simulator: booted the Combo disk to CP/M 2.2 and drove
the escape sequences below through `R8` + `TYPE`, because the CCP echoes a typed
ESC as `^[` and never lets one reach the parser.

### A program asking for blue got red

`ESC[44m` then `ESC[2J` - select a blue background, clear the screen - filled
all 25x80 cells solid **red**. That is what build 53's erase fix made visible
and what put a `[DECISION]` item in `todo.txt` the same day.

The SGR parameter carries an *ANSI* colour index, and `currentAttr` is a *CGA*
attribute byte. The two orderings agree on four colours and disagree on four:

    ANSI  0 black 1 red  2 green 3 yellow 4 blue 5 magenta 6 cyan 7 white
    CGA   0 black 1 blue 2 green 3 cyan   4 red  5 magenta 6 brown 7 lt grey

`applySGR` stored the parameter straight into the nibble, so `ESC[31m` drew
blue, `ESC[44m` filled red, `ESC[33m` drew cyan and `ESC[36m` drew brown. Half
of the palette a program can name came out as a different colour, and the four
that were right - black, green, magenta, white - were right by coincidence.

- **A new `CGAColor`**, next to `TerminalDialect` and `ControlKey` in `Views/`
  and split out for the same reason: it is a pure function of a byte, so
  `Tests/CGAColorTests.swift` can exercise it with no display, no emulator and
  no UIKit. It holds the eight-entry table, both orderings written out by name,
  and the reason the stored byte must stay CGA. The mapping is an exchange of
  bits 0 and 2 and is therefore its own inverse, which the table records and
  nothing relies on.

- **The translation happens at the SGR parse site and nowhere else.** Not in the
  renderer, not in the erase path, and above all not in the guest attribute
  path: a CP/M program can hand over a raw CGA attribute byte through RomWBW's
  HBIOS VDA "set attribute" call (`HBF_VDASAT` -> `emu_video_set_attr()` ->
  `emulatorVDASetAttr`), and `TerminalView`'s `cgaColors` is a CGA palette.
  Both of those are correct as they stand; only the SGR entry points were wrong.
  The default attribute does not move either - `0x07` is light grey on black in
  both orderings - so no reset value changed.

- **This brings the port in line with `romwbw_emu`'s web frontend**, which
  renders through xterm.js and has always read SGR colours as ANSI. `z80cpmw`
  has the identical bug at the identical site and is not fixed by this change.

### Bold no longer falls off when a colour arrives

The same two lines masked the foreground with `0xF0`, which clears bit 3 - the
intensity bit `SGR 1` sets - along with the colour. So `ESC[1;31m` came out dim
while `ESC[31;1m` came out bright, for no reason a program could see. Intensity
and colour are independent attributes and the order they arrive in must not
matter. The mask is now `0xF8`, which is what `z80cpmw`'s `TerminalView` uses at
the same site after hitting this in its own terminal; this port was the one
still on `0xF0`. The background mask stays `0x0F`: the background is three bits
and has no intensity bit of its own.

### Verified on the simulator, not only by reading

`ESC[44m ESC[2J` now fills the screen with RGB `(0, 0, 170)` - CGA 1, blue - and
each colour sampled out of the screenshot is the palette entry it should be:
`ESC[31m` is `(170, 0, 0)` red, `ESC[33m` is `(170, 85, 0)` brown, `ESC[36m` is
`(0, 170, 170)` cyan, `ESC[32m` is `(0, 170, 0)` green and a bare `ESC[0m` is
`(170, 170, 170)` light grey. `ESC[1;31m` and `ESC[31;1m` both come out
`(255, 85, 85)`, bright red, where a plain `ESC[31m` on the same screen is
`(170, 0, 0)` - the two orders now agree and the dim one is still dim.

Not verified: the pre-fix binary was not rebuilt and re-run to watch the red
screen again; build 53's entry above records that observation. Nothing in this
build has been run on a device, or under Mac Catalyst. The CSI parser around
`applySGR` still has no tests of its own - only the colour arithmetic does - and
that remains the standing `[MAC]` item in `todo.txt`.

## Version 1.5.1 (Build 53)

Two terminal changes a user can see, and the section that had been sitting here
without a build number because nothing in it had been compiled. It has been now.

`Tests/run_tests.sh`: 180 checks across five suites plus the two `CoreSymlinks`
shape checks, all passing (172 before; `KeyMapTests` grew from 34 to 42).
`xcodebuild` clean for the iPhone 17 Pro simulator and for Mac Catalyst, with no
new warnings. Installed and run on the iPhone 17 Pro simulator: booted the Combo
disk to CP/M 2.2 and drove the escape sequences below through `R8` + `TYPE`,
because the CCP echoes a typed ESC as `^[` and never lets one reach the parser.

### An erase paints the current background

Every erase in the terminal - `ED`, `EL`, `ECH`, `ICH`, `DCH`, `IL`, `DL`, `SU`,
`SD`, the VT52 `ESC J` / `ESC K`, and both scroll paths - blanked cells with a
default `TerminalCell()`: white on black, whatever the guest had set. So a
program could select a background, clear the screen, and get a black screen with
its own text drawn on a colour it had not asked for. A strict VT, xterm and both
sibling ports paint the *current* SGR background; this port was the last one
that did not. z80cpmw made the same change with tests, cpmdroid's `ED`/`EL`
already used the current rendition, and the web frontend gets it from xterm.js.

- **A new `blankCell`**, next to `displayAttr` and unpacking the attribute byte
  exactly the way the glyph-write path does, so an erased cell and a character
  written into it afterwards always agree. Seventeen call sites now use it. The
  two that do not are the initial screen allocation and the scrollback padding,
  which are not erases and must stay at the default.

- **`clearTerminal()` split in two.** It was the `ESC[2J` path *and* the
  machine-level clear, and it reset `scrollTop`/`scrollBottom`. Erase-in-display
  says what to do with the cells and nothing about the terminal's modes - `ED`
  is not `DECSTBM` - so a program that sets a scrolling region and then clears
  its screen was silently losing the region. `eraseScreen()` is now the guest
  path (`ESC[2J`, VT52 `ESC E`, the HBIOS VDA clear): cells and cursor only.
  `clearTerminal()` is the machine path (Start, Reset): it resets the rendition
  *first*, then erases, then resets the region. z80cpmw split the same two jobs
  apart for the same reason.

- **The ordering that made this dangerous.** `reset()` called `clearTerminal()`
  before setting `currentAttr = 0x07`, which was harmless while an erase always
  painted the default and would have painted a fresh boot in the dead session's
  colour the moment it stopped. The power-on block now runs before the clear, and
  `clearTerminal()` resets the rendition itself so `startEmulator()` - which has
  no such block in front of it - is covered too.

Verified on the simulator, not only by reading: `ESC[44m ESC[2J` filled all
25x80 cells with the background and the text written after it matched. It came
out *red*, not blue, which is a second bug this one made visible and did not
cause - `applySGR` stores the raw ANSI index in a byte the painter reads as a
CGA index, so 1 and 4 swap and 3 and 6 swap. Pre-existing, identical in
z80cpmw, and now an open item in `todo.txt` rather than a surprise.

Also verified there: `ESC[5;10r` survived a following `ESC[2J` - nine lines fed
at the region bottom scrolled inside rows 5-10 and left the rest of the screen
alone, which is the outcome that distinguishes a preserved region from a reset
one - and Reset from a fully coloured screen came back black rather than
coloured. All of it on the iPhone 17 Pro simulator; nothing in this build has
been run on a device.

### Ctrl+arrow is a binding of its own

The nav-key branch in `pressesBegan` tested only for `.command`, so a held Ctrl
was discarded before the general Ctrl fold below it could see it, and Ctrl+Left
sent exactly what Left sent. Neither `SpecialKey` nor `KeyMap` had a slot for a
modified variant, so a Custom profile could not say otherwise either.

- **Four new `SpecialKey` cases** - `ctrlUp` / `ctrlDown` / `ctrlLeft` /
  `ctrlRight` - bound in every preset profile and editable in Settings like any
  other key. WordStar and VT100 send the xterm modified forms `\E[1;5A` / `B` /
  `C` / `D`, byte for byte what `z80cpmw/Keymap.h` binds. cpmemu's WordStar
  `^A ^F ^W ^Z` was the alternative and was not taken: the xterm form is the one
  with a cross-terminal meaning, all four WordStar bytes are still reachable by
  typing Ctrl+A/F/W/Z, and z80cpmw had already shipped this. `KNOWN_PROBLEMS.md`
  records the reasoning.
- **VT52 is the deliberate exception**, binding Ctrl+arrow to the plain VT52
  arrow: a VT52 has no parameterised CSI to put a modifier in, and giving it one
  would be the same lie as giving it F5-F12.
- **An absent modified binding falls back to the unmodified one**, which is what
  `z80cpmw`'s `KeyMap::find()` does and what keeps a Custom profile saved before
  this build behaving exactly as it did instead of going silent. An explicitly
  empty binding still means "send nothing" and does not fall back.
- **iPadOS only, and the code says so** rather than pretending otherwise: macOS
  claims Ctrl+arrow for Mission Control at the WindowServer level, so on Mac
  Catalyst the press never reaches the app.

`Tests/KeyMapTests.swift` gained eight checks for all of the above. The runtime
half is unverified: synthetic arrow-key events do not reach the app inside the
simulator at all (neither plain nor modified produced any guest input), so the
end-to-end path was not exercised on a device or a simulator.

### Documentation

`docs/notes_to_windos.md`'s symlink-hazard section had no live example. It has
one now, and it is this repository's own week: `romwbw_emu` `322ca8e` added the
REQUIRED backend function `emu_host_file_get_read_name()` and called it from
`hbios_dispatch.cc`, which is one of the 21 symlinks under `iOSCPM/Core/` - so
the call arrived here with no commit, no diff and no version number changing,
and the build simply stopped linking. The mirror of the same hazard bit at the
same time: this checkout was two commits behind its own origin, on `49851aa`
while `15f48e9` - the commit that defines the getter - was already on the
remote. A symlink pins nothing at either end, so the check now covers this
repo's own `git status -sb` alongside the two siblings. The section also names
what `Tests/run_tests.sh` does and does not prove: its C++ suite catches a newly
required core function without needing Xcode, but only because the *test's* stub
list must grow too - defining the real function in `emu_io_ios.mm` is a separate
edit that only the Xcode build checks.

`KNOWN_PROBLEMS.md`'s "Nav keys ignore their modifiers" entry is now about the
keys that still do (Shift+Up, Alt+Right, Shift+Insert), and records the
Ctrl+arrow convention and the reasoning behind it.

### `todo.txt` is open work again, and `MANUAL_CHECKS.md` is new

`todo.txt` went 275 lines to 143. It had stopped being a list of things to do:
closing an item was producing a paragraph explaining that it had closed, which
was longer than the item had been, so roughly two lines in three were narration
of finished work - reset confirmation tapped, `R8` fallback observed, which
line cite had gone stale, what a previous round had corrected in another
repository's document. None of that asks anyone to do anything, and all of it
already lives in this file or in a commit message. It is deleted, not
summarised.

- **`MANUAL_CHECKS.md`** now holds the three things that need a person driving
  the app: build 52's six destructive `W8`/`R8` checks, the WordStar diamond and
  Escape under Catalyst, and Ctrl+arrow. `todo.txt` keeps one line pointing at
  it, and the file says outright that a check is *deleted* once someone runs it.
  It also corrects the premise those items had been carried on - only the
  Ctrl+arrow one needs hardware. The rest run in the Simulator, whose sandbox is
  a real directory under `simctl get_app_container`, or under Catalyst.
- **Every surviving item is tagged** `[MAC]`, `[RELEASE]` or `[DECISION]`, so a
  session on a machine that is not this one can see at a glance what it can
  take.
- **The release-order material collapses to one line** pointing at
  romwbw_emu's `docs/RELEASE_ORDER_2026-08-25.md`, which owns it. The residue
  that is genuinely this port's - do not bump `releaseTag` before build 52
  ships, and the catalog bump's second data-loss path - stays.
- **No file:line cites survive.** Every one this file carried into
  `EmulatorViewModel.swift` had gone stale, some inside a single build. Items
  name a function or a greppable string now.

### This port had stopped linking, and nothing said so

The rest of this section was written on a Linux machine with no Xcode, no Swift
and no Objective-C toolchain, and was committed uncompiled (`15f48e9`). It has
been through a compiler now, as part of build 53, and it builds and runs.

`iOSCPM/Core/` symlinks into `../romwbw_emu/src`, so an upstream commit moves
the core under this repo without touching a file here. On 2026-08-26 romwbw_emu
`322ca8e` added `emu_host_file_get_read_name()` - the read twin of
`emu_host_file_get_write_name()`, for `HBF_HOST_GETRNAME` - and `emu_io.h` marks
it a REQUIRED backend function precisely because `handleEXT()` references it
unconditionally. `emu_io_ios.mm` did not define it. Build 52 was committed the
day before, so the app has not been built since; the next build would have
failed to link.

- **`emu_io_ios.mm` defines it**, returning `""`. That is a legal answer and
  `emu_io.h` names it as one: `HBF_HOST_GETRNAME` reports "no answer" and `R8`
  falls back to printing what was asked for. It is not the *best* answer here -
  the Swift layer resolves the name case-insensitively against `Imports` and
  could report what it really opened - and the shape of that fix is in
  `todo.txt` rather than written blind. romwbw_emu's browser backend answers
  `""` for the same reason.
- **`Tests/CoreKeyboardTests.cc` stubs it too.** That suite is the only check in
  the repo that compiles the symlinked core, so it is the only thing that can
  notice this class of break - and it was itself failing to link, which is how
  this was found.
- **A missing-symbol sweep of the whole backend contract**, not just the one the
  linker happened to name first: every function declared in `emu_io.h` was
  checked against `emu_io_ios.mm`, `emu_io_common.cc` and `hbios_core.cc`.
  `emu_host_file_get_read_name()` was the only one missing. `emu_host_path_caps()`,
  the other new required symbol, is already defined here.

### A zero-byte W8 export vanished

`W8` on an empty CP/M file told the guest it had succeeded and nothing appeared
in `Exports`. An empty file is a real file - the CLI and Windows backends both
create it, and romwbw_emu stopped dropping it in the browser backend for v1.36 -
so this closes a divergence rather than choosing a behaviour. `cpmdroid` closed
the identical one in `c06fa58`, in the same two shapes:

- `emu_host_file_close_write()` moved to `WRITE_READY` only when the buffer had
  bytes in it, so an empty export never reached the state the Swift layer polls.
  The test is now on `HOST_FILE_WRITING` alone.
- `checkHostFileState()` guarded on the data pointer, and
  `emu_host_file_get_write_data()` returns `nullptr` for an empty buffer *by the
  shared contract* - so the pointer could never answer the question the state
  had already answered. Only the leaf name is guarded now; a zero-byte export
  arrives as an empty `Data`, and `Data.write(to:)` creates the file.

Either half alone would still have swallowed the export. Left out of build 52 on
purpose - that build was a security fix and was kept minimal.

### `Tests/run_tests.sh` runs off a Mac

The C++ suite needs a C++11 compiler, not Xcode, and it is the only check that
catches a core sync this port has not absorbed. It now falls back to `c++` when
there is no `xcrun`, skips the four Swift suites explicitly, and ends with
"PASSED, 4 suite(s) SKIPPED - this was not a full run" rather than "ALL TESTS
PASSED". The Mac path is unchanged when `xcrun` is present and was not exercised
here.

### Docs: three claims that were false, and two steps that did not warn

- **`docs/DISK_W8FIX_RUNBOOK.md` said the app "verifies each image's SHA-256"**
  against the catalog. It does not - that was the fourth document asserting an
  enforcement this port does not have, after the three in
  `docs/DISK_DISTRIBUTION.md` corrected in build 52. Corrected, with the live
  measurement that makes the distinction clear: on 2026-08-26 the published
  `v1.4.5/hd1k_combo.img` was downloaded whole and *does* hash to the
  `be19984e…` its published `disks.xml` names. What is shipped is consistent;
  the enforcement is what is missing.
- **The same runbook called the `<disks version>` bump "the app invalidates
  cached disks on a version change"**, at the exact step that tells you to make
  it. That bump deletes every `.img` in the user's `Documents/Disks`, imported
  and app-created ones included, with no confirmation. The step now says so and
  points at `todo.txt`. `docs/DISK_CATALOG_PINNING.md` gained the same warning
  at the step that bumps the pin, together with the build-52 ordering
  constraint.
- **`todo.txt` said the pinned `v1.4.5` catalog was `<disks version="12">`.** It
  is 13, byte-identical to `release_assets/disks.xml` (sha256 `6ae94b8c…`),
  checked by fetching it. The correction matters: nothing is pending, and the
  next respin fires the wipe on every installed device at once. It has also
  already fired once in the field: the 12 → 13 catalog reached users on
  2026-07-22, when `disks.xml` was uploaded to `v1.4.11` — which is Latest, and
  which the app still floated on, the pin landing three days later in `4be8a13`
  (build 42). Nothing recorded that until now.
- **`KNOWN_PROBLEMS.md`'s disk-size entry described one hardcoded 8 MB.** There
  are two: `EmptyDiskDocument.fileWrapper` (`ContentView.swift`) writes its own
  `Data(repeating: 0xE5, count: 8 * 1024 * 1024)` with no reference to
  `defaultDiskSize`, and `createNewDisk` then overwrites that file with a second
  one. A size picker has to feed both.
- **`todo.txt`'s erase-family line numbers were 29 lines stale** (`:2269`
  through `:2397`), as was the `executeCSI` range and the count of suites in
  `Tests/`. Cites in that file now name greppable symbols and case comments
  instead of line numbers wherever they were touched.

### Measured against the live releases, and recorded

None of this changed code; it replaced belief with measurement. What is still
actionable is in `todo.txt`, the runbook and `MANUAL_CHECKS.md`; the rest is
here.

- The published `v1.4.5` combo carries the **old** `W8`: its only usage string
  is `Usage: W8 <cpmname>`, with no `[hostpath]`, and the interlock probe bytes
  `06 e9 cf` appear nowhere in the image. romwbw_emu's
  `RELEASE_ORDER_2026-08-25.md` has that as "Believed yes, not verified here";
  it is verified now. The catalog as published cannot arm the host-path `W8`, so
  the exposure build 52 closes is via images imported through Files.
- It also still carries the fixed lowercase `w8` (broken signature 0, fixed
  signature 10), which is what the runbook's 2026-07-22 audit claimed.
- Help floats to **Latest**, which is `v1.4.11` - `v1.4.5` is a prerelease. All
  eight published help assets were fetched and compared: `help_index.json` and
  five of the seven topics are byte-identical to `release_assets/`. Two are not,
  where `todo.txt` recorded one. `help_file_transfer.md` is the worse of them -
  it names `com.awohl.iOSCPM` and "Files app → iOSCPM" when the bundle id is
  `com.awohl.cpm` and the Files name is `Z80CPM`, so both folder paths it gives
  a user are wrong.

## Version 1.5.1 (Build 52)

### W8 could delete the user's disk library

`W8 ANYFILE.TXT ..` destroyed the entire `Documents` folder — `Disks`,
`Imports` and `Exports`, so every disk image the user had downloaded — and
reported success to the guest.

Three things lined up. `W8` takes an optional host path and sends it verbatim.
`emu_host_file_open_write()` stored it unsanitised as the export *filename*.
And `saveToExportsFolder` then built a destination with
`exportsDir.appendingPathComponent(name)` followed by
`try? fm.removeItem(at: destURL)` — where `appendingPathComponent` does **not**
escape `..`, so the URL resolved to `Documents`, and `removeItem` on it
succeeds and deletes recursively. The `try?` swallowed the error; the guest was
told the export succeeded because `emu_host_file_close_write()` returns before
the Swift layer ever runs.

Reproduced against the shipped logic on a scratch tree, and again after the
fix: `Documents: GONE` became `Documents: present, disk image intact`.

Fixed in three places, deliberately overlapping, because a check that only
holds while another layer behaves is not a check:

- **The core reduces the string first.** `emu_host_file_open_write()` now runs
  it through the shared `emu_host_path_basename()` (new upstream in
  romwbw_emu v1.36), which takes both separators and never returns `""`, `"."`
  or `".."`. This alone closes it, and closes it for any future UI layer.
- **`ExportPath`** (new, `iOSCPM/Views/ExportPath.swift`) owns reducing a guest
  string to a leaf and proving the result lands directly inside `Exports`. Split
  out for the reason `TerminalDialect`, `ControlKey` and `KeyMap` were — it
  touches no UIKit, so it is testable, and this is the one that most needed to
  be. `Tests/ExportPathTests.swift`, 24 checks, including the ten traversal
  strings and the two Foundation behaviours that made the old version
  destructive.
- **`saveToExportsFolder` no longer calls `removeItem` at all.**
  `Data.write(to:)` already replaces an existing file; the remove was pure
  downside.

### R8 imported the wrong file and said nothing

The same unsanitised path on the read side. `R8 /USERS/ME/FOO.COM` built
`Imports/USERS/ME/FOO.COM`, missed, and then fell back to **the first file in
the folder** — loading unrelated contents into CP/M under the requested name,
with a success message on both sides. `../SOMETHING` could also address files
outside `Imports`.

The core reduces the path to a leaf before the delegate sees it, the lookup
reduces again, and a miss is now reported instead of substituted. A file whose
name differs only in case is still found: CP/M's CCP uppercases the whole
command line, so the guest asks for `FOO.COM` when the file is `foo.com`, and
the native backend has always resolved that case-insensitively. This now does
too, which matters on a case-sensitive volume.

### W8 says where the file went

`emu_host_file_get_write_name()` answers with the real `Exports` path rather
than an echo of the guest's string, so the new upstream `HBF_HOST_GETNAME`
(0xE8) gives the CP/M user something they can act on — previously `To host:`
named a path that does not exist anywhere on the device. The Swift layer takes
the leaf through a separate accessor, `emu_host_file_get_write_leaf_c()`,
because it joins to `Exports` itself.

### Not in this build, on purpose

`releaseTag` still points at **v1.4.5**. Refreshing the disk-image catalog is
what puts a path-capable `W8` in front of every user, so it must not happen in
the same step as, or before, this fix reaching them. The order is written down
in romwbw_emu's `docs/RELEASE_ORDER_2026-08-25.md`; this build is step 1 of it,
and the catalog bump is step 5.

That order guards the `W8` path. It does not guard the other destructive thing
the catalog bump does, which is new to `todo.txt` in this build and not fixed
here: `disks.xml` carries a `version` attribute, and on any change to it
`checkCatalogVersionAndInvalidate` calls `deleteAllDownloadedDisks()`, which
removes **every** `.img` in `Documents/Disks` — including disks the user
imported through Files and disks the app itself created, neither of which the
catalog can give back — and tells the user afterwards. The attribute has moved
on essentially every catalog change to date, so step 5 fires it. What should
happen instead is a product decision, so it is written down rather than guessed
at. `KNOWN_PROBLEMS.md`'s "Data Loss Risk with GitHub Disks" entry, which
described only the download-over-the-top case, now names this trigger too, and
`docs/DISK_DISTRIBUTION.md`'s "Version Attribute" section — which had it as
disks that "may be invalidated if checksums changed", with users "notified of
available updates", none of which the code does — now describes what actually
happens.

### Downloads are not checksum-verified on this port

Found while checking the above and also only written down, not fixed.
`EmulatorViewModel` has two download implementations. `downloadDiskWithRetry()`
hashes the installed file against the manifest's `sha256`, deletes it and
retries on a mismatch — and is dead: its only callers are its own four retry
arms. Every real download goes through `downloadDiskFromSettings()`, which
moves the temp file into place without hashing it. The catalog hash survives as
the coloured digest in `DiskDownloadRow`, computed after the file is installed
and acted on by nothing.

`docs/DISK_DISTRIBUTION.md` asserted the opposite in three places ("SHA256
checksum is verified", "All downloads are verified against the manifest's SHA256
checksum", "No disk is used without passing verification"). Its "Integrity
Verification" section is now marked intended-not-shipped and describes the live
path, and `todo.txt` carries the choice — delete the dead path, or move its
check into the live one.

Two smaller facts that had sat only in `KNOWN_PROBLEMS.md` are now in `todo.txt`
as well, re-verified against the source and otherwise unchanged: a new disk is
always 8 MB (`createNewDisk(at:size:)` has a `size:`, the single call site in
`ContentView` passes none, and there is no size picker, while an import is
accepted up to `maxDiskSize`, 64 MB), and a created disk is `0xE5` fill with no
HD1K filesystem laid down, so it is unusable until something formats it.

### Stale claims in the docs

`docs/notes_to_windos.md` warned about siblings on topic branches with a dated
example: `../cpmemu` on `posix-console` (`55cc13f`) rather than `main`. That
branch has since landed — `55cc13f` is dated 2026-08-23 and is an ancestor of
`main`, and `posix-console` is no longer a local branch there — and a warning
whose one concrete example is stale invites being dismissed. The hazard is
unchanged, so the anecdote is replaced by what the tests do and do not prove:
`Tests/run_tests.sh` (`=== CoreSymlinks ===`) asserts that all 21 entries under
`iOSCPM/Core/` are still mode 120000 in the index and that none dangle, then
compiles through them — but a symlink into a sibling parked on a topic branch
resolves, compiles and passes exactly as a correct one does, so which commit is
behind the link is not something any test here can see.

`KNOWN_PROBLEMS.md` still described `SpecialKey` as "a flat 10-case enum".
Build 51 made it twenty-two. The point it was supporting — that the binding
schema has no slot for a modified arrow — is unaffected.

The same entry said z80cpmw "does the same thing" with modifiers and elsewhere
that it "has no equivalent" for Ctrl+arrow. Both are now false: z80cpmw's
`TerminalView.cpp` passes a modifier mask to `m_keymap.find()`, and its
`Keymap.h` defaults bind Ctrl+Up/Down/Right/Left to `\E[1;5A`..`D`. Corrected
to say so. No convention is picked for ioscpm here — cpmemu sends the WordStar
bytes `^A ^F ^W ^Z` and z80cpmw sends the xterm forms, and choosing between them
is the open item in `todo.txt`, unchanged by this.

## Version 1.5.1 (Build 51)

### Three parity gaps closed

- **F1-F12 are bindable.** `SpecialKey` was ten cases; it is twenty-two now, the
  same set `z80cpmw/Keymap.h` defines, with the same VT220/xterm sequences byte
  for byte - `\EOP` through `\EOS` for F1-F4, then `\E[15~`, `\E[17~` and up,
  skipping 16 and 22 as a real VT220 does. That was the reason key maps were not
  interchangeable between the ports. The VT52 profile is the exception on
  purpose: a VT52 has four keypad function keys as `ESC P`..`ESC S` and no
  others, so F5-F12 send nothing there rather than borrowing a VT100 sequence a
  VT52 program cannot be expecting.
- **The terminal gained the editing finals it was missing** - `@` ICH, `P` DCH,
  `X` ECH, `S` SU, `T` SD - and now acts on two DEC private modes it previously
  only parsed: DECAWM (`?7`), so a guest can turn autowrap off and have the last
  column overwrite instead of wrapping, and DECTCEM (`?25`), so a full-screen
  program can hide the cursor while it redraws. Both reset to their power-on
  state on cold boot, so a guest that hides the cursor and then dies does not
  leave it hidden for the next session. SU sends lines to scrollback only when
  the region is the whole screen, matching what LF already did - lines pushed out
  of a status-line window were never history.
- **Help works offline.** The index and all seven topics now ship inside the app.
  The download still comes first and the cache second, so a correction published
  to a release still reaches users without an app update - but a first run with
  no network, or a release whose help assets were not attached, no longer leaves
  the user with nothing. That second case is not hypothetical: `cpmdroid` shipped
  this exact arrangement with no bundled copy, its assets stopped being attached
  after v1.11, and every build from then on had no help at all with nothing
  failing anywhere to say so.

### Also

- `KeyMap.swift` is split out of `TerminalView.swift`. None of it touches UIKit,
  and that made it testable - `Tests/KeyMapTests.swift` adds 34 checks, which
  assert the F-key bytes against z80cpmw's table rather than against "something
  reasonable", since a plausible but different sequence is exactly what would
  make maps silently non-portable again.
- The root `disks.xml` is deleted. It was byte-identical to
  `release_assets/disks.xml` and had no consumer - the app builds its catalog URL
  from the pinned release tag.
- The test suite is 150 checks, from 116.

## Version 1.5.1 (Build 50)

### The VDA keyboard works, and there are tests that say so

A cross-port audit of this repo against `romwbw_emu`, `cpmemu` and `z80cpmw`
found the core current — the 21 symlinks in `iOSCPM/Core/` were already
resolving to `romwbw_emu` v1.36 and every item on its migration checklist was
done — and turned up two bugs in the shared HBIOS dispatcher instead. Both are
fixed upstream in `romwbw_emu` `bf03758` and arrive here through the symlinks;
this build is the one that carries them.

- **`VDAKST` said "no key" however much was queued.** It set the pending count
  in `E` but left the status byte in `A` at zero, and `A` is what a caller
  tests. Its `CIO` twin, `CIOIST`, has always set both.
- **`VDAKRD` handed the guest a stale byte.** With no key pending it flagged the
  wait and returned *without rewinding PC*. Dispatch is a two-byte
  `OUT (0xEF),A` followed by the Z80 proxy's own `RET`, so skipping the rewind
  let that `RET` fire immediately with `E` still holding whatever the previous
  call left there — the guest read it as a keystroke and never came back for the
  real one. `CIOIN` has rewound since the non-blocking path was added, and this
  port runs non-blocking (`hbios_core.cc` calls `setBlockingAllowed(false)`,
  because the UI thread cannot stop for a key), which is exactly the arm where
  it mattered.

Neither is reached by the normal serial-console boot, which is why nothing had
been reported. But `SYSGET_VDACNT` reports one VDA to every port, so any guest
that used the video keyboard hit both.

### Tests

`Tests/run_tests.sh` grew from 40 checks to 116, in three suites plus a
structural check:

- **CoreSymlinks** — asserts all 21 entries under `iOSCPM/Core/` are still
  symlinks and still resolve. They have been flattened into stale copies once
  before (`docs/notes_to_windos.md`), and a flattened copy compiles and passes
  every behavioural test; it just quietly stops tracking upstream.
- **CoreKeyboardTests** (new, C++, 24 checks) — compiles the shared core
  *through those symlinks* and drives HBIOS the way the Z80 proxy does, in the
  non-blocking mode this app uses. Covers `CIOIN`/`CIOIST`/`VDAKRD`/`VDAKST`,
  the PC rewind, the whole WordStar diamond surviving `CIOIN` unchanged, and
  `CIOOUT` buffering rather than writing behind the UI thread's back. This is
  the first test in the repo that touches the emulator at all.
- **ControlKeyTests** (new, Swift, 50 checks) — the Ctrl fold build 49 added.
  The arithmetic moved out of `TerminalUIView` into `ControlKey.swift` so it
  could be tested at all, the same split that made `TerminalDialect` testable;
  `controlByte(for: UIKey)` still does the UIKit half. Covers every letter in
  both cases, the non-letter combinations build 49 added, and the hazard that
  commit called out by name and nothing verified: `uppercased()` maps a German
  `ß` to `SS`, so a full Unicode fold would hand the guest `^S` — WordStar
  cursor-left — from a key that used to send nothing.
- **TerminalDialectTests** — unchanged, 40 checks.

No user-visible change beyond the two fixes above.

## Version 1.5.1 (Build 49)

### Synced to the romwbw_emu v1.36 core - control keys belong to the guest

Takes the v1.35 -> v1.36 migration notice
(`romwbw_emu/docs/DOWNSTREAM_2026-08-23.md`). The sweep behind it started with a
Windows user reporting "Ctrl R exits me from CPM"; `^R` was already clean here,
but the same shape of bug was not.

- **Ctrl with anything that is not a letter now reaches CP/M.** The only Ctrl
  keys that ever arrived were `a`-`z`, because 26 `UIKeyCommand`s were the whole
  mechanism and every other Ctrl press was dropped on the floor. `Ctrl+[` (ESC),
  `Ctrl+\`, `Ctrl+]`, `Ctrl+^`, `Ctrl+_`, `Ctrl+@` and `Ctrl+Space` (NUL),
  `Ctrl+?` and `Ctrl+Backspace` (DEL), and every `Ctrl+Shift+letter` now fold to
  their ASCII control byte in one place. The 26 key commands are kept for Mac
  Catalyst, where claiming a key explicitly is the reliable way to keep AppKit's
  own Ctrl-letter bindings away from the WordStar diamond.
- **`Ctrl+J` was indistinguishable from Enter.** Two separate LF -> CR rewrites
  sat on the input path, one in `queueInput` and one in `emu_console_queue_char`.
  Nothing needed them: every key that means Enter already sends CR. They ate the
  only 0x0A a user could produce - `Ctrl+J`, and a key map binding spelled
  `\n` - so both are gone and the mapping now happens once, in `insertText`,
  where the software keyboard's Return genuinely does arrive as LF. This is the
  same audit v1.36 ran on its own tty read path.
- **Escape claims priority over system behaviour on Mac Catalyst**, where ESC is
  also the leave-full-screen gesture. `keyCommands` now returns nothing while a
  dialog has the keyboard, so a priority Escape cannot outrank the alert it is
  meant to dismiss.
- **A dialog now really does hold the keyboard.** The terminal stays first
  responder underneath a dialog and its key commands are the first UIKit
  consults, so Escape and Return were reaching CP/M instead of dismissing.
  Only the disk-overwrite warning ever suppressed capture; the error alert -
  including the ROM-failure alert added below - never did. All three dialogs
  drawn over the terminal now do.
- **Reset asks first.** The toolbar Reset button sits next to Play/Stop, and a
  cold boot drops the running program and the entire scrollback. It is now
  behind a confirmation, whether or not the machine is running - the history is
  wiped either way. This is the fourth bullet of the new upstream contract,
  "Platform Contract: Ctrl-A..Ctrl-Z Belong to the Guest", reached by a tap
  rather than by a key.
- **The dead `emu_console_check_ctrl_c_exit()` stub is deleted.** Upstream
  removed the declaration in v1.36; nothing ever called it in any port, and a
  dead function that looks like a live `^C` interception is a trap for the next
  person auditing exactly that question. `emu_console_check_escape()` stays - it
  is still declared and still live for the CLI - and its comment now records
  that iOSCPM reserves no key, which is what the contract asks of the
  `escape_char == 0` case.
- `keyboard.ctrlRToCpm` from the Windows port is deliberately **not** ported:
  there is nothing here to switch off.

### A ROM that fails to load no longer starts the CPU

- **`loadSelectedResources()` reported a failed ROM and returned anyway**, so
  `start()` ran the Z80 over whatever bank 0 happened to hold and the status
  line said "Running". It now returns a result and Start honours it. A disk that
  fails to load is still non-fatal - booting with no disk is legitimate.
- **The reason survives.** All three failure modes - not in the app bundle,
  unreadable, or rejected by the core's HCB validation - reported "not found",
  which sends people hunting for a file that is right there. The bridge now
  validates with `emu_validate_rom_hcb()` before loading and keeps the message,
  so a corrupt or wrong-release ROM says so.

### Terminal fixes

- **`ESC[nM` (Delete Line) could crash the app.** With `n` larger than the
  distance from the cursor to the bottom of the scrolling region, the loop bound
  fell below its start and the Swift `Range` trapped. `n` is now clamped to the
  region for both DL and IL - deleting more lines than exist just clears it.
- **Reverse video was destructive.** `SGR 7` swapped the colour nibbles in
  place with no record that it had, so a second `SGR 7` swapped back, and
  `SGR 27` gave up and reset to white-on-black - throwing away whatever colours
  were set. Reverse is now a flag, and the swap happens on the way to a cell
  rather than being stored, so it is a clean toggle and the colours underneath
  are never disturbed. That also fixes a loss the in-place swap could not avoid:
  the background nibble is three bits, so a bright foreground did not survive a
  round trip through it. The flag is cleared wherever the whole attribute byte
  is replaced, including the HBIOS `VDASetAttr` path. `SGR 22` (bold off) is
  implemented.
- **CSI parsing is bounded.** Digit and parameter counts are capped and parsed
  values clamped, matching the Windows port, so a runaway guest cannot grow the
  parser's state without limit.

### Build and housekeeping

- **The Z80 decoder no longer pays for tracing it never uses.** `QKZ80_NO_TRACE`
  is defined for both configurations; nothing in this port ever calls
  `set_trace()`. Follows `cpmemu` `06262ff`.
- **About shows the RomWBW pin** (`3.5.1`) beside the app version. A disk slice
  built by a different release prints an HBIOS/CBIOS mismatch, so it is the
  first thing worth asking for in a bug report.
- Documentation audit against the sibling ports: the README credited RomWBW as
  MIT where the attestation filed with Apple says GPL-3.0-or-later; the stated
  minimum OS predated the iOS 15 deployment target; `docs/DISK_CATALOG_PINNING.md`
  still described iOS as the unpinned outlier three weeks after the pin shipped;
  the root `disks.xml` was three catalog versions stale and carried the
  pre-W8-fix combo hash. `KNOWN_PROBLEMS.md` gains a Keyboard section recording
  the decisions from this sweep that are deliberate and must not be re-flagged.

## Version 1.5.1 (Build 48)

### Disk capacity is no longer narrowed silently (shared core)

- **`disk.size / 512` was truncated into a 32-bit sector count** at two points
  in the HBIOS dispatcher, which the compiler reported as
  "implicit conversion loses integer precision". A truncating conversion keeps
  the remainder, so an image just past 2 TiB would have reported as nearly
  empty rather than as huge, and `DIOCAP` would have handed the guest a
  capacity unrelated to the disk. `HBDisk` now has a `total_sectors()`
  accessor - matching `MemDiskState::total_sectors()` beside it - which clamps
  at the largest sector count HBIOS can express instead of wrapping.
- No behaviour change for any disk that can exist today; a 49 MB six-slice
  hd1k image still mounts and reports 8176 KB per slice under `STAT DSK:`.
- Fixed in the shared `romwbw_emu` core (`5667a34`), so it reaches the other
  ports too.

## Version 1.5.1 (Build 47)

### An erase no longer decides we are a VT52 (issue #2)

- **A single `ESC K` switched the terminal for the rest of the session.** The
  VT52 choice was inferred from ordinary output, applied globally, and never
  expired. `ESC J` and `ESC K` - erase to end of screen, erase to end of line -
  counted as proof of VT52, but they are the erase commands of the ADM-3A,
  Televideo, Hazeltine and Heath families too, so a CP/M program installed for
  any of those emits them constantly while meaning nothing about VT52. Measured
  on build 46: `ESC Z` answered `<27>[?1;0c` at the MBASIC prompt, an unrelated
  statement printed `ESC K`, and the same `ESC Z` then answered `<27>/Z`.
- **Why all three terminal settings failed the same way.** The dialect is
  global, so once it was wrong, reinstalling WordStar for vt100, ansi or vt52
  made no difference - which is what issue #2 reported.
- **What changed.** `ESC J` and `ESC K` no longer switch the dialect. What still
  does is what a VT100-configured program has no reason to emit: it spells
  cursor movement `CSI A/B/C`, not `ESC A/B/C`. `ESC Y` direct cursor addressing
  is unmistakable and is the sequence a real VT52 program cannot avoid, so
  genuine VT52 still works, and `ESC <` still returns to ANSI.
- **Why erring toward ANSI is safe.** The VT52 action sequences never consult
  the dialect - `ESC A/B/C/I/J/K` and `ESC Y` are carried out either way. Only
  `ESC D`, `ESC E`, `ESC H` and the `ESC Z` reply depend on it, and guessing
  VT52 wrongly is the destructive direction: it turns `ESC E` from Next Line
  into clear-the-screen.

### First tests in the repo

- `Tests/run_tests.sh` compiles and runs host-side unit tests with `swiftc` - no
  Xcode test target, no simulator, no display. `Tests/TerminalDialectTests.swift`
  covers the above in 40 checks.

## Version 1.5.1 (Build 45)

### Synced to the romwbw_emu v1.35 core

- **The bundled ROM is refreshed.** `emu_avw.rom` was intact but predated the
  upstream rebuild; the app now ships the ROM that reproduces from
  `src/emu_hbios.asm`. Verified with `romwbw_emu/roms/verify_romwbw_pin.sh`,
  which passes this tree with no warnings.
- **A corrupt file was being shipped inside the app bundle.**
  `iOSCPM/Resources/emu_hbios.bin` had a damaged HBIOS configuration block
  (`57 b8 36 2b` — bad marker, nonsense version) and was copied into the app by
  the Resources build phase, while no Swift or Objective-C++ referenced it. It
  was a stale build intermediate riding along in every release. Removed, with
  its four `project.pbxproj` entries.
- The core now pins the RomWBW release it emulates (v3.5.1) in
  `romwbw_pin.h` and refuses a ROM built for a different release, or one whose
  configuration block is corrupt, instead of starting a CPU that produces no
  output. `Core/romwbw_pin.h` is symlinked alongside the other core files —
  without it the build fails with `'romwbw_pin.h' file not found`.
- Inherited by recompiling: `emu_file_load()` no longer terminates the process
  on an unseekable path (a document handed over by a file picker is exactly
  that case), `emu_file_save()` is atomic instead of truncating its target
  before writing, and the disk read/write paths check their seeks.

## Version 1.5.1 (Build 43)

### Terminal Scrollback: keyboard navigation + configurable size

Brings iOS/macOS scrollback to full parity with the Windows (z80cpmw) port.

- **Hardware-keyboard navigation** (new): **Shift+PageUp / Shift+PageDown** page
  through history one screen at a time; **Ctrl+Home / Ctrl+End** jump to the
  oldest retained line / live bottom. Plain PageUp/PageDown/Home/End still go to
  CP/M as before. Touch drag and trackpad / mouse-wheel scrolling are unchanged.
- **Configurable capacity** (new): Settings → Preferences → **Scrollback** sets
  the history size (Off / 500 / 1000 / 2000 / 5000 / 10000 lines); 0 disables
  capture. Persisted as `scrollbackLines`. The default is now **1000 lines**
  (matching the other ports), down from the previous fixed 2000.

### Disk catalog pinned to an explicit release

- The downloadable disk catalog is now pinned to ioscpm release **v1.4.5**
  instead of floating on `releases/latest`, matching the Windows/Android ports.
  This guarantees downloaded disks match the embedded RomWBW v3.5.1 ROM (no
  HBIOS/CBIOS version-mismatch warning at boot). Help content still floats.

## Version 1.4.11 (Build 41)

### Emulator Core Sync (romwbw_emu v1.34)

Brings the iOS/macOS port up to the v1.34 platform contract so it builds and
runs against the current shared core. See romwbw_emu `DOWNSTREAM.md` and
`docs/DOWNSTREAM_2026-07-21.md`.

- **Platform API (required):** `emu_host_file_close_write()` now returns `bool`.
  iOS buffers the W8 export and hands it to the OS asynchronously (Exports
  folder / share sheet), so the synchronous close reports success like the
  browser backend; a late write failure is surfaced in the Swift layer.
- **Platform API (required):** added `emu_console_input_exhausted()` and
  `emu_console_input_eof()` (both return `false` — only a CLI reading a closed
  pipe can exhaust input). Without these the port would not link against v1.34.
- **R8 host-file read:** verified against v1.34's new behavior — the core now
  rewinds PC and waits for the host file to be provided or cancelled instead of
  importing a 0-byte file. The port's folder-based reader already resolves the
  wait on every path (`emu_host_file_load` on success, `emu_host_file_cancel`
  on missing/unreadable file), so no code change was required.

Inherited automatically from the shared core (no port changes needed): 64-bit
disk offsets, `HBR_IO` on host disk-write failures instead of silent data loss,
bounded writes to in-memory disk images, and the `emu_file_load_to_mem` /
`emu_load_romldr_rom` hardening. Disk persistence on background, the manifest
write warning, the NVRAM string API, and unified RAM-bank init were already in
place and remain compatible.

### New: Terminal Scrollback

- Scroll back through output history by dragging the terminal (or trackpad /
  mouse-wheel on Mac). A ring buffer keeps the last 2000 lines that scroll off
  the top. A "Live" pill appears while viewing history; tap it — or type any
  key — to snap back to the bottom. The cursor is hidden while scrolled back.
  History is preserved across screen clears (CLS) and dropped on a cold boot.

### New: Configurable Keyboard Mapping

- The navigation keys (arrows, Home/End, Page Up/Down, Insert, Forward Delete)
  on a hardware/external keyboard can be remapped to arbitrary byte sequences,
  using the same termcap-style escape schema as the z80cpmw / romwbw_emu family
  (`\E`, `^X`, `^?`, `\NNN` octal, `\n \r \t \b \s`). Preset profiles:
  **WordStar** (the historical default — arrows send Ctrl-E/S/D/X, unchanged),
  **VT100/ANSI**, and **VT52**; plus per-key customization in Settings. The
  selection persists.

### New: Import File… (stage arbitrary host files for R8)

- R8/W8 transfers always use the sandbox Documents/Imports and Documents/Exports
  folders, so a batch or scripted build (e.g. one that ends in several W8s)
  never triggers a file dialog. To bring in a file from anywhere, **Import
  File…** copies the picked file(s) into Imports (a later `R8` reads them), and
  **Open Exports Folder** surfaces W8 output for sharing. The file picker only
  appears when you invoke Import File… — it is never driven by the guest, so it
  can neither interrupt a batch transfer nor stall the emulator.

## Version 1.4.10 (Build 39)

### Terminal Emulation (fixes GitHub #2)
- Deferred autowrap (VT100 "last column" behavior): writing the rightmost column no longer immediately wraps and scrolls the screen, so full-screen layouts (WordStar, Zork status lines, the TERMDEF border test) render correctly. Also removes a spurious blank line after a full 80-column line.
- VT52 terminal support: direct cursor addressing (`ESC Y`), cursor moves (`ESC A/B/C/D`), home (`ESC H`), reverse line feed (`ESC I`), erase to end of screen/line (`ESC J`/`ESC K`), Heath/Zenith clear (`ESC E`), identify (`ESC Z`), and ANSI exit (`ESC <`). Mode auto-detects from VT52-exclusive sequences (or `ESC[?2l`); ANSI/VT100 behavior is unchanged until a VT52 sequence appears.
- Terminal query answerback: responds to cursor-position report (`ESC[6n`), status (`ESC[5n`), and device attributes (`ESC[c`, `ESC Z`).
- Robustness: charset/line-size designators (`ESC (`, `ESC )`, `ESC #`, …) are now consumed instead of leaking a stray glyph; added absolute cursor positioning (`ESC[G`, `ESC[d`).

## Version 1.4.8 (Build 35)

### Power Management
- Console idle detection: emulator sleeps 10ms instead of 0.1ms when guest is polling keyboard with no input, reducing CPU/battery drain at the CP/M prompt

## Version 1.4.7 (Build 34)

Mac catch-up release: brings Mac to parity with iOS v1.4.6.

### Boot & NVRAM
- NVRAM persistence: Boot settings from ROM's SYSCONF ('W' menu) now survive app restarts
- Simplified boot configuration — removed boot string text field, use ROM's SYSCONF menu instead
- Read-only display of current auto-boot setting with Clear Auto-Boot safety button
- Fixed autoboot clearing via legacy boot_string mechanism
- Boot setting now correctly applied on both start and reset

### Disk Management
- Write protection warning when modifying auto-downloaded disk images ("Don't Warn Again" option)
- Removed per-disk slice limits — all slices now accessible to OS tools
- Removed duplicate Infocom disk (already included in Games)
- Fixed duplicate Games entry in disk manifest

### UI Improvements
- Build date and number shown in status bar and About box
- Font size options consolidated into submenu to reduce menu clutter
- Help menu (Cmd+?) now works properly on Mac Catalyst
- Better error diagnostics in Help system with HTTP status checking and cache fallback
- Keyboard handling fix for manifest warning dialog

### Emulator Core
- Unified RAM bank initialization using shared HBIOSDispatch bitmap
- Boot disk correctly assigned as A: via upstream CB_BOOTVOL
- Manifest disk write detection in emulator I/O layer

## Version 1.4.5 (Build 32)
- NVRAM boot configuration persists across sessions
- Simplified boot options UI - configure via ROM's SYSCONF ('W' menu)
- Clear Auto-Boot button to reset stuck boot settings
- Manifest disk write warning when modifying auto-downloaded disks
- Fixed autoboot clearing (legacy boot_string mechanism)

## Version 1.4.4 (Build 31)
- Add auto-start feature with countdown
- Fix boot option NVRAM integration
- Add build number to About box

## Version 1.4.3 (Build 29)
- Unify RAM bank initialization to use shared HBIOSDispatch bitmap
- Remove Infocom disk (duplicate of Games)
- Fix duplicate Games entry in disk manifest
- Add distribution documentation

## Version 1.4.2 (Build 24)
- Remove per-disk slice limits UI and settings
- Move control key stripe from horizontal to left side vertical
- Connect Help menu bar item to show Help view
- Add better error diagnostics to Help system
- Add Auto slice option
- Fix boot disk as A: via upstream CB_BOOTVOL

## Version 1.4.1 (Build 18)
- Auto-calculate disk slice count based on number of loaded disks
- Update CP/M 3 description - now working with bank config fixes
- Add export compliance key to suppress App Store encryption dialog

## Version 1.4.0 (Build 15)
- Add remote help system with platform-specific examples
- Add menu items to open Imports/Exports folders
- Fix W8/R8 file transfer for Mac Catalyst
- Integrate upstream emu_init shared initialization
- Add Ctrl key toolbar for control character input
- Fix input handling and remove debug output
- Working bank config changes

## Version 1.3.7
- Refactor to use qkz80 subclassing for I/O and halt handling

## Version 1.3.6
- Update disk catalog to v6 with 21 RomWBW 3.5.1 disk images
- Fix license display from MIT to GPL v3 in About boxes
- Add KNOWN_PROBLEMS.md documenting disk creation and data persistence issues

## Version 1.3.5
- Fix auto-download using same path as settings download

## Version 1.3.3
- Fix sequential download bug
- Update menu bar name

## Version 1.3.1
- Version bump for TestFlight

## Version 1.3.0
- Add automatic retry for disk downloads
- Add ROM attestation for App Store review

## Version 1.2.0
- Catalog versioning
- Error handling improvements
- Debug flag support

## Version 1.1.0
- Add R8/W8 host file transfer utilities
- Add VT100 terminal emulation for Infocom games
- Add privacy policy and license

## Version 1.0.0
- Initial release
- Full Z80 emulation with accurate instruction timing
- RomWBW HBIOS compatibility
- VT100/ANSI terminal with escape sequence support
- Multiple disk support (up to 4 units, hd1k format)
- Download disk images from RomWBW project
- Local file support for disk images
- Mac Catalyst support
- Copy/paste support
- Auto-save downloaded disk images
- Remote disk catalog with caching
