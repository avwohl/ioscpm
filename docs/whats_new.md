# What's New in Z80CPM

Z80CPM runs CP/M on iPhone, iPad and Mac, on an emulated Z80 with RomWBW's HBIOS
underneath it.  Here is everything that has changed since the last time anyone
posted about it.

---

## Choose which RomWBW release you run

There is a **RomWBW Release** picker in Settings.  It lists every release the disk
catalog publishes that the emulator can actually run — 3.5.1 and 3.6.0 today —
newest first.  A release the catalog does not mark stable says so in its own row,
"RomWBW 3.7.0 (preview)", so you can see what you are picking before you pick it.

**Changing release deletes nothing.**  Your four drive selections, your auto-boot
string, the machine's saved CP/M settings and every downloaded image are remembered
separately per release.  Go 3.5.1 → 3.6.0 and back and the whole library, the same
drives and the same boot string come back with no download at all — switching back
costs about 12 KB, which is the catalog list and nothing else.

While you are on one release, the other release's images stop appearing in the drive
menus, so you cannot put a 3.5.1 system disk in a 3.6.0 machine by accident.  Nothing
is deleted or moved; those files reappear the moment you switch back.  Disks you
imported or created yourself are always listed.

You cannot change release with a machine running, and in fact you can no longer open
Settings at all while one is running.  Cmd+, answers *"Stop the emulator before
opening Settings. The disks in the drives belong to the running machine."*  This
matters more than it sounds: changing a disk slot under a running machine used to
write the image that was actually mounted over whichever file you had just picked,
destroying it, while your real work was never saved.

About lists every release the emulator can run rather than one pinned version —
"RomWBW 3.5.1, 3.6.0 core".  If a disk prints an HBIOS/CBIOS mismatch at boot, that
line is the first thing to quote in a bug report.

## The ROM and the disks come from a published catalog

**Nothing ships inside the app any more.**  No ROM, no disk image.  Every one is
downloaded from a published catalog and checked against the size and SHA-256 that
catalog publishes, every time it is used.  A new disk image, or a corrected one, can
reach you without an App Store update at all.

The **ROM Image** picker lists the ROMs the release you selected publishes.  A line
under it tells you where the bytes are — *"downloaded, and checked again every time
it is used"*, or *"512 KB to download. Press Play and it is fetched before the
machine starts."* — with a Download ROM button and a progress bar, so you can fetch
it now rather than discover you have no signal at the moment you want to boot.
Pressing Play fetches the ROM before the disks, because it is small and it is the one
thing the machine cannot start without.

If the ROM cannot be downloaded or cannot be trusted, the machine does not start.  A
**ROM Not Available** alert names the release and the file and says what went wrong.
The app never quietly substitutes another release's ROM, which would boot with a
version-mismatch warning most people scroll past.  Just before the ROM reaches the
emulator the app also reads the RomWBW version out of the image itself and refuses if
it disagrees with the release whose disks are in the drives — a checksum can only say
the bytes are the published ones, this says what the guest will actually report.

Press Play with a ROM that will not load and the Z80 used to run over whatever
happened to be in memory while the status line said "Running" — no output, no
explanation.  It stops now, and the alert distinguishes the three cases: the file is
not on the device, it cannot be read, or it is damaged or built for a different
release.  All three used to report "not found", which sent people hunting for a file
that was right there.  A disk that fails to load is still not fatal; booting with no
disk is allowed.

You can also **point the app at a different catalog** entirely.  Settings has a
Catalog section where you type the address of a catalog index.  It always shows which
catalog is in use, and when it is not the built-in one an orange warning says that
every ROM and disk now comes from whoever publishes that catalog.  Each catalog keeps
its own downloads folder and its own slot, ROM and boot-string settings, so trying
another costs a fetch and nothing else and switching back finds your library exactly
as you left it — which matters, because two catalogs can publish completely different
images under the same release name and the same filenames.  If you never point
anywhere else you will not notice any of this.

---

## Terminal emulation

**One stray erase no longer turns the terminal into a VT52.**  (This is GitHub issue
#2, and it is probably the single most noticeable fix here.)  A single `ESC K` or
`ESC J` — the ordinary erase-to-end-of-line and erase-to-end-of-screen that ADM-3A,
Televideo, Hazeltine and Heath programs emit constantly — used to convince the
terminal it was a VT52, permanently, for every program in the rest of the session.
After that, screens cleared when they should have scrolled, and reinstalling WordStar
for vt100, ansi or vt52 made no difference, because the wrong choice was global and
never expired.  Erases no longer change the terminal type.  Real VT52 programs still
work: they give themselves away with `ESC A/B/C` cursor movement and `ESC Y` direct
addressing, and `ESC <` still returns to ANSI.

**Five more editing commands work**: insert characters, delete characters, erase
characters in place, and scroll the screen — or just the current scrolling region —
up or down.  Editors and other full-screen programs that use these redraw cleanly
instead of leaving stale text behind.

**Programs can turn off wrap at the last column**, so writing into the last column
overwrites it instead of pushing the cursor onto the next line.  This was previously
parsed and ignored, which made programs relying on it scroll the screen unexpectedly.
**Programs can also hide the cursor** while they repaint, so it no longer flickers
around during a redraw.  Both reset at a cold boot, so a program that changes them and
then crashes cannot leave the terminal odd for your next session.

**Clearing the screen paints the background colour the program chose**, and no longer
silently throws away the scrolling region.  Every erase used to fill with the default
light grey on black whatever colour was in force, so a program's text ended up sitting
on a colour it had not asked for.  And a program that set up a region — rows 5-10 for
a status area, say — lost it on a clear, after which everything scrolled the whole
screen.

**Delete Line no longer crashes the app.**  A program asking to delete more lines than
there were between the cursor and the bottom of the screen — which an editor clearing
to the end of its buffer does routinely — brought the whole thing down.

**Stray characters after some escape sequences are gone.**  `ESC[>c` printed `c`,
`ESC[>4;2m` printed `4;2m`, and the sequences for choosing a cursor shape or doing a
soft reset left their last character on screen as a character.

**The Reset button asks first.**  A cold boot throws away the running program and the
whole scrollback, so it confirms before doing that.

## Colour and attributes

**Colours are the colours the program asked for.**  Half the palette used to come out
wrong: `ESC[31m` (red) drew blue, `ESC[44m` (blue background) filled red, `ESC[33m`
drew cyan and `ESC[36m` drew brown.  Only black, green, magenta and white happened to
be right.  The default screen colour never moved, which is why this was invisible
until a program asked for a colour.

**Bright colours work.**  A program asking for bright red (`ESC[91m`) used to get
nothing at all — the text carried on in whatever colour was in force, which from a
fresh screen is plain light grey, so it looked as though no colour had been asked for.
Bright backgrounds draw as the matching ordinary background, because this screen has
only eight of them.

**Bold, underline and blink render.**  Bold in a heavier font, underline as a rule in
the text's own colour, blink at twice a second.  A program could ask for all three and
only a brightness change ever showed.  Blinking costs nothing when nothing on screen is
blinking.  And asking for bold and then a colour (`ESC[1;31m`) used to come out dim
while the other order came out bright — the colour was silently clearing the bold.

**256-colour and true-colour escapes no longer paint the wrong colour.**  The numbers
inside `ESC[38;5;<n>m` and `ESC[38;2;<r>;<g>;<b>m` were being acted on as though each
were a colour command of its own, so a program ended up with a colour it never asked
for.  Those sequences are stepped over cleanly now — this terminal has only the sixteen
CGA colours, so the colour is left as it was.

**`ESC[39m` and `ESC[49m`** — back to the default foreground and background — are
understood, so a program can drop a colour without resetting everything else it had set.

**Reverse video is a clean toggle.**  Turning it on twice turned it back off, and
turning it off reset the terminal to plain white-on-black, throwing away whatever
colours the program had set.  It is applied on the way to the screen now, so the colours
underneath are never disturbed.

## Scrollback

The terminal keeps a history of the lines that scroll off the top.  Drag with a finger
on iOS, or use the trackpad or wheel on a Mac.  A **Live** button appears while you are
looking at history — tap it, or type anything, to snap back to the bottom.  The cursor
is hidden while you are scrolled back.  History survives a program clearing the screen
and is dropped when the machine boots.

**It actually keeps what scrolls off now.**  The history had never recorded a single
line: every ordinary newline that pushed a line off the top threw that line away, so no
matter how much output had gone by, scrolling back showed nothing.  Everything else in
this section only became useful once that was fixed.

- A **Scrollback** picker in Settings: Off, 500, 1000, 2000, 5000 or 10000 lines.  The
  default is 1000.
- On a hardware keyboard, **Shift+Page Up / Shift+Page Down** move a screen at a time
  and **Ctrl+Home / Ctrl+End** jump to the oldest kept line and back to the live bottom.
  Plain Page Up, Page Down, Home and End still go to CP/M, so nothing an editor expects
  was taken away.
- On the Mac the **scroll wheel** works.  One notch used to be less than a row and got
  rounded down to zero, so the wheel did nothing at all; it moves three lines per notch
  now.  Drag scrolling also matches the rows you can actually see, which matters on a
  phone in portrait where the text is letterboxed.
- The status bar shows **`sb 0/0`** — how far back you are scrolled, and how many lines
  of history exist.
- Lines only enter the history when the whole screen scrolls, so a program with a fixed
  status area does not fill your history with its own lines.
- Press Stop and then Play and the stopped machine's output is gone, instead of sitting
  above the new startup banner.

## Selecting and copying text

**On iPhone and iPad: press and hold, then drag.**  Selection used to do nothing at all
on iOS — tapping, press-and-hold and double-tap all failed to produce one, so Copy could
only ever copy the whole screen.  A plain one-finger drag still scrolls; it is the
half-second hold that starts a selection instead.  Lifting your finger brings up **Copy
/ Copy All / Paste**.

**On the Mac: drag the pointer.**  The highlight is drawn under the characters, so text
stays readable whatever colours the program picked.

The selection runs in reading order and wraps at the end of a row, so copying a wrapped
line gives you the whole line, and it copies out of history when you are scrolled back.
It includes the character you finished on — dragging across `DIR` on the Mac used to
highlight and copy only `DI`.  Clicking, or scrolling, clears it.

**Paste is reachable without a hardware keyboard.**  It is in the press-and-hold menu.
Before, the only way to paste was Cmd+V, so on an iPhone with no hardware keyboard there
was no way to paste at all.

## Keyboard

**An on-screen row of arrow, editing and function keys.**  Without a hardware keyboard,
not one of the keys in the key map could be pressed.  A row under the terminal now
carries them on three pages — **Nav** (arrows plus Home/End/Page Up/Page Down/Insert/
Delete), **Fn** (F1-F12) and **Ctrl** (the four Ctrl+arrows).  Each key sends exactly
what the hardware key would, through the same key map.  It can be turned off in Settings
→ Preferences → On-screen Key Row.  On a Mac it is the only way to send Ctrl+arrow,
which the system takes for itself.

**Remap the navigation keys.**  A Keyboard Mapping section decides what the arrows,
Home, End, Page Up/Down, Insert and Forward Delete send to CP/M.  Pick a preset —
**WordStar** (the historical default, arrows send Ctrl-E/S/D/X), **VT100/ANSI**, or
**VT52** — or open Customize Keys and type a byte sequence for any single key, using
`\E` for Escape, `^X` for Ctrl-X, `^?` for Delete, `\NNN` for an octal byte, and
`\n \r \t \b \s`.

**F1 to F12 work** and send the standard VT220/xterm sequences instead of nothing, and
each appears in Customize Keys.  The VT52 profile is the deliberate exception: a real
VT52 only has F1-F4, so F5-F12 send nothing there.

**Ctrl+arrow is its own key you can rebind.**  Ctrl+Up/Down/Left/Right used to be
treated as plain arrows with the Ctrl thrown away.  WordStar and VT100 send the standard
xterm forms (`ESC[1;5A` and friends); VT52 sends the plain arrow, because a VT52 has no
way to express a modifier.  A Custom profile saved before this keeps behaving exactly as
it did.

**Ctrl with any key, not just letters, reaches CP/M.**  Ctrl combined with anything
other than a letter used to be dropped: Ctrl+[ (Escape), Ctrl+\, Ctrl+], Ctrl+^, Ctrl+_,
Ctrl+@ and Ctrl+Space (NUL), Ctrl+? and Ctrl+Backspace (Delete), Ctrl+/ and every
Ctrl+Shift+letter now send the control byte the program expects.

**Ctrl+J sends a line feed, not Enter** — two places on the input path were silently
rewriting line feed to carriage return.  The software keyboard's Return still sends
carriage return, which is what CP/M wants.

**Escape and Return dismiss dialogs** instead of going straight through to CP/M, which
they used to do because the terminal kept the keyboard underneath the dialog.

**Typing reaches programs that drive the video display** rather than the serial console.
Such a program was told "nothing typed" however much you had typed, and the one call that
did fetch a key handed back a leftover byte and then never asked again.  Booting to the
ordinary CP/M prompt was never affected, which is why this went unnoticed.

## Disks

**A catalog change never deletes your disks.**  It used to wipe every image in the app's
disk folder whenever the catalog moved — including disks you imported through Files and
disks you created in the app, which no catalog could ever give back — with no tap and no
download needed to set it off.  That is gone.  Each installed image is judged on its own
instead: one you have not written to is refreshed quietly, one you have saved work into
offers you an update and is never overwritten without asking, and one that is already
current is left alone.  For scale: the one real catalog bump changed two ROM hashes and
zero of the twenty disk hashes, so the old behaviour would have deleted twenty images and
re-downloaded twenty identical copies, possibly over cellular.

**A downloaded disk whose published version has moved on says so.**  The row carries a
note and an orange badge, and its menu gains **Update to Latest Version**.  If you have
never written to that disk the app fetches the new copy by itself on Wi-Fi; if you have,
it asks first, says plainly that files you saved inside will be lost, and offers to copy
them out with W8 or export the disk from Files instead.  There used to be no control that
re-downloaded a stale disk at all — the row just painted a red checksum most people had no
way to interpret.

**Downloads are verified before they replace anything.**  Nothing was verified at all
before, and the new file went in on top of the old one before it had been looked at — so a
corrupt or truncated download could destroy a working disk and leave nothing behind.  A bad
one is retried and then reported as *"Checksum mismatch — not saved"*, with your existing
disk untouched.

**Choose the size of a new disk image.**  A New Disk Size picker that "Create New…"
honours: 8.4 MB (1 drive), 17.0 MB (2 drives), 34.1 MB (4 drives) and 59.6 MB (7 drives) —
only sizes the emulator will actually load, which is why the round 16/32/64 MB are not
offered.  Every created disk used to be 8 MB.

**Cancelling a download works.**  The X used to restart the transfer a second later.  And
pressing Play on a drive whose disk is not downloaded yet and then stopping that download
used to leave the app stuck — the "Downloading" panel stayed on screen for ever with no
button to dismiss it and the machine never started.  Four different things could trigger
that, including the app standing down from an automatic refresh because you were on a
metered connection, which needed no action from you at all.

**Reset stops writing the old disk back.**  After Reset the app went on writing the
emulator's in-memory image over your file every twenty seconds even though the machine was
stopped.

**The disk list is responsive.**  Opening and scrolling it used to read the whole of every
downloaded image — up to 98 MB per redraw for the 49 MB combo disk — just to show a
checksum next to each row.

**A disk slot is no longer wiped when the catalog cannot name it.**  If the catalog
stopped listing a disk you had assigned, that assignment used to be erased permanently on
the next fetch.  The name is remembered now: the slot shows empty, the machine skips it,
and the disk comes back on its own when the catalog names it again.

## File transfer (R8 / W8)

**W8 with a path could wipe your whole disk library.**  Running `W8 ANYFILE.TXT ..` used
to delete the entire Documents folder — every disk image you had downloaded, plus your
Imports and Exports folders — while telling CP/M the export had succeeded.  A W8 export is
now always written as a single file directly inside Exports, whatever path the guest asks
for, and nothing is deleted to make room for it.

**R8 no longer loads the wrong file silently.**  If it could not find what you asked for
it used to quietly load whatever file happened to be first in Imports and report success,
so CP/M held unrelated contents under the name you typed.  A miss is reported now and no
CP/M file is created — not even an empty one.  A path like `R8 /USERS/ME/FOO.COM` or
`R8 ../SOMETHING` cannot reach outside Imports, and naming a folder is refused rather than
leaving an empty file behind.

**Import File… (for R8).**  Pick a file from anywhere and the app copies it into Imports,
where a later `R8` finds it.  R8 and W8 themselves only ever use the Imports and Exports
folders, so a batch ending in several W8s never pops a file dialog and never stalls the
machine — the picker appears only because you asked for it.  "Open Imports Folder" and
"Open Exports Folder" show you both.

**R8 reports the name it actually opened**, in the file's own spelling.  It used to echo
back the upper-cased name CP/M shouted, so a file stored as `esc.txt` was reported as
`ESC.TXT`.

**Empty files transfer in both directions.**  `W8` on an empty CP/M file used to tell the
guest it had succeeded while nothing appeared in Exports; `R8` on a zero-byte file left the
transfer stuck waiting for ever.

**W8 tells you where the file actually went.**  The "To host:" line used to echo back the
path you typed, naming a location that exists nowhere on the device.  It reports the real
path inside Exports now.

## Configuration profiles

Settings has a **Configuration Profiles** section.  Set the machine up the way you want it
— ROM, all four disk slots, what it autoboots, terminal settings and key map — then name it
and save.  Tap a saved profile to load it, swipe to delete, or update an existing one from
the current settings.  Only the key-map half could be saved before.

A profile records which RomWBW release it was saved on, and finds its ROM and disks by what
they are rather than by exact filename, so it still applies after you switch release.  Pick
EMU RCZ80 under one release and you still have EMU RCZ80 after switching.

Applying a profile that cannot restore everything tells you so: a **Profile Partly Applied**
alert lists each drive or setting it could not put back — including which RomWBW release a
drive's disk was saved under — and confirms everything else was applied.  A profile could
restore three drives out of four and say nothing you could act on.

Typing a name that is already taken tells you, before you press anything, the name it will
actually save under — *"Test" is already a profile. This saves as "Test 2"* — and says to
swipe the old one away first if you want the name back.  Saving under a taken name used to
quietly produce a differently-named profile with nothing on screen saying so.  Pressing
Return in the field saves.

## Settings

**Error messages actually appear.**  Every error the app raised — a disk that would not
load, a failed download, no disk selected, a file it could not read — was silently
swallowed.  Only the "Disk May Be Overwritten" warning ever showed, because two alerts were
fighting over the same slot and only the last one counted.  This restored every error
message in the app, not one.  An alert raised while you are in Settings also appears over
Settings, and OK returns you there, instead of throwing you out onto the terminal screen.

**The terminal bell can be turned off** — useful when something rings it in a loop.
Resetting the machine deliberately does not turn it back on: the setting is yours, not the
guest's.

**Text fields look like text fields.**  Both the catalog address box and the "New profile
name" box have a visible border, and "Save Current" is a filled capsule button.  A field's
grey prompt text and a greyed-out button label used to be the same grey text on the same
background, and a tap aimed at the field could be swallowed by the dead button.

**Catalog problems say which half failed** — *"Could not fetch the list of RomWBW
releases"* versus *"The RomWBW release list loaded, but the 3.5.1 disk catalog did not"* —
with the underlying reason and a Retry button.  If a saved copy is on screen anyway it is
demoted to a quiet one-line note instead of an error, because the disks below it still work.
A corrupt or truncated catalog is refused rather than read as a short disk list, which used
to surface much later as "Cannot find disk(s) in catalog" when you pressed Play.  And if
every release the catalog publishes is one this emulator cannot run, it says so plainly and
names the releases it does run, rather than showing an empty list.

Anywhere a control is unavailable, Settings now puts a sentence on screen telling you what
to do about it — stop the emulator, wait for the catalog being read, or type an address.

## Help

The seven help topics are read from the same catalog the ROM and disks come from, each
checked against the size and SHA-256 that catalog publishes, so a correction can reach an
installed app without an App Store update.  If the network is unreachable — or the server
answers with something that is not a readable index, a truncated response or an error page —
Help falls back to the copy it last downloaded, and then to the copies inside the app.

**The text was rewritten.**  It had stopped being true in ways worth naming:

- It was written as though iOS were the only platform ("tap the gear icon").  Each topic now
  says what to do on iPhone, iPad, Mac and Windows, and Folder Locations has a section per
  platform.
- Every OS guide told you to press **0** at the boot menu, which answers *"No system image on
  disk"*.  The first attached hard disk is unit **2**, and all five guides say so now.
- It told you to press Ctrl+E for an emulator console that does not exist, used an old app
  name and bundle id, and gave a drive-letter table that did not match what RomWBW prints at
  boot.  The Combo image is six slices, so it alone accounts for D: through H:, and the map
  CP/M prints at boot is named as the thing to read rather than counting.
- It offered iPhone and iPad users Cmd+C and Cmd+V for copy and paste — shortcuts needing a
  hardware keyboard — and said nothing about selecting by touch.

First Launch now describes what actually happens: the app carries no ROM and no disk image,
it downloads the ROM the selected release publishes, checks it, then downloads the Combo
image into slot 0.  Added along the way: what D, L and W do at the boot prompt; that the
control strip covers @ through _, so NUL is Ctrl then @; that the scrollback stays put while
CP/M keeps printing; and that you have to reboot after changing a disk slot.

## On the Mac

**A real Emulator menu**, with keyboard shortcuts: Start / Stop (Cmd+R), Reset
(Cmd+Shift+R), Clear Screen (Cmd+K), Jump to Live (Cmd+L), Save All Disks (Cmd+S), Open
Imports Folder, Open Exports Folder and Settings (Cmd+,).  Every one of these used to be a
toolbar button only, with no keyboard equivalent.

**The window remembers its size and position.**  It used to open at the system default size
on every single launch.  It refuses to restore a frame that would strand you — smaller than
the terminal, larger than the screen, or entirely off every display — and a minimum window
size stops dragging the corner crushing the terminal to a sliver.

---

## Known limitations

Worth saying out loud, so nobody spends an evening on one of these:

- A downloaded disk you have saved work into cannot be updated without losing that work.
  You get a warning before it is replaced, and it is never replaced unasked, but the
  contents cannot be preserved.  Copy the files out with W8 first.
- A disk made with "Create New…" is blank fill — no directory, no boot track, no system —
  so it is unusable until something formats it.  `cpmtools` is the workaround.
- Whether a multi-slice new disk comes up as several CP/M drive letters has not been
  confirmed on real hardware.
- A text selection cannot be adjusted after you lift your finger; there are no grab handles,
  so you drag again.  Dragging a selection past the top edge does not scroll.  New output
  arriving under a live selection leaves the highlight on cells whose text has changed.
- Ctrl+arrow from a hardware keyboard never arrives on a Mac — macOS takes those four for
  Mission Control before the app is offered them.  The on-screen key row's Ctrl page is the
  only route.
- Navigation keys other than the four arrows ignore their modifiers: Shift+Up, Alt+Right and
  Shift+Insert send what the bare key sends.
- The Settings gear is disabled while the machine is running, so the scrollback size cannot
  be changed without stopping first.
- There is no scrollbar — the `sb n/m` counter is the only cue to where you are in the
  history.
- Switching RomWBW release with no network empties the four disk slots in memory, and
  nothing restores them when the new release's catalog cannot be loaded.
- The first launch after upgrading, with no network, cannot boot: your images have been
  renamed for the new layout but no catalog has been fetched to resolve the names against.
  It fixes itself on the first launch with a connection, and nothing is lost in the meantime.
