/*
 * HBIOS Core - RomWBW HBIOS Emulation Implementation
 *
 * Uses the shared HBIOSDispatch for HBIOS function handling.
 */

#include "hbios_core.h"
#include "emu_io.h"
#include <cstring>

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

  // Clear input queue
  while (!input_queue.empty()) input_queue.pop();

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

  // Copy ROM data (up to 512KB)
  size_t copy_size = (size > 512 * 1024) ? 512 * 1024 : size;
  memcpy(rom, data, copy_size);

  // Copy HCB (HBIOS Configuration Block) to RAM bank 0x80
  uint8_t* ram = memory.get_ram();
  if (ram) {
    memcpy(ram, rom, 512);  // First 512 bytes
  }

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

  // Reset CPU to start at address 0
  cpu.regs.PC.set_pair16(0x0000);
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
      // Check if dispatch is waiting for input
      if (hbios.isWaitingForInput()) {
        waiting_for_input = true;
        break;  // Stop execution until input arrives
      }
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
    case 0x68:  // UART data
      if (emu_console_has_input()) {
        return emu_console_read_char() & 0xFF;
      }
      return 0;

    case 0x6D:  // UART status (SSER)
      // Bit 0: RX ready, Bit 5: TX empty
      return (emu_console_has_input() ? 0x01 : 0x00) | 0x20;

    case 0x78:  // Bank register
    case 0x7C:
      return memory.get_current_bank();

    default:
      return 0xFF;
  }
}

void HBIOSEmulator::handle_out(uint8_t port, uint8_t value) {
  switch (port) {
    case 0x68:  // UART data
      emu_console_write_char(value);
      break;

    case 0x78:  // RAM bank
    case 0x7C:  // ROM bank
      memory.select_bank(value);
      break;

    case 0xEE:  // EMU signal port
      hbios.handleSignalPort(value);
      break;
  }
}
