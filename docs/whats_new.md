# What's New

User-visible changes to Z80CPM (this repository's iOSCPM) between **2026-07-13 and
2026-09-11**, which is builds 41 through 72.  This is the short, plain-language
companion to `CHANGELOG.md`: it lists only what a person using the app can see, do
or notice differently.  Tooling, tests, CI, release runbooks and repository hygiene
are in the changelog and deliberately not here.

Both features and behaviour changes are listed.  Several of the most noticeable
entries in this window are fixes — a terminal that had never kept a line of
scrollback, half the colour palette coming out wrong — and leaving them out would
misrepresent what changed.

## What you can actually install right now

**The App Store serves version 1.5.1, published 2026-09-05.**  Everything in the
first half of this document, up to and including build 61, is in that release.
Builds 62 and later exist only in the development tree — they have not been
released, and nothing in them has reached a device you can hold.  **Version 1.6.1
has never been on the App Store.**

If you are on the App Store version, note that 1.5.1 only arrived on 2026-09-05.
Before that date the installable app was 1.4.9, from March.  So the whole of builds
41 through 61 below reached you at once, on that one day.

The exception is Help.  Its text is fetched over the network rather than compiled
in, so a corrected help topic reaches an installed app without an App Store update.
The help rewrites dated 2026-08-28 and 2026-09-01 were readable in 1.4.9 before
1.5.1 shipped.

> *Measured 2026-09-11 with `tools/check-store-version.sh`.  The App Store lookup
> reports a version number and not a build number, so "at most build 61" is what can
> be measured: version 1.5.1 heads builds 43 through 66, builds 62-65 were never
> compiled, and build 66 was not committed until two days after the Store published.
> Build 61 is the build that was submitted, on 2026-09-04, the day before 1.5.1
> appeared.*

---

# In the App Store version (1.5.1 — builds 41 to 61)

## Terminal

- **A stray erase no longer turns the terminal into a VT52.**  (Build 47, GitHub
  issue #2.)  A single `ESC K` or `ESC J` — the ordinary erase-to-end-of-line and
  erase-to-end-of-screen that ADM-3A, Televideo, Hazeltine and Heath programs emit
  constantly — used to convince the terminal it was a VT52, permanently, for every
  program in the rest of the session.  After that, screens cleared when they should
  have scrolled, and reinstalling WordStar for vt100, ansi or vt52 made no
  difference, because the wrong choice was global and never expired.  Erases no
  longer change the terminal type.  Real VT52 programs still work: they give
  themselves away with `ESC A/B/C` cursor movement and `ESC Y` direct addressing,
  and `ESC <` still returns to ANSI.

- **Colours are the colours the program asked for.**  (Build 54.)  Half the palette
  came out wrong: `ESC[31m` (red) drew blue, `ESC[44m` (blue background) filled red,
  `ESC[33m` drew cyan and `ESC[36m` drew brown.  Only black, green, magenta and
  white happened to be right.  The default screen colour did not move, so this was
  invisible until a program asked for a colour.

- **Bright colours, bold, underline and blink all render.**  (Build 55.)  A program
  asking for bright red (`ESC[91m`) used to get nothing at all — the text carried on
  in whatever colour was in force, which from a fresh screen is plain light grey, so
  it looked as though no colour had been asked for.  Bright foregrounds now draw
  bright.  Bold draws in a heavier font, underline draws a rule in the text's own
  colour, and blinking text blinks — before, a program could ask for all three and
  only a brightness change ever showed.  Bright backgrounds draw as the matching
  ordinary background, because this screen has only eight of them.

- **Bold no longer falls off when a colour arrives.**  (Build 54.)  `ESC[1;31m` used
  to come out dim while `ESC[31;1m` came out bright — the colour was silently
  clearing the bold.  Both orders now give the same result.

- **256-colour and true-colour escapes no longer paint the wrong colour.**  (Build
  55.)  The numbers inside `ESC[38;5;<n>m` and `ESC[38;2;<r>;<g>;<b>m` were being
  acted on as though each were a colour command of its own, so a program ended up
  with a colour it never asked for.  Those sequences are now stepped over cleanly:
  this terminal has only the sixteen CGA colours, so the colour is left as it was.

- **Clearing the screen paints the chosen background, and keeps the scrolling
  region.**  (Build 53.)  Every erase used to fill with the default light grey on
  black whatever colour was in force, so a program's text ended up on a colour it
  had not chosen.  And a program that set up a scrolling region — rows 5-10 for a
  status area, say — used to lose it silently on a clear, after which everything
  scrolled the whole screen.

- **Stray characters after some escape sequences are gone.**  (Build 55.)  `ESC[>c`
  printed `c`, `ESC[>4;2m` printed `4;2m`, and the sequences for choosing a cursor
  shape or doing a soft reset left their last character on screen.

- **Five more editing commands work.**  (Build 51.)  Insert characters, delete
  characters, erase characters in place, and scroll the screen or just the current
  region up or down.  Editors and other full-screen programs that use these redraw
  cleanly instead of leaving stale text behind.  Lines only enter your scrollback
  when the whole screen scrolls, so a program with a fixed status area does not fill
  the history with its own lines.

- **Programs can turn off wrap at the last column, and can hide the cursor.**
  (Build 51.)  Both were previously parsed and ignored — which made programs relying
  on the first one scroll the screen unexpectedly, and left the cursor flickering
  around during a redraw.  Both reset at a cold boot, so a program that changes them
  and then crashes cannot leave the terminal odd for your next session.

- **Delete Line no longer crashes the app.**  (Build 49.)  A program asking to delete
  more lines than there were between the cursor and the bottom of the screen — which
  an editor clearing to the end of its buffer does routinely — crashed.  Deleting
  more lines than exist now just clears them.

- **Reverse video is a clean toggle.**  (Build 49.)  Turning it on twice turned it
  back off, and turning it off reset the terminal to plain white-on-black, throwing
  away whatever colours the program had set.  Reverse is now applied on the way to
  the screen, so the colours underneath are never disturbed.

- **Reset asks first.**  (Build 49.)  A cold boot throws away the running program and
  the whole scrollback, so the Reset button now confirms before it does that,
  whether or not the machine is running.

- **The terminal bell can be turned off.**  (Build 61.)  A Terminal Bell toggle in
  Settings silences BEL (Ctrl-G), which is useful when something rings it in a loop.
  Resetting the machine deliberately does not turn it back on: the setting is yours,
  not the guest's.

## Scrollback

- **Scroll back through what has already scrolled off.**  (Build 41, and it only
  really worked from build 57.)  The terminal keeps a history of lines that leave the
  top of the screen.  Drag with a finger on iOS, or use the trackpad or wheel on a
  Mac.  A "Live" button appears while you are looking at history — tap it, or type
  anything, to snap back to the bottom.  The cursor is hidden while you are scrolled
  back.  History survives a program clearing the screen and is dropped when the
  machine boots.

- **Scrollback finally keeps what scrolls off the top.**  (Build 57.)  Until this
  build the history had never recorded a single line: every ordinary newline that
  pushed a line off the top threw that line away, so no matter how much output had
  gone by, scrolling back showed nothing.  This is why everything else in this
  section only became useful at build 57.

- **Choose how much history to keep.**  (Build 43.)  A Scrollback picker in Settings
  — Off, 500, 1000, 2000, 5000 or 10000 lines — and the choice is remembered.  The
  default is now **1000** lines, down from a fixed 2000.

- **Page through history from a hardware keyboard.**  (Build 43.)  Shift+Page Up and
  Shift+Page Down move a screen at a time; Ctrl+Home and Ctrl+End jump to the oldest
  kept line and back to the live bottom.  Plain Page Up, Page Down, Home and End
  still go to CP/M, so nothing an editor expects was taken away.

- **The mouse wheel scrolls history on the Mac.**  (Build 57.)  One notch used to be
  less than a row and got rounded down to zero, so the wheel did nothing at all.  It
  now moves three lines per notch, matching the Windows version.  Drag scrolling also
  matches the rows you can actually see, which matters on a phone in portrait where
  the text is letterboxed.

- **The status bar shows how much history there is.**  (Build 57.)  `sb 0/0` beside
  the version: how far back you are scrolled, and how many lines exist.  Straight
  after a boot it reads 0/0, because nothing has scrolled off yet.

- **Play after Stop starts with a clean history.**  (Build 58.)  The stopped
  machine's output used to sit above the new startup banner, and a new session could
  open already scrolled back into output from a machine that was no longer running.

## Selecting and copying text

- **Press and hold, then drag, to select text on iPhone and iPad.**  (Build 61.)
  Before this, selection did nothing at all on iOS — tapping, press-and-hold and
  double-tap all failed to produce one, so Copy could only ever copy the whole
  screen.  A plain one-finger drag still scrolls; it is the half-second hold that
  starts a selection instead.  Lifting your finger brings up Copy / Copy All / Paste.

- **Drag to select on the Mac.**  (Build 57.)  The highlight is drawn under the
  characters, so text stays readable whatever colours the program picked.  The
  selection runs in reading order and wraps at the end of a row, so copying a wrapped
  line gives you the whole line, and it copies out of history when you are scrolled
  back.  Clicking, or scrolling, clears it.

- **Selection no longer drops the last character.**  (Build 61.)  Dragging across
  `DIR` on the Mac highlighted and copied only `DI` — the cell actually under the
  pointer was never part of the selection.

- **Paste is reachable without a hardware keyboard.**  (Build 61.)  Paste is now in
  the press-and-hold menu.  Before this the only way to paste was Cmd+V, so on an
  iPhone with no hardware keyboard there was no way to paste at all.  The item
  appears only when there is text on the clipboard.

## Keyboard

- **Remap the arrow and navigation keys.**  (Build 41.)  A Keyboard Mapping section
  in Settings decides what the arrows, Home, End, Page Up/Down, Insert and Forward
  Delete send to CP/M on a hardware keyboard.  Pick a preset — **WordStar** (the
  historical default, arrows send Ctrl-E/S/D/X), **VT100/ANSI** or **VT52** — or open
  Customize Keys and type a byte sequence for any single key, using `\E` for Escape,
  `^X` for Ctrl-X, `^?` for Delete, `\NNN` for an octal byte and `\n \r \t \b \s`.

- **An on-screen row of arrow, editing and function keys.**  (Build 61.)  Without a
  hardware keyboard, not one of the keys in the key map could be pressed.  A row
  under the terminal now carries them on three pages — **Nav** (arrows plus
  Home/End/Page Up/Page Down/Insert/Delete), **Fn** (F1-F12) and **Ctrl** (the four
  Ctrl+arrows).  Each key sends exactly what the hardware key would, through the same
  key map.  It can be turned off in Settings → Preferences → On-screen Key Row.  On a
  Mac it is the only way to send Ctrl+arrow, which the system takes for itself.

- **F1 to F12 work and can be rebound.**  (Build 51.)  They send the standard
  VT220/xterm sequences instead of nothing, and each appears in Customize Keys.  The
  VT52 profile is the deliberate exception: a real VT52 only has F1-F4, so F5-F12
  send nothing there.

- **Ctrl+arrow is its own key you can rebind.**  (Build 53.)  Ctrl+Up/Down/Left/Right
  used to be treated as plain arrows with the Ctrl thrown away.  Customize Keys gains
  four rows for them.  WordStar and VT100 send the standard xterm forms
  (`ESC[1;5A` and friends); VT52 sends the plain arrow, because a VT52 has no way to
  express a modifier.  A Custom profile saved before this keeps behaving exactly as it
  did.

- **Ctrl with any key, not just letters, reaches CP/M.**  (Build 49.)  Ctrl combined
  with anything other than a letter used to be dropped.  Ctrl+[ (Escape), Ctrl+\,
  Ctrl+], Ctrl+^, Ctrl+_, Ctrl+@ and Ctrl+Space (NUL), Ctrl+? and Ctrl+Backspace
  (Delete), Ctrl+/ and every Ctrl+Shift+letter now send the control byte the program
  expects.

- **Ctrl+J sends a line feed, not Enter.**  (Build 49.)  Two places on the input path
  were silently rewriting line feed to carriage return.  The software keyboard's
  Return still sends carriage return, which is what CP/M wants.

- **Escape and Return dismiss dialogs instead of reaching CP/M.**  (Build 49.)  They
  used to go straight through to the guest, because the terminal kept the keyboard
  underneath the dialog.

- **Typing reaches programs that use the video display.**  (Build 50.)  A CP/M program
  driving the video device rather than the serial console was told "nothing typed"
  however much you had typed, and the one call that did fetch a key handed back a
  leftover byte and then never asked again.  Booting to the ordinary CP/M prompt was
  never affected, which is why this went unnoticed.

## Disks

- **A catalog update stopped deleting disks you made.**  (Build 56.)  When the disk
  catalog changed, the app used to delete every image in its folder — including disks
  you imported through Files and disks you created in the app, which no catalog could
  ever give back — with no tap and no download needed to set it off.  From this build
  it deleted only images the new catalog itself lists.  *(Removed entirely in the
  unreleased builds; see below.)*

- **Downloaded disks are checked before they replace anything.**  (Build 55.)  A
  download is now checksummed before it is installed.  Until this, nothing was
  verified at all and the new file went in on top of the old one before it had been
  looked at — so a corrupt or truncated download could destroy a working disk and
  leave nothing behind.  A bad one is retried and then reported as "Checksum mismatch
  — not saved", with your existing disk untouched.

- **Downloaded disks can be told they are out of date.**  (Build 61.)  A disk whose
  published version has moved on carries a one-line note and an orange badge, and its
  row menu gains "Update to Latest Version".  If you have never written to that disk
  the app fetches the new copy by itself on Wi-Fi; if you have, it asks first, says
  plainly that files you saved inside will be lost, and offers to copy them out with
  W8 or export the disk from Files instead.  Before this there was no control that
  re-downloaded a stale disk at all — the row just painted a red checksum most people
  had no way to interpret.

- **The cancel button on a download actually cancels.**  (Build 61.)  It used to
  restart the transfer a second later.

- **Choose the size of a new disk image.**  (Build 61.)  A New Disk Size picker that
  "Create New…" honours: 8.4 MB (1 drive), 17.0 MB (2 drives), 34.1 MB (4 drives) and
  59.6 MB (7 drives) — only sizes the emulator will actually load, which is why the
  round 16/32/64 MB are not offered.  Before this every created disk was 8 MB.

- **Reset stops writing the old disk back.**  (Build 61.)  After Reset the app went on
  writing the emulator's in-memory image over your file every twenty seconds even
  though the machine was stopped.

- **The disk list stopped re-hashing every image as you scroll.**  (Build 61.)
  Opening and scrolling the disk list used to read the whole of every downloaded image
  — up to 98 MB per redraw for the 49 MB combo disk — just to show a checksum.

## ROM

- **A ROM built for the wrong RomWBW release is refused.**  (Build 45.)  The app reads
  a ROM's embedded version before running it, and a file that is not a RomWBW ROM, or
  whose configuration block is damaged, is refused with a message naming the release
  it claims to be — rather than starting a machine that prints nothing.

- **A ROM that fails to load no longer starts the CPU.**  (Build 49.)  Pressing Play
  used to run the Z80 over whatever happened to be in memory while the status line
  said "Running" — no output, no explanation.  Start now stops, and the alert says
  which of the three things went wrong: the file is not on the device, it cannot be
  read, or it is corrupt or built for a different release.  Previously all three
  reported "not found", which sent people hunting for a file that was right there.  A
  disk that fails to load is still not fatal — booting with no disk is allowed.

- **About names the RomWBW release.**  (Build 49.)  A disk built by a different
  release prints an HBIOS/CBIOS mismatch at boot, so this is the first thing to quote
  in a bug report.

## File transfer (R8 / W8)

- **Import File… (for R8).**  (Build 41.)  Pick a file from anywhere and the app
  copies it into its Imports folder, where a later `R8` finds it.  R8 and W8
  themselves only ever use the Imports and Exports folders, so a batch ending in
  several W8s never pops a file dialog and never stalls the machine — the picker
  appears only because you asked for it.

- **W8 with a path could wipe your disk library.**  (Build 52.)  Running `W8
  ANYFILE.TXT ..` used to delete the whole Documents folder — every disk image you had
  downloaded, plus Imports and Exports — while telling CP/M the export had succeeded.
  A W8 export is now always written as a single file directly inside Exports, whatever
  path the guest asks for, and nothing is deleted to make room for it.

- **R8 no longer loads the wrong file silently.**  (Builds 52 and 61.)  If R8 could not
  find what you asked for it used to quietly load whatever file happened to be first
  in Imports and report success, so CP/M held unrelated contents under the name you
  typed.  A miss is now reported and no CP/M file is created — not even an empty one.
  A path like `R8 /USERS/ME/FOO.COM` or `R8 ../SOMETHING` cannot reach outside Imports,
  and naming a folder is refused rather than leaving an empty file behind.

- **R8 reports the name it actually opened.**  (Build 61.)  In the file's own spelling
  — it used to echo back the upper-cased name CP/M shouted, so a file stored as
  `esc.txt` was reported as `ESC.TXT`.

- **Empty files transfer in both directions.**  (Builds 53 and 55.)  `W8` on an empty
  CP/M file used to tell the guest it had succeeded while nothing appeared in Exports.
  `R8` on a zero-byte file used to leave the transfer stuck waiting for ever.

- **W8 tells you where the file actually went.**  (Build 52.)  The "To host:" line used
  to echo back the path you typed, which named a location that exists nowhere on the
  device.  It now reports the real path inside Exports.

## Settings and profiles

- **Error messages actually appear on screen.**  (Build 56.)  Every error the app
  raised — a disk that would not load, a failed download, no disk selected, a file it
  could not read — was silently swallowed.  Only the "Disk May Be Overwritten" warning
  ever showed, because two alerts were fighting over the same slot and only the last
  one counted.  This restores every error message in the app, not one.

- **Save and reload a whole machine as a named profile.**  (Build 61.)  A
  Configuration Profiles section: set the machine up — ROM, all four disk slots, what
  it autoboots, terminal settings and key map — then name it and save.  Tap to load,
  swipe to delete, or update an existing one from the current settings.  Previously
  only the key-map half could be saved.

## Help

Help text is downloaded rather than compiled in, so these reached readers when the
files were published, not when a build shipped.

- **Help works with no network.**  (Build 51.)  The index and all seven topics now
  ship inside the app as a last fallback.  Help still fetches the published version
  first and falls back to what it downloaded last time, so corrections still arrive
  without an app update — but a first launch with no network no longer shows an empty
  help screen.

- **Help stopped being written as though iOS were the only platform.**  (2026-08-28,
  first in build 55.)  Each topic now says what to do on iPhone, iPad, Mac and
  Windows, and Folder Locations has a section per platform.  Three instructions were
  also measured and found false — most importantly, every OS guide told you to press
  0 at the boot menu, which answers "No system image on disk"; the first attached hard
  disk is unit 2, and all five guides now say so.

- **The published help caught up with the app.**  (Build 56, 2026-09-01.)  The topics
  on the server still told you to press Ctrl+E for an emulator console that does not
  exist, used the old app name and bundle id, and gave a drive-letter table that did
  not match what RomWBW prints at boot.  All eight files were republished together.

- **Help describes how to select text on a phone.**  (Build 61.)  Quick Start used to
  offer iPhone and iPad users only Cmd+C and Cmd+V — shortcuts needing a hardware
  keyboard — and said nothing about selecting on iOS at all.

## Mac

- **A real Emulator menu.**  (Build 61.)  Start / Stop (Cmd+R), Reset (Cmd+Shift+R),
  Clear Screen (Cmd+K), Jump to Live (Cmd+L), Save All Disks (Cmd+S), Open Imports
  Folder, Open Exports Folder and Settings (Cmd+,).  Until now every one of these was
  a toolbar button only, with no keyboard equivalent.

- **The window remembers its size and position.**  (Build 61.)  The Mac app used to
  open at the system default size on every single launch.  It now reopens where and
  how big you left it, and refuses to restore a frame that would strand you — smaller
  than the terminal, larger than the screen, or entirely off every display.  A minimum
  window size stops dragging the corner crushing the terminal to a sliver.

---

# Not released yet — development tree only (builds 62 to 72)

**None of this is installable.**  These builds have not been released; build 71 has
been uploaded to App Store Connect, and an upload is not a submission and a
submission is not a release.  Nothing below has run on physical iOS hardware — every
measurement in this repository was made on a simulator or on a Mac.

## Pick your RomWBW release

- **A RomWBW Release picker in Settings.**  (Build 64, reordered in build 72.)  It
  lists every release the disk catalog publishes that this app's emulator can actually
  run, newest first, and a release the catalog does not mark stable says so in its own
  row — "RomWBW 3.7.0 (preview)" — so you can see what you are picking before you pick
  it.  The order is the catalog's own publishing order reversed; nothing parses version
  numbers.  A brand-new preview release can therefore appear at the top of the menu
  without becoming the one a fresh install gets.

- **Changing release deletes nothing.**  (Builds 63 and 64.)  Your four drive
  selections, your auto-boot string, the machine's saved CP/M settings and every
  downloaded image are remembered separately per release, so going 3.5.1 → 3.6.0 and
  back brings the whole library, the same drives and the same boot string back with no
  download at all.  Measured: switching back cost 12 KB — the catalog list, and
  nothing else.

- **The drive menus show only the selected release's disks.**  (Build 64.)  So you
  cannot put a 3.5.1 system disk in a 3.6.0 machine by accident.  Nothing is deleted
  or moved — those files reappear the moment you switch back — and disks you imported
  or created yourself are still listed.

- **You cannot change release, or open Settings at all, with a machine running.**
  (Builds 64 and 67.)  Cmd+, now answers "Stop the emulator before opening Settings.
  The disks in the drives belong to the running machine."  Before build 67 the
  keyboard and menu route was open even though the toolbar gear was disabled, and
  changing a disk slot there wrote the image that was actually mounted over whichever
  file you had just picked, destroying it, while your real work was never saved.

- **About lists every release the app can run.**  (Build 62.)  "RomWBW 3.5.1, 3.6.0
  core" today, rather than one pinned version.

## Nothing ships inside the app any more

- **The ROM comes from the catalog.**  (Builds 65 and 66.)  The ROM Image picker lists
  the ROMs the selected release publishes, and from build 66 the app carries no ROM and
  no disk image at all — every one is downloaded and checked against the size and
  SHA-256 the catalog publishes.  A fresh install starts on whichever release the
  catalog recommends, 3.6.0 today, instead of always on 3.5.1.

- **Settings says where the ROM is, and offers to fetch it.**  (Build 65.)  A line
  under the picker reads "downloaded, and checked again every time it is used", or
  "512 KB to download. Press Play and it is fetched before the machine starts", with a
  Download ROM button and a progress bar — so you can get it now rather than discover
  you have no signal at the moment you want to boot.

- **Play fetches the ROM before it starts the machine.**  (Build 65.)  Before the
  disks, because it is small and it is the one thing the machine cannot start without.

- **"ROM Not Available" instead of a silent wrong boot.**  (Build 65.)  If the
  selected release's ROM cannot be downloaded or cannot be trusted, the machine does
  not start: an alert names the release and the file and says what went wrong.  The app
  never substitutes another release's ROM, which would boot with a version-mismatch
  warning most people scroll past.  Just before the ROM reaches the emulator the app
  also reads the RomWBW version out of the image itself and refuses if it disagrees
  with the release whose disks are in the drives — a checksum can only say the bytes
  are the published ones; this says what the guest will actually report.

- **Upgrading moves you to the newest release.**  (Build 67.)  If you already had
  disks from an older version, the app moves you to the release the catalog recommends
  instead of leaving you on 3.5.1.  Your 3.5.1 disks, drive assignments and boot string
  are not deleted — picking 3.5.1 again brings the whole library back with no download.

- **Caveat: the first launch after upgrading needs a connection.**  (Build 66.)
  Because the app no longer carries a ROM, the first launch after upgrading cannot boot
  with no network — your disks have been renamed for the new layout but no catalog has
  been fetched to resolve the names against.  It fixes itself on the first launch with
  a connection, and nothing is lost in the meantime.  Accepted rather than fixed.

## The disk catalog

- **Disks and ROMs come from a published catalog, not a pinned app release.**  (Build
  64.)  The app reads one published index, then the catalog for the release you
  selected, and downloads each file from where that catalog says.  A new disk image, or
  a corrected one, can now reach you without an App Store update.  *(A whole new RomWBW
  release still needs an app release — the picker only offers releases the installed
  emulator can boot.)*

- **A catalog change never deletes your disks.**  (Builds 63 and 66.)  The wipe is
  gone, and so is the alert announcing it.  Each installed image is judged on its own
  instead: one you have not written to is refreshed quietly, one you have saved work
  into offers you an update and is never overwritten without asking, and one that is
  already current is left alone.  The one real catalog bump changed two ROM hashes and
  zero of the twenty disk hashes — the old behaviour would have deleted twenty images
  and re-downloaded twenty identical copies, possibly over cellular.

- **Your migrated combo disk is not re-downloaded.**  (Build 64.)  The big
  `hd1k_combo` image you already have is recognised as current, so the app does not
  spend 49 MB re-fetching a disk with identical contents.  The two copies were compared
  file by file and hold the same 94 files; only unused slack differs.

- **A disk slot is no longer wiped when the catalog cannot name it.**  (Build 63.)  If
  the catalog stopped listing a disk you had assigned, that assignment used to be
  erased permanently on the next fetch.  The name is remembered now: the slot shows
  empty, the machine skips it, and the disk comes back on its own when the catalog
  names it again.

- **Catalog problems say which half failed.**  (Build 64.)  "Could not fetch the list
  of RomWBW releases" versus "The RomWBW release list loaded, but the 3.5.1 disk
  catalog did not", with the underlying reason and a Retry button.  If a saved copy is
  on screen anyway it is demoted to a quiet one-line note instead of an error, because
  the disks below it still work.

- **A corrupt or wrong catalog is refused, not shown.**  (Build 64.)  A truncated
  download used to read as a short disk list, which surfaced much later as "Cannot find
  disk(s) in catalog" when you pressed Play.

- **A message when this app can run none of the published releases.**  (Build 64.)
  Rather than an empty or stale disk list, it says so plainly and names the releases it
  does run.

- **Cancelling a disk download no longer freezes the app.**  (Build 68.)  Press Play on
  a drive whose disk is not downloaded yet, then stop that download, and the
  "Downloading" panel used to stay on screen for ever with no button to dismiss it and
  the machine never starting.  Four things could trigger it — tapping Cancel, the
  system cancelling the transfer, the app standing down from an automatic refresh
  because you were on a metered connection, and the file changing underneath the
  transfer.  The metered-connection one needed no action from you at all.  **This bug
  is in build 61, so it is one an App Store user can still hit today.**

- **Point the app at a different disk catalog.**  (Builds 69 and 72.)  A Catalog
  section in Settings where you type the address of a catalog index.  It always shows
  which catalog is in use, and when it is not the built-in one an orange warning says
  that every ROM and disk now comes from whoever publishes that catalog.  Addresses must
  be `https://` or `file://`, and the catalog cannot be changed while the emulator is
  running.  Each catalog keeps its own downloads folder and its own slot, ROM and
  boot-string settings, so trying another costs a fetch and nothing else and switching
  back finds your library exactly as you left it — which matters because two catalogs
  can publish different images under the same release name and the same filenames.  A
  device that never points anywhere else sees no change at all.

## Settings, profiles and help

- **The Catalog section works on a fresh install.**  (Build 72.)  As build 69 stood it
  opened with both buttons greyed out and nothing on screen saying why, on every fresh
  install — reported as "Catalog says Use built-in but all the options are grey".
  "Use This Catalog" is now live as soon as you open Settings, and pressing it on the
  address already in use re-reads that catalog, which is how you pick up a re-published
  disk list without changing anything.  "Use Built-In" is greyed out only when it has
  nothing to undo.  Every state in which a control is off now puts a sentence on screen
  telling you what to do about it.

- **A catalog re-read really re-downloads.**  (Build 72.)  Both catalog documents are
  now fetched fresh rather than possibly being answered out of the system's own web
  cache, so you get the bytes published at that moment.

- **The text fields look like text fields.**  (Build 72.)  Both the catalog address box
  and the "New profile name" box now have a visible border, and "Save Current" is a
  filled capsule button.  Before, a field's grey prompt text and a greyed-out button
  label were the same grey text on the same background — reported as "one is a prompt
  text in a fill-in field, the other a disabled button, but they look the same" — and a
  tap aimed at the field could be swallowed by the dead button.

- **Profile save tells you the name it will use.**  (Build 72.)  A line under the field
  says what pressing Save will do.  Type a name that already exists and it names the one
  it will use instead — *"Test" is already a profile. This saves as "Test 2"* — and says
  to swipe the old one away first if you want the name back.  Before this, saving under
  a taken name quietly produced a differently-named profile with nothing on screen
  saying so.  Settings now also confirms the save, where the only confirmation used to
  appear on the terminal status line hidden behind Settings.  Pressing Return in the
  field saves.

- **An error alert no longer closes Settings.**  (Build 72.)  A catalog that will not
  load, a ROM that is not available, a disk overwrite warning — the alert now appears
  over Settings and OK returns you there, instead of throwing you out onto the terminal
  screen.

- **A profile that only partly applies says what it could not restore.**  (Build 66.)
  A "Profile Partly Applied" alert lists each drive or setting it could not put back —
  including which RomWBW release a drive's disk was saved under — and confirms
  everything else was applied.  Before, a profile could restore three drives out of four
  and say nothing you could act on.

- **Your ROM choice follows the machine, not the filename.**  (Build 65.)  Pick EMU
  RCZ80 under one release and you still have EMU RCZ80 after switching, and a profile
  saved by an older version still finds its ROM instead of reporting it missing.

- **Help comes from the disk catalog.**  (Build 70.)  Help reads its topics from the
  same catalog the ROM and disks come from, each checked against the size and SHA-256
  the catalog publishes, so a correction can reach an installed app without an App Store
  update and a device pointed at another catalog reads that catalog's help.  If the
  server answers with something that is not a readable index — a truncated response, an
  error page — Help now falls back to the cached copy and then to the copy inside the
  app, instead of stopping with an error.

- **All seven help topics rewritten.**  (Build 70.)  First Launch describes what
  actually happens: the app carries no ROM and no disk image, it downloads the ROM the
  selected release publishes, checks it, then downloads the Combo image into slot 0 —
  where the old text claimed two disk images were selected for you.  The drive-letter
  table is corrected (the Combo image is six slices, so D: through H:), and the map CP/M
  prints at boot is named as the authority.  Added: what D, L and W do at the boot
  prompt; that the control strip covers @ through _, so NUL is Ctrl then @; that the
  scrollback stays put while CP/M keeps printing; and that you must reboot after
  changing a disk slot.  One side effect: this text is now shared with the Android and
  Windows versions, so some paragraphs address those platforms.

---

# Known gaps

Open at 2026-09-11, recorded here because a "what's new" list that omits them reads
as more finished than the app is.  Sources: `KNOWN_PROBLEMS.md`, `MANUAL_CHECKS.md`,
`todo.txt`, `WIP.md`.

- A downloaded disk you have saved work into cannot be updated without losing that
  work.  Build 61 warns before replacing one and never replaces one unasked, but it
  cannot preserve the contents.
- A disk made with "Create New…" has no filesystem on it — no directory, no boot
  track, no system — so it is unusable until something formats it.
- Whether a multi-slice new disk comes up as several CP/M drive letters has never been
  checked on real hardware.  If it does not, the size picker's larger options are wrong.
- A text selection cannot be adjusted after you lift your finger; there are no grab
  handles.  Dragging a selection past the top edge does not scroll.  New output under a
  live selection leaves the highlight on cells whose text has changed.
- Ctrl+arrow from a hardware keyboard never arrives on a Mac — macOS takes those four
  for Mission Control first.  The on-screen key row's Ctrl page is the only route.
- Navigation keys other than the four arrows still ignore their modifiers: Shift+Up,
  Alt+Right and Shift+Insert send what the bare key sends.
- The Settings gear is disabled while the machine is running, so the scrollback size
  cannot be changed without stopping.
- There is no scrollbar; the `sb n/m` counter is the only cue to where you are in the
  history.
- *(Tree only)* Switching release with no network empties the four disk slots in memory
  and nothing restores them when the new catalog cannot be loaded.
- *(Tree only)* Play stays live through the whole ROM-and-disk download, so a second
  press starts a second download and boot over the first.
