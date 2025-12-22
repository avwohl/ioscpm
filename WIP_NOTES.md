# WIP: CP/M 3 Support and Code Consolidation

## Current Issue (Updated Dec 22, 2024)
- ~~iOS version shows "no devices" in boot menu ('d' command returns nothing)~~ **FIXED**
- **CP/M 3 still hangs where boot prompt should appear**
- Command-line version (romwbw_emu) works correctly
- Boot menu works, 'd' command works, but CP/M 3 hangs during initialization

## Changes Made (Dec 22, 2024)

### 1. Fixed ROM ident bytes bug
- `emu_hbios.asm` had wrong signature: `0xB8` instead of `0xA8` (~'W')
- Patched at lines 112 and 315: changed `0B8h` to `0A8h`
- Patched binary `emu_hbios_32k.bin` at offsets 0x104 and 0x501
- Updated `emu_avw.rom` and `emu_romwbw.rom`
- Copied updated ROM to iOS project

### 2. Removed manual memory pokes - let ROM handle everything
- **Removed** `setup_hbios_ident()` function from `hbios_core.cc`
- **Removed** manual proxy installation (`D3 EF C9` at 0xFFF0) from `start()`
- **Removed** write protection in `romwbw_mem.h` for 0xFE00-0xFE02, 0xFF00-0xFF02, 0xFFFC-0xFFFD

The ROM's `emu_hbios.asm` now handles everything:
1. Z80 starts at 0x0000 (ROM bank 0)
2. Runs HB_START at 0x0200
3. LDIR copies proxy from 0x0500 to 0xFE00-0xFFFF (includes ident + entry points)
4. Signal port sequence (0xEE) registers dispatch addresses
5. OUT (0xEE), 0xFF enables trapping
6. Switches to bank 1 (romldr) via trampoline

### 3. Added debug tracing
Debug output added to diagnose why devices aren't showing:

**hbios_core.cc:**
- Port 0xEE (signal): logs each signal value
- Port 0xEF (dispatch): logs function code B and unit C
- Proxy check: verifies 0xFFF0 contains `D3 EF C9` after 1000 instructions
- Ident check: verifies 0xFE00 contains `57 A8 35`

**hbios_dispatch.cc:**
- `initMemoryDisks()`: logs HCB config values read from ROM
- `SYSGET_DIOCNT`: logs md_disks and hd_disks counts

## Expected Debug Output
```
[SIGNAL] port 0xEE value=0x01        <- boot starting
[SIGNAL] port 0xEE value=0x02        <- proxy ready
[MD] initMemoryDisks called...
[MD] HCB config: ramd_start=0x81 ramd_banks=8 romd_start=0x04 romd_banks=12
[PROXY CHECK] 0xFFF0: D3 EF C9       <- OUT (0xEF), A; RET
[IDENT CHECK] 0xFE00: 57 A8 35       <- 'W', ~'W', ver
[HBIOS] port 0xEF dispatch: B=0xF8 C=0x10 (func=SYSGET)
[DIOCNT] md_disks: 1,1 hd_disks: 0 total=2
```

## What to Check
1. **Is port 0xEF ever called?** If not, proxy isn't installed (LDIR failed)
2. **Does PROXY CHECK show `D3 EF C9`?** If not, ROM copy to 0xFFF0 failed
3. **Does DIOCNT show `total=2`?** If 0, md_disks not being enabled
4. **Are signal ports called?** Should see 0x01, 0x02, then address bytes, then 0xFF

## Files Modified
- `/Users/wohl/src/romwbw_emu/src/emu_hbios.asm` - fixed ident bytes
- `/Users/wohl/src/romwbw_emu/src/romwbw_mem.h` - removed write protection
- `/Users/wohl/src/romwbw_emu/src/hbios_dispatch.cc` - added debug logging
- `/Users/wohl/src/romwbw_emu/roms/emu_hbios_32k.bin` - patched binary
- `/Users/wohl/src/romwbw_emu/roms/emu_avw.rom` - updated
- `/Users/wohl/src/romwbw_emu/roms/emu_romwbw.rom` - updated
- `/Users/wohl/src/ioscpm/iOSCPM/Resources/emu_avw.rom` - updated
- `/Users/wohl/src/ioscpm/iOSCPM/Core/hbios_core.cc` - removed manual setup, added debug

## Key Insight
romwbw_emu has its OWN HBIOS implementation in `romwbw_emu.cc` - it does NOT use `HBIOSDispatch` class.
iOS uses `HBIOSDispatch` via symlinked `hbios_dispatch.cc/h`.
Both use the same `romwbw_mem.h` for banked memory.

## Architecture
```
romwbw_emu:
  romwbw_emu.cc -> own HBIOS handling (handle_hbios_call, etc.)
                -> romwbw_mem.h (banked_mem class)

ioscpm:
  hbios_core.cc -> HBIOSDispatch (symlink to hbios_dispatch.cc)
               -> romwbw_mem.h (symlink, same banked_mem class)
```

## Recent Fixes (Dec 22, 2024)

### Fixed: 'd' command now shows devices
Added port 0xED (BNKCALL) handler to `hbios_core.cc`:
```cpp
case 0xED: {
  // EMU BNKCALL port - bank call to HBIOS vectors
  uint16_t call_addr = regs.IX.get_pair16();
  if (call_addr == 0x0406) {
    // PRTSUM - Print device summary
    emulator->hbios.handlePRTSUM();
  }
  break;
}
```

### Verified: Same disk images in use
Added SHA256 checksums to disk catalog (disks.xml v7). Verified iOS and romwbw_emu use identical hd1k_combo.img:
`c14b9bef3eca03523c059b6c5eb4921e66323921dc481ebf5f84fb378627fb0f`

### Improved: HBIOS logging
Updated port 0xEF logging to show all function names (CIOIN, CIOOUT, CIOIST, DIOSEEK, DIOREAD, etc.) instead of just a few.

## Diagnosing CP/M 3 Hang

The current log (`~/x.txt`) only shows:
1. Boot initialization
2. Disk loading (HD0, HD1)
3. Boot menu display ("RetroBrew SBC Boot Loader")
4. CIOIST polling (waiting for keyboard input)

**The log does NOT show CP/M 3 boot** - it stops at the boot menu waiting for input.

### What's Needed
1. **Capture log DURING CP/M 3 boot** - select CP/M 3 from menu and let it run until hang
2. Look for:
   - SYSBOOT call (B=0xFE)
   - DIOREAD/DIOSEEK calls (loading CP/M 3)
   - Bank operations (SYSSETBNK, SYSBNKCPY)
   - What function is being called when it hangs

### Potential Causes
1. Missing HBIOS function that CP/M 3 uses during initialization
2. Wrong return value from some SYSGET subfunction
3. Bank switching issue with CP/M 3's banked BDOS
4. BNKCALL to address other than 0x0406 (PRTSUM) being ignored

## Next Steps
1. **Get new log** showing actual CP/M 3 boot process (not just boot menu)
2. Compare HBIOS calls during CP/M 3 boot between iOS and romwbw_emu
3. Check if any BNKCALL addresses other than 0x0406 are needed
