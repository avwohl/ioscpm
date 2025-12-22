/*
 * HBIOS Core - RomWBW HBIOS Emulation Implementation
 *
 * Uses the shared HBIOSDispatch for HBIOS function handling.
 */

#include "hbios_core.h"
#include "emu_io.h"
#include <cstring>
#include <cstdarg>

// Debug log file - set to nullptr to disable logging
FILE* debug_log_file = nullptr;

// Debug logging - disabled in production (no-op when debug_log_file is null)
static inline void hlog(const char*, ...) {
  // No-op - debug logging disabled
}

//=============================================================================
// hbios_cpu Implementation
//=============================================================================

hbios_cpu::hbios_cpu(qkz80_cpu_mem* mem, HBIOSEmulator* emu)
  : qkz80(mem), emulator(emu) {}

void hbios_cpu::halt() {
  emu_status("HLT instruction - emulation stopped\n");
  hlog("[HALT] Z80 HLT at PC=0x%04X\n", regs.PC.get_pair16());
  emulator->running = false;
}

void hbios_cpu::unimplemented_opcode(qkz80_uint8 opcode, qkz80_uint16 pc) {
  emu_error("Unimplemented opcode 0x%02X at PC=0x%04X\n", opcode, pc);
  hlog("[UNIMPL] Unimplemented opcode 0x%02X at PC=0x%04X\n", opcode, pc);
  emulator->running = false;
}

qkz80_uint8 hbios_cpu::port_in(qkz80_uint8 port) {
  switch (port) {
    case 0x68: {  // UART data register - read character
      int ch = emulator->hbios.readInputChar();
      return (ch >= 0) ? (ch & 0xFF) : 0;
    }

    case 0x6D:  // UART Line Status Register (LSR)
      // Bit 0: Data Ready, Bit 5: THRE (transmitter empty), Bit 6: TEMT
      return 0x60 | (emulator->hbios.hasInputChar() ? 0x01 : 0x00);

    case 0x78:  // Bank register
    case 0x7C:
      return emulator->memory.get_current_bank();

    case 0xFE:  // Sense switches (front panel)
      return 0x00;

    default:
      return 0xFF;
  }
}

void hbios_cpu::port_out(qkz80_uint8 port, qkz80_uint8 value) {
  // DEBUG: Log port output (except noisy 0xEF which is HBIOS dispatch)
  if (port >= 0xE0 && port != 0xEF) {
    hlog( "[PORT OUT] port=0x%02X value=0x%02X PC=0x%04X\n",
            port, value, regs.PC.get_pair16());
  }

  switch (port) {
    case 0x78:  // RAM bank
    case 0x7C:  // ROM bank
      // Initialize RAM bank if first access (ensures page zero/HCB is present)
      // This is needed because CP/M 3 uses direct port I/O for bank switching
      // instead of HBIOS SYSSETBNK, bypassing the initialization in that handler.
      emulator->initializeRamBankIfNeeded(value);
      emulator->memory.select_bank(value);
      break;

    case 0xEC: {
      // EMU BNKCPY port - inter-bank memory copy
      // Called when HB_BNKCPY at 0xFFF6 executes: OUT (0xEC), A
      // Parameters:
      //   HL = source address, DE = dest address, BC = byte count
      //   0xFFE4 = source bank, 0xFFE7 = dest bank
      uint16_t src_addr = regs.HL.get_pair16();
      uint16_t dst_addr = regs.DE.get_pair16();
      uint16_t length = regs.BC.get_pair16();
      uint8_t src_bank = emulator->memory.fetch_mem(0xFFE4);
      uint8_t dst_bank = emulator->memory.fetch_mem(0xFFE7);

      // DEBUG: Always log BNKCPY calls
      static int bnkcpy_count = 0;
      bnkcpy_count++;
      hlog("[BNKCPY #%d] src=%02X:%04X dst=%02X:%04X len=%d PC=0x%04X\n",
           bnkcpy_count, src_bank, src_addr, dst_bank, dst_addr, length,
           regs.PC.get_pair16());

      // Perform inter-bank copy
      for (uint16_t i = 0; i < length; i++) {
        uint8_t byte;
        uint16_t s_addr = src_addr + i;
        uint16_t d_addr = dst_addr + i;

        // Read from source
        if (s_addr >= 0x8000) {
          byte = emulator->memory.fetch_mem(s_addr);
        } else {
          byte = emulator->memory.read_bank(src_bank, s_addr);
        }

        // Write to dest
        if (d_addr >= 0x8000) {
          emulator->memory.store_mem(d_addr, byte);
        } else {
          emulator->memory.write_bank(dst_bank, d_addr, byte);
        }
      }
      break;
    }

    case 0xED: {
      // EMU BNKCALL port - bank call to HBIOS vectors
      // Called when HB_BNKCALL at 0xFFF9 executes: OUT (0xED), A
      // On entry: A = target bank, IX = call address in target bank
      uint16_t call_addr = regs.IX.get_pair16();
      hlog( "[BNKCALL] bank=0x%02X addr=0x%04X\n", value, call_addr);

      // Dispatch to HBIOSDispatch for known vectors
      if (call_addr == 0x0406) {
        // PRTSUM - Print device summary (used by boot loader 'D' command)
        emulator->hbios.handlePRTSUM();
      } else {
        hlog( "[BNKCALL] Unknown vector 0x%04X - ignoring\n", call_addr);
      }
      // Z80 proxy code has its own RET, so no action needed
      break;
    }

    case 0x68:  // UART data register - direct character output (used by boot menu)
      // Output character to buffer (will be displayed by runBatch)
      emulator->hbios.queueOutputChar(value);
      break;

    case 0xEE:  // EMU signal port
      hlog("[SIGNAL] port 0xEE value=0x%02X\n", value);
      emulator->hbios.handleSignalPort(value);
      break;

    case 0xEF: {  // HBIOS dispatch port
      uint8_t func = emulator->cpu.regs.BC.get_high();
      uint8_t unit = emulator->cpu.regs.BC.get_low();

      // Suppress repeated CIOIST spam - only log every 1000th or when func changes
      static uint8_t last_func = 0xFF;
      static int cioist_count = 0;

      if (func == 0x02) {  // CIOIST
        cioist_count++;
        // Log buffer state periodically to debug input issues
        bool has_input = emulator->hbios.hasInputChar();
        if (last_func != 0x02) {
          hlog("[HBIOS] CIOIST polling started... (has_input=%d)\n", has_input ? 1 : 0);
        } else if (cioist_count % 1000 == 0) {
          hlog("[HBIOS] ...CIOIST x%d (has_input=%d)\n", cioist_count, has_input ? 1 : 0);
        }
        // If we have input, log every call to trace transition
        if (has_input) {
          hlog("[HBIOS] CIOIST with input available! cioist_count=%d\n", cioist_count);
        }
        last_func = func;
        emulator->hbios.handlePortDispatch();
        break;
      }

      // Log other functions normally
      if (last_func == 0x02 && cioist_count > 1) {
        hlog("[HBIOS] ...CIOIST ended after %d polls\n", cioist_count);
        cioist_count = 0;
      }
      last_func = func;

      // Map function code to name
      const char* func_name = "???";
      switch (func) {
        case 0x00: func_name = "CIOIN"; break;
        case 0x01: func_name = "CIOOUT"; break;
        case 0x03: func_name = "CIOOST"; break;
        case 0x04: func_name = "CIOINIT"; break;
        case 0x05: func_name = "CIOQUERY"; break;
        case 0x06: func_name = "CIODEVICE"; break;
        case 0x10: func_name = "DIOSTATUS"; break;
        case 0x11: func_name = "DIORESET"; break;
        case 0x12: func_name = "DIOSEEK"; break;
        case 0x13: func_name = "DIOREAD"; break;
        case 0x14: func_name = "DIOWRITE"; break;
        case 0x15: func_name = "DIOVERIFY"; break;
        case 0x17: func_name = "DIODEVICE"; break;
        case 0x18: func_name = "DIOMEDIA"; break;
        case 0x1A: func_name = "DIOCAP"; break;
        case 0x1B: func_name = "DIOGEOM"; break;
        case 0x20: func_name = "RTCGETTIM"; break;
        case 0x21: func_name = "RTCSETTIM"; break;
        case 0x40: func_name = "VDAINI"; break;
        case 0x41: func_name = "VDAQRY"; break;
        case 0x45: func_name = "VDASCP"; break;
        case 0x48: func_name = "VDAWRC"; break;
        case 0x4C: func_name = "VDAKST"; break;
        case 0x4E: func_name = "VDAKRD"; break;
        case 0xE0: func_name = "EXTSLICE"; break;
        case 0xF0: func_name = "SYSRESET"; break;
        case 0xF1: func_name = "SYSVER"; break;
        case 0xF2: func_name = "SYSSETBNK"; break;
        case 0xF3: func_name = "SYSGETBNK"; break;
        case 0xF4: func_name = "SYSSETCPY"; break;
        case 0xF5: func_name = "SYSBNKCPY"; break;
        case 0xF6: func_name = "SYSALLOC"; break;
        case 0xF8: func_name = "SYSGET"; break;
        case 0xF9: func_name = "SYSSET"; break;
        case 0xFA: func_name = "SYSPEEK"; break;
        case 0xFB: func_name = "SYSPOKE"; break;
        case 0xFE: func_name = "SYSBOOT"; break;
      }
      hlog("[HBIOS] B=0x%02X C=0x%02X (%s)\n", func, unit, func_name);
      emulator->hbios.handlePortDispatch();
      break;
    }
  }
}

//=============================================================================
// Constructor/Destructor
//=============================================================================

HBIOSEmulator::HBIOSEmulator()
  : memory(), cpu(&memory, this), running(false), waiting_for_input(false),
    debug(false), instruction_count(0), boot_string_pos(0), initialized_ram_banks(0)
{
  // Initialize banked memory
  memory.enable_banking();

  // Set up HBIOS dispatcher with CPU and memory references
  hbios.setCPU(&cpu);
  hbios.setMemory(&memory);

  // iOS uses non-blocking I/O (UI must remain responsive)
  hbios.setBlockingAllowed(false);

  reset();
}

HBIOSEmulator::~HBIOSEmulator() {
  stop();
}

//=============================================================================
// Reset
//=============================================================================

void HBIOSEmulator::reset() {
  running = false;
  waiting_for_input = false;
  instruction_count = 0;
  boot_string_pos = 0;
  initialized_ram_banks = 0;

  // Reset HBIOS dispatcher (clears input/output buffers)
  hbios.reset();

  // Reset CPU
  cpu.regs.AF.set_pair16(0);
  cpu.regs.BC.set_pair16(0);
  cpu.regs.DE.set_pair16(0);
  cpu.regs.HL.set_pair16(0);
  cpu.regs.PC.set_pair16(0);
  cpu.regs.SP.set_pair16(0);

  // Select ROM bank 0
  memory.select_bank(0);
}

//=============================================================================
// RAM Bank Initialization
//=============================================================================

void HBIOSEmulator::initializeRamBankIfNeeded(uint8_t bank) {
  // Only initialize RAM banks 0x80-0x8F
  if (!(bank & 0x80) || (bank & 0x70)) return;

  uint8_t bank_idx = bank & 0x0F;
  if (initialized_ram_banks & (1 << bank_idx)) return;  // Already initialized

  hlog("[BANK INIT] Initializing RAM bank 0x%02X with page zero and HCB\n", bank);

  // Copy page zero (0x0000-0x0100) from ROM bank 0 - contains RST vectors
  for (uint16_t addr = 0x0000; addr < 0x0100; addr++) {
    uint8_t byte = memory.read_bank(0x00, addr);  // Read from ROM bank 0
    memory.write_bank(bank, addr, byte);          // Write to RAM bank
  }

  // Copy HCB (0x0100-0x0200) from ROM bank 0 - HBIOS configuration
  for (uint16_t addr = 0x0100; addr < 0x0200; addr++) {
    uint8_t byte = memory.read_bank(0x00, addr);
    memory.write_bank(bank, addr, byte);
  }

  // Mark this bank as initialized
  initialized_ram_banks |= (1 << bank_idx);
}

//=============================================================================
// ROM Loading
//=============================================================================

bool HBIOSEmulator::loadROM(const uint8_t* data, size_t size) {
  if (!data || size == 0) {
    emu_error("[HBIOS] ROM data is null or empty\n");
    return false;
  }

  uint8_t* rom = memory.get_rom();
  if (!rom) {
    emu_error("[HBIOS] ROM memory not allocated\n");
    return false;
  }

  // Clear RAM for clean state when loading a new ROM
  // (following porting notes: ensures stop/start behaves identically to fresh app launch)
  memory.clear_ram();

  // Copy ROM data (up to 512KB)
  size_t copy_size = (size > 512 * 1024) ? 512 * 1024 : size;
  memcpy(rom, data, copy_size);

  // Patch APITYPE at 0x0112 to 0x00 (HBIOS) instead of 0xFF (UNA)
  // This is required for REBOOT and other utilities to work correctly
  rom[0x0112] = 0x00;  // CB_APITYPE = HBIOS

  // Copy HCB (HBIOS Configuration Block) to RAM bank 0x80
  uint8_t* ram = memory.get_ram();
  if (ram) {
    memcpy(ram, rom, 512);  // First 512 bytes
  }

  // NOTE: HBIOS ident signatures and entry points are set up by the ROM code
  // itself. The ROM's emu_hbios.asm copies proxy (including ident) from 0x0500
  // to 0xFE00-0xFFFF via LDIR at startup. We do NOT manually set them here.

  emu_log("[HBIOS] ROM loaded: %zu bytes\n", copy_size);

  // DEBUG: Show HCB config after ROM load
  hlog( "[ROM-DEBUG] After ROM load - HCB config:\n");
  hlog( "[ROM-DEBUG]   CB_RAMD_BNKS (0x1DD) = %02X\n", rom[0x1DD]);
  hlog( "[ROM-DEBUG]   CB_ROMD_BNKS (0x1DF) = %02X\n", rom[0x1DF]);
  hlog( "[ROM-DEBUG]   CB_DEVCNT (0x10C) = %02X\n", rom[0x10C]);
  hlog( "[ROM-DEBUG]   CB_APITYPE (0x112) = %02X (should be 0x00 for HBIOS)\n", rom[0x112]);

  return true;
}

bool HBIOSEmulator::loadROMFromFile(const std::string& path) {
  std::vector<uint8_t> data;
  if (!emu_file_load(path, data)) {
    return false;
  }
  return loadROM(data.data(), data.size());
}

//=============================================================================
// Disk Management
//=============================================================================

bool HBIOSEmulator::loadDisk(int unit, const uint8_t* data, size_t size) {
  hlog( "[DISK-DEBUG] loadDisk called: unit=%d size=%zu\n", unit, size);
  bool result = hbios.loadDisk(unit, data, size);
  // Show disk loading on stderr for visibility
  fprintf(stderr, "[DISK] Unit %d: %s (%zu bytes)\n", unit, result ? "loaded" : "FAILED", size);
  hlog( "[DISK-DEBUG] loadDisk result: %s, isDiskLoaded(%d)=%d\n",
          result ? "success" : "FAILED", unit, hbios.isDiskLoaded(unit) ? 1 : 0);
  return result;
}

bool HBIOSEmulator::loadDiskFromFile(int unit, const std::string& path) {
  return hbios.loadDiskFromFile(unit, path);
}

const uint8_t* HBIOSEmulator::getDiskData(int unit) const {
  if (!hbios.isDiskLoaded(unit)) return nullptr;
  const HBDisk& disk = hbios.getDisk(unit);
  return disk.data.empty() ? nullptr : disk.data.data();
}

size_t HBIOSEmulator::getDiskSize(int unit) const {
  if (!hbios.isDiskLoaded(unit)) return 0;
  return hbios.getDisk(unit).data.size();
}

bool HBIOSEmulator::isDiskLoaded(int unit) const {
  return hbios.isDiskLoaded(unit);
}

void HBIOSEmulator::closeAllDisks() {
  hlog( "[DISK-DEBUG] closeAllDisks called\n");
  hbios.closeAllDisks();
}

void HBIOSEmulator::setDiskSliceCount(int unit, int slices) {
  hbios.setDiskSliceCount(unit, slices);
}

//=============================================================================
// Input Queue
//=============================================================================

void HBIOSEmulator::queueInput(int ch) {
  if (ch == '\n') ch = '\r';  // LF -> CR for CP/M

  // Queue to HBIOSDispatch's internal buffer (state machine approach)
  hbios.queueInputChar(ch);

  hlog("[INPUT] queueInput(0x%02X '%c') waiting_for_input was %d\n",
       ch, (ch >= 32 && ch < 127) ? ch : '?', waiting_for_input ? 1 : 0);

  // Clear waiting flag if we were blocked on input
  if (waiting_for_input) {
    waiting_for_input = false;
  }
}

bool HBIOSEmulator::hasInput() const {
  return hbios.hasInputChar() || boot_string_pos < boot_string.size();
}

void HBIOSEmulator::setBootString(const std::string& str) {
  boot_string = str;
  boot_string_pos = 0;
}

//=============================================================================
// Execution Control
//=============================================================================

void HBIOSEmulator::start() {
  // Key startup info goes to both file and stderr
  fprintf(stderr, "[HBIOS] Build: " __DATE__ " " __TIME__ "\n");
  hlog("[HBIOS] Build: " __DATE__ " " __TIME__ "\n");
  hlog("[HBIOS] Starting emulation\n");

  // Set Z80 mode
  cpu.set_cpu_mode(qkz80::MODE_Z80);

  // Enable banking
  memory.enable_banking();

  // DEBUG: Enable proxy parameter tracing
  memory.set_trace_proxy_params(true);

  // Debug: check disk state BEFORE reset
  hlog( "[HBIOS] Before reset - checking disk state:\n");
  for (int i = 0; i < 4; i++) {
    hlog( "[HBIOS]   disk[%d].is_open = %d\n", i, hbios.isDiskLoaded(i) ? 1 : 0);
  }

  // Reset HBIOS state for new ROM (like web version does)
  hbios.reset();

  // Debug: check disk state AFTER reset
  hlog( "[HBIOS] After reset - checking disk state:\n");
  for (int i = 0; i < 4; i++) {
    hlog( "[HBIOS]   disk[%d].is_open = %d\n", i, hbios.isDiskLoaded(i) ? 1 : 0);
  }

  // Initialize memory disks (MD0=RAM, MD1=ROM) and populate disk unit table
  hlog( "[HBIOS] Calling initMemoryDisks()\n");
  hbios.initMemoryDisks();

  // DEBUG: Dump HCB disk unit table and drive map from ROM
  uint8_t* rom = memory.get_rom();
  uint8_t* ram = memory.get_ram();
  if (rom && ram) {
    hlog( "[HCB-DEBUG] Disk Unit Table at 0x160 (ROM vs RAM bank 0x80):\n");
    for (int i = 0; i < 16; i++) {
      uint8_t rom_type = rom[0x160 + i*4 + 0];
      uint8_t rom_unit = rom[0x160 + i*4 + 1];
      uint8_t ram_type = ram[0x160 + i*4 + 0];
      uint8_t ram_unit = ram[0x160 + i*4 + 1];
      if (rom_type != 0xFF || ram_type != 0xFF) {
        hlog( "[HCB-DEBUG]   [%d] ROM: type=%02X unit=%02X | RAM: type=%02X unit=%02X\n",
                i, rom_type, rom_unit, ram_type, ram_unit);
      }
    }
    hlog( "[HCB-DEBUG] Drive Map at 0x120 (ROM vs RAM):\n");
    hlog( "[HCB-DEBUG]   ROM: ");
    for (int i = 0; i < 16; i++) hlog( "%02X ", rom[0x120 + i]);
    hlog( "\n[HCB-DEBUG]   RAM: ");
    for (int i = 0; i < 16; i++) hlog( "%02X ", ram[0x120 + i]);
    hlog( "\n[HCB-DEBUG] CB_DEVCNT (0x10C): ROM=%02X RAM=%02X\n",
            rom[0x10C], ram[0x10C]);
    hlog( "[HCB-DEBUG] CB_RAMD_BNKS (0x1DD): ROM=%02X | CB_ROMD_BNKS (0x1DF): ROM=%02X\n",
            rom[0x1DD], rom[0x1DF]);
  }

  // NOTE: HBIOS proxy at 0xFFF0 is installed by the ROM code itself.
  // The ROM's emu_hbios.asm copies proxy from 0x0500 to 0xFE00-0xFFFF via LDIR.
  // We do NOT manually install it here - let the ROM handle everything.

  // Register reset callback for SYSRESET (REBOOT command)
  hbios.setResetCallback([this](uint8_t reset_type) {
    emu_log("[SYSRESET] %s boot - restarting\n",
            reset_type == 0x01 ? "Warm" : "Cold");
    // Switch to ROM bank 0
    memory.select_bank(0x00);
    // Set PC to 0 to restart from ROM
    cpu.regs.PC.set_pair16(0x0000);
  });

  // Reset all CPU registers (like web version does)
  cpu.regs.AF.set_pair16(0);
  cpu.regs.BC.set_pair16(0);
  cpu.regs.DE.set_pair16(0);
  cpu.regs.HL.set_pair16(0);
  cpu.regs.PC.set_pair16(0x0000);  // Start at ROM address 0
  cpu.regs.SP.set_pair16(0x0000);

  // Select ROM bank 0
  memory.select_bank(0);

  running = true;
  waiting_for_input = false;
  instruction_count = 0;

  // Feed boot string to HBIOS input buffer
  if (!boot_string.empty()) {
    hbios.queueInputChars((const uint8_t*)boot_string.data(), boot_string.size());
    hbios.queueInputChar('\r');  // Submit with CR
  }
}

void HBIOSEmulator::stop() {
  running = false;
}

void HBIOSEmulator::setDebug(bool enable) {
  debug = enable;
  emu_set_debug(enable);
  hbios.setDebug(enable);
  memory.set_debug(enable);
}

//=============================================================================
// Main Execution Loop
//=============================================================================

void HBIOSEmulator::runBatch(int count) {
  if (!running) return;

  // One-time check: verify proxy at 0xFFF0 and 0xFFF6 after boot code runs
  static bool proxy_checked = false;
  if (!proxy_checked && instruction_count > 1000) {
    proxy_checked = true;
    uint8_t b0 = memory.fetch_mem(0xFFF0);
    uint8_t b1 = memory.fetch_mem(0xFFF1);
    uint8_t b2 = memory.fetch_mem(0xFFF2);
    hlog("[PROXY CHECK] 0xFFF0: %02X %02X %02X (expect D3 EF C9 = HBIOS invoke)\n", b0, b1, b2);
    // Check BNKCPY proxy at 0xFFF6
    uint8_t c0 = memory.fetch_mem(0xFFF6);
    uint8_t c1 = memory.fetch_mem(0xFFF7);
    uint8_t c2 = memory.fetch_mem(0xFFF8);
    hlog("[PROXY CHECK] 0xFFF6: %02X %02X %02X (expect D3 EC C9 = BNKCPY trigger)\n", c0, c1, c2);
    // Also check ident at 0xFE00
    uint8_t id0 = memory.fetch_mem(0xFE00);
    uint8_t id1 = memory.fetch_mem(0xFE01);
    uint8_t id2 = memory.fetch_mem(0xFE02);
    hlog("[IDENT CHECK] 0xFE00: %02X %02X %02X (expect 57 A8 35)\n", id0, id1, id2);
  }

  // Track CP/M 3 boot progress and detect when it crashes back to boot menu
  static bool cpm3_loading = false;
  static bool cpm3_started = false;
  static bool xbnkmov_dumped = false;
  static uint16_t last_pc = 0;

  // Detect boot loader start (SYSBOOT was called)
  if (!cpm3_loading && hbios.getBootInProgress()) {
    cpm3_loading = true;
    hlog("[CPM3-TRACE] Boot process started\n");
  }

  // After CP/M 3 has printed signon (RAM Disk Initialized), dump xbnkmov location
  // The xbnkmov routine is typically at ~0xFBE9 in CBIOS
  // Lower threshold to 500K to catch state before crash
  if (cpm3_loading && !xbnkmov_dumped && instruction_count > 500000) {
    xbnkmov_dumped = true;
    hlog("[CPM3-TRACE] Dumping CBIOS xbnkmov region (0xFB00-0xFC00):\n");
    for (uint16_t addr = 0xFB00; addr < 0xFC00; addr += 16) {
      hlog("  %04X: ", addr);
      for (int i = 0; i < 16; i++) {
        hlog("%02X ", memory.fetch_mem(addr + i));
      }
      hlog("\n");
    }
    // Also dump the BNKCPY proxy region
    hlog("[CPM3-TRACE] BNKCPY proxy region (0xFFF0-0xFFFF):\n");
    hlog("  FFF0: ");
    for (int i = 0; i < 16; i++) {
      hlog("%02X ", memory.fetch_mem(0xFFF0 + i));
    }
    hlog("\n");
  }

  // Check if we're blocked waiting for input
  if (hbios.getState() == HBIOS_NEEDS_INPUT) {
    waiting_for_input = true;
    return;
  }
  waiting_for_input = false;

  for (int i = 0; i < count && running; i++) {
    // DEBUG: Trace execution at BNKCPY proxy (0xFFF6) only - skip noisy 0xFFF0
    uint16_t pc_before = cpu.regs.PC.get_pair16();
    if (pc_before == 0xFFF6) {
      hlog("[PROXY EXEC] PC=0xFFF6 (BNKCPY) HL=%04X DE=%04X BC=%04X\n",
           cpu.regs.HL.get_pair16(), cpu.regs.DE.get_pair16(), cpu.regs.BC.get_pair16());
    }

    cpu.execute();
    instruction_count++;

    // Detect return to boot loader after CP/M 3 started
    uint16_t pc_after = cpu.regs.PC.get_pair16();
    if (cpm3_loading && !cpm3_started && pc_after >= 0x0100 && pc_after < 0x0400) {
      // Execution returned to boot loader code (ROM addresses 0x0100-0x0400)
      cpm3_started = true;
      hlog("[CPM3-TRACE] WARNING: Execution returned to boot loader! PC=0x%04X (was 0x%04X)\n",
           pc_after, last_pc);
      hlog("[CPM3-TRACE] Dumping stack (SP=0x%04X):\n", cpu.regs.SP.get_pair16());
      uint16_t sp = cpu.regs.SP.get_pair16();
      for (int j = 0; j < 8; j++) {
        uint8_t lo = memory.fetch_mem(sp + j*2);
        uint8_t hi = memory.fetch_mem(sp + j*2 + 1);
        hlog("  SP+%d: %04X\n", j*2, lo | (hi << 8));
      }
    }
    last_pc = pc_after;

    // Check state after each instruction
    HBIOSState state = hbios.getState();
    if (state == HBIOS_NEEDS_INPUT) {
      waiting_for_input = true;
      break;  // Stop executing until input is provided
    }
    if (state == HBIOS_HALTED) {
      running = false;
      break;
    }
  }

  // Poll output buffer and send chars to display
  if (hbios.hasOutputChars()) {
    std::vector<uint8_t> chars = hbios.getOutputChars();
    for (uint8_t ch : chars) {
      emu_console_write_char(ch);
    }
  }
}
