/*
 * HBIOS Core - RomWBW HBIOS Emulation Implementation
 *
 * Uses the shared HBIOSDispatch for HBIOS function handling.
 */

#include "hbios_core.h"
#include "emu_init.h"
#include "emu_io.h"
#include <cstring>
#include <cstdarg>

//=============================================================================
// HBIOSCPUDelegate Implementation
//=============================================================================

void HBIOSEmulator::onHalt() {
  running = false;
}

void HBIOSEmulator::onUnimplementedOpcode(uint8_t opcode, uint16_t pc) {
  emu_error("Unimplemented opcode 0x%02X at PC=0x%04X\n", opcode, pc);
  running = false;
}

void HBIOSEmulator::logDebug(const char* fmt, ...) {
  // Debug logging disabled
}

//=============================================================================
// Constructor/Destructor
//=============================================================================

HBIOSEmulator::HBIOSEmulator()
  : memory(), cpu(&memory, this), running(false), waiting_for_input(false),
    debug_enabled(false), instruction_count(0), boot_string_pos(0),
    controlify_mode(CTRL_OFF), initialized_ram_banks(0)
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
  controlify_mode = CTRL_OFF;
  initialized_ram_banks = 0;

  // Clear console input queue
  emu_console_clear_queue();

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
  // Use shared RAM bank initialization (copies page zero, HCB, and patches APITYPE)
  emu_init_ram_bank(&memory, bank, &initialized_ram_banks);
}

//=============================================================================
// ROM Loading
//=============================================================================

bool HBIOSEmulator::loadROM(const uint8_t* data, size_t size) {
  if (!data || size == 0) {
    emu_error("[HBIOS] ROM data is null or empty\n");
    return false;
  }

  // Clear RAM for clean state when loading a new ROM
  // (ensures stop/start behaves identically to fresh app launch)
  memory.clear_ram();

  // Use shared ROM loading function
  return emu_load_rom_from_buffer(&memory, data, size);
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
  bool result = hbios.loadDisk(unit, data, size);
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
  hbios.closeAllDisks();
}

void HBIOSEmulator::setDiskSliceCount(int unit, int slices) {
  hbios.setDiskSliceCount(unit, slices);
}

//=============================================================================
// Input Queue
//=============================================================================

void HBIOSEmulator::setControlify(ControlifyMode mode) {
  controlify_mode = mode;
}

void HBIOSEmulator::queueInput(int ch) {
  if (ch == '\n') ch = '\r';  // LF -> CR for CP/M

  // Apply controlify conversion if active
  if (controlify_mode != CTRL_OFF) {
    // Convert A-Z and a-z to control codes 1-26
    int upper = (ch >= 'a' && ch <= 'z') ? (ch - 32) : ch;
    if (upper >= '@' && upper <= '_') {
      ch = upper - '@';  // '@'=0, 'A'=1, ... 'Z'=26, etc.
    }
    // Turn off one-char mode after conversion
    if (controlify_mode == CTRL_ONE_CHAR) {
      controlify_mode = CTRL_OFF;
    }
  }

  // Queue to emu_console - this is what CIOIN reads from
  emu_console_queue_char(ch);

  // Clear waiting flag if we were blocked on input
  if (waiting_for_input) {
    waiting_for_input = false;
  }
}

bool HBIOSEmulator::hasInput() const {
  return emu_console_has_input() || boot_string_pos < boot_string.size();
}

void HBIOSEmulator::setBootString(const std::string& str) {
  boot_string = str;
  boot_string_pos = 0;
}

//=============================================================================
// Execution Control
//=============================================================================

void HBIOSEmulator::start() {
  // Set Z80 mode
  cpu.set_cpu_mode(qkz80::MODE_Z80);

  // Enable banking
  memory.enable_banking();

  // Reset HBIOS state for new ROM
  hbios.reset();

  // Use shared initialization: patches APITYPE, copies HCB to RAM,
  // sets up HBIOS ident signatures, initializes memory disks,
  // and copies HCB to shadow RAM with shadow bits set
  emu_complete_init(&memory, &hbios, nullptr);

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

  // Feed boot string to emu_console input buffer
  if (!boot_string.empty()) {
    for (size_t i = 0; i < boot_string.size(); i++) {
      emu_console_queue_char(boot_string[i]);
    }
    emu_console_queue_char('\r');  // Submit with CR
  }
}

void HBIOSEmulator::stop() {
  running = false;
}

void HBIOSEmulator::setDebug(bool enable) {
  debug_enabled = enable;
  emu_set_debug(enable);
  hbios.setDebug(enable);
  memory.set_debug(enable);
}

//=============================================================================
// Main Execution Loop
//=============================================================================

void HBIOSEmulator::runBatch(int count) {
  if (!running) return;

  // Check if we're blocked waiting for input
  if (hbios.getState() == HBIOS_NEEDS_INPUT) {
    waiting_for_input = true;
    return;
  }
  waiting_for_input = false;

  for (int i = 0; i < count && running; i++) {
    cpu.execute();
    instruction_count++;

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
