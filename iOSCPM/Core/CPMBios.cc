/*
 * CPMBios.cc - BIOS initialization for iOS CP/M Emulator
 */

#include "CPMBios.h"
#include <cstring>

// IBM 8" SSSD sector skew table (26 sectors)
static const uint8_t xlttab[26] = {
    1,7,13,19,25,5,11,17,23,3,9,15,21,
    2,8,14,20,26,6,12,18,24,4,10,16,22
};

void cpm_init_bios(char* memory) {
    uint8_t* mem = reinterpret_cast<uint8_t*>(memory);

    // Initialize BIOS jump table (17 entries, each is JMP to itself)
    // The emulator traps these addresses, so the JMP targets don't matter
    // but some programs read them, so they should point back to entry
    for (int i = 0; i < 17; i++) {
        uint16_t addr = BIOS_BASE + (i * 3);
        mem[addr] = 0xC3;           // JMP instruction
        mem[addr + 1] = addr & 0xFF;
        mem[addr + 2] = addr >> 8;
    }

    // Copy sector translation table
    memcpy(&mem[XLTTAB_ADDR], xlttab, 26);

    // Initialize Disk Parameter Block for 8" SSSD
    // DPB0 at F64D (15 bytes)
    uint16_t dpb = DPB0_ADDR;
    mem[dpb++] = 26;        // SPT low - sectors per track
    mem[dpb++] = 0;         // SPT high
    mem[dpb++] = 3;         // BSH - block shift (1K blocks)
    mem[dpb++] = 7;         // BLM - block mask
    mem[dpb++] = 0;         // EXM - extent mask
    mem[dpb++] = 242;       // DSM low - max block number
    mem[dpb++] = 0;         // DSM high
    mem[dpb++] = 63;        // DRM low - max directory entry
    mem[dpb++] = 0;         // DRM high
    mem[dpb++] = 0xC0;      // AL0 - directory allocation
    mem[dpb++] = 0;         // AL1
    mem[dpb++] = 16;        // CKS low - checksum size
    mem[dpb++] = 0;         // CKS high
    mem[dpb++] = 2;         // OFF low - reserved tracks
    mem[dpb++] = 0;         // OFF high

    // Initialize Disk Parameter Headers for drives A-D
    // Each DPH is 16 bytes
    uint16_t dph_addrs[4] = {DPH0_ADDR, DPH1_ADDR, DPH2_ADDR, DPH3_ADDR};
    uint16_t csv_base = CSV0_ADDR;
    uint16_t alv_base = ALV0_ADDR;

    for (int drive = 0; drive < 4; drive++) {
        uint16_t dph = dph_addrs[drive];
        uint16_t csv = csv_base + (drive * 16);  // 16 bytes per CSV
        uint16_t alv = alv_base + (drive * 31);  // 31 bytes per ALV

        // XLT - no sector translation (disk images are not skewed)
        mem[dph + 0] = 0;
        mem[dph + 1] = 0;
        // Scratch areas (used by BDOS)
        mem[dph + 2] = 0;
        mem[dph + 3] = 0;
        mem[dph + 4] = 0;
        mem[dph + 5] = 0;
        mem[dph + 6] = 0;
        mem[dph + 7] = 0;
        // DIRBUF pointer
        mem[dph + 8] = DIRBUF_ADDR & 0xFF;
        mem[dph + 9] = DIRBUF_ADDR >> 8;
        // DPB pointer
        mem[dph + 10] = DPB0_ADDR & 0xFF;
        mem[dph + 11] = DPB0_ADDR >> 8;
        // CSV pointer
        mem[dph + 12] = csv & 0xFF;
        mem[dph + 13] = csv >> 8;
        // ALV pointer
        mem[dph + 14] = alv & 0xFF;
        mem[dph + 15] = alv >> 8;
    }

    // Clear work areas
    memset(&mem[DIRBUF_ADDR], 0, 128);  // Directory buffer
    memset(&mem[CSV0_ADDR], 0, 64);     // Checksum vectors (4 * 16)
    memset(&mem[ALV0_ADDR], 0, 124);    // Allocation vectors (4 * 31)
}

bool cpm_is_bios_trap(uint16_t pc) {
    return pc >= BIOS_BASE && pc < BIOS_BASE + 0x33;
}
