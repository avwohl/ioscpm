# Runbook: refresh release disk images with the fixed w8.com

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

Note: `cpmemu/util/cpm_disk.py` reads/writes **single hd1k** images correctly
but its **combo** extract/add path is unreliable (it returned the wrong slice's
`w8.com`). Always patch a combo via the dd-slice method below, never the combo
path directly.

## Produce the fixed combo (reproducible, verified)

```bash
CPM=~/src/cpmemu/util/cpm_disk.py

# 1. Get the current published combo and a known-good fixed w8.com
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

## Update the catalog and upload (release-management step — do by hand)

The app downloads `disks.xml` from `releases/latest/download/` and verifies each
image's SHA-256 against it, so the image and catalog must be uploaded **together**.

1. In `release_assets/disks.xml` (the uploaded catalog, currently `version="12"`):
   - set the `hd1k_combo.img` `<sha256>` to the new hash from step 4,
   - bump the `<disks version="…">` attribute (12 → 13) so clients re-download
     the fixed combo (the app invalidates cached disks on a version change).
2. Upload both to the release:
   ```bash
   gh release upload <tag> --repo avwohl/ioscpm --clobber \
     hd1k_combo_fixed.img#hd1k_combo.img disks.xml
   ```
   (Consider cutting a fresh release tag matching the app version, e.g. v1.4.11 —
   the release is currently v1.4.5.)

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
