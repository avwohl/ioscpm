# Manual checks

Checks that need a person: an app installed and driven by hand, keys pressed, a
screen watched.  Nothing here can be settled by reading the source or by any
suite in `Tests/`, which is why none of it lives in `todo.txt` - that file keeps
a one-line pointer at this one.

**Delete a check once someone has run it.**  What it found goes in
`CHANGELOG.md`; what it left open goes in `todo.txt`.  A check that has been run
and left in place turns this file into the accumulating record `todo.txt` was.

**Some of these need a gesture, not a person, and a gesture can be synthesised.**
`tools/simdrive.py` drives the booted Simulator with real touch events - taps,
presses, press-and-drag, flicks - addressed in the pixel coordinates of a
`simctl` screenshot, so you point at what you can see.  Build 61's text
selection was verified with it end to end.  Two limits keep it honest: it
calibrates the device screen inside the Simulator window and **fails rather than
guessing** when its own measurement disagrees with the device's screenshot, and
synthetic **key** events still do not reach the app at all (check 3), so type by
tapping the on-screen keyboard.  What it cannot be is a finger - see the note in
section 17 - so it retires a check only where the check is about behaviour and
not about touch itself.

    tools/simdrive.py calibrate            # and it will tell you if it is lost
    tools/simdrive.py shot /tmp/s.png      # read your coordinates off this
    tools/simdrive.py press 238 1000 346 1000

Most of this needs a Mac, not a device.  **Whether the machine you are on is
one is a question to measure, not to read here** — this paragraph and the one
that followed it have contradicted each other for several builds because each
recorded a different machine.  `ls -d /Applications/Xcode.app` settles it.  If
`xcodebuild` tells you it "requires Xcode", that alone means nothing: it is
printed both when `xcode-select` merely points at the Command Line Tools and
when there is no Xcode at all.  When it is present but unselected, prefix the
command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, which
needs no `sudo`.  The iOS Simulator runs the identical
Swift layer against a real sandbox - `xcrun simctl get_app_container booted
com.awohl.cpm data` gives you the `Documents` folder to inspect - and
`SUPPORTS_MACCATALYST = YES`, so the Catalyst pass is a `xcodebuild
-destination 'platform=macOS,variant=Mac Catalyst'` away.  Say so if a check
really does need hardware: check 3 needs an iPad with a hardware keyboard, check
4 a real device, and check 8 a phone or a keyboard-less iPad - the point of that
one is the case where there is no hardware keyboard to fall back on.

**Build 67 has been run.**  On 2026-09-07, on a Mac with Xcode 26.6, this tree
was built for the iOS Simulator, for an arm64 device and for Mac Catalyst,
installed on an iPhone 17 simulator, and driven.  Section 18 was worked
through - 8 of its 11 boxes are ticked with what was measured.  Sections 19 and
20 were not: counted 2026-09-15, §19 is 4 ticked and 16 open, and §20 is 0
ticked and 10 open, recording its happy path in prose instead.  Builds 62 through 66 never reached a simulator,
which is why so much of this file was written as unrunnable.

`sh tools/check-store-version.sh` is the only thing that says what USERS have.
Measured 2026-09-15: the App Store serves 1.6.1, released 2026-09-12, against a
tree at 1.6.1 build 72 - which the script brackets as "at most build 70", since
1.6.1 heads builds 67-72 and the lookup does not say which. Run it rather than
reading this line; built is not shipped.  **Observations
below carrying a date or a build number older than 67 were made on an EARLIER
tree** - build 55, 56 or 61 - and have not been repeated since.

What runs on any machine, Xcode or not, is `sh Tests/run_tests.sh`: 21 suites,
about 1,250 assertions, exit 0 - measured 2026-09-15, and it moves every
build, so run it rather than trusting this number.  One of
them now type-checks `EmulatorViewModel.swift` against the macosx SDK with the
real bridging header, which is what caught `emulator?.loadROM(fromData:)` - the
Objective-C `loadROMFromData:` imports into Swift as `loadROM(from:)`, so the
app target did not build at all.  **A type-check is not a run**, and it does not
reach the five files that import UIKit - `ContentView`, `TerminalView`,
`CatalystWindow`, `HelpView` and `iOSCPMApp` - which need an iOS SDK and have
never been through a compiler in the state they are in now.
`Tests/check_view_bindings.sh` checks every `viewModel.<member>`
`ContentView.swift` asks for against the model's declarations, and it is the
only thing standing between a renamed member and a build that fails on the
first machine that has Xcode.

---

## 1. Build 52's destructive W8/R8 paths

Build 52 is a data-loss fix and none of it has been driven by hand.  Use a
**throwaway disk library**: check 1 is the one that used to delete everything.

- [ ] `W8 ANYFILE.TXT ..` -> refuses, or exports to `Exports/export.txt`.
      Afterwards `Documents`, `Documents/Disks` and `Documents/Imports` are all
      still there.
- [ ] `W8 FOO.TXT` -> still exports normally.  The `H_CAPS` interlock in the new
      `w8.com` must **not** fire for a path-less export; if it does, a refreshed
      disk image breaks ordinary transfers for everyone.
- [ ] `W8 FOO.TXT out.txt` -> lands in `Exports` as `out.txt`, and the
      `To host:` line names the real `Exports` path rather than a bare name.
- [ ] `R8 NOSUCH.COM` -> reports "not found in Imports".  Before build 52 it
      silently loaded the first file in the folder instead.
- [ ] `R8 FOO.COM` where the file on disk is really `foo.com` -> still found.
      This is the case-insensitive resolve in the Swift layer.
- [ ] `W8` on a zero-byte CP/M file -> a zero-byte file appears in `Exports`.
      It used to vanish with a success message on both sides.  `SAVE 0
      EMPTY.TXT` at the `A>` prompt makes the empty file (CCP built-in, not
      checked here); any other route to a zero-length CP/M file does as well.

Checks 1 and 2 need a disk image carrying the **new** `w8.com`, and **both
published releases serve one**.  Measured 2026-09-08 by downloading the two
images the app can actually install and counting bytes in them:

    hd1k_combo-v0-3.5.1.img  0ca4ec60…  Usage: W8 <cpmname> [hostpath], one 06 e9 cf
    hd1k_combo-v0-3.6.0.img  f4873027…  the same, and one 06 ea cf in each as well

There is nothing left to choose between at download time: `releaseTag` is gone,
nothing in the app fetches from `avwohl/ioscpm` any more, and every image it can
install comes from the romwbw_disks catalog.  What can still make checks 1, 2, 14
and 15 the wrong test is an image already sitting in `Documents/Disks` from an
older build - `v1.4.5`'s combo has only `Usage: W8 <cpmname>`, no `[hostpath]` -
because the interface-v0 migration renames such a file to
`hd1k_combo-v0-3.5.1.img` on its NAME alone and never looks inside it.  On a
fresh install you have the new one by construction; on an upgraded device,
**check which one you have before running any of them**:

    xxd -p w8.com | tr -d '\n' | grep -c 06e9cf   # 1 = interlocked, 0 = armed

## 2. The WordStar diamond, and Escape, under Mac Catalyst

Never watched under Catalyst.  Build for Mac Catalyst and run WordStar.

- [ ] Walk the diamond: `^A ^D ^E ^F ^K ^P ^R ^S ^V ^X ^Y` and `^QS`.  Every one
      of the twelve reaches WordStar and none of them is eaten by AppKit's emacs
      `StandardKeyBinding` bindings.  Why that is expected to hold is in
      `KNOWN_PROBLEMS.md`; this is the observation that settles it.
- [ ] Escape reaches the guest windowed **and** full-screen, now that the escape
      `UIKeyCommand` sets `wantsPriorityOverSystemBehavior`.
- [ ] Escape dismisses each of the four dialogs in `modalHasKeyboard`
      (`ContentView.swift`) rather than reaching CP/M: the disk-overwrite
      warning, the error alert and the reset confirmation.

## 3. Ctrl+arrow end to end

**This one really does need an iPad with a hardware keyboard.**  Synthetic key
events do not reach the app inside the Simulator at all (a plain arrow between
typed characters produces no guest input either, so there is not even a
baseline), and macOS claims Ctrl+arrow for Mission Control at the WindowServer
level before Catalyst sees it.

The mapping is covered by `Tests/KeyMapTests.swift`; what is unobserved is the
three-line resolution in `pressesBegan` that turns a held Ctrl into the modified
binding.

- [ ] Under the VT100 or WordStar profile, Ctrl+Up / Down / Right / Left send
      `\E[1;5A` / `B` / `C` / `D` and the plain arrows still send what they did.
- [ ] Under VT52, Ctrl+arrow sends the plain VT52 arrow (`\EA`..`\ED`).

---

## 4. The three per-cell faces, on a device

Build 55 gave a cell a `flags` byte and taught `TerminalView` to draw it. All
three were watched on the **iPhone 17 Pro simulator** and nothing was run on
hardware, where the font metrics and the timer are not the simulator's.

Drive them the way build 55 did: put the escape sequences in a file, `R8` it and
`TYPE` it, because the CCP echoes a typed ESC as `^[` and never lets one reach
the parser.

- [ ] `ESC[1mBOLD` draws in a heavier face and the grid does not move. The
      metrics come from the plain face alone, so a bold run must not push the
      rest of its line right or overlap the cell beside it.
- [ ] `ESC[4mUNDER` draws a rule in the *glyph's* colour, not in white.
- [ ] `ESC[5mBLINK` alternates about twice a second, and the cell keeps its
      background through the off phase - only the glyph and its rule go.
- [ ] A screen with **no** blinking cell never repaints on its own. The timer is
      created only while one is on screen (`syncBlinkTimer`); if an idle CP/M
      prompt is redrawing twice a second, that is the bug this check exists for.
- [ ] Scroll a blinking line up into scrollback and back down. The flags travel
      with the cell.

## 5. A download that fails its checksum

Build 55 moved the SHA256 check onto the live download path. Nothing has driven
the rejection arm — only the passing one, which is every ordinary download.

- [ ] Point the app at a catalog whose `sha256` for one image is wrong. Serve
      your own through a proxy: editing the cached
      `Documents/Disks/catalog-v0-<release>.json` reaches only the offline path,
      because a fetched catalog is checked against the index's `catalog_sha256`
      before it is parsed. (The `disks_catalog.xml` this box used to name is not
      fetched or written by any build since 63.) The download must retry three
      times, end as **Checksum mismatch**, and leave **no** `.img` behind in
      `Documents/Disks`.
- [ ] The first-run fetch (`downloadDisksAndStart`) surfaces that as a failure
      rather than starting the emulator with a missing disk.
- [ ] A catalog entry with no `<sha256>` at all is **refused**, with
      `No checksum in catalog - not saved`, and nothing is written to
      `Documents/Disks`. This box used to say the opposite — "the field has
      always been optional and a missing hash is not a failure" — and had been
      wrong since 2026-09-01, when `downloadDiskFromSettings` started refusing
      such an entry rather than installing it. Every entry in both published
      catalogs carries a hash - 20 disks under 3.5.1 and 24 under 3.6.0, checked
      2026-09-08 - so one without is a degraded or hostile catalog.

## 6. A generation bump that now deletes nothing

**Read this before ticking anything: the behaviour this section used to check
is gone, and its boxes were inverted rather than deleted.**  A catalog
`generation` bump used to delete every downloaded image the new catalog named.
`checkCatalogGenerationAndInvalidate` is now `recordCatalogGeneration`, which
writes the number under `catalogGeneration.v0.<release>` and does nothing else,
and `deleteCatalogDisks(named:)` is gone.  What decides now is
`reassessDiskFreshness()` and `DiskLedger.action`, per file, from provenance -
they offer an update and never destroy work.

The measurement that settled it: the only generation bump that has ever
happened - romwbw_disks commit `aab3a4f`, 1 -> 2 on both releases - changed two
ROM hashes and **zero** of the twenty disk hashes.  The old code would have
deleted and re-downloaded twenty byte-identical images because two ROMs were
rebuilt.  Both releases publish generation 2 today, so a device that last saw 1
has a real bump waiting for it and is the right thing to stage.

Build 56's narrowing - delete only the images the new catalog names, keep the
user's own - was driven on the iPhone 17 Pro simulator in its day, with two
catalog disks and two of the user's own in `Documents/Disks`: the two catalog
disks went, the two others stayed, and the alert gave both counts.  That is
history now.  The thing it narrowed no longer exists.

- [ ] **A real bump deletes nothing.**  Set `catalogGeneration.v0.3.5.1` to `1`
      in the app container's preferences (shut the simulator down first -
      `cfprefsd` caches, see §16 for the `plutil` recipe), relaunch, and let the
      catalog land.  The log must read
      `[Catalog] RomWBW 3.5.1 generation 1 -> 2` and **every file in
      `Documents/Disks` must still be there**.  Count them before and after.  If
      anything is deleted, stop: that is the whole failure this build removed.
- [ ] **A disk that is selected in a slot is left alone.**  The slot must still
      name the same file afterwards and the emulator must still boot off it.
      The old question here was whether `refreshAvailableDisks` and
      `restoreDiskSelections` emptied a slot whose file had just been deleted;
      the question now is whether anything moved at all.
- [ ] **The same, while the emulator is running off that disk.**  Nothing may be
      deleted under a running machine and nothing may be refreshed under one
      either - `reassessDiskFreshness()` stands down while a disk is loaded, and
      §16 has the boxes for what the Update control must do instead.
- [ ] **A case-differing name is still recognised as the catalog's.**
      `HD1K_COMBO.IMG` beside the catalog's `hd1k_combo-v0-3.5.1.img`.  The fold
      is deliberately case-insensitive so it behaves the same on both kinds of
      volume.  Nothing is deleted either way now, so what this checks is that
      the ledger and the freshness row find the file rather than reporting it as
      an unknown image of the user's own.
- [ ] **No alert fires.**  The invalidation used to raise one giving two counts,
      "n catalog disks removed" and "n of yours kept".  There is no such alert
      in the code any more.  Seeing one on a generation bump means a copy of the
      deletion path survived somewhere.

---

## 7. *(closed — build 61 was driven)*

All five boxes are measured and the section is gone, per the rule at the top of
this file.  CP/M 2.2 boots on the iPhone 17 Pro simulator and takes software-
keyboard input; scrollback moves `sb 0/12` -> `sb 12/12` on a one-finger swipe;
the Catalyst build launches and its pointer drag and Cmd+C return real text.
`CHANGELOG.md` under build 61 has the detail.

**The number is kept as a hole on purpose.**  `todo.txt` and `CHANGELOG.md` cite
these sections by number ("sections 8 through 16", "sections 14 and 15"), so
renumbering would silently retarget every one of them.

## 8. The on-screen key row, on a phone

The largest parity gap in the port: every key in the map arrived through
`UIKey`, so on a phone or a keyboard-less iPad **none of the 26 could be
pressed at all**.  `KeyRowLayout.pages` is three pages — Nav (4 arrows + Home,
End, PgUp, PgDn, Ins, Del), Fn (F1-F12), Ctrl (the four Ctrl+arrows).  A test
asserts every `SpecialKey` case is on one of them; nothing has pressed one.

- [ ] On a **phone**, the row appears under the terminal and every key on all
      three pages sends what the current profile says it should.  Under VT100,
      the Nav arrows send `\E[A`..`\E[D` and F1-F4 send `\EOP`..`\EOS`.
- [ ] The page picker switches pages and the row does not resize the terminal
      as it does.
- [ ] `showKeyRow` off hides it and the terminal takes the space back.
- [ ] The row respects the key profile: switch VT100 -> VT52 and the same Nav
      arrow now sends `\EA`..`\ED`.
- [ ] It does not overlap the home indicator or the keyboard when a hardware
      keyboard is absent and the software one is up.

## 9. The Ctrl page under Mac Catalyst

This is the page's whole reason to exist.  macOS claims Ctrl+arrow for Mission
Control at the WindowServer level before Catalyst is offered the press, so the
hardware binding checked in section 3 can never fire there — the row is the
only way to send those four.

- [ ] Under Catalyst, with the VT100 profile, the Ctrl page's four keys send
      `\E[1;5A` / `B` / `C` / `D`.
- [ ] The same four pressed on the **hardware** keyboard still do nothing under
      Catalyst.  That is expected, not a regression, and confirming it is what
      justifies the page.

## 10. The Emulator menu and window restore, under Catalyst

`iOSCPMApp.swift` replaced only `CommandGroup(.help)` before this.  The new
`CommandMenu("Emulator")` reaches `ContentView` over the same `NotificationCenter`
hop the Help item already used, so each item is a separate wire that can be
mis-spelled silently.  **Press every one.**

- [ ] Start / Stop (Cmd-R), Reset... (Shift-Cmd-R), Clear Screen (Cmd-K), Jump
      to Live (Cmd-L), Save All Disks (Cmd-S), Open Imports Folder, Open Exports
      Folder, Settings... (Cmd-,).  Each does what its label says.
- [ ] Reset... and Settings... raise the same dialogs the in-app controls do,
      and Escape dismisses them (section 2 covers the escape path).
- [ ] Cmd-S does not collide with anything AppKit wants, and the two folder
      items open Finder at the real `Documents/Imports` and `Documents/Exports`.

Window state is split so the decision is testable and the UIKit call is not:
`WindowFrame` has 34 checks, `CatalystWindow` has none.  Minimum size is
640x480; a restored frame must leave at least 60x60 on screen.

- [ ] Resize and move the window, quit, relaunch: it comes back where it was.
- [ ] Restore with the saved frame mostly off-screen — unplug a second display,
      or edit `catalystWindowFrame` in the app container's preferences.  The
      window must land somewhere reachable rather than off the edge.
- [ ] Below iOS 16 there is no supported way to place a window and the code says
      so rather than reaching for a private API; confirm it degrades to the
      system default instead of failing.

## 11. Applying a profile

`EmulatorProfile` is the machine where `KeyProfile` was only the key-map half:
ROM, disks, boot string, key profile and bindings, scrollback capacity, bell,
manifest warning, key-row visibility, new-disk size.

It **deliberately does not carry the security-scoped bookmarks.**  A bookmark is
a token issued to one installation, not a name — a profile carrying one would
either fail to resolve or, worse, look like it had restored a disk it had not.
That is the thing to check hardest.

- [ ] Save a profile, change every setting it covers, apply it back.  All of it
      returns, and the summary line matches what is actually in force.
- [ ] Apply a profile naming a disk that is **not** present.  It must **say
      so** — `applyProfile` returns an `unresolved` list and appends
      `disk <n>: <filename>`, adding `(saved under RomWBW <ver>)` when the
      profile was saved under another release, because `hd1k_ws4` exists in
      3.5.1 and not in 3.6.0 and that is a permanent answer rather than a
      download away.  What to watch for is the silent case: a slot that appears
      to have restored a disk it has not.

      This box used to demand the slot "end up empty".  Check what the screen
      does against what `applyProfile` returns before filing anything: it
      reports the name rather than clearing the slot, and which of those is
      wanted is a decision nobody has recorded.

- [ ] ~~Two profiles saved under the same name collapse to one.~~  **Not
      reachable from the UI, so there is nothing to check.**  Every save goes
      through `ProfileStore.uniqueName(basedOn:)`, and the sheet tells the user
      when the name it will actually use differs from the one they typed.  The
      collapse behaviour the suite asserts is a store-level property the
      interface prevents you from producing.
- [ ] Delete the profile that is marked last-used; the pointer is dropped rather
      than left dangling.
- [ ] A profile saved on one device and carried to another restores everything
      except the disks, and is honest about the disks.

A profile now also records the RomWBW release it was saved under, and resolves
its disks by catalog id rather than by exact filename.  Neither is exercised
here: both are about crossing a release boundary, so their boxes are in §19
beside the picker that does the crossing.

## 12. A multi-slice disk, and the size picker

`DiskSize.offered` is 8 MB hd1k, then 2 / 4 / 7 hd512 slices (N x 8,519,680).
The round numbers are deliberately absent: `emu_validate_disk_image()` **refuses** a
16, 32 or 64 MB image, which is the trap a naive picker falls into.  Before this
the exporter wrote its own hardcoded 8 MB regardless of the choice.

**This is also how `WIP.md`'s one open question gets settled** — whether
multi-slice hd512 is right, or whether it should be 1 MB + N x 8 MB hd1k with a
hand-written type-0x2E MBR.  The reasoning says hd512 needs no MBR and lands its
slices exactly on the file.  Nothing has confirmed it on a real machine.

- [ ] Create a disk at each offered size.  The file on disk is exactly the byte
      count the picker promised — check both the `.fileExporter` path and the
      rewrite, because it was the exporter that ignored the choice.
- [ ] The 2-slice disk mounts and **two drive letters appear**.  4 and 7 give
      four and seven.  If they do not, the open question is answered the other
      way and `DiskSize.swift` needs the hd1k shape with an MBR.
- [ ] Write files to the second slice, eject, remount: the data is there.  A
      slice that runs off the end of the file would show up here.
- [ ] The app still accepts an imported disk up to 64 MB.  Import is unchanged
      and must stay that way.

## 13. The bell toggle

`processNormalChar`'s BEL arm used to call `playBeep` with nothing to consult, so
a guest that BELs in a loop could not be silenced.  It is gated inside
`TerminalScreen` next to the counter now, which is what made it testable with no
audio engine near it; the Settings toggle is "Terminal Bell".

- [ ] BEL rings with the toggle on and is silent with it off.  `^G` at the `A>`
      prompt, or `TYPE` a file with a `0x07` in it.
- [ ] A guest BELing in a loop can be silenced **while it runs**, not only
      before it starts.
- [ ] Reset the machine with the bell off.  It stays off — `resetToPowerOn()`
      deliberately does not touch it, because the setting is the user's and not
      the guest's, and a test says so.
- [ ] The setting survives a relaunch, and travels in a profile (section 11).

## 14. R8 now says which file it is actually reading

`emu_host_file_open_read()` (`emu_io_ios.mm`) is **synchronous** as of build 61.
It used to park the request on the main queue and return, so the state was still
`WAITING_READ` when R8 asked `H_GETRNAME` (0xEA) ten Z80 instructions later, and
`emu_host_file_get_read_name()` truthfully answered `""` — leaving R8 to print
the name the CCP shouted at it.  `Tests/CoreHostFileTests.cc` proves the core
side of this against both backend shapes; what no suite can reach is the
Objective-C++ that does the actual resolving.

Needs an image whose `r8.com` calls 0xEA, and both published Combos qualify:
the bytes `06 ea cf` occur once in `hd1k_combo-v0-3.5.1.img` and once in
`hd1k_combo-v0-3.6.0.img`, measured 2026-09-08 on the published files.  A freshly
downloaded Combo on either release is enough; an image carried over from
`v1.4.5` is not, and the migration renames one of those to a v0 name without
looking inside it.

- [ ] Put a file in `Imports` whose name is **lowercase**: `esc.txt`.  At the
      `A>` prompt run `R8 ESC.TXT` (the CCP uppercases it whatever you type).
      R8 must print `Reading: /…/Documents/Imports/esc.txt` — an absolute path,
      ending in the **file's own** lowercase spelling.  Printing `ESC.TXT` means
      the resolve took the case the CCP invented, which is what
      `fileExists(atPath:)` used to do on a case-insensitive volume.
- [ ] The file arrives in CP/M intact and under the expected name.
- [ ] A **zero-byte** file in `Imports` still produces a zero-byte CP/M file
      rather than an error.  The open must reach `HOST_FILE_READING` even with
      nothing to read; guarding that on a non-empty read is the hole build 53
      closed on the write side.

## 15. R8 on a file that is not there — a deliberate behaviour change

Before build 61 the open **succeeded** for a name that did not resolve: R8
printed `Creating:`, the first read hit instant EOF, and a zero-byte CP/M file
was left behind.  The open now fails.

- [ ] `R8 NOSUCH.COM` → R8 reports it cannot open the host file, and **no CP/M
      file is created**.  `DIR` afterwards must not show a zero-length
      `NOSUCH.COM`.
- [ ] The alert still names the Imports folder path, and the folder exists
      afterwards — the Swift handler is now failure-only and creating that
      directory is the one thing it still does.
- [ ] `R8 ../SOMETHING` cannot reach outside `Imports`.  The containment
      reduction is still in front of the scan, not instead of it.
- [ ] `R8` naming a **directory** inside `Imports` fails rather than making an
      empty CP/M file.  `fopen` succeeds on a directory on Darwin — measured —
      so this is the `S_ISREG` guard, and nothing else exercises it.
- [ ] A file in `Imports` **larger than 8 MB** fails the open rather than
      arriving truncated.  R8 derives the CP/M name from what was typed and
      cannot notice a short read, so a truncated copy would land under the right
      name with both sides reporting success.

## 16. A superseded disk image, refreshed

Build 61's `DiskLedger`.  The suite (`Tests/DiskLedgerTests.swift`, 66 checks)
covers the decision; the **automatic path has now been driven end to end** on the
iPhone 17 Pro simulator against a real sandbox, which is what the ticked box
below records.  Everything else here is still unobserved.

Staging a case by hand needs two things known.  The ledger is a **JSON string**,
so `PlistBuddy` (which strips the quotes) and a `-key value` launch argument
(which parses `{…}` as a plist dict) both corrupt it — use
`plutil -replace diskLedger -string '<json>' \
  "$(xcrun simctl get_app_container booted com.awohl.cpm data)/Library/Preferences/com.awohl.cpm.plist"`.
And `cfprefsd` caches preferences, so **shut the simulator down** before editing
that plist or the app will never see it.

The interesting setup is the one every existing install is in: an image on disk
with **no ledger entry**, because nothing has ever written one.

- [ ] Fresh install, download the Combo, then relaunch.  The row shows a green
      hash and offers no update.  Provenance was recorded by the download.
- [ ] Install with an image already present and no ledger (simulate by deleting
      the `diskLedger` key from the app container's preferences).  On the next
      catalog fetch the file is hashed **once**, off the main thread; a matching
      image adopts its provenance and never hashes again.  Watch that a
      relaunch does not re-read 49 MB.
- [ ] An image that does **not** match the catalog and has no ledger entry gets
      the orange Update control and the "any files you saved will be lost"
      confirmation — and is **never** refreshed on its own, on any network.
      There is no evidence that separates a superseded image from one the user
      wrote to, and guessing here destroys data.
- [x] With a ledger entry proving the file pristine and superseded, on an
      unmetered path it refreshes itself unattended.  Verified 2026-09-04:
      `hd1k_games.img` was staged carrying a different image's bytes with
      provenance to match, and the app logged
      `[Freshness] Path: reachable=true expensive=false constrained=false`,
      `[Freshness] Refreshing superseded image 'hd1k_games.img' automatically`,
      `SHA256 verified: 7f33738c…`, `Install successful` — the file ended up
      hashing to the catalog's value, the ledger recorded the new provenance with
      its measurement, and the **next launch downloaded nothing at all**, which
      is the half that would otherwise loop.  No `.incoming` left behind.
- [ ] The row goes green in the UI afterwards.  Only the log and the files were
      inspected above; nobody has looked at the settings screen.
- [ ] On **cellular** it does not refresh — the row says "waiting for Wi-Fi" and
      the Update button still works if tapped.  Low Data Mode behaves the same
      way and says so.  Unobserved: the simulator reports an unconstrained,
      inexpensive path and there is no way to make it say otherwise.
- [ ] Cellular must not produce an error.  The automatic session's own refusal
      arrives as `NSURLErrorNotConnectedToInternet`, whose text is "The Internet
      connection appears to be offline" — a lie on good LTE.  It must be
      swallowed into the waiting state, not retried three times and parked as a
      red error.
- [ ] Boot the machine off a superseded disk and leave it running.  Nothing
      refreshes it, and the note says "stop the emulator to update this disk".
      The Update item must be **gone** from the menu, not merely inert: the next
      flush would write the old image straight back over the download while the
      ledger recorded the new hash as this file's provenance, which is a lie that
      never corrects itself.
- [ ] Start an automatic refresh on Wi-Fi and press Play before it finishes.
      The transfer is cancelled rather than landing under the running machine,
      and the row goes back to showing the installed disk.
- [ ] The same, but let the machine WRITE to the disk before the download lands
      (create a file in CP/M and wait for the twenty-second flush, or Stop).
      The install must be **abandoned** — the log says the file changed under the
      transfer — and the user's disk must still be there with their file in it.
      This is the check that the whole feature is safe; it is the one path on
      which an unattended download can reach a file somebody is using.
- [ ] Fill the device's storage and then update a disk.  The old image must
      survive: the install stages into `Disks/<name>.img.incoming` and swaps, so
      a failure leaves what was there rather than nothing.  Confirm no stray
      `.incoming` file is left behind afterwards.
- [ ] Cancel a refresh with the X while the old disk is still installed.  The row
      must go back to the green installed state, **not** to a download arrow —
      the file never went anywhere.  And it must **stay** cancelled: a cancelled
      transfer used to fall into the generic retry arm and restart itself a
      second later.
- [ ] Press **Reset**, then look at a superseded disk that was in a slot.  It
      must still count as mounted — no automatic refresh, no Update item —
      because `HBIOSEmulator::reset()` leaves the disk loaded and the machine can
      still write its copy back.  Also confirm the twenty-second auto-save timer
      has stopped: `[SaveDisks]` must not keep appearing in the log after a
      Reset the way it did before.
- [ ] Delete a superseded disk.  The orange "any files you saved in it are lost"
      note goes with it rather than sitting under a row for a file that no longer
      exists.
- [ ] Settings with the Combo installed no longer stutters.  `checksumStatus`
      used to hash 49 MB inside `body`; it is a dictionary lookup now, so
      scrolling the disk list should cost nothing.

## 17. Press-and-drag selection, on a real finger

**These became runnable on 2026-09-04**: build 61 went to App Store Connect for
iOS and Mac, so a TestFlight build should be installable on real hardware well
before the release itself clears review.  Being *able* to run them is not having
run them, and none of the boxes below may be ticked from a simulator.

The gesture was driven end to end on the iPhone 17 Pro simulator with synthetic
mouse events, and everything a *decision* can settle is settled there and in
`Tests/TerminalSelectionTests.swift`.  What a simulator cannot supply is a
finger.  All four boxes below are about the difference, and **needs a device**.

- [ ] **The press takes, reliably, held by a human hand.**
      `minimumPressDuration` and `allowableMovement` were both left at UIKit's
      defaults on purpose — perturbing them perturbs the arbitration that makes
      scrolling work — but the default `allowableMovement` is 10 points, and a
      synthetic mouse holds *perfectly* still where a thumb does not.  If the
      press fails on a real hand often enough to be annoying, raise
      `allowableMovement` **and then re-run the scroll box below**, because
      raising it is exactly what removes the long press's movement-failure path.
- [ ] **A slow scroll drag is never stolen by the long press.**  The arbitration
      is "a flick reaches the pan's threshold before the press reaches its
      duration".  A deliberately slow drag is the case where that is closest to
      a coin toss, and a synthetic drag cannot be slow the way a person is.
      Scroll must still scroll.
- [ ] **The haptic fires on `.began`.**  `UISelectionFeedbackGenerator` is a
      no-op on a simulator and on Catalyst.  It is the only feedback a finger
      covering the cell it just selected can actually perceive, so if it does
      not fire the gesture is much harder to discover than it reads here.
- [ ] **The selection is usable on an iPad in Split View and in Slide Over**,
      where the terminal is narrow, the letterbox bars are wide and a drag
      leaves the view often.  `cell(at:)` clamps to the grid so a drag that
      leaves still selects to the edge; that is checked in the suite as
      arithmetic and not as a gesture.

Two things are known missing rather than unchecked, and neither needs a person
to discover:

- **There are no grab handles.**  A selection cannot be adjusted after the
  finger lifts — it has to be dragged again.  Handles are not obtainable from
  `UIEditMenuInteraction` at any price; they come only from `UITextInteraction`,
  whose `textInput` property is typed `(any UIResponder & UITextInput)?`, so
  buying them means 26 new `UITextInput` members plus `UITextPosition`,
  `UITextRange` and `UITextSelectionRect` subclasses and a tokenizer — on a view
  whose "document" is a mutable 80x25 buffer that scrollback rewrites underneath
  any live range.  Hand-drawn handles hit-tested in the existing pan handler are
  the cheap version if it turns out to be wanted.
- **Guest output scrolls out from under a live selection.**  `handlePan` clears
  the selection when *you* scroll, because the span is in screen coordinates —
  but a line feed from CP/M moves the same content through `updateCells` and
  nothing clears it there, so the highlight stays on its cells while different
  text arrives under it.  This is not new and not iOS-only: the Mac has behaved
  this way since build 57.  It is left alone rather than fixed blind, because
  the obvious fix — clear on any cell change — would also fire on the cursor
  blink and on every keystroke echo.
- **Dragging past the top edge does not autoscroll.**  It clamps to row 0.  It
  cannot simply call `onScroll` either: the anchor is a screen-space `GridPos`,
  so a scroll silently makes it point at different text.  Autoscroll would have
  to shift the anchor's row by the number of lines scrolled.

---

## 18. The interface-v0 storage migration, on a real container

Build 63 renames every catalog disk in `Documents/Disks` from `hd1k_combo.img`
to `hd1k_combo-v0-3.5.1.img`, and rewrites the four disk slots, every saved
profile and the ledger to match.

**RUN 2026-09-07, at build 67, on an iPhone 17 simulator**, against containers
staged to look like pre-v0 devices: legacy filenames, legacy keys, a user's own
image, and a distinctive mtime on every file so a copy could not be mistaken for
a rename.  The boxes below carry what was measured.  What is still open is
marked, and it is the part a simulator cannot stand in for.

The tree carries builds 64, 65 and 66 as well, so the binary in front of you
does §19's fetch and §20's ROM download too.  Read the three sections as one sitting:
everything below is still about the rename, but the catalog it meets afterwards
is the v0 one and the ROM it boots with is a download rather than a file in the
app.

Stage a container that looks like a real one before touching any of this:
`xcrun simctl get_app_container booted com.awohl.cpm data` gives you the
`Documents` folder, and the app's preferences plist is beside it.  A container
with two catalog disks, one image the user imported, a slot pointing at each, a
saved profile and a ledger with a record for each is enough for all of it.

- [x] **The renames happen and nothing else moves.**  MEASURED 2026-09-07:
      `hd1k_combo.img` and `hd1k_ws4.img` came back as `-v0-3.5.1.img`,
      `mywork.img` kept its name, and **every mtime was unchanged** (staged at
      `Jan 1 12:00:00 2026`, still that afterwards) — so `moveItem`, not a copy.  The two catalog images
      come back as `-v0-3.5.1.img`; the imported one keeps its name; and
      `disks_catalog.xml` is untouched.  Check the size **and the modification
      time** of a renamed file against what they were: if mtime moved, it was
      copied rather than renamed, and every ledger measurement has just been
      invalidated.
- [ ] **The library is not re-hashed on the next launch.**  With the ledger
      correctly rekeyed, nineteen of twenty catalog images should be judged
      without reading a byte.  Watch for `measureDisks` running over the whole
      directory — that is what a wrong rekey looks like, and it is ~210 MB.
- [x] **A slot survives.**  MEASURED: legacy `selectedDisks` untouched at
      `[hd1k_combo.img, hd1k_ws4.img, mywork.img, ""]`, and
      `selectedDisks.v0.3.5.1` = `[hd1k_combo-v0-3.5.1.img,
      hd1k_ws4-v0-3.5.1.img, mywork.img, ""]`.  **The profile half is still
      open** — no saved profile was staged.  The slots come back pointing
      at the renamed files, the emulator boots off them, and applying a saved
      profile still resolves its disks *and its ROM*.  `romFilename` is
      deliberately not migrated, and the reason for that changed when the
      bundled ROM went: there is no file in the app to name any more, and which
      catalog filename `emu_avw` has depends on the release the profile is
      applied under, so there is no single string to rewrite it to.
      `applyProfile` matches it by catalog id instead (`ROMOption.answersTo`).
- [x] **A slot bound to a local file is still bound to it.**  MEASURED: the
      user's own `mywork.img` stayed in its slot under its own name, and
      `localDiskBookmarks.v0.3.5.1` holds the legacy array verbatim with the
      unsuffixed key still beside it.  `""` in
      `selectedDisks` means both "no disk" and "local file", and this is the
      case that proves the migration left it alone.  The bookmarks themselves
      moved key: `localDiskBookmarks` is scoped per release now, like
      `selectedDisks` and `emulatorNvram`, and the migration copies the legacy
      unsuffixed array into `localDiskBookmarks.v0.3.5.1` verbatim and
      unconditionally - there is no filename in a bookmark, so nothing about it
      depends on which files moved, and this same launch writes that key later.
      Confirm the versioned key exists afterwards and the legacy one is still
      beside it.
- [ ] **A destination that already exists is kept, and the slot stays on the
      OLD name.**  Put both `hd1k_combo.img` and `hd1k_combo-v0-3.5.1.img` in
      the directory with a slot naming `hd1k_combo.img`, run it, and confirm
      both files are still there afterwards **and that
      `selectedDisks.v0.3.5.1` still says `hd1k_combo.img`**.  Rewriting that
      slot to the v0 name binds it to the OTHER image - the one that was
      already sitting there, which this pass neither moved nor verified - and
      `saveDownloadedDisks()` then writes the running machine back over that
      one.  `CatalogMigration.blockedByExistingDestination(in:)` is what keeps
      the stored names behind with the file, and the old file is offered again
      as a user-added disk, because a pre-v0 name has no release in it for
      `belongsToAnotherRelease` to object to.  The app boots off whichever the
      slot names.  `migratedToInterfaceV0` must still be SET afterwards: this
      collision is permanent - the pass deletes neither copy, so every later
      launch would find it again - and holding the flag back for it would
      re-run the whole pass on every launch for the life of the install while
      printing a deferral that can never come true.
- [ ] **A rename that fails leaves everything consistent.**  **Not with a
      directory at the destination**, which is what this box used to say.
      `contentsOfDirectory` lists a directory like any other name, so
      `renames(in:)` drops that rename before `moveItem` is ever reached and
      what you would measure is the box above instead.  For the move itself to
      throw, the destination has to be ABSENT from the listing: `chmod 555` on
      `Documents/Disks` leaves it listable and makes every `moveItem` into it
      fail.  Confirm each affected slot still names the *old* file, that the
      emulator still boots off it, and that `migratedToInterfaceV0` is absent
      afterwards so the migration runs again on the next launch rather than
      freezing half-done.  Restore the permissions, relaunch, and confirm the
      names are rewritten then and the flag is set.
- [x] **Running it twice changes nothing.**  MEASURED: after a relaunch no
      image mtime moved, no name gained a second `-v0-`, and
      `migratedToInterfaceV0` stayed set.  Clear `migratedToInterfaceV0` in
      the preferences plist, relaunch, and confirm no file is renamed a second
      time and no name gains a second `-v0-`.
- [x] **A directory that cannot be listed defers the NAMES, and moves the KEYS
      anyway.**  MEASURED 2026-09-07 with `chmod 000` on `Documents/Disks`:
      `selectedDisks.v0.3.5.1`, `emulatorNvram.v0.3.5.1` and
      `localDiskBookmarks.v0.3.5.1` all EXIST holding the legacy values verbatim
      with pre-v0 names, and `migratedToInterfaceV0` is absent.  Build 67 fixed
      slot 0 here: `restoreDiskSelections()` forced the catalog default into it,
      which made `persistSelectedDisks(remembering:)` skip it and wrote that
      default over the carried name.  See `slotZeroFallbackIsSafe`.  Make `Documents/Disks` unreadable (`chmod 000` on the simulator
      container is enough), clear `migratedToInterfaceV0`, and relaunch.
      Nothing may be renamed - that part is obvious - but **this box was
      inverted after the deferral was found to lose data, so read it rather than
      remembering it.**  `selectedDisks.v0.3.5.1`, `emulatorNvram.v0.3.5.1` and
      `localDiskBookmarks.v0.3.5.1` must now all **exist**, holding the legacy
      values carried across verbatim with their pre-v0 names untouched, and
      `migratedToInterfaceV0` must still be absent.  Returning early instead -
      which is what "defers everything" used to mean - lost the user's boot
      string and their four slots permanently, because this same launch goes on
      to write those versioned keys itself and the legacy ones are then never
      read again.  Restore the permissions, relaunch, and confirm the names are
      rewritten then and the flag is set.
- [x] **Nothing deletes an image, on any path.**  MEASURED across a migration,
      two release switches and four relaunches: `catalogVersion` still reads
      `13` and was never touched, `catalogGeneration.v0.<rel>` went empty -> `2`,
      and no image was removed — both releases' ROMs and combo images sat side
      by side in `Documents/Disks` throughout.  `catalogVersion` still reads
      `13` and is never touched - the old key is orphaned, not carried across.
      `catalogGeneration.v0.3.5.1` starts empty and the first v0 fetch writes
      `2`, which is what both catalogs publish today.  Neither number can reach
      a deletion any more: §6 records that the invalidation is gone.  So a
      catalog fetch must clear no images at all, and if anything is deleted,
      stop - that is the failure this whole sequence exists to prevent.
- [x] **The boot string survives.**  MEASURED: `emulatorNvram` `"C:autoboot"`
      reached `emulatorNvram.v0.3.5.1`, was shown in Settings as the Auto-Boot
      value, and the ROM printed `NV Switches Found` and auto-booted from it.  `emulatorNvram.v0.3.5.1` should hold what
      `emulatorNvram` held, and the autoboot setting should be unchanged in
      SYSCONF after a warm boot.
- [x] **A fresh install is not affected.**  MEASURED on an erased simulator:
      no renames, `migratedToInterfaceV0` set, first-launch catalog defaults
      applied, slot 0 seeded with the recommended combo, and
      `catalogGeneration.v0.3.6.0` written as `2`.  Install into an empty container: no
      renames, no keys copied, first-launch catalog defaults still applied, slot
      0 still gets a disk.

## 19. The interface-v0 fetch and the release picker, on a real device

Build 64 deletes `releaseTag` and fetches `index-v0.json` from `romwbw_disks`,
then that release's catalog, then assets from the catalog's own `base_url`.  It
also adds a RomWBW release picker.

**RUN 2026-09-07, at build 67.**  The requests have been made and watched.  It was written on a machine with no Xcode;
`Tests/CatalogDocumentTests.swift` covers the document rules and skipped.  The
documents have now been checked from a shell, which is a different thing from
this code fetching them: on 2026-09-08 the compiled-in index URL returned HTTP
200 and bytes identical to `romwbw_disks/catalog/v0/index.json`, both releases'
catalogs matched the `catalog_sha256` and `catalog_size` the index claims, and
all four published ROMs matched their catalog entries.  So the URLs and the
hashes are right.  What is unobserved is the app going and getting them.

Do §18 first, on the same container.  A device that has not been through the
rename is not the interesting case for most of what follows.

- [x] **It fetches two documents and nothing else.**  MEASURED 2026-09-07: a
      launch on an erased simulator left `index-v0.json` and
      `catalog-v0-3.6.0.json` in `Documents/Disks`, the index byte-identical to
      what the compiled-in URL serves AND to `romwbw_disks/catalog/v0/index.json`,
      and the catalog matching the `catalog_sha256`/`catalog_size` the index
      claims.  The second URL came out of the first document.  **Caveat on this
      box's own wording:** the shipping binary still names
      nothing. That caveat held until build 70: the help system read its own
      `avwohl/ioscpm` URL then and reads `CatalogMigration.indexURL` now, so
      **no** request should go there - the three matches left in the Swift
      sources are comments recording the removal.  No
      `disks.xml` and no `v1.x.y` tag survives anywhere in the binary.  Watch the console for
      `[Catalog] Fetching index:` followed by `[Catalog] Fetching catalog:`.
      The second URL must come out of the first document, and no request may go
      to `avwohl/ioscpm` at all.  A request to `.../v1.4.12/disks.xml` means a
      tag survived somewhere.
- [x] **An asset URL has exactly one slash.**  MEASURED indirectly and
      conclusively: four assets (two ROMs, two 51 MB combo images) downloaded and
      verified.  Note the premise of this box is wrong — a doubled slash does
      NOT 404; GitHub serves it identically — so a successful download is the
      evidence, not the absence of an error.  Tap Download on any disk and read
      the URL in the log: `…/v0-romwbw-3.5.1/hd1k_combo-v0-3.5.1.img`, not
      `…/v0-romwbw-3.5.1//hd1k_combo…`.  A doubled separator is what the old
      client-side `"/"` produced, and it 404s.
- [x] **The disk list reads correctly again.**  MEASURED: after the migration
      the installed images show as installed with a green tick and their hash
      prefix, not as "(download)".  The `hd1k_combo` equivalence exception was
      exercised on a container carrying the real pre-v0 provenance
      `89b8ae1aaa6867dc…`: the row went from "A newer version is available" to
      installed-and-current, and a non-matching provenance still offered the
      update.  Every catalog row matches a file
      the migration renamed, so twenty rows show as installed rather than as
      "(download)" with the user's own images listed separately below.  That
      mismatch is what build 63 left behind and what this build ends.
- [x] **Nothing is deleted on the first v0 fetch.**  MEASURED:
      `catalogGeneration.v0.3.5.1` and `.v0.3.6.0` were both absent beforehand
      and both read `2` afterwards, and nothing in `Documents/Disks` was
      removed.  `catalogGeneration.v0.3.5.1`
      is empty before it and reads `2` after it - that is what both catalogs
      publish today, checked 2026-09-08 - and the images in `Documents/Disks`
      are all still there.  If the library is cleared, stop: that is the wipe
      the whole sequence exists to prevent, and §6 records that the deletion
      path it could have come from is gone.
- [ ] **A corrupted catalog is refused, not parsed.**  Hardest check here and
      the most valuable: serve a catalog whose bytes do not match the index's
      `catalog_sha256` (a proxy, or edit the cached
      `Documents/Disks/catalog-v0-3.5.1.json` and force a load of it).  The app
      must report a catalog-hop failure and fall back — never show a short disk
      list.
- [ ] **Offline is usable.**  Turn the network off and relaunch: the saved
      catalog loads, the slots resolve, and the emulator boots.  The message
      must say the list is the saved one rather than claiming an error, and no
      modal alert should appear when there is a usable cache.  Boot this one on
      a release whose ROM is already in `Documents/Disks`: with no bundled ROM
      left, an offline launch on a release that has never fetched its ROM stops
      at §20's **ROM Not Available** instead, which is correct behaviour and
      not this box failing.
- [ ] **The two hops are told apart.**  Break only the second one (a proxy that
      404s the catalog URL, or a cached index naming a URL that does not exist)
      and confirm the message says the release list loaded and the catalog did
      not.  With both broken it must name the index, not the catalog.
- [ ] **The picker offers EVERY release the index lists, and marks neither of
      today's two.**  3.5.1 and 3.6.0 are what the live index publishes, so two
      rows.  The right check is not "two" but "as many rows as
      `romwbw_versions` has entries with a `catalog_url`": this build filters on
      nothing else, and a third release appearing upstream must appear here with
      no app update.  Nothing is greyed out and no row says "(needs a newer
      build)" - there is no such state since romwbw_emu v1.44 deleted the
      compile-time release list, and a row that looked unavailable would be a
      regression rather than a correct refusal.  Both releases publish
      `"status": "stable"`, checked against the live index 2026-09-08, so
      neither row may carry a parenthesised suffix: `RomWBW 3.6.0 (preview)` was
      right when this was written and is wrong now.  Any status other than
      "stable" is shown verbatim, so a suffix coming back means upstream moved
      the field rather than that the row is broken.
- [ ] **The About screen names the release IN PLAY, not a list.**  It read
      `RomWBW 3.5.1, 3.6.0 core` until the release list went; there is no list
      to name now.  Open About before starting the machine and it must read
      `RomWBW <selected> selected - no ROM loaded yet`; start the machine, open
      it again, and it must read `RomWBW <release> ROM loaded` naming the
      release the loaded ROM's HBIOS configuration block declares.  The second
      is the answer to ask for in a bug report about an HBIOS/CBIOS mismatch,
      because the mismatch means the disks disagree with exactly that value.
      Worth one deliberate cross-check: it must agree with the release the
      picker shows selected, and if it does not, that is the bug.
- [ ] **A fresh install lands on 3.6.0.**  Install into an empty container, let
      the index land, and read the picker and `selectedRomWBWVersion.v0`.  3.6.0
      is the release flagged `"default": true` today (live index, 2026-09-08).
      This box was written when the source disagreed with itself: the call site
      passed `romwbwVersion` as `keeping:`, and on a fresh install that is
      already the pre-v0 `3.5.1` seed, so rule 1 of `preferred` matched every
      launch and the flagged default was unreachable.  `romWBWVersionToKeep`
      passes nil when nobody has chosen, which is the fix; **it has never run on
      a device, so check it rather than assuming it.**
- [ ] **An UPGRADING install stays on 3.5.1 and keeps its drives.**  The other
      half of the same change, and the one with something to lose.  Take a
      container that already has pre-v0 disks and configured slots, launch the
      new build, and confirm the storage migration renames the images, the
      picker still reads 3.5.1, and all four slots still name their disks.
      `romWBWVersionToKeep` decides this by looking for a non-empty
      `selectedDisks.v0.3.5.1`, so a device that had disks downloaded but no slot
      configured is expected to move to 3.6.0 - which is correct, and worth
      writing down separately if you can make one.
- [ ] **Switching to 3.6.0 changes everything that is per release, and destroys
      nothing.**  Slots empty, catalog re-fetches, `catalog-v0-3.6.0.json`
      appears beside the 3.5.1 one, and the boot string becomes 3.6.0's (empty,
      the first time).  Then switch back: the 3.5.1 slots, boot string and
      images are exactly as they were.  **Check `Documents/Disks` before and
      after: no file may disappear on either move.**
- [ ] **A slot bound to a local file is released and re-read on the switch, and
      never carried across.**  New this session and never exercised.
      `localDiskBookmarks` is keyed per release now, like `selectedDisks` and
      `emulatorNvram`, and the switch calls
      `stopAccessingSecurityScopedResource()` on each slot before clearing it.
      The arriving release's own bindings come back LATER, not in the switch:
      `restoreDiskSelections()` ends by calling `restoreLocalDiskBindings()`
      once the new catalog has landed, so a slot that is empty for as long as
      the fetch takes is the design and not the failure.  Bind slot 1 to a
      file of your own through Files on 3.5.1; switch to 3.6.0 and confirm the
      slot is empty rather than still naming that file; bind a *different* file
      there; switch back and confirm 3.5.1 has its original one.  Then do it
      twenty times in a row.  A switch that dropped the URLs without the
      balancing stop leaks one sandbox extension per slot per switch, and the
      symptom is not an error message - it is the app quietly losing the ability
      to open any file at all.
- [ ] **The other release's disks are not in the picker, and are still on
      disk.**  On 3.6.0 the slot menus must not list `hd1k_combo-v0-3.5.1.img`
      as a user-added disk.  Then check `Documents/Disks` and confirm every one
      of those files is still there — hidden from a menu is not the same as
      gone, and only one of those is acceptable.  A disk you imported yourself
      must still be listed.
- [ ] **The ROM the picker shows belongs to the release in play, at every
      moment.**  This box used to be about a Settings warning that the ROM was
      3.5.1's under a 3.6.0 release; there is no bundled ROM left to produce
      that state, and `availableROMs` is now built from the loaded catalog's
      `roms[]` alone.  So: switch to 3.6.0 and watch the ROM row through the
      whole move.  While the new catalog is in flight the row must be blank or
      say the catalog has not been read - `restoreROMSelection()` is called
      against an empty catalog on purpose - and it must never show
      `emu_avw-v0-3.5.1.rom` under 3.6.0 for even a moment.  Then confirm RomWBW
      itself prints no `*** WARNING: HBIOS/CBIOS Version Mismatch ***` on the
      boot that follows (§20 has that boot).
- [ ] **The picker is unavailable while running.**  Start the emulator, open
      Settings, and confirm the picker is disabled.  Then try it from a second
      window on Catalyst if you can: the model must refuse and say so rather
      than emptying the slots under a running machine.
- [ ] **An index that asks for a different release while the machine is RUNNING
      is HELD until Stop.**  New this session and never exercised, and it is the
      one path that moves the release without the user touching the picker.  The
      picker's guard is a `didSet` on `romwbwVersion`; the index hop reaches
      `applyRomWBWVersionSwitch` past it, so a fetch landing mid-session could
      empty the four slots underneath a running emulator - and
      `saveDownloadedDisks()` writes the guest's live image back to the file the
      SLOT names, so the periodic flush and the one in `stop()` would both find
      nothing to write to and drop the user's work without a word.  Stage it by
      being on a release the index does not offer: put a release the index has
      dropped into `selectedRomWBWVersion.v0` in the preferences plist, or
      serve a doctored index.  ("A release the core still supports" was the
      other half of this sentence until romwbw_emu v1.44; there is no such
      category now, and any release string the index does not list will do.)  Start the emulator, create
      a file in CP/M, and let the fetch land.  The log must read
      `[Catalog] RomWBW <new> held: the machine is running on <old>`, the slots
      must not move, and the disk list must stay the running release's.  Then
      press Stop: `[Catalog] Taking the held move to RomWBW <new>` must appear
      **after** the save, and the file you created must still be in the image
      when you switch back.  The ordering inside `stop()` is the whole check -
      `saveDownloadedDisks()` first, the held switch second.
- [ ] **Switching while a fetch is in flight drops the stale answer.**  This is
      the check that needs a throttled connection: with the Network Link
      Conditioner on a slow profile, launch, and switch release before
      `[Catalog] Fetching catalog:` has answered.  The log must show
      `[Catalog] Dropping the RomWBW <old> response`, the disk list must be the
      new release's, and **`catalogGeneration.v0.<new>` must not have been
      written with the old release's generation**.  What is at stake changed
      with §6: no image is deleted on any generation any more, so the failure
      here is now a recorded number that lies about the release it is filed
      under rather than a wipe.  Both releases read generation 2 today, so read
      the key - the absence of an alert proves nothing, and there is no alert
      left to be absent.
- [ ] **The ROM picker still shows its selection.**  `ROMOption`'s identity
      changed from a per-construction UUID to the filename, and the rows are
      rebuilt from every catalog fetch now.  Open Settings and confirm the ROM
      row reads `EMU AVW` and not a blank, before and after a release switch.
- [ ] **A profile applies ACROSS a release switch, and is honest about the one
      disk it cannot bring.**  Rewritten this session and never exercised; the
      old box asserted the opposite outcome and was right about the old code.  A
      profile used to resolve its disks by exact filename, and a catalog
      filename carries the release (`hd1k_combo-v0-3.5.1.img`), so applying a
      3.5.1 profile on 3.6.0 reported all four slots unresolved - which made
      profiles and the release picker mutually exclusive features.
      `resolveProfileDisk` now falls back to the catalog `id`, the stem, when
      the exact name misses.  Save a profile on 3.5.1 with the Combo in slot 0
      and **`hd1k_ws4` in another slot**, switch to 3.6.0, and apply it: the
      Combo slot must come back as `hd1k_combo-v0-3.6.0.img`, and `hd1k_ws4`
      must be the ONE unresolved slot, reported as
      `disk N: hd1k_ws4-v0-3.5.1.img (saved under RomWBW 3.5.1)`.  That is a
      real and permanent answer rather than a download away: 3.5.1 publishes
      `hd1k_ws4` and 3.6.0 does not - upstream's combo.def calls that slice "wp"
      there - confirmed against both published catalogs on 2026-09-08 (20 disk
      ids under 3.5.1, 24 under 3.6.0, `hd1k_ws4` in the first only).  Applying
      a profile must not move the release and must not blank the slots it could
      not fill.
- [ ] **A profile also resolves a disk only the OTHER release publishes.**  The
      stems the matcher knows are OBSERVED from the catalogs this app has
      fetched, in `catalogDiskStems.v0`, rather than read out of a frozen
      twenty-name table.  So a device that has never been on 3.6.0 has never
      seen `hd1k_cobol`, `hd1k_dos65`, `hd1k_infocom`, `hd1k_msx` or `hd1k_wp` -
      the five ids 3.6.0 adds, all bootable.  Save a profile on 3.6.0 naming one
      of them, switch to 3.5.1 and back, and confirm it still resolves.  If that
      key is missing the five, nothing recorded them and the fallback cannot
      fire.

---

## 20. The ROM comes from the catalog, and the app carries none

Build 65 loads the ROM the selected release publishes, verified against the
catalog's `size` and `sha256` every time it is used, and refuses to start a
release whose ROM it cannot get.  **Build 66 then deletes the bundled ROM**,
which is what makes the boxes below read the way they do.
`iOSCPM/Resources/emu_avw.rom` is gone and its four references came out of the
pbxproj; `git ls-files` now matches no `.rom`, `.img`, `.bin`, `.com` or `.dsk`
at all.  `bundledROMFilename`, `bundledROMRelease`, `bundledROMURL`,
`bundledROMFacts`, `bundledROMOption`, `bundledROMFallbackRelease` and
`switchToBundledROMRelease()` went with it, and so did the **Use RomWBW 3.5.1**
button on both ROM-problem alerts.

**RUN 2026-09-07, at build 67, for the happy path.**  Both releases' ROMs were
fetched from the catalog and verified: `emu_avw-v0-3.5.1.rom`
`4b11402a29fad22d…` and `emu_avw-v0-3.6.0.rom` `01d1ca6d142e9b75…`, both 524,288
bytes, each matching the entry its own catalog flags `default: true` — picked by
that flag and not by array position, since `emu_rcz80` is also published.  CP/M
2.2 booted on both, printing `CBIOS v3.5.1 [WBW]` and `CBIOS v3.6.0 [WBW]` with
no HBIOS/CBIOS mismatch warning, which is the check that the fetched ROM and the
fetched disk are a matched pair.  The Release `.app` built for arm64 contains no
`.rom` and no `.img`, so that is now a property of the artifact and not only of
`git ls-files`.  **The FAILURE paths below have not been run** — a hash
mismatch, a truncated ROM, a fetch with no network.

**Every box below was rewritten on 2026-09-08 and three of them were inverted.
Do not drive this section from memory.**  What it used to check first was that
3.5.1 boots offline having never downloaded a ROM - "the guarantee the bundled
ROM exists for".  That guarantee was false, and why it was false is the thing to
know before touching any of this: `start()` returns early on
`diskCatalog.isEmpty`, and the catalog and every disk in it are downloads.  A
device that has never had a network has no disk to boot and never had one, so a
ROM to boot it with bought nothing.  What the 512 KB actually bought was
skipping the ROM download on 3.5.1, and on 3.5.1 alone.

Do §19 first - a device that has never fetched a catalog cannot exercise any of
this.

- [ ] **A first launch with no network cannot boot, and fails for the right
      reason.**  Install into an empty container with the network off and press
      Play.  There must be no boot, and the failure must be the disk catalog's -
      "Failed to load disk catalog", from `start()`'s `diskCatalog.isEmpty` arm -
      arriving before anything asks for a ROM.  A **ROM Not Available** alert
      here means the two failures are in the wrong order and the user is being
      sent after the smaller of them.  This box asserted the opposite until
      2026-09-08.
- [ ] **3.5.1 downloads its own ROM now, exactly once.**  Fresh install, network
      ON, stay on 3.5.1, press Play.  The log must show
      `[ROM] Fetching …/v0-romwbw-3.5.1/emu_avw-v0-3.5.1.rom`, and afterwards
      `Documents/Disks` must hold `emu_avw-v0-3.5.1.rom`: 524,288 bytes,
      `4b11402a…`, byte-for-byte the ROM this app used to carry (both the
      published asset and that hash re-measured 2026-09-08).  Then relaunch and
      press Play again - **no second request**.  The copy on disk is verified
      against the catalog every time it is used, not fetched again.
- [ ] **3.6.0 fetches its own ROM before the machine starts.**  Switch to 3.6.0,
      press Play, and watch: `[ROM] Fetching …/v0-romwbw-3.6.0/emu_avw-v0-3.6.0.rom`,
      the download overlay, then the boot.  `Documents/Disks` must then hold
      `emu_avw-v0-3.6.0.rom` **beside** `emu_avw-v0-3.5.1.rom` and the 3.5.1
      images you already had - two releases' assets coexisting is what the
      naming scheme is for.  There is no longer any release whose ROM lives
      somewhere other than this directory; the old note here said the opposite.
- [ ] **And it boots without the mismatch warning.**  The whole point.  RomWBW
      must NOT print `*** WARNING: HBIOS/CBIOS Version Mismatch ***` on a 3.6.0
      disk under a 3.6.0 ROM.  Seeing it means the ROM that loaded was not the
      one that was fetched.
- [ ] **A ROM that will not download stops the machine, and offers nothing the
      app cannot do.**  Turn the network off with 3.6.0 selected and its ROM not
      yet fetched, then press Play.  There must be no boot, and an alert titled
      **ROM Not Available** whose message names RomWBW 3.6.0, names
      `emu_avw-v0-3.6.0.rom`, says why, and ends with the two real ways out - a
      connection, or the other ROM this release publishes.  **There must be no
      "Use RomWBW 3.5.1" button.**  It is gone: there is no bundled ROM behind
      it any more, and a build still offering it would be offering to boot a
      release the user did not choose.  Confirm the alert presents from the
      terminal screen *and* from Settings - it is declared on both, because only
      the view on top can present one.
- [ ] **A corrupt ROM is caught before it is used, and the file is not
      deleted.**  With a 3.6.0 ROM downloaded, truncate it in the container
      (`xcrun simctl get_app_container booted com.awohl.cpm data`) and press
      Play: the log must say it was rejected on its SIZE, fetch it once more,
      and boot.  Do it again corrupting bytes in the middle instead, so the
      length still matches, and confirm the CHECKSUM arm is the one that speaks.
      Then corrupt it once more with the network off: that one must report and
      not boot - and after all three the file must still be in
      `Documents/Disks`.  Nothing here may delete a user's file.
- [ ] **It gives up after one re-fetch rather than looping.**  Serve a ROM whose
      bytes can never match - a proxy, or a cached catalog carrying the wrong
      `sha256` for it.  The second failure must report that it is still wrong
      after being fetched again, and stop.  `romRefetched` is what remembers
      that; a third request on the same launch means it is not being consulted,
      and this is the arm that would otherwise spend a metered connection on a
      catalog entry that is simply wrong.
- [ ] **The second ROM is real.**  Pick EMU RCZ80 in Settings, fetch it, boot,
      and confirm the ROM-resident applications are the RC2014 set rather than
      the SBC one.  Both releases publish it at 524,288 bytes - `03e64691…` on
      3.5.1, `9b204cd7…` on 3.6.0, downloaded and hashed 2026-09-08.  Then
      switch release: the choice must stay EMU RCZ80 rather than reverting to
      EMU AVW, because it is remembered by catalog `id`.
- [ ] **A profile saved before this build still applies.**  A profile from build
      64 carries `romFilename` `"emu_avw.rom"`, which no catalog names and which
      no longer names a file in the app either.  Apply it and confirm the ROM
      resolves rather than being reported unresolved - that is
      `ROMOption.answersTo` matching on the catalog id, and it is now the only
      thing that can resolve such a profile at all.
- [ ] **One ROM fetch per release per device, and none unasked.**  Inverted:
      this used to require that a whole launch on 3.5.1 make no `.rom` request
      at all, which was true only while the app carried 3.5.1's ROM.  Now watch
      a launch on a release whose ROM is **already** in `Documents/Disks`, with
      Charles or the console: there must be no `.rom` request.  A fetch on every
      launch would be 512 KB of somebody's data for a file that is already there
      and already verified.

## 21. Help comes from the catalog, on a device

Build 70 pointed `HelpViewModel` at `CatalogMigration.indexURL` and deleted the
last ioscpm URL in the app.  None of it has been compiled - there was no Xcode
on the machine that wrote it - so this is a first sighting rather than a
regression check, and the first thing to establish is that Help opens at all.

- [ ] **The list is the published one.**  Open Help with a network.  Seven
      topics, and the descriptions are romwbw_disks' wording - "Getting started
      with the emulator", "Transfer files between host and CP/M".  Open Quick
      Start: it must begin "The first launch needs a network connection.  The
      app carries no ROM and no disk image."  The copy this app used to serve
      said two disk images are automatically selected, so that opening sentence
      is the whole difference between reading the catalog and reading the old
      release assets.
- [ ] **A topic that does not match what the index published is refused.**  With
      Charles or a local index, serve a topic body of the right length and the
      wrong content, or edit one byte.  The reader must get the cached or
      bundled copy, NOT the served one - and the bundled copy is byte-identical
      to the published text, so tell them apart by making the served body
      visibly different rather than by reading the wording.
- [ ] **Airplane mode, twice.**  With help never opened on that install, the
      seven topics still list and open from the bundle.  Then online once,
      offline again: the cache answers.  The cached index is written in this
      app's own shape rather than as the bytes that arrived, so this is the
      check that the re-encode round-trips.
- [ ] **A custom index moves help with it.**  Point the catalog index setting at
      another index and reopen Help: it must read that index's `help` block,
      and its cache must land beside the default one rather than on top of it -
      `Caches/help@<tag>` next to `Caches/help`.  Clear the field and the
      original topics come back.
- [ ] **An index with no help block, and one with a broken block.**  Serve an
      index whose `help` key is absent: the app falls back to its bundled
      topics and the release picker still works.  Then serve one where `help`
      is malformed - `"topics": 3` - and confirm the RELEASE LIST still loads.
      That is the whole point of decoding that key with `try?`, and it is the
      one failure in this change that would cost the user their catalog rather
      than their help.

## 22. Two presses of Play during a download

`start()` now refuses a second entry while one is in flight, and the toolbar
Play/Stop button is disabled for exactly that window.  What no check here can
settle is the window itself: it only exists while the ROM and the disks are
actually being fetched, so it needs a real transfer that lasts long enough to
press a button twice.  `Tests/run_tests.sh`'s `StartReentrancyGuard` stage
checks the shape of the code and cannot press anything.

Give yourself a slow transfer: Network Link Conditioner, or a local index and
catalog served from a throttled proxy.  A 49 MB combo image on a bad connection
is the case this was written for.

- [ ] With the ROM not yet downloaded for the selected release, press Play and
      then press it again while "Downloading ... ROM" is up.  The button must be
      **disabled** for the whole window, and the debug log must show
      `[Start] a start is already in flight` if you reach it by the Cmd-key
      route instead.  One transfer, one boot.
- [ ] The same during the DISK download, which is the long one.  Watch
      `Documents/Disks` (`xcrun simctl get_app_container booted com.awohl.cpm
      data`): exactly one `.img` must appear, and no partial file may be left
      behind.  Two starts used to orphan the first `URLSessionDownloadTask` and
      race the same destination in `moveItem`.
- [ ] Cancel the download from Settings while a start is waiting on it.  The
      start must END - status "Error: download failed", one alert - and Play
      must work again afterwards.  This is the terminus that is easiest to
      leave out, because nothing on screen says the flag is still set.
- [ ] Every other way a start can end, checked for the same thing: the release
      has no ROM to be had (airplane mode with the ROM absent), a selected disk
      is not in the catalog, no disk is selected at all.  After each one, Play
      must be pressable again.
- [ ] Press **Reset** while a start is in flight, then Play.  Reset carries no
      `.disabled` and leaves the machine not running, so it clears the flag
      itself; if Play is dead after a Reset, that is the bug.
- [ ] Let a start finish, then Stop and Play again, twice over, and leave the
      machine running for a minute.  `startEmulator()` now invalidates
      `diskSaveTimer` before scheduling a new one; a leaked timer shows up as
      two saves twenty seconds apart rather than one.

## 23. What Start says, and a Start that lands on a running machine

Two things no check in this repository can see.  `RomWBWRelease.startBanner` is
tested by behaviour in `CatalogDocumentTests`, and the
`StartRefusesALiveMachineAndSaysWhatItStarts` stage checks that
`startEmulator()` asks it and refuses a live machine — but both are shape and
string, and neither has ever been on a screen.  Nothing here constructs an
`EmulatorViewModel`, and `TerminalScreen.write` truncates at the right margin
rather than folding, so an over-long line loses its tail in silence.

cpmdroid settled the question these checks leave open on a Galaxy Tab A8
(efe9554): the RomWBW boot loader prints `RetroBrew SBC [SBC_simh_std] Boot
Loader` **below** the banner rather than clearing it.  That is a different guest
on a different terminal; it is the reason to expect these lines to survive and
not evidence that they do here.

- [ ] Press Play on a machine set to a **development snapshot**.  The first line
      must read `Starting RomWBW 3.7.0-dev.14 - emu_avw-v0-3.7.0-dev.14.rom`,
      whole, with the `-dev.14` on both halves and nothing cut off at column 80.
      That is the longest real case: 58 columns, measured.
- [ ] One `  Disk N: <file>` line per drive that actually has an image, and the
      N is the **drive**.  Put an image in drive 2 and nothing in 0 or 1: it must
      say `Disk 2`.
- [ ] A slot whose image is missing or corrupt must be **absent** from the list,
      not named.  Delete a downloaded `.img` out of `Documents/Disks` with the
      slot still selected, press Play, and confirm the failed drive appears in
      the error alert and NOT in the banner.
- [ ] A slot bound to a file you browsed to shows the file's own name and not
      the container path it came from.
- [ ] The status line reads `Running RomWBW <release>` and **keeps** reading it
      after the guest has painted over the terminal.  That is the half the guest
      cannot reach, and the reason it is said twice.
- [ ] **The guard.**  Press Play with a disk still to download, press Reset while
      it downloads, press Play again, and let both flights land.  The machine
      must come up **once**: the screen must not be cleared a second time, the
      session's output must still be there, and the debug log must show
      `[START] the machine is already running`.  Before this guard the second
      flight cleared the screen, emptied the scrollback and cold-restarted the
      guest.
