# iOS: pin the disk catalog to an explicit ioscpm release

> **Superseded for the tree, not for the field (build 64, interface v0).**
> `releaseTag`, `catalogURL` and `releaseBaseURL` are deleted. This app now
> reads one compiled-in index URL from `avwohl/romwbw_disks` and takes every
> asset URL from the catalog behind it; there is no tag to pin and no pin to
> bump. See `docs/DISK_DISTRIBUTION.md` under "Interface v0".
>
> **Everything below still governs the builds users have.** They are hardwired
> to one of these tags' asset URLs — `v1.4.5` up to build 58, `v1.4.12` from
> build 61, and `releases/latest` on anything predating the pin — GitHub release
> assets cannot be redirected, and both tags must stay live and keep their
> prerelease flags exactly as recorded here for as long as one of those builds
> is installed. Nothing in this migration frees a tag; only the last uninstall
> does.

**Status:** Done, then superseded. Applied in `4be8a13` (2026-07-25, v1.5.1
build 42): `EmulatorViewModel.swift` built both the catalog URL and the download
base from a single `releaseTag`. **The pin moved to `v1.4.12` in `0010591`
(2026-09-03); it read `v1.4.5` from build 42 through build 58.** Build 64 then
deleted the constant outright.

**The shipping binary carries no pin at all any more.**
`sh tools/check-store-version.sh` on 2026-09-15 says 1.6.1, released
2026-09-12, **at most build 70**; 1.6.1 heads builds 67-72, so it is at least
67, and build 64 deleted the constant. Every build it could be is a v0 client
reading `avwohl/romwbw_disks`. The question this paragraph used to answer —
which of `v1.4.5` and `v1.4.12` the Store's binary reads — no longer has a
subject.

On 2026-09-08 the same script said 1.5.1, released 2026-09-05, at most build
61, and both pins lived inside that range. That was the last measurement in
which the pinned scheme was what users were on.

**It frees neither tag.** What matters for them is installs, not the current
submission, and a 1.4.9 or 1.5.x device is pinned until somebody updates it.
Run the script for the version and the date rather than reading a build number
out of this file. Re-measured 2026-09-15: the pinned `disks.xml` and
`hd1k_combo.img` URLs both return 200, as does `v1.4.5`'s `disks.xml`.

Mismatch check (verify step 3) **confirmed** — on the *v1.4.5* Combo (sha256
`be19984e…`, byte-exact to that tag's disks.xml), which is the measurement that
was actually run: it boots against the `emu_avw.rom` the app bundled at the time
(HBIOS SYSVER 0x3510 = v3.5.1.0) with CBIOS v3.5.1 and **no** HBIOS/CBIOS
mismatch banner — verified headlessly in the native `romwbw_emu` CLI, which
shares the exact core the iOS app compiles (see memory `ioscpm-native-boot-verify`).
Those bytes are not lost with the bundle: they are published as
`emu_avw-v0-3.5.1.rom`, and its catalog hash
`4b11402a29fad22de304775b7c415eb6a74600df06bd57828b9931a7e9693258` — re-measured
against the live catalog on 2026-09-08 — is the hash the deleted resource had.
That result carries to the `v1.4.12` combo (`89b8ae1a…`) by argument rather than
by a re-run: the two images differ in 5,121 bytes out of 51,380,224 and every one
of them is inside `R8.COM`, `W8.COM` or their two directory entries, so the CBIOS
is byte-identical and the banner cannot appear. If you want it re-measured on the
new bytes instead of argued from a diff, that is a Mac task and it has not been
done.
**Why:** the Windows (z80cpmw) and Android (cpmdroid) ports already pinned the
disk catalog to an explicit release tag; iOS was the last port floating on
`releases/latest`. This doc records what changed and why.

---

## Background

All three clients used to embed the **same** `emu_avw.rom` (sha256 `4b11402a…`,
which identifies as **RomWBW HBIOS v3.5.1**). That hash changed in `8cb26f9`
(shipped in build 45), which refreshed the bundled ROM from `romwbw_emu` v1.35
so it reproduces from `src/emu_hbios.asm`; the RomWBW version it reports did
**not** change.

**None of the three bundles a ROM now** — cpmdroid and z80cpmw deleted theirs on
2026-09-07, ioscpm on 2026-09-08 — and every ROM comes from the same catalog the
disks do, verified against a published hash before it is loaded. `4b11402a…` did
not become wrong when the file went away; it is what the catalog publishes for
`emu_avw-v0-3.5.1.rom`.

The disk images the clients download must be built from a matching RomWBW
version, or CP/M prints `*** WARNING: HBIOS/CBIOS Version Mismatch ***` at cold
boot. **That constraint is unchanged, and it is the whole reason any of this
exists.** What changed is where the guarantee comes from: a pin froze one
release's disks against one build's ROM, whereas the v0 catalog pairs them by
RomWBW release and lets the core say which releases it can run.

To guarantee the match, the disk catalog was **pinned** to one explicit ioscpm
release instead of `latest`. Where each port stands as of 2026-09-08:

| Port | Where | Catalog source |
|---|---|---|
| Windows (z80cpmw) | `CatalogV0.cpp`; `DiskCatalog.cpp` → `RELEASE_TAG` before it | v0 index; pinned `v1.4.12` in shipped builds |
| Android (cpmdroid) | `DiskCatalogRepository.kt` → `INDEX_URL`, which replaced `RELEASE_TAG` | v0 index; pinned `v1.4.12` in shipped builds |
| iOS (this app) | `EmulatorViewModel.swift` → `indexURL`, which replaced `releaseTag` | v0 index from build 64; pinned up to build 63 |

All three trees now compile in the same one URL, which is the point: it is the
only thing left that a port can get wrong on its own.

`v1.4.12` (2026-09-01) is the pinned release: the same v3.5.1 disk set, with
`hd1k_combo.img` respun to carry the current `r8.com` and `w8.com`. Nineteen of
the twenty images are byte-identical to `v1.4.5`'s; only the combo moved.

`v1.4.5` is still published and **still marked prerelease** — re-measured
2026-09-08, `gh api repos/avwohl/ioscpm/releases/tags/v1.4.5 --jq .prerelease` is
`true`. It is a prerelease mirror of `v1.4.11` (both catalogs hash `6ae94b8c…`)
carrying the v3.5.1 set with the w8-lowercase-fixed combo. It is frozen: nothing
may be uploaded to it and its flag does not move.

**`releases/latest` became `v1.4.12` on 2026-09-04**, deliberately — what that
decided, and what it cost, is recorded in `docs/DISK_W8FIX_RUNBOOK.md` under
"2026-09-04". The consequence for this document is that `latest` and the pin are
now the same tag, so they are no longer two independent layers. A future release
that must not reach the floating fleet has to be held by its own `--prerelease`
flag; there is no longer an accident keeping `latest` behind the pin.

### Why it was pinned

Until 2026-09-04, `latest` was `v1.4.11` = CBIOS v3.5.1, so while iOS floated it
happened to match.
But the day a **v3.6.0** ioscpm release is published as a *normal*
(non-prerelease) release, it becomes "Latest", and a floating client would
immediately start downloading v3.6.0 disks against its **v3.5.1** ROM →
mismatch warning on every download, on every already-installed client. The pin
removes that trap: the disks can't change under an installed client until the
tag is deliberately bumped and a new build ships.

### What the pin cost, and why it is not the scheme any more

The same sentence describes the pin's protection and its defect: **the disks
can't change under an installed client.** A bad disk cannot be withdrawn either.

That is not hypothetical. `v1.4.5`'s `R8.COM` handed an unfiltered host basename
to `F_DELETE`, so importing a file whose name held `?` or `*` silently erased
every matching CP/M file first. A fixed image was built and published — and the
broken one went on being served for two more days, to every device pinned to
`v1.4.5`, because publishing an asset is not the same as shipping it. Reaching
those users needed an edit to `releaseTag`, a rebuild, a submission and a
review. That is the cost the pin charges for its safety, and it is charged
exactly when the news is worst.

The v0 catalog keeps the protection and drops the cost. A client that reads
`base_url` out of a per-release catalog can be handed a corrected image the
moment it is published, while still never being handed a *different RomWBW
release's* disks — the pairing the pin existed to enforce is now enforced by the
release the catalog belongs to, and by the core being asked whether it can run
it, rather than by a constant nobody can change from outside the App Store.

The lesson generalises past this app: a pin is a promise that nothing will
change, and "nothing" includes the fix.

---

## The change (applied)

File: **`iOSCPM/Views/EmulatorViewModel.swift`**, as shipped — the constant was
`releaseTag`, and the comment/pattern matched cpmdroid's:

```swift
    // Downloadable disk catalog - pinned to an explicit ioscpm release (matching
    // the Windows/Android ports). The core's HBIOS identifies as RomWBW v3.5.1;
    // disks from a different RomWBW release print an HBIOS/CBIOS mismatch warning
    // at boot. Bump this tag together with core/ROM upgrades. Help (HelpView)
    // deliberately stays on releases/latest — help floats, disks are pinned.
    private static let releaseTag = "v1.4.12"
    private static let catalogURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)/disks.xml"
    private static let releaseBaseURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)"
```

It replaced two constants that hard-coded `…/releases/latest/download/…`.

### The URL shape — it is NOT a plain `latest → v1.4.12` substitution

There is no next bump, but the shape still has to be read correctly by anyone
reconstructing what a build in the field fetches: the path segments reorder
between the two forms.

- floating: `…/releases/`**`latest/download`**`/<asset>`
- pinned:   `…/releases/`**`download/v1.4.12`**`/<asset>`

`releaseBaseURL` keeps the same **trailing-slash convention as the floating
line it replaced** (no trailing slash), so the download code that appends
`"/<filename>"` still produces correct URLs.

---

## Do NOT change — and then build 70 did

This section said help stays floating and `HelpView.swift` is to be left alone:

```swift
    private static let indexURL = "https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json"
    private var baseURL: String = "https://github.com/avwohl/ioscpm/releases/latest/download/"
```

Both constants are gone. **Build 70 moved help onto the catalog**, the last
ioscpm URL compiled into the app: `HelpView.indexURL` is
`CatalogMigration.indexURL`, and the topics come from a `help` block inside that
index whose `base_url` is `avwohl/romwbw_disks`' `help-v0` tag. See
`docs/HELP_SYSTEM.md`.

The asymmetry the instruction was protecting — help not version-locked to the
ROM, disk images are — still holds; help simply reaches the client by the same
document as everything else now. What has *not* changed is the obligation
below: the floating help URL must keep answering, because the Store's binary is
at most build 70 and at least 67, so whether it fetches help from there is not
knowable from this tree.

---

## What still has to hold

This was the acceptance test for the change. Steps 1 and 3 have no tree left to
run against; what step 2 checked is now a standing obligation to the field
rather than a post-change sanity check.

1. **The pinned assets keep resolving**, for as long as one build that fetches
   them is installed:
   ```
   for u in \
     https://github.com/avwohl/ioscpm/releases/download/v1.4.12/disks.xml \
     https://github.com/avwohl/ioscpm/releases/download/v1.4.12/hd1k_combo.img \
     https://github.com/avwohl/ioscpm/releases/download/v1.4.5/disks.xml \
     https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json; do
       curl -sILo /dev/null -w "%{http_code}  $u\n" "$u"
   done
   ```
   All four returned `200` on 2026-09-08, and again on 2026-09-15.

2. **The flags stay where they are.** Re-measured 2026-09-08 with
   `gh api repos/avwohl/ioscpm/releases/...`: `v1.4.5` is `prerelease=true`,
   `v1.4.12` is `prerelease=false`, and `releases/latest` resolves to `v1.4.12`.
   That last pair was set deliberately on 2026-09-04;
   `docs/DISK_W8FIX_RUNBOOK.md` under "2026-09-04" records what it traded.

3. **The tree's own version of step 3 is not a check but a refusal.** The ROM's
   `size` and `sha256` are verified against the catalog every time it is used,
   and `loadSelectedResources()` will not start a machine whose ROM image's own
   HCB bytes name a release other than the selected one. The mismatch banner is
   prevented rather than watched for. `sh tools/check-shipped-disks.sh` was the
   standing check that no port's tree had drifted from the published catalog; it
   was deleted from all four ports on 2026-09-13. Its warning about packages is
   the part worth keeping in mind without it: **a tree agreeing with the catalog
   is not a user having the tree.**

---

## The RomWBW v3.6.0 upgrade — it happened, and not like this

This planned a lockstep tag bump across three ports. That is not how 3.6.0
arrived, and the plan is kept because most of what it was guarding against is
still real.

**What actually happened.** `romwbw_disks` publishes 3.6.0 as its own catalog
under its own tag, and the index promoted it out of preview on 2026-09-05. Read
live on 2026-09-08 it is `"status": "stable"`, `"default": true`, generation 2,
2 ROMs and 24 disks. The `emu_avw` v3.6.0 ROM the plan said did "not yet
exist" does exist and is published: `emu_avw-v0-3.6.0.rom`, 524288 bytes,
`01d1ca6d142e9b757d4fd98c2229f2e506dd8c3253839391c8f5d4f6263c6557`. No ioscpm
tag was cut, no constant was bumped in any port, and no app release was needed
for any of it. That is the migration paying for itself.

What still holds:

1. **Do not reuse `v1.4.5` or `v1.4.12`, ever.** `v1.4.5` is frozen under
   `docs/DISK_W8FIX_RUNBOOK.md`. `v1.4.12` is what shipped builds pin **and**
   what `releases/latest` resolves to, so writing to it reaches the pinned and
   the floating fleet in one move.
2. **A binary must not be offered a release its core cannot run.** This is now
   enforced rather than scheduled: the index publishes each release's
   `hbios.ver_byte`/`upd_byte`, and each v0 client filters the list through its
   own core (`emu_romwbw_release_supported`). A build predating 3.6.0 simply
   never sees the entry, so "ship the ROM first, then the disks" stops being an
   ordering a person has to remember. `ROMWBW_SUPPORTED_RELEASES` in
   `romwbw_emu/src/romwbw_pin.h` is where a core says what it can run; it names
   3.5.1 and 3.6.0 today.
3. **The `<disks version="N">` warning, undiminished.** Changing that attribute
   makes an installed pre-v0 app delete `.img` files from `Documents/Disks` on
   its next fetch — including, on the oldest installs, disks the user imported
   or created, which no catalog can give back. Build 56 narrowed it and build 63
   stopped reading the attribute, but neither reaches a device already in the
   field. `generation` is not a replacement for it and is not a substitute
   danger either: advancing `generation` deletes nothing at all, by measurement
   as well as by design. See "User Data Persistence" in `KNOWN_PROBLEMS.md` and
   `docs/DISK_DISTRIBUTION.md`'s "Version Attribute" section.
4. **A new ioscpm release still becomes "Latest" unless it is marked
   `--prerelease`**, and `releases/latest` is a live entry point for both the
   help system and any install predating the pin. Those installs are also the
   ones with no `W8`/`R8` path sanitiser — that is build 52 — so what a
   refreshed catalog puts in front of them is gated by step 5 of
   `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md`, and that gate is why the
   ordering survives the migration even though no tag is bumped any more.
   `docs/DISK_W8FIX_RUNBOOK.md` is the procedure; its SUPERSEDED block is the
   corrected recipe, and its 2026-09-04 section records what the trade cost on
   exactly this point.
