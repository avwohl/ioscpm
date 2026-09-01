# Runbook: refresh release disk images with the fixed w8.com

> ## SUPERSEDED 2026-09-01 — read this before running anything below
>
> **The upload recipe in this file was wrong and would have destroyed the
> safety property the whole plan depends on.** It said to
> `gh release upload <tag> --clobber` and "Do **not** cut a fresh tag". Doing
> that to `v1.4.5` overwrites the assets every installed client is pinned to,
> which arms the changed images retroactively on every device with no update —
> the one action `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md` forbids
> absolutely. It also told you to bump `<disks version="…">`, two paragraphs
> after correctly warning that bumping it deletes every `.img` in the user's
> `Documents/Disks`.
>
> **What was actually done, and what to copy instead.** The R8/W8 refresh
> shipped on 2026-09-01 as **`v1.4.12`, a new prerelease tag**, with `v1.4.5`
> untouched (still `be19984e…`, still 30 assets) and the catalog `version`
> attribute deliberately left at `13`, so the wipe never fired. The rules that
> came out of doing it:
>
> - **New tag, always. Never `--clobber` `v1.4.5`.** A new tag is cheap; the
>   retroactive arming is not undoable.
> - **`--prerelease`, always.** This is load-bearing, not cosmetic. The App
>   Store fleet is 1.4.9 (builds 36/37, 2026-03-19), which predates the catalog
>   pin and fetches from `releases/latest/download/` — so a *normal* release is
>   fetched by every installed device immediately. Check afterwards that
>   `gh api repos/avwohl/ioscpm/releases/latest --jq .tag_name` still names the
>   old tag.
> - **Never move `<disks version>`.** Change the affected `<sha256>` and nothing
>   else. The warning below is right; the instruction to bump was not.
> - **Attach the whole catalog's worth of assets to the new tag**, not just the
>   changed image: every port derives asset URLs from its pinned tag, so a
>   missing filename 404s for any build that later pins it.
> - **Use `romwbw_emu/disks/rebuild_disk_utils.sh` and `verify_disk_utils.sh`**,
>   which take a tree root, handle the combo through the `wbw_hd1k_0` diskdef,
>   and assert the `06 e9 cf` interlock. They replace the `dd`-slice recipe
>   below, which stays only as an explanation of the layout.
> - **Refresh the *published* bytes, not `romwbw_emu/disks/hd1k_combo.img`.**
>   The tracked image is a superset carrying developer scratch files.
>
> One artifact to know about: **`hd1k_combo_ioscpm_w8fixed.img`**, on `v1.4.5`,
> is byte-identical to the *unfixed* combo despite its name, is in no catalog
> entry, and was deliberately dropped from `v1.4.12`. Do not republish it.
>
> Everything below is kept for its audit history and its signature method, both
> of which are still correct. The two numbered upload steps are corrected in
> place.

## Background

`w8.com` on every hd1k image built before 2026-07-21 has a broken lowercase
conversion: um80 0.3.42 miscompiled `add a,'a'-'A'` to `add a,0`, so **W8
exported UPPERCASE filenames**. The fix is a corrected `w8.com` (see
`romwbw_emu/docs/DOWNSTREAM_2026-07-21.md` §5).

Audit signature (hex, in the file's tolower routine):
- `fe41d8fe5bd0c600` = **broken** build
- `fe41d8fe5bd0c620` = **fixed** build (`add a,0x20`)

## Audit result (2026-07-22)

The published **v1.4.5** `hd1k_combo.img` slice 0 (CP/M 2.2, the disk the app
boots by default) carried the **broken** 1024-byte `w8.com`. The combo's other
slices already had the fixed build. `hd1k_infocom.img` in romwbw_emu is fixed.

That combo has since been patched and re-uploaded — the v1.4.5 release now
serves the fixed one. See "Update the catalog and upload" below.

Re-checked against the live release on 2026-08-26 by downloading
`v1.4.5/hd1k_combo.img` and counting the signatures: **broken 0, fixed 10**, and
the file hashes to the `be19984e…` the published `disks.xml` names. The same
download also settles a question romwbw_emu's `RELEASE_ORDER_2026-08-25.md`
leaves open ("Do shipped images carry the old W8? *Believed yes, not verified
here*"): it does. The only `W8` usage string in the image is
`Usage: W8 <cpmname>` — no `[hostpath]` — and the interlock probe bytes
`06 e9 cf` do not occur anywhere in the image. So the catalog as published today
cannot arm the host-path `W8` at all; the exposure that build 52 fixes is via
images a user imports through Files, not via anything this release serves.

Note: `cpmemu/util/cpm_disk.py` reads/writes **single hd1k** images correctly
but its **combo** extract/add path is unreliable (it returned the wrong slice's
`w8.com`). Always patch a combo via the dd-slice method below, never the combo
path directly.

## Produce the fixed combo (reproducible, verified)

```bash
CPM=~/src/cpmemu/util/cpm_disk.py

# 1. Get the current published combo and a known-good fixed w8.com
#    (v1.4.5 now serves the already-fixed combo; this recipe is kept as the
#     method for patching any future combo respin)
gh release download v1.4.5 --repo avwohl/ioscpm --pattern hd1k_combo.img --clobber
mkdir -p fixw8 && (cd fixw8 && python3 "$CPM" extract ~/src/romwbw_emu/disks/hd1k_infocom.img W8.COM)
# fixw8/w8.com is the fixed 1280-byte build (contains fe41d8fe5bd0c620)

# 2. Pull slice 0 out (1MB MBR prefix, then an 8MB slice), patch it as a single hd1k
dd if=hd1k_combo.img of=slice0.img bs=1048576 skip=1 count=8
python3 "$CPM" delete slice0.img W8.COM
python3 "$CPM" add    slice0.img fixw8/w8.com

# 3. Write slice 0 back and produce the fixed combo
cp hd1k_combo.img hd1k_combo_fixed.img
dd if=slice0.img of=hd1k_combo_fixed.img bs=1048576 seek=1 conv=notrunc

# 4. Verify: zero broken, W8.COM now 1280 bytes
python3 - <<'PY'
b=bytes.fromhex("fe41d8fe5bd0c600"); f=bytes.fromhex("fe41d8fe5bd0c620")
d=open("hd1k_combo_fixed.img","rb").read()
assert d.count(b)==0 and d.count(f)>0, "patch failed"
print("OK: broken=0 fixed=%d" % d.count(f))
PY

shasum -a 256 hd1k_combo_fixed.img
```

A verified build produced during the 2026-07-22 session has:
`sha256 = be19984edbcbb901973c268b870587235ea128e3c5e13b80a35d8c9488ec6d6e`
(size unchanged: 51380224 bytes). Re-verify after re-running — the hash is
stable only if the same published combo and fixed w8.com are used.

## Update the catalog and upload — DONE twice (3c10095 2026-07-22; v1.4.12 2026-09-01)

**Both halves of this step are already applied; nothing here is outstanding.**
`release_assets/disks.xml` is `<disks version="13">`, and that attribute has not
moved since `3c10095` (2026-07-22) bumped it 12 → 13. Its combo `<sha256>` has
moved twice, and the two are no longer the same file:

- **`v1.4.5`** (uploaded 2026-07-25) serves the catalog naming
  `be19984e…` — the um80-lowercase-fixed combo, but still the *old* `R8`/`W8`.
  Frozen. Every port pins this tag today.
- **`v1.4.12`** (2026-09-01, prerelease) serves the catalog naming
  `89b8ae1a…` — the same image with the current `r8.com`/`w8.com`. This is what
  `release_assets/disks.xml` tracks now, as of `d31815e`.

So `release_assets/` deliberately no longer matches what the fleet reads. If you
need the bytes `v1.4.5` serves, fetch them from the release rather than from
this checkout.

The app downloads `disks.xml` from the pinned `releases/download/v1.4.5/`
(`releaseTag` in `EmulatorViewModel.swift`; see `docs/DISK_CATALOG_PINNING.md`),
so the image and catalog must be uploaded **together**.

It does **not** verify the image's SHA-256 against the catalog, whatever this
paragraph said before. The live download path, `downloadDiskFromSettings`, moves
the temp file into `Documents/Disks/` without hashing it; the implementation that
does hash, `downloadDiskWithRetry`, is dead. See `todo.txt` under "nothing
verifies a downloaded disk's SHA256" and the "Integrity Verification" section of
`docs/DISK_DISTRIBUTION.md`. The catalog hash is still worth getting right - it
is displayed to the user, and it is what the fix will enforce - but nothing
refuses a mismatched image today. (Checked 2026-08-26: the published v1.4.5
`hd1k_combo.img` does hash to the `be19984e…` in the published `disks.xml`, so
what is shipped is consistent; it is the enforcement that is missing, not the
hash.)

The two steps below are the recipe for a **future** combo respin, corrected
2026-09-01 against what the `v1.4.12` respin actually did. Do not re-run them
against what is shipped now, and do not use any earlier revision of them: the
version they replaced said to `--clobber` `v1.4.5` and to bump the catalog
`version`, and both are forbidden. See the SUPERSEDED block at the top.

1. In `release_assets/disks.xml` (the uploaded catalog):
   - set the `hd1k_combo.img` `<sha256>` to the new hash from step 4,
   - **leave the `<disks version="…">` attribute exactly as it is.** An earlier
     revision of this line told you to bump it. Do not. See the warning
     immediately below, which was always right; `v1.4.12` shipped with it left
     at `13` and that is what kept the wipe from firing.

   > **Bumping that attribute destroys user data.** It is not a cache hint. On
   > the next catalog fetch after the bump, `checkCatalogVersionAndInvalidate`
   > calls `deleteAllDownloadedDisks()`, which removes **every** `.img` in
   > `Documents/Disks` — including disks the user imported through Files and
   > disks the app created, neither of which the catalog can give back — and
   > tells the user afterwards. It needs no tap and no download. This is the
   > second data-loss path on the same release step the `releaseTag` block
   > guards, it is unfixed, and what should happen instead is a product
   > decision. Read `todo.txt`, "THE SECOND DATA-LOSS PATH ON THAT SAME RELEASE
   > STEP", before running this step — it is not covered by romwbw_emu's
   > `docs/RELEASE_ORDER_2026-08-25.md`, which reasons only about `W8` and `R8`.
2. Publish to a **new prerelease tag**, carrying every catalog asset:
   ```bash
   gh release create vX.Y.Z --repo avwohl/ioscpm --prerelease \
     --title '... (asset carrier, not an app release)' \
     --notes '...' \
     upload/*          # all 20 catalog images + disks.xml + the 8 help files
   ```
   **Never `--clobber`, and never upload to `v1.4.5`.** An earlier revision of
   this step said to do exactly that and to not cut a fresh tag. That is the
   forbidden action: overwriting `v1.4.5`'s assets arms the changed images
   retroactively on every installed client, with no update and no way back.
   A new tag reaches nobody until a build points at it — *provided* it is a
   prerelease, because the installed fleet predates the pin and follows
   `releases/latest`.

   Bumping the *pin* is a separate, later decision: it means changing
   `releaseTag` in `EmulatorViewModel.swift` and shipping an app build, and it
   must not happen until that build carries the sanitiser. That is step 5 of
   `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md` and it is currently blocked.

   Then verify, and treat any failure as a reason to
   `gh release delete vX.Y.Z --cleanup-tag`:
   ```bash
   gh api repos/avwohl/ioscpm/releases/latest --jq .tag_name     # must be the OLD tag
   gh api repos/avwohl/ioscpm/releases/tags/vX.Y.Z --jq .prerelease   # must be true
   curl -sL .../releases/download/v1.4.5/hd1k_combo.img | sha256sum  # must be unchanged
   curl -sL .../releases/latest/download/disks.xml | sha256sum       # must be unchanged
   ```

## Remaining audit (likely unnecessary)

Only the combo bundles R8/W8. If you want to be exhaustive, scan the single-OS
images for the broken signature before deciding whether any need the same fix:

```bash
for f in $(gh release view v1.4.5 --repo avwohl/ioscpm --json assets \
            --jq '.assets[].name | select(endswith(".img"))'); do
  gh release download v1.4.5 --repo avwohl/ioscpm --pattern "$f" --clobber -O - 2>/dev/null \
   | python3 -c 'import sys;d=sys.stdin.buffer.read();print("%-20s broken=%d"%(sys.argv[1],d.count(bytes.fromhex("fe41d8fe5bd0c600"))))' "$f"
done
```

Also pin any disk-image builds to **RomWBW v3.5.1** — the emulator core
identifies its HBIOS as v3.5.1, and boot slices from other RomWBW releases print
a HBIOS/CBIOS version-mismatch warning.
