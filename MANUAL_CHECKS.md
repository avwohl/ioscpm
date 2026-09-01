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
really does need hardware; only the Ctrl+arrow one does.

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
