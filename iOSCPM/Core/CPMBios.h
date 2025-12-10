/*
 * CPMBios.h - BIOS initialization for iOS CP/M Emulator
 *
 * Sets up the CP/M BIOS memory layout programmatically,
 * eliminating the need for external BIOS assembly.
 */

#ifndef CPMBIOS_H
#define CPMBIOS_H

#include <cstdint>

// CP/M memory layout constants
constexpr uint16_t CPM_LOAD_ADDR = 0xE000;   // CCP+BDOS load address
constexpr uint16_t BIOS_BASE = 0xF600;       // BIOS entry points

// BIOS layout from bios.asm
// Jump table: F600-F632 (17 entries * 3 bytes = 51 bytes)
// XLTTAB:   F633 (26 bytes, sector skew table)
// DPB0:     F64D (15 bytes, disk parameter block)
// DPH0:     F65C (16 bytes per drive * 4 drives)
// DIRBUF:   F69C (128 bytes, directory buffer)
// CSV0-3:   F71C (16 bytes each, checksum vectors)
// ALV0-3:   F75C (31 bytes each, allocation vectors)

constexpr uint16_t XLTTAB_ADDR = 0xF633;
constexpr uint16_t DPB0_ADDR = 0xF64D;
constexpr uint16_t DPH0_ADDR = 0xF65C;
constexpr uint16_t DPH1_ADDR = 0xF66C;
constexpr uint16_t DPH2_ADDR = 0xF67C;
constexpr uint16_t DPH3_ADDR = 0xF68C;
constexpr uint16_t DIRBUF_ADDR = 0xF69C;
constexpr uint16_t CSV0_ADDR = 0xF71C;
constexpr uint16_t ALV0_ADDR = 0xF75C;

// BIOS entry point offsets (relative to BIOS_BASE)
enum BiosEntry {
    BIOS_BOOT    = 0x00, BIOS_WBOOT   = 0x03, BIOS_CONST   = 0x06,
    BIOS_CONIN   = 0x09, BIOS_CONOUT  = 0x0C, BIOS_LIST    = 0x0F,
    BIOS_PUNCH   = 0x12, BIOS_READER  = 0x15, BIOS_HOME    = 0x18,
    BIOS_SELDSK  = 0x1B, BIOS_SETTRK  = 0x1E, BIOS_SETSEC  = 0x21,
    BIOS_SETDMA  = 0x24, BIOS_READ    = 0x27, BIOS_WRITE   = 0x2A,
    BIOS_PRSTAT  = 0x2D, BIOS_SECTRN  = 0x30,
};

// Disk geometry for 8" SSSD (standard CP/M format)
constexpr int CPM_TRACKS = 77;
constexpr int CPM_SECTORS = 26;
constexpr int CPM_SECTOR_SIZE = 128;
constexpr int CPM_TRACK_SIZE = CPM_SECTORS * CPM_SECTOR_SIZE;
constexpr int CPM_DISK_SIZE = CPM_TRACKS * CPM_TRACK_SIZE;

// Initialize BIOS tables in memory
void cpm_init_bios(char* memory);

// Check if PC is at a BIOS trap address
bool cpm_is_bios_trap(uint16_t pc);

#endif // CPMBIOS_H
