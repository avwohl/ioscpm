# iOS: pin the disk catalog to an explicit ioscpm release

**Status:** Done. Applied in `4be8a13` (2026-07-25, v1.5.1 build 42):
`EmulatorViewModel.swift` builds both the catalog URL and the download base from
a single `releaseTag`. **The pin is `v1.4.12` as of `0010591`; it read `v1.4.5`
from build 42 to build 58.** No build carrying `v1.4.12` has reached a user — the
App Store serves 1.4.9, builds 36/37. Measure that with
`tools/check-store-version.sh` rather than reading a number here.
The pinned `disks.xml` + `hd1k_combo.img` URLs both return 200.
Mismatch check (verify step 3) **confirmed** — on the *v1.4.5* Combo (sha256
`be19984e…`, byte-exact to that tag's disks.xml), which is the measurement that
was actually run: it boots against the shipped `emu_avw.rom`
(HBIOS SYSVER 0x3510 = v3.5.1.0) with CBIOS v3.5.1 and **no** HBIOS/CBIOS
mismatch banner — verified headlessly in the native `romwbw_emu` CLI, which
shares the exact core the iOS app compiles (see memory `ioscpm-native-boot-verify`).
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
| Windows (z80cpmw) | `DiskCatalog.cpp` → `RELEASE_TAG` | pinned `v1.4.12` |
| Android (cpmdroid) | `DiskCatalogRepository.kt` → `RELEASE_TAG` | pinned `v1.4.12` |
| iOS (this app) | `EmulatorViewModel.swift` → `releaseTag` | pinned `v1.4.12` |

`v1.4.12` (2026-09-01) is the pinned release: the same v3.5.1 disk set, with
`hd1k_combo.img` respun to carry the current `r8.com` and `w8.com`. Nineteen of
the twenty images are byte-identical to `v1.4.5`'s; only the combo moved.

`v1.4.5` is still published and **still marked prerelease** — re-measured
2026-09-04, `gh api repos/avwohl/ioscpm/releases/tags/v1.4.5 --jq .prerelease` is
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
    private static let releaseTag = "v1.4.12"
    private static let catalogURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)/disks.xml"
    private static let releaseBaseURL = "https://github.com/avwohl/ioscpm/releases/download/\(releaseTag)"
```

It replaced two constants that hard-coded `…/releases/latest/download/…`.

### The URL shape — it is NOT a plain `latest → v1.4.12` substitution

Worth remembering when the tag is next bumped: the path segments reorder
between the two forms.

- floating: `…/releases/`**`latest/download`**`/<asset>`
- pinned:   `…/releases/`**`download/v1.4.12`**`/<asset>`

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
     https://github.com/avwohl/ioscpm/releases/download/v1.4.12/disks.xml
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
   **not** reuse `v1.4.5`, and do not reuse `v1.4.12` either. `v1.4.5` is frozen
   under `docs/DISK_W8FIX_RUNBOOK.md`; `v1.4.12` is what every port now pins
   **and** what `releases/latest` resolves to, so overwriting it would reach both
   the pinned and the floating fleet at once.
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
   > give back. Narrowed in build 56 — `deleteCatalogDisks(named:)` takes only
   > the images the new catalog names, so an imported or created disk survives —
   > but not closed, and it does nothing for the builds actually in service.
   > See "User Data Persistence" in `KNOWN_PROBLEMS.md`, which carries what is
   > still open, and `docs/DISK_DISTRIBUTION.md`'s "Version Attribute" section.
4. Rebuild and ship all three apps with the v3.6.0 ROM.

Until iOS ships a v3.6.0 ROM, keep any v3.6.0 ioscpm release marked
**prerelease** so it can't become "Latest" and disturb clients still on v3.5.1.
