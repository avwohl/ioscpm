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
> One artifact to know about: **`hd1k_combo_ioscpm_w8fixed.img`**, on `v1.4.5`
> **and on `v1.4.11`**, is byte-identical to the *unfixed* combo despite its
> name, is in no catalog entry at either tag, and was deliberately dropped from
> `v1.4.12` — which is why that release has 29 assets where the older two have
> 30. Do not republish it, and do not delete it from either release: nothing
> fetches it, and `v1.4.5` may not be touched at all.
>
> Everything below is kept for its audit history and its signature method, both
> of which are still correct. The two numbered upload steps are corrected in
> place.

## 2026-09-04 — the flag was cleared on `v1.4.12`, on purpose

`releases/latest` resolves to **`v1.4.12`**. This was decided rather than
happening, and the rules above are amended by it, not repealed. Read this before
concluding that a rule was broken.

**What was done, in order.**

1. The eight help assets on `v1.4.12` were replaced with the repo's current
   `release_assets/help_index.json` and `help_*.md`, using
   `gh release upload v1.4.12 --clobber`. `v1.4.12` had shipped an older, thinner
   help set naming the wrong container id (`com.awohl.iOSCPM`; the app is
   `com.awohl.cpm`) with no Android or Windows sections. Verified afterwards
   against `repos/avwohl/ioscpm/releases/tags/v1.4.12` — not against the
   `releases/latest` redirect, which has served stale bytes for minutes after an
   upload before — that all 21 disk assets kept their original asset ids and
   their 2026-09-01 timestamps, and that only the eight help objects are new.
2. `gh release edit v1.4.12 --prerelease=false`, then `--latest`. Clearing the
   flag alone did **not** move `releases/latest`: GitHub keeps an explicit
   `make_latest` on a release created as a prerelease, so the second command is
   required and its absence is silent.
3. Measured after: `latest/download/disks.xml` is byte-identical to
   `release_assets/disks.xml` and still `<disks version="13">`;
   `latest/download/hd1k_combo.img` hashes `89b8ae1a…`, matching the catalog;
   `latest/download/help_index.json` matches the repo.

**Why `--clobber` was used, when the rule above forbids it.** The rule exists to
stop published *disk* bytes changing under a client pinned to them — the
retroactive arming that is not undoable. Help is the deliberately floating half:
`HelpView.swift` and z80cpmw's `HelpWindow.cpp` both fetch it from
`releases/latest/download/`, so replacing it is the mechanism, not a violation of
it. No disk image and no `disks.xml` was touched. **The rule stands for disk
assets and for `v1.4.5` absolutely.**

**Why the flag was cleared.** The App Store fleet is 1.4.9 (builds 36/37), which
predates the catalog pin and floats. It was fetching `v1.4.11`'s combo, whose
`r8.com` hands an unfiltered host basename to `F_DELETE` — importing a host file
whose name holds `?` or `*` erases every matching CP/M file first, silently. No
build carrying the repin can be produced on the machines that have this work, so
the flag was the only lever that reaches those devices at all.

**What it actually reaches, which is less than it sounds.** `start()` only
downloads a disk that is **absent** — it gates on `isDiskDownloaded`. A device
that already holds `hd1k_combo.img` never re-fetches it, so the flip reaches
fresh installs and first downloads and nobody else. `todo.txt` claimed "every one
of those devices starts fetching the fixed R8 on its next catalog read"; that was
an overstatement and this corrects it. Reaching the rest needs the client-side
refresh added in build 60 (`DiskLedger.swift`), and therefore needs a build.

**What it cost.** Those builds have no W8 path sanitiser — that is build 52 — and
refreshing the catalog is what puts a path-capable `W8` in front of a user, which
is why `RELEASE_ORDER_2026-08-25.md` step 5 gates a catalog bump on the port
carrying its sanitiser. The mitigation is the `06 e9 cf` interlock and it is
partial: see the superseded note under "Audit result (2026-07-22)" above for
exactly how far it goes. No wipe fired — the version attribute is 13 on
`v1.4.11` and `v1.4.12` alike, checked on both.

**The rule for the next release is unchanged.** `--prerelease` always, on any
asset carrier, unless someone deliberately decides otherwise and writes down what
they traded — which is what this section is. A v3.6.0 disk set in particular must
still be held: the floating fleet has a v3.5.1 ROM and would take the mismatch on
every download.

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
`06 e9 cf` do not occur anywhere in the image. So the catalog as published *on
that date* could not arm the host-path `W8` at all; the exposure that build 52
fixes was via images a user imports through Files, not via anything the release
served.

> **Superseded 2026-09-04 — that last sentence is no longer true of what the
> repository serves.** `v1.4.12`'s `hd1k_combo.img` (`89b8ae1a…`) carries
> `Usage: W8 <cpmname> [hostpath]`, `Usage: R8 <hostpath>` and the `06 e9 cf`
> probe, and `releases/latest` now resolves to `v1.4.12`. So the floating 1.4.9
> fleet does download a host-path-capable `W8`. What holds it is the probe, not
> the tag: `HBF_HOST_CAPS` (0xE9) does not exist in a build 36/37 core, HBIOS
> answers A = 0xFF from the unknown-function path, and `W8` refuses the path
> form. That closes the honest footgun and nothing else — the interlock is
> advisory, lives inside `W8.COM`, and a crafted `.COM` calling 0xE2 directly
> skips it, exactly as `romwbw_emu/docs/RELEASE_ORDER_2026-08-25.md` says in its
> "the interlock is not a security boundary" block. That exposure predates today
> and is unchanged by it. See "2026-09-04" below for why the trade was taken.

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
#    Build from the PUBLISHED bytes, as here - not from
#    ~/src/romwbw_emu/disks/hd1k_combo.img, which is a superset carrying seven
#    developer scratch files that shipping would publish.
gh release download <tag-to-refresh> --repo avwohl/ioscpm --pattern hd1k_combo.img --clobber
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
  Frozen. Every port pinned this tag until `0010591`; none does now.
- **`v1.4.12`** (2026-09-01) serves the catalog naming `89b8ae1a…` — the same
  image with the current `r8.com`/`w8.com`. This is what
  `release_assets/disks.xml` tracks, as of `d31815e`, and what all three ports
  pin. It was published `--prerelease`; that flag was cleared on 2026-09-04 and
  it is now `releases/latest` as well. See "2026-09-04" at the top.

`release_assets/` therefore matches the pinned catalog again — it is
byte-identical to `v1.4.12`'s `disks.xml`. What it does not match is `v1.4.5`; if
you need the bytes that tag serves, fetch them from the release rather than from
this checkout.

The app downloads `disks.xml` from the pinned `releases/download/v1.4.12/`
(`releaseTag` in `EmulatorViewModel.swift`; see `docs/DISK_CATALOG_PINNING.md`),
so the image and catalog must be uploaded **together**.

**Since 2026-09-01 it does verify.** `downloadDiskFromSettings` hashes the temp
file against the catalog's `<sha256>` and refuses to install a mismatch, after
three attempts; the dead `downloadDiskWithRetry` that used to hold the only
hashing code is deleted. See the "Integrity Verification" section of
`docs/DISK_DISTRIBUTION.md`. So the catalog hash is now enforced, not advisory,
and getting it wrong stops the disk installing rather than merely colouring a
label red. It was already worth getting right; now it is load-bearing.

**Pre-ship gate, run 2026-09-01: every published asset matches its catalog, on
both tags.** An earlier note here recorded checking one file, `hd1k_combo.img`,
which was not enough once a mismatch became fatal rather than cosmetic. All
twenty entries of each catalog were streamed from the release and hashed against
the `<sha256>` and `<size>` the same release serves:

	Tag	Entries	Bad	Missing a hash
	v1.4.5	20	0	0
	v1.4.12	20	0	0

The nineteen non-combo hashes are identical across both tags, which is the
independent confirmation that `v1.4.12` re-uploaded them byte-identical rather
than rebuilding them. Only `hd1k_combo.img` differs: `be19984e…` on `v1.4.5`,
`89b8ae1a…` on `v1.4.12`.

Re-run this before any release that changes an asset, because enforcement turns
a stale catalog hash into a disk that cannot be installed at all:

```bash
tag=v1.4.5   # or the tag being shipped
base=https://github.com/avwohl/ioscpm/releases/download/$tag
python3 - "$base" <<'PY'
import re,sys,hashlib,urllib.request
base=sys.argv[1]
xml=urllib.request.urlopen(base+"/disks.xml").read().decode()
for m in re.finditer(r'<disk>(.*?)</disk>', xml, re.S):
    b=m.group(1)
    fn=re.search(r'<filename>(.*?)</filename>',b)
    h=re.search(r'<sha256>\s*([0-9a-fA-F]+)\s*</sha256>',b)
    if not fn: continue
    if not h: print("NOHASH", fn.group(1)); continue
    d=hashlib.sha256(); n=0
    with urllib.request.urlopen(f"{base}/{fn.group(1)}") as r:
        while (c:=r.read(1<<20)): d.update(c); n+=len(c)
    ok = d.hexdigest()==h.group(1).lower()
    print("OK  " if ok else "FAIL", fn.group(1), n)
PY
```

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

   > **Bumping that attribute deletes files on every installed device.** It is
   > not a cache hint. On the next catalog fetch after the bump,
   > `checkCatalogVersionAndInvalidate` clears downloaded images and tells the
   > user afterwards. It needs no tap and no download, and it is not covered by
   > romwbw_emu's `docs/RELEASE_ORDER_2026-08-25.md`, which reasons only about
   > `W8` and `R8`.
   >
   > Build 56 narrowed it to the images the **new** catalog names, so a disk the
   > user imported or created is kept — but **the builds in service still have
   > the old loop**, which took every `.img` in `Documents/Disks`. The App Store
   > serves 1.4.9 (builds 36/37); those predate the narrowing *and* the catalog
   > pin, so they fetch from `releases/latest/download/` and a normal release
   > reaches them at once. Until a build carrying the narrowing is one users
   > actually have, treat a version bump as destroying their whole disk library.
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
