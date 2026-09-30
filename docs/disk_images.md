# Disk images and ROMs

How the app finds, checks and stores ROMs and disk images. [DISK_DISTRIBUTION.md](DISK_DISTRIBUTION.md)
describes the catalog format and the release process behind the app.

ROMs and disk images come from
[romwbw_disks](https://github.com/avwohl/romwbw_disks), which publishes one
catalog per RomWBW release. The app compiles in a single index URL: the index
lists the releases, Settings' **RomWBW Release** picker chooses among them, and
every download URL comes from the chosen release's own catalog. Settings' **Catalog**
section points the app at a different index entirely; each index keeps its own
downloads and settings.

Every download is checked against the SHA-256 the catalog gives, and the
catalog itself against the index's before it is read. The ROM is re-verified
every time it is loaded, which is a check no disk could survive once the guest
has written to it. A release whose ROM cannot be fetched does not start: an
alert names the release and the file rather than quietly substituting another
release's ROM, which is what leaves RomWBW printing an HBIOS/CBIOS version
mismatch part-way through a boot.

Each release publishes more than one ROM, and which of them boots is a choice in
Settings. A release flagged `preview` is marked as one in the picker. When a ROM
cannot be fetched the app names the release and the file and says what would fix
it - a connection, or the other ROM that release publishes - rather than falling
back to another release's ROM, which is what leaves RomWBW printing a version
mismatch part-way through a boot.

**A new RomWBW release does NOT need a new build**, and neither do new disks or
ROMs within one. The picker offers every release the published index lists -
with one exception that is a choice and not a compile-time list: an entry the
index flags `prerelease` is a RomWBW development snapshot, and the picker drops
it unless Settings -> RomWBW Release -> Show Development Snapshots is ticked,
which is off in a fresh install.

That is a change: until romwbw_emu v1.44 this app filtered the index against a
compile-time list of releases its core had been checked against, so 3.7.0 would
have been fetched and then hidden. The list gated the wrong axis. A release
number is the pairing between HBIOS and a disk image's CBIOS - which the guest
itself enforces, by printing *** WARNING: HBIOS/CBIOS Version Mismatch *** on a
mismatched pair - and not what the emulator depends on. What the emulator
depends on is two I/O ports and the set of HBIOS functions it services, and that
interface is versioned by the catalog's own name: everything a **v0** index
publishes speaks v0, and a change this core could not service would be published
as `index-v1.json`, which this app does not read.

Which releases exist, which is the default, and what each one carries are
questions for the published index, not for this file - the app shows what it
finds, and [romwbw_disks](https://github.com/avwohl/romwbw_disks) is where it is
published. Each disk entry carries its own `license` field, which the app
displays; that field is the authority on what an image is under.

Downloaded images live in the app's `Documents/Disks` folder (a custom index
gets its own `Disks@<hash>` beside it, so two catalogs' identically-named
images cannot collide) and work offline. Filenames carry the release -
`hd1k_combo-v0-3.5.1.img` - so two RomWBW releases' disks sit side by side, and
so do the slot selections and boot settings that go with them. Switching
release deletes nothing.
