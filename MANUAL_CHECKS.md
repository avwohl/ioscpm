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

Most of this needs a Mac, not a device, and **this machine is one** — Xcode 26.6
is at `/Applications/Xcode.app`.  If `xcodebuild` tells you it "requires Xcode",
that only means `xcode-select` points at the Command Line Tools; prefix the
command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` rather
than concluding there is no toolchain.  The iOS Simulator runs the identical
Swift layer against a real sandbox - `xcrun simctl get_app_container booted
com.awohl.cpm data` gives you the `Documents` folder to inspect - and
`SUPPORTS_MACCATALYST = YES`, so the Catalyst pass is a `xcodebuild
-destination 'platform=macOS,variant=Mac Catalyst'` away.  Say so if a check
really does need hardware: check 3 needs an iPad with a hardware keyboard, check
4 a real device, and check 8 a phone or a keyboard-less iPad - the point of that
one is the case where there is no hardware keyboard to fall back on.

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

Checks 1 and 2 need a disk image carrying the **new** `w8.com`, and **the
catalog now serves one**: `v1.4.12/hd1k_combo.img` (`89b8ae1a…`) has
`Usage: W8 <cpmname> [hostpath]`, `Usage: R8 <hostpath>` and the `06 e9 cf`
probe.  That was not true when this section was written - `v1.4.5`'s combo has
only `Usage: W8 <cpmname>`, no `[hostpath]` - so a device holding the older image
looks identical in the picker and silently makes checks 1, 2, 14 and 15 the wrong
test.  **Check which one you have before running any of them**, either by
downloading the combo fresh on a clean install or by copying one in through Files
from `romwbw_emu/disks/`:

    xxd -p w8.com | tr -d '\n' | grep -c 06e9cf   # 1 = interlocked, 0 = armed

## 2. The WordStar diamond, and Escape, under Mac Catalyst

Never watched under Catalyst.  Build for Mac Catalyst and run WordStar.

- [ ] Walk the diamond: `^A ^D ^E ^F ^K ^P ^R ^S ^V ^X ^Y` and `^QS`.  Every one
      of the twelve reaches WordStar and none of them is eaten by AppKit's emacs
      `StandardKeyBinding` bindings.  Why that is expected to hold is in
      `KNOWN_PROBLEMS.md`; this is the observation that settles it.
- [ ] Escape reaches the guest windowed **and** full-screen, now that the escape
      `UIKeyCommand` sets `wantsPriorityOverSystemBehavior`.
- [ ] Escape dismisses each of the three dialogs in `modalHasKeyboard`
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

- [ ] Point the app at a catalog whose `<sha256>` for one image is wrong (edit
      the cached `Documents/Disks/disks_catalog.xml`, or serve your own). The
      download must retry three times, end as **Checksum mismatch**, and leave
      **no** `.img` behind in `Documents/Disks`.
- [ ] The first-run fetch (`downloadDisksAndStart`) surfaces that as a failure
      rather than starting the emulator with a missing disk.
- [ ] A catalog entry with no `<sha256>` at all is **refused**, with
      `No checksum in catalog - not saved`, and nothing is written to
      `Documents/Disks`. This box used to say the opposite — "the field has
      always been optional and a missing hash is not a failure" — and had been
      wrong since 2026-09-01, when `downloadDiskFromSettings` started refusing
      such an entry rather than installing it. All 20 entries in the pinned
      catalog carry a hash, so one without is a degraded or hostile catalog.

## 6. The narrowed catalog invalidation

**Build 63 moved this path out from under the check.** The invalidation is now
`checkCatalogGenerationAndInvalidate`, it reads the interface-v0 `generation`
rather than the `<disks version>` attribute, and it stores it under
`catalogGeneration.v0.3.5.1`. Editing `catalogVersion` no longer drives anything:
that key is orphaned, and the catalog this build fetches carries no generation,
so nothing here can fire until release B points at a v0 catalog. Drive the boxes
below then, against the new key — the deletion logic they are about
(`deleteCatalogDisks(named:)`) is unchanged.

Build 56 made the catalog invalidation delete only the images the new catalog
names. It was driven on the **iPhone 17 Pro simulator** by editing the
stored `catalogVersion` in the app container's preferences and relaunching, with
two catalog disks and two of the user's own in `Documents/Disks`: the two catalog
disks went, the two others stayed, and the alert gave both counts. What that
could not cover:

- [ ] A real catalog whose `version` attribute has genuinely moved, rather than a
      stored default edited from underneath the app. The path is the same, but
      nothing has run it end to end from a published catalog.
- [ ] A disk that is *selected* in a slot when it is cleared. `refreshAvailableDisks`
      and `restoreDiskSelections` run straight after; check the slot ends up empty
      rather than pointing at a file that is gone.
- [ ] The same, while the emulator is **running** off that disk. Disks are held in
      memory, so the session should survive; the file underneath it will not.
- [ ] A case-differing name — `HD1K_COMBO.IMG` beside the catalog's
      `hd1k_combo.img`. The match is deliberately case-insensitive so it behaves
      the same on both kinds of volume, which means such a file *is* treated as
      the catalog's. Confirm that is what you want.

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
- [ ] Apply a profile naming a disk that is **not** present.  The slot must end
      up empty and say so — not silently point at nothing, and not appear to
      have restored a disk it has not.
- [ ] Two profiles saved under the same name collapse to one, and it is the
      first of them (the suite asserts this; confirm the UI agrees).
- [ ] Delete the profile that is marked last-used; the pointer is dropped rather
      than left dangling.
- [ ] A profile saved on one device and carried to another restores everything
      except the disks, and is honest about the disks.

## 12. A multi-slice disk, and the size picker

`DiskSize.offered` is 8 MB hd1k, then 2 / 4 / 7 hd512 slices (N x 8,519,680).
The round numbers are deliberately absent: `emu_check_disk_size()` **refuses** a
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

Needs an image whose `r8.com` calls 0xEA.  `v1.4.12/hd1k_combo.img` does — the
bytes `06 ea cf` occur in it — so a freshly downloaded Combo is enough; the
`v1.4.5` image is not.

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
profile and the ledger to match.  **None of it has been run.**  It was written
on a machine with no Xcode; `Tests/CatalogMigrationTests.swift` covers the
decisions and skipped, and nothing has executed a single `moveItem`.

The tree carries build 64 as well, so the binary in front of you does §19's
fetch too.  Read the two sections as one sitting: everything below is still
about the rename, but the catalog it meets afterwards is the v0 one.

Stage a container that looks like a real one before touching any of this:
`xcrun simctl get_app_container booted com.awohl.cpm data` gives you the
`Documents` folder, and the app's preferences plist is beside it.  A container
with two catalog disks, one image the user imported, a slot pointing at each, a
saved profile and a ledger with a record for each is enough for all of it.

- [ ] **The renames happen and nothing else moves.**  The two catalog images
      come back as `-v0-3.5.1.img`; the imported one keeps its name; and
      `disks_catalog.xml` is untouched.  Check the size **and the modification
      time** of a renamed file against what they were: if mtime moved, it was
      copied rather than renamed, and every ledger measurement has just been
      invalidated.
- [ ] **The library is not re-hashed on the next launch.**  With the ledger
      correctly rekeyed, nineteen of twenty catalog images should be judged
      without reading a byte.  Watch for `measureDisks` running over the whole
      directory — that is what a wrong rekey looks like, and it is ~210 MB.
- [ ] **A slot survives, and so does a profile.**  The slots come back pointing
      at the renamed files, the emulator boots off them, and applying a saved
      profile still resolves its disks *and its ROM* — `romFilename` is
      deliberately not migrated, because it names a file in the app bundle.
- [ ] **A slot bound to a local file is still bound to it.**  `""` in
      `selectedDisks` means both "no disk" and "local file", and this is the
      case that proves the migration left it alone.
- [ ] **A destination that already exists is kept, and nothing is deleted.**
      Put both `hd1k_combo.img` and `hd1k_combo-v0-3.5.1.img` in the directory,
      run it, and confirm both are still there afterwards and the app boots off
      the v0 one.
- [ ] **A rename that fails leaves everything consistent.**  Make one move fail
      (a directory named `hd1k_bp-v0-3.5.1.img`, say, is enough to make
      `moveItem` throw) and confirm that slot still names the *old* file, that
      the emulator still boots off it, and that the migration runs again on the
      next launch rather than freezing half-done.
- [ ] **Running it twice changes nothing.**  Clear `migratedToInterfaceV0` in
      the preferences plist, relaunch, and confirm no file is renamed a second
      time and no name gains a second `-v0-`.
- [ ] **A directory that cannot be listed defers everything.**  Make
      `Documents/Disks` unreadable (`chmod 000` on the simulator container is
      enough), clear `migratedToInterfaceV0`, and relaunch.  Nothing may be
      renamed — that part is obvious — but the point of the check is the keys:
      `selectedDisks.v0.3.5.1` must be **unchanged**, not filled with names
      whose files never moved, and `migratedToInterfaceV0` must still be absent.
      Restore the permissions, relaunch, and confirm the pass completes then.
- [ ] **The invalidation deletes nothing.**  `catalogVersion` still reads `13`
      and is never touched — the old key is orphaned, not carried across, which
      is the whole reason `13 ≠ 1` cannot fire against the names the rename has
      just created.  `catalogGeneration.v0.3.5.1` starts empty; the binary you
      are driving carries §19 as well, so the first v0 fetch writes `1` there
      and takes the first-run branch.  Either way a catalog fetch must clear no
      images at all.  If anything is deleted, stop — that is the failure this
      whole sequence exists to prevent.
- [ ] **The boot string survives.**  `emulatorNvram.v0.3.5.1` should hold what
      `emulatorNvram` held, and the autoboot setting should be unchanged in
      SYSCONF after a warm boot.
- [ ] **A fresh install is not affected.**  Install into an empty container: no
      renames, no keys copied, first-launch catalog defaults still applied, slot
      0 still gets a disk.

## 19. The interface-v0 fetch and the release picker, on a real device

Build 64 deletes `releaseTag` and fetches `index-v0.json` from `romwbw_disks`,
then that release's catalog, then assets from the catalog's own `base_url`.  It
also adds a RomWBW release picker.  **None of it has made a network request.**
It was written on a machine with no Xcode and no network access to GitHub;
`Tests/CatalogDocumentTests.swift` covers the document rules and skipped.  Every
URL and hash in the code was read out of the committed documents under
`romwbw_disks/catalog/v0/`.

Do §18 first, on the same container.  A device that has not been through the
rename is not the interesting case for most of what follows.

- [ ] **It fetches two documents and nothing else.**  Watch the console for
      `[Catalog] Fetching index:` followed by `[Catalog] Fetching catalog:`.
      The second URL must come out of the first document, and no request may go
      to `avwohl/ioscpm` at all.  A request to `.../v1.4.12/disks.xml` means a
      tag survived somewhere.
- [ ] **An asset URL has exactly one slash.**  Tap Download on any disk and read
      the URL in the log: `…/v0-romwbw-3.5.1/hd1k_combo-v0-3.5.1.img`, not
      `…/v0-romwbw-3.5.1//hd1k_combo…`.  A doubled separator is what the old
      client-side `"/"` produced, and it 404s.
- [ ] **The disk list reads correctly again.**  Every catalog row matches a file
      the migration renamed, so twenty rows show as installed rather than as
      "(download)" with the user's own images listed separately below.  That
      mismatch is what build 63 left behind and what this build ends.
- [ ] **Nothing is deleted on the first v0 fetch.**  `catalogGeneration.v0.3.5.1`
      is empty before it and reads `1` after it, and the images in
      `Documents/Disks` are all still there.  If the library is cleared, stop:
      that is the wipe the whole two-build sequence exists to prevent.
- [ ] **A corrupted catalog is refused, not parsed.**  Hardest check here and
      the most valuable: serve a catalog whose bytes do not match the index's
      `catalog_sha256` (a proxy, or edit the cached
      `Documents/Disks/catalog-v0-3.5.1.json` and force a load of it).  The app
      must report a catalog-hop failure and fall back — never show a short disk
      list.
- [ ] **Offline is usable.**  Turn the network off and relaunch: the saved
      catalog loads, the slots resolve, and the emulator boots.  The message
      must say the list is the saved one rather than claiming an error, and no
      modal alert should appear when there is a usable cache.
- [ ] **The two hops are told apart.**  Break only the second one (a proxy that
      404s the catalog URL, or a cached index naming a URL that does not exist)
      and confirm the message says the release list loaded and the catalog did
      not.  With both broken it must name the index, not the catalog.
- [ ] **The picker offers 3.5.1 and 3.6.0, and marks the preview.**  The core
      supports both today (`ROMWBW_SUPPORTED_RELEASES` in `src/romwbw_pin.h`),
      so both appear, with `RomWBW 3.6.0 (preview)` reading as a preview in the
      row itself.  The About screen's `RomWBW 3.5.1, 3.6.0 core` line should
      agree with what is offered.
- [ ] **Switching to 3.6.0 changes everything that is per release, and destroys
      nothing.**  Slots empty, catalog re-fetches, `catalog-v0-3.6.0.json`
      appears beside the 3.5.1 one, and the boot string becomes 3.6.0's (empty,
      the first time).  Then switch back: the 3.5.1 slots, boot string and
      images are exactly as they were.  **Check `Documents/Disks` before and
      after: no file may disappear on either move.**
- [ ] **The other release's disks are not in the picker, and are still on
      disk.**  On 3.6.0 the slot menus must not list `hd1k_combo-v0-3.5.1.img`
      as a user-added disk.  Then check `Documents/Disks` and confirm every one
      of those files is still there — hidden from a menu is not the same as
      gone, and only one of those is acceptable.  A disk you imported yourself
      must still be listed.
- [ ] **The ROM mismatch warning stays unreachable.**  Build 65 fetches the
      release's own ROM, so on 3.6.0 the Settings warning about booting a 3.5.1
      ROM must NOT appear once the catalog has loaded — see §20.  If it does,
      the ROM picker is showing the bundled ROM under a release that is not its
      own, which is the state the warning exists for and a bug in the
      resolution, not in the warning.
- [ ] **The picker is unavailable while running.**  Start the emulator, open
      Settings, and confirm the picker is disabled.  Then try it from a second
      window on Catalyst if you can: the model must refuse and say so rather
      than emptying the slots under a running machine.
- [ ] **Switching while a fetch is in flight drops the stale answer.**  This is
      the check that needs a throttled connection: with the Network Link
      Conditioner on a slow profile, launch, and switch release before
      `[Catalog] Fetching catalog:` has answered.  The log must show
      `[Catalog] Dropping the RomWBW <old> response`, the disk list must be the
      new release's, and **`catalogGeneration.v0.<new>` must not have been
      written with the old release's generation**.  No image may be deleted.
      Both releases are at generation 1 today, so a bug here is invisible until
      one of them moves — read the key, do not trust the absence of an alert.
- [ ] **The ROM picker still shows its selection.**  `ROMOption`'s identity
      changed from a per-construction UUID to the filename, and the rows are
      rebuilt from every catalog fetch now.  Open Settings and confirm the ROM
      row reads `EMU AVW` and not a blank, before and after a release switch.
- [ ] **A profile still applies.**  Profiles are not per release: save one on
      3.5.1, apply it on 3.5.1, and confirm every slot resolves.  Applying it
      while on 3.6.0 should report its disks as unresolved and change nothing —
      not blank the slots.

---

## 20. The ROM comes from the catalog

Build 65 loads the ROM the selected release publishes, verified against the
catalog's `size` and `sha256` every time it is used, and refuses to start a
release whose ROM it cannot get.  **None of it has run.**  Written on a machine
with no Xcode and no network access to GitHub; the document rules are in
`Tests/CatalogDocumentTests.swift`, which cannot execute there.

Do §19 first — a device that has never fetched a catalog cannot exercise any of
this.

- [ ] **3.5.1 boots with the network off and no ROM download, ever.**  Not "out
      of the box": a fresh install has no disk images and no catalog either, so
      it cannot boot anything until it has been online once — that is the disk
      story, not the ROM story, and conflating the two makes this check fail for
      the wrong reason.  So: fresh install, network ON, stay on 3.5.1, let the
      catalog land and download the disks you want.  Then turn the network OFF,
      relaunch, and press Play.  It must boot, and there must be no `.rom`
      request at all: the bundled `emu_avw.rom` is byte-for-byte
      `emu_avw-v0-3.5.1.rom`, and `resolveROM()` proves that by hash rather than
      assuming it.  Settings must read "this app already carries these exact
      bytes".  **If this one fails, nothing else here matters** — it is the
      guarantee the bundled ROM exists for.
- [ ] **3.6.0 fetches its own ROM before the machine starts.**  Switch to 3.6.0,
      press Play, and watch: `[ROM] Fetching …/v0-romwbw-3.6.0/emu_avw-v0-3.6.0.rom`,
      the download overlay, then the boot.  `Documents/Disks` must then hold
      `emu_avw-v0-3.6.0.rom` **beside** the 3.5.1 images you already had
      (`hd1k_combo-v0-3.5.1.img` and the rest) — two releases' assets coexisting
      is what the naming scheme is for.  Note that there is normally NO
      `emu_avw-v0-3.5.1.rom` on the device: 3.5.1's ROM is the one in the app.
- [ ] **And it boots without the mismatch warning.**  The whole point.  RomWBW
      must NOT print `*** WARNING: HBIOS/CBIOS Version Mismatch ***` on a 3.6.0
      disk under a 3.6.0 ROM.  Seeing it means the ROM that loaded was not the
      one that was fetched.
- [ ] **A ROM that will not download stops the machine, and says what to do.**
      Turn the network off with 3.6.0 selected and the ROM not yet fetched, then
      press Play.  There must be no boot: an alert naming RomWBW 3.6.0, naming
      `emu_avw-v0-3.6.0.rom`, saying why, and offering **Use RomWBW 3.5.1**.
      Take that offer and confirm it lands back on 3.5.1 with its slots intact.
      **A boot that happens anyway is the bug this release exists to remove** —
      it would be the bundled 3.5.1 ROM under 3.6.0 disks.
- [ ] **A corrupt ROM is caught before it is used, and the file is not
      deleted.**  With a 3.6.0 ROM downloaded, truncate it in the container
      (`xcrun simctl get_app_container booted com.awohl.cpm data`) and press
      Play: the log must say it was rejected on its SIZE, fetch it once more,
      and boot.  Do it again corrupting bytes in the middle instead, so the
      length still matches, and confirm the CHECKSUM arm is the one that speaks.
      Then corrupt it once more with the network off: that one must report and
      not boot — and after all three the file must still be in
      `Documents/Disks`.  Nothing here may delete a user's file.
- [ ] **The second ROM is real.**  Pick EMU RCZ80 in Settings, fetch it, boot,
      and confirm the ROM-resident applications are the RC2014 set rather than
      the SBC one.  Then switch release: the choice must stay EMU RCZ80 rather
      than reverting to EMU AVW, because it is remembered by catalog `id`.
- [ ] **A profile saved before this build still applies.**  A profile from build
      64 carries `romFilename` `"emu_avw.rom"`, which no catalog names.  Apply
      it and confirm the ROM resolves rather than being reported unresolved —
      that is `ROMOption.answersTo` matching on the catalog id.
- [ ] **Nothing fetches a ROM without being asked.**  Watch a whole launch on
      3.5.1 with Charles or the console: there must be no request for a `.rom`
      at all.  The bundled bytes satisfy the catalog entry, and a ROM fetch on
      every launch would be 512 KB of somebody's data for nothing.
