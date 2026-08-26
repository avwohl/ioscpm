# iOS: pin the disk catalog to an explicit ioscpm release

**Status:** Done. Applied in `4be8a13` (2026-07-25, v1.5.1 build 42):
`EmulatorViewModel.swift` builds both the catalog URL and the download base from
a single `releaseTag = "v1.4.5"`. Every build from 43 on has shipped with it.
The pinned `disks.xml` + `hd1k_combo.img` URLs both return 200.
Mismatch check (verify step 3) **confirmed**: the pinned v1.4.5 Combo (sha256
`be19984e…`, byte-exact to disks.xml) boots against the shipped `emu_avw.rom`
(HBIOS SYSVER 0x3510 = v3.5.1.0) with CBIOS v3.5.1 and **no** HBIOS/CBIOS
mismatch banner — verified headlessly in the native `romwbw_emu` CLI, which
shares the exact core the iOS app compiles (see memory `ioscpm-native-boot-verify`).
**Why:** the Windows (z80cpmw) and Android (cpmdroid) ports already pinned the
disk catalog to an explicit release tag; iOS was the last port floating on
`releases/latest`. This doc records what changed and why.

---

## Background

All three clients embed the **same** `emu_avw.rom` (sha256 `c7abc580…`, which
identifies as **RomWBW HBIOS v3.5.1**). That hash changed in `8cb26f9`
(shipped in build 45), which refreshed the bundled ROM from `romwbw_emu` v1.35
so it reproduces from `src/emu_hbios.asm`; the RomWBW version it reports did
**not** change, and the file is now byte-identical to
`romwbw_emu/roms/emu_avw.rom`.

The disk images the clients download must be built from a matching RomWBW
version, or CP/M prints `*** WARNING: HBIOS/CBIOS Version Mismatch ***` at cold
boot.

To guarantee that match, the disk catalog is **pinned** to one explicit ioscpm
release instead of `latest`:

| Port | Where | Catalog source |
|---|---|---|
| Windows (z80cpmw) | `DiskCatalog.cpp` → `RELEASE_TAG` | pinned `v1.4.5` |
| Android (cpmdroid) | `DiskCatalogRepository.kt` → `RELEASE_TAG` | pinned `v1.4.5` |
| iOS (this app) | `EmulatorViewModel.swift` → `releaseTag` | pinned `v1.4.5` |

`v1.4.5` is a published release (a prerelease mirror of `v1.4.11`, carrying the
v3.5.1 disk set with the w8-fixed combo). It is intentionally marked
**prerelease** so it does **not** become the repo's "Latest".

### Why it was pinned

While iOS floated, `latest` = `v1.4.11` = CBIOS v3.5.1, so it happened to match.
But the day a **v3.6.0** ioscpm release is published as a *normal*
(non-prerelease) release, it becomes "Latest", and a floating client would
immediately start downloading v3.6.0 disks against its **v3.5.1** ROM →
mismatch warning on every download, on every already-installed client. The pin
removes that trap: the disks can't change under an installed client until the
tag is deliberately bumped and a new build ships.

---

## The change (applied)

File: **`iOSCPM/Views/EmulatorViewModel.swift`**, as shipped (near line 123 —
the comment/pattern matches cpmdroid's):

```swift
    // Downloadable disk catalog - pinned to an explicit ioscpm release (matching
    // the Windows/Android ports). The core's HBIOS identifies as RomWBW v3.5.1;
    // disks from a different RomWBW release print an HBIOS/CBIOS mismatch warning
    // at boot. Bump this tag together with core/ROM upgrades. Help (HelpView)
    // deliberately stays on releases/latest — help floats, disks are pinned.
    private static let releaseTag = "v1.4.5"
    private static let catalogURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)/disks.xml"
    private static let releaseBaseURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)"
```

It replaced two constants that hard-coded `…/releases/latest/download/…`.

### The URL shape — it is NOT a plain `latest → v1.4.5` substitution

Worth remembering when the tag is next bumped: the path segments reorder
between the two forms.

- floating: `…/releases/`**`latest/download`**`/<asset>`
- pinned:   `…/releases/`**`download/v1.4.5`**`/<asset>`

`releaseBaseURL` keeps the same **trailing-slash convention as the floating
line it replaced** (no trailing slash), so the download code that appends
`"/<filename>"` still produces correct URLs.

---

## Do NOT change

Help stays floating — leave `HelpView.swift` as-is:

```swift
    private static let indexURL = "https://github.com/avwohl/ioscpm/releases/latest/download/help_index.json"
    private var baseURL: String = "https://github.com/avwohl/ioscpm/releases/latest/download/"
```

This help/disks asymmetry is deliberate and matches the other two ports (help
content isn't version-locked to the ROM; disk images are).

---

## Verify after the change

1. Build & run. Open the disk catalog — it should load the list (no error) and
   downloads should succeed.
2. Sanity-check the pinned URL resolves:
   ```
   curl -sILo /dev/null -w '%{http_code}\n' \
     https://github.com/avwohl/ioscpm/releases/download/v1.4.5/disks.xml
   ```
   Expect `200`.
3. Boot a downloaded disk (e.g. Combo) and confirm **no** "HBIOS/CBIOS Version
   Mismatch" banner (v3.5.1 disks vs v3.5.1 ROM).

---

## Future: the RomWBW v3.6.0 upgrade (not part of this task)

When the stack is rebuilt to RomWBW v3.6.0, do it in lockstep across all ports:

1. Build the v3.6.0 `emu_avw` ROM (a v3.6.0 `SBC_simh_std_v360.rom` is parked in
   `romwbw_emu/archive/romwbw-v3.6.0/`, but the `emu_avw` v3.6.0 build does not
   yet exist) and rebuild the disk set from v3.6.0.
2. Cut a **new** ioscpm tag (e.g. `v1.6.0`; the app already ships v1.5.1) — do
   **not** reuse `v1.4.5` (the installed v3.5.1 fleet is hardwired to it).
3. Bump the pinned tag in **all three**: z80cpmw `DiskCatalog.cpp`, cpmdroid
   `DiskCatalogRepository.kt`, and this iOS constant.

   > Two things gate that bump on this port, and neither is about the ROM.
   > **(a)** The build that carries the new tag must also carry the `W8`/`R8`
   > path sanitiser — build 52 or later. Refreshing the catalog is what puts a
   > path-capable `W8` in front of every user; the order is romwbw_emu's
   > `docs/RELEASE_ORDER_2026-08-25.md` (this port is step 1, the bump is
   > step 5). **(b)** A new catalog almost certainly carries a new
   > `<disks version="N">`, and changing that attribute makes every installed
   > app delete every `.img` in its `Documents/Disks` on the next fetch —
   > including disks the user imported or created, which the catalog cannot
   > give back. That is unfixed and undecided; see `todo.txt`, "THE SECOND
   > DATA-LOSS PATH ON THAT SAME RELEASE STEP", and
   > `docs/DISK_DISTRIBUTION.md`'s "Version Attribute" section.
4. Rebuild and ship all three apps with the v3.6.0 ROM.

Until iOS ships a v3.6.0 ROM, keep any v3.6.0 ioscpm release marked
**prerelease** so it can't become "Latest" and disturb clients still on v3.5.1.
