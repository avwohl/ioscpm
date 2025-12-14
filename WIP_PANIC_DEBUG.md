# Work In Progress: iOS CP/M PANIC Debug

## Original Problem
- PANIC during CP/M boot: `>>> PANIC: @80BB[0093:F600:0000:0A00:CFFC]`
- Occurs after "Configuring Drives..." message
- PANIC comes from CBIOS ALLOC routine when Carry flag is set (allocation fails)

## Fix Applied
- Added Z80 flag handling to HBIOS SYSALLOC in `hbios_dispatch.cc`
- On success: sets Z flag (bit 6), clears C flag
- On failure: clears Z flag, sets C flag (bit 0)
- Uses `qkz80_cpu_flags::Z` and `qkz80_cpu_flags::CY` constants

## Progress After Fix
- CP/M boot got further - showed boot message
- New error: `[HBIOS CIO] Unhandled function 0xFF (unit=226)`
- func=0xFF and unit=226 (0xE2) are garbage values indicating corruption

## Investigation Notes

### User mentioned a "HEAPTOP/HEAPEND fix" in CLI/WASM
- Said they saw Claude mention it in a previous conversation
- Could not find this fix in:
  - Git history (searched commits)
  - Code comments
  - Documentation

### Key files examined:
- `/Users/wohl/src/romwbw_emu/src/emu_hbios.asm` - HCB has CB_HEAP=0, CB_HEAPTOP=0 at offsets 0x20, 0x22
- `/Users/wohl/src/romwbw_emu/src/hbios_dispatch.cc` - HBIOS heap runs 0x0200-0x8000
- `/Users/wohl/src/romwbw_emu/src/romwbw_mem.h` - Has WORKAROUND protecting CBIOS DEVMAP at 0x8678-0x867B
- `/Users/wohl/esrc/RomWBW-v3.5.1/Source/CBIOS/cbios.asm` - CBIOS has its OWN heap (HEAPTOP/HEAPEND) separate from HBIOS

### Important distinction:
- **HBIOS heap**: Used by SYSALLOC (0xF6), managed in hbios_dispatch.cc
- **CBIOS heap**: Internal to CBIOS, uses HEAPTOP (initialized to BUFPOOL) and HEAPEND (CBIOS_END-64)
- These are SEPARATE - CBIOS ALLOC doesn't call HBIOS SYSALLOC

### Possible fix locations to investigate:
1. `emu_hbios.asm` CB_HEAP/CB_HEAPTOP values (currently 0, maybe should be 0x0200?)
2. Memory protection in `romwbw_mem.h` write_bank() - already protects DEVMAP, maybe needs to protect HEAPTOP too?
3. Bank initialization in SYSSETBNK - copies HCB but maybe not all needed values?

## To Resume
1. Ask user if they remember more details about the HEAPTOP fix
2. Try setting CB_HEAP=0x0200 and CB_HEAPTOP=0x0200 in emu_hbios.asm and rebuild
3. Add more logging to trace where corruption occurs before CIO 0xFF error
4. Compare CLI romwbw_emu execution trace vs iOS execution to find divergence
