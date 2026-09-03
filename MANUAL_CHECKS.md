# Manual checks

Checks that need a person: an app installed and driven by hand, keys pressed, a
screen watched.  Nothing here can be settled by reading the source or by any
suite in `Tests/`, which is why none of it lives in `todo.txt` - that file keeps
a one-line pointer at this one.

**Delete a check once someone has run it.**  What it found goes in
`CHANGELOG.md`; what it left open goes in `todo.txt`.  A check that has been run
and left in place turns this file into the accumulating record `todo.txt` was.

Most of this needs a Mac, not a device.  The iOS Simulator runs the identical
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

Checks 1 and 2 need a disk image carrying the **new** `w8.com`, and the catalog
does not serve one - `v1.4.5/hd1k_combo.img` has only `Usage: W8 <cpmname>` in
it, no `[hostpath]`.  Copy an image in through Files from `romwbw_emu/disks/`
instead, and check which one you have first:

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
- [ ] A catalog entry with no `<sha256>` at all still installs. The field has
      always been optional and a missing hash is not a failure.

## 6. The narrowed catalog invalidation

Build 56 made `checkCatalogVersionAndInvalidate` delete only the images the new
catalog names. It was driven on the **iPhone 17 Pro simulator** by editing the
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

## 7. Build 59 has never been compiled — this gates 8 through 13

Everything below arrived in `8e7587f` and has had exactly one kind of
verification: `Tests/run_tests.sh`, 11 suites, 869 checks.  Every piece of it
that touches SwiftUI or UIKit — `ContentView.swift`, `TerminalView.swift`,
`EmulatorViewModel.swift`, `iOSCPMApp.swift`, `CatalystWindow.swift` — has never
been through a compiler, because no machine that has touched this work had
Xcode.  `xcrun --sdk macosx swiftc -parse` is a syntax check and was the most
that could be run.

- [ ] It builds at all.  `xcodebuild` for the Simulator **and** for
      `-destination 'platform=macOS,variant=Mac Catalyst'`.  Do this before
      anything else here; a type error in the UI layer would fail every check
      below for one reason, and finding that out five checks in wastes the pass.
- [ ] It launches, boots CP/M and takes keyboard input the way build 58 did.
      The sweep moved the whole screen model and escape parser out of
      `EmulatorViewModel` into `TerminalScreen`; the suite says the parser is
      right, and nothing says the wiring to the view is.
- [ ] Scrollback still works — build 57 fixed it and build 58 cleared it on
      start.  Both go through code the extraction moved.

If it does not build and the fix is not small, `git revert 8e7587f` backs the
whole sweep out; it went in as a fast-forward and comes out cleanly.

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
