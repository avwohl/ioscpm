# iOS: pin the disk catalog to an explicit ioscpm release

**Status:** Code change applied in `EmulatorViewModel.swift` (pinned to `v1.4.5`);
syntax-verified and the pinned `disks.xml` + `hd1k_combo.img` URLs both return 200.
Mismatch check (verify step 3) **confirmed**: the pinned v1.4.5 Combo (sha256
`be19984e…`, byte-exact to disks.xml) boots against the shipped `emu_avw.rom`
(HBIOS SYSVER 0x3510 = v3.5.1.0) with CBIOS v3.5.1 and **no** HBIOS/CBIOS
mismatch banner — verified headlessly in the native `romwbw_emu` CLI, which
shares the exact core the iOS app compiles (see memory `ioscpm-native-boot-verify`).
Remaining: on-device **Build & run** in the app UI (verify step 1) once the iOS
platform SDK finishes installing. Low risk, one file.
**Why now:** the Windows (z80cpmw) and Android (cpmdroid) ports pin the disk
catalog to an explicit release tag; iOS is the only port still floating on
`releases/latest`. This doc says exactly what to change and why.

---

## Background

All three clients embed the **same** `emu_avw.rom` (sha256 `75990ada…`, which
identifies as **RomWBW HBIOS v3.5.1**). The disk images they download must be
built from a matching RomWBW version, or CP/M prints
`*** WARNING: HBIOS/CBIOS Version Mismatch ***` at cold boot.

To guarantee that match, the disk catalog is **pinned** to one explicit ioscpm
release instead of `latest`:

| Port | Where | Catalog source |
|---|---|---|
| Windows (z80cpmw) | `DiskCatalog.cpp` → `RELEASE_TAG` | pinned `v1.4.5` |
| Android (cpmdroid) | `DiskCatalogRepository.kt` → `RELEASE_TAG` | pinned `v1.4.5` |
| **iOS (this app)** | `EmulatorViewModel.swift` | **floating `latest`** ← the outlier |

`v1.4.5` is a published release (a prerelease mirror of `v1.4.11`, carrying the
v3.5.1 disk set with the w8-fixed combo). It is intentionally marked
**prerelease** so it does **not** become the repo's "Latest".

### The risk of leaving iOS on `latest`

Today `latest` = `v1.4.11` = CBIOS v3.5.1, so iOS happens to match. But the day
a **v3.6.0** ioscpm release is published as a *normal* (non-prerelease) release,
it becomes "Latest" and the iOS app would immediately start downloading v3.6.0
disks against its **v3.5.1** ROM → mismatch warning on every download, on every
already-installed iOS client. Pinning removes that trap: the disks can't change
under an installed client until you deliberately bump the tag and ship a new
build.

---

## The change

File: **`iOSCPM/Views/EmulatorViewModel.swift`**

Find these two constants (currently near line 124):

```swift
    // Downloadable disk catalog - fetched from disks.xml in GitHub releases
    private static let catalogURL = "https://github.com/avwohl/ioscpm/releases/latest/download/disks.xml"
    private static let releaseBaseURL = "https://github.com/avwohl/ioscpm/releases/latest/download"
```

Replace with (matching the cpmdroid comment/pattern):

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

### Watch the URL shape — it is NOT a plain `latest → v1.4.5` substitution

The path segments reorder between the two forms:

- floating: `…/releases/`**`latest/download`**`/<asset>`
- pinned:   `…/releases/`**`download/v1.4.5`**`/<asset>`

Keep `releaseBaseURL`'s **trailing-slash convention identical to the current
line** (no trailing slash) so the existing download code that appends
`"/<filename>"` keeps producing correct URLs.

> If the Swift compiler objects to one `static let` referencing another in its
> initializer, just inline the tag into both strings (e.g.
> `".../releases/download/v1.4.5/disks.xml"`). Functionally identical.

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

1. Build the v3.6.0 `emu_avw` ROM (a v3.6.0 `SBC_simh_std_v360.rom` exists in
   `romwbw_emu/roms`, but the `emu_avw` v3.6.0 build does not yet) and rebuild
   the disk set from v3.6.0.
2. Cut a **new** ioscpm tag (e.g. `v1.5.0`) — do **not** reuse `v1.4.5` (the
   installed v3.5.1 fleet is hardwired to it).
3. Bump the pinned tag in **all three**: z80cpmw `DiskCatalog.cpp`, cpmdroid
   `DiskCatalogRepository.kt`, and this iOS constant.
4. Rebuild and ship all three apps with the v3.6.0 ROM.

Until iOS ships a v3.6.0 ROM, keep any v3.6.0 ioscpm release marked
**prerelease** so it can't become "Latest" and disturb clients still on v3.5.1.
