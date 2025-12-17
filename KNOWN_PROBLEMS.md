# Known Problems

## Disk Creation

### Limited Disk Size Support
Currently only two disk sizes are supported. Need the ability to create disks of arbitrary/correct sizes.

### Proper Disk Initialization
When creating a new disk, it should be properly initialized with:
- E5 deleted flags in the directory entries
- Correct magic numbers for the disk format

### Creating Disks on Linux (Workaround)

Until disk creation is added to the app UI, you can create properly formatted HD1K disk images on Linux.

**Install cpmtools:**
```bash
sudo apt install cpmtools
```

**Supported disk sizes:**
- 8MB (8388608 bytes) - single slice disk
- 49MB (51380224 bytes) - 6-slice disk (6 × ~8MB)

**Create an 8MB single-slice disk:**
```bash
# Create empty file filled with E5 (CP/M empty marker)
dd if=/dev/zero bs=1 count=8388608 | tr '\000' '\345' > mydisk.img

# Format with CP/M filesystem (wbw_hd1k format)
mkfs.cpm -f wbw_hd1k mydisk.img
```

**Create a 49MB multi-slice disk:**
```bash
# Create empty file filled with E5
dd if=/dev/zero bs=1 count=51380224 | tr '\000' '\345' > mydisk.img

# Format each slice (0-5) - each slice is an independent CP/M filesystem
for slice in 0 1 2 3 4 5; do
    mkfs.cpm -f wbw_hd1k -b $slice mydisk.img
done
```

**Copy files to the disk:**
```bash
# Copy a file to slice 0 (drive A: in CP/M)
cpmcp -f wbw_hd1k mydisk.img localfile.com 0:FILENAME.COM

# List files on slice 0
cpmls -f wbw_hd1k mydisk.img
```

**Note:** The `wbw_hd1k` format is not included in standard cpmtools. You need the RomWBW diskdefs file.

**Option 1:** Use local RomWBW diskdefs (if you have RomWBW source):
```bash
# Point cpmtools to RomWBW diskdefs
export CPMTOOLS_DISKDEFS=/path/to/RomWBW/Source/Images/diskdefs

# Or use -T flag
mkfs.cpm -T /path/to/RomWBW/Source/Images/diskdefs -f wbw_hd1k mydisk.img
```

**Option 2:** Download diskdefs from RomWBW:
```bash
wget https://raw.githubusercontent.com/wwarthen/RomWBW/master/Source/Images/diskdefs
export CPMTOOLS_DISKDEFS=./diskdefs
```

**Option 3:** Add this to `/etc/cpmtools/diskdefs`:
```
diskdef wbw_hd1k
  seclen 512
  tracks 1024
  sectrk 16
  blocksize 4096
  maxdir 1024
  skew 0
  boottrk 2
  os 2.2
end
```

For multi-slice disks, use slice-specific definitions (`wbw_hd1k_0`, `wbw_hd1k_1`, etc.) which include proper offsets - see the RomWBW diskdefs file for full definitions.

## User Data Persistence

### Exporting User-Modified Disks
If a user downloads a disk to the iPad and adds their own files to it, there is currently no way to get that modified disk off the iPad.

### Data Loss Risk with GitHub Disks
Disks downloaded from GitHub are writable, allowing users to store data in them. However, this data can be lost at any time if a new version of the disk is released and downloaded, overwriting the user's changes.

**Potential solutions to consider:**
- Copy-on-write: Create a local copy when user first modifies a downloaded disk
- Separate user disks from system/downloaded disks
- Warn users before overwriting modified disks
- Provide disk export functionality (share sheet, Files app integration)
