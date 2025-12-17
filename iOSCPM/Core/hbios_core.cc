/*
 * HBIOS Core - RomWBW HBIOS Emulation Implementation
 *
 * Uses the shared HBIOSDispatch for HBIOS function handling.
 */

#include "hbios_core.h"
#include "emu_io.h"
#include <cstring>

//=============================================================================
// Helper: Set up HBIOS ident signatures in RAM common area
// This is required for REBOOT and other utilities to recognize the system
//=============================================================================

static void setup_hbios_ident(banked_mem& memory) {
  uint8_t* ram = memory.get_ram();
  if (!ram) return;

  // Common area 0x8000-0xFFFF maps to bank 0x8F (index 15 = 0x0F)
  // Physical offset in RAM = bank_index * 32KB + (addr - 0x8000)
  const uint32_t COMMON_BASE = 0x0F * 32768;  // Bank 0x8F = index 15

  // Create ident block at 0xFF00 in common area
  uint32_t ident_phys = COMMON_BASE + (0xFF00 - 0x8000);
  ram[ident_phys + 0] = 'W';       // Signature byte 1
  ram[ident_phys + 1] = ~'W';      // Signature byte 2 (0xA8)
  ram[ident_phys + 2] = 0x35;      // Combined version: (major << 4) | minor = (3 << 4) | 5

  // Also create ident block at 0xFE00 (some utilities may look there)
  uint32_t ident_phys2 = COMMON_BASE + (0xFE00 - 0x8000);
  ram[ident_phys2 + 0] = 'W';
  ram[ident_phys2 + 1] = ~'W';
  ram[ident_phys2 + 2] = 0x35;

  // Store pointer to ident block at 0xFFFC (little-endian)
  uint32_t ptr_phys = COMMON_BASE + (0xFFFC - 0x8000);
  ram[ptr_phys + 0] = 0x00;        // Low byte of 0xFF00
  ram[ptr_phys + 1] = 0xFF;        // High byte of 0xFF00
}

//=============================================================================
// Constructor/Destructor
//=============================================================================

HBIOSEmulator::HBIOSEmulator()
  : memory(), cpu(&memory), running(false), waiting_for_input(false),
    debug(false), instruction_count(0), boot_string_pos(0)
{
  // Initialize banked memory
  memory.enable_banking();

  // Set up HBIOS dispatcher with CPU and memory references
  hbios.setCPU(&cpu);
  hbios.setMemory(&memory);

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

  // Clear input queues (both internal and global)
  while (!input_queue.empty()) input_queue.pop();
  emu_console_clear_queue();

  // Reset HBIOS dispatcher
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

  // Set up HBIOS identification signatures in common area
  setup_hbios_ident(memory);

  emu_log("[HBIOS] ROM loaded: %zu bytes\n", copy_size);
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
  return hbios.loadDisk(unit, data, size);
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
  input_queue.push(ch);
  emu_console_queue_char(ch);
  waiting_for_input = false;
  hbios.clearWaitingForInput();  // Also clear dispatch's waiting flag
}

bool HBIOSEmulator::hasInput() const {
  return !input_queue.empty() || boot_string_pos < boot_string.size() || emu_console_has_input();
}

void HBIOSEmulator::setBootString(const std::string& str) {
  boot_string = str;
  boot_string_pos = 0;
}

//=============================================================================
// Execution Control
//=============================================================================

void HBIOSEmulator::start() {
  emu_log("[HBIOS] Starting emulation\n");

  // Set Z80 mode
  cpu.set_cpu_mode(qkz80::MODE_Z80);

  // Enable banking
  memory.enable_banking();

  // Reset HBIOS state for new ROM (like web version does)
  hbios.reset();

  // Initialize memory disks (MD0=RAM, MD1=ROM) and populate disk unit table
  hbios.initMemoryDisks();

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

  // Feed boot string to input queue
  for (size_t i = 0; i < boot_string.size(); i++) {
    emu_console_queue_char(boot_string[i] & 0xFF);
  }
  if (!boot_string.empty()) {
    emu_console_queue_char('\r');  // Submit with CR
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
  if (!running || waiting_for_input) return;

  for (int i = 0; i < count && running && !waiting_for_input; i++) {
    uint16_t pc = cpu.regs.PC.get_pair16();
    uint8_t opcode = memory.fetch_mem(pc) & 0xFF;

    // Check for HBIOS trap
    if (hbios.checkTrap(pc)) {
      int trap_type = hbios.getTrapType(pc);
      if (!hbios.handleCall(trap_type)) {
        emu_error("[HBIOS] Failed to handle trap at 0x%04X\n", pc);
      }
      // Note: Don't check isWaitingForInput here - let the I/O port handler
      // manage input waiting (matching web version behavior)
      instruction_count++;
      continue;
    }

    // Handle HLT instruction
    if (opcode == 0x76) {
      emu_status("HLT instruction - emulation stopped\n");
      running = false;
      break;
    }

    // Handle IN instruction (0xDB)
    if (opcode == 0xDB) {
      uint8_t port = memory.fetch_mem(pc + 1) & 0xFF;
      uint8_t value = handle_in(port);
      cpu.set_reg8(value, qkz80::reg_A);
      cpu.regs.PC.set_pair16(pc + 2);
      instruction_count++;
      continue;
    }

    // Handle OUT instruction (0xD3)
    if (opcode == 0xD3) {
      uint8_t port = memory.fetch_mem(pc + 1) & 0xFF;
      uint8_t value = cpu.get_reg8(qkz80::reg_A);
      handle_out(port, value);
      cpu.regs.PC.set_pair16(pc + 2);
      instruction_count++;
      continue;
    }

    // Execute normal instruction
    cpu.execute();
    instruction_count++;
  }
}

//=============================================================================
// I/O Port Handlers
//=============================================================================

uint8_t HBIOSEmulator::handle_in(uint8_t port) {
  switch (port) {
    case 0x78:  // Bank register
    case 0x7C:
      return memory.get_current_bank();

    case 0xFE:  // Sense switches (front panel) - match CLI
      return 0x00;

    default:
      return 0xFF;
  }
}

void HBIOSEmulator::handle_out(uint8_t port, uint8_t value) {
  switch (port) {
    case 0x78:  // RAM bank
    case 0x7C:  // ROM bank
      memory.select_bank(value);
      break;

    case 0xEE:  // EMU signal port
      hbios.handleSignalPort(value);
      break;
  }
}
