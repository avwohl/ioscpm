/*
 * HBIOS Core - RomWBW HBIOS Emulation
 *
 * Wrapper around HBIOSDispatch for iOS/macOS compatibility.
 * This header provides the HBIOSEmulator class used by RomWBWEmulator.mm.
 */

#ifndef HBIOS_CORE_H
#define HBIOS_CORE_H

#include "qkz80.h"
#include "romwbw_mem.h"
#include "hbios_dispatch.h"
#include <cstdint>
#include <string>
#include <vector>
#include <queue>

// Forward declaration
class HBIOSEmulator;

//=============================================================================
// Custom CPU - subclass of qkz80 for halt/unimplemented opcode handling
//=============================================================================

class hbios_cpu : public qkz80 {
public:
  hbios_cpu(qkz80_cpu_mem* mem, HBIOSEmulator* emu);

  void halt() override;
  void unimplemented_opcode(qkz80_uint8 opcode, qkz80_uint16 pc) override;

  // I/O port handlers - override for custom I/O
  void port_out(qkz80_uint8 port, qkz80_uint8 value) override;
  qkz80_uint8 port_in(qkz80_uint8 port) override;

private:
  HBIOSEmulator* emulator;
};

//=============================================================================
// HBIOS Emulator Class
//=============================================================================

class HBIOSEmulator {
  friend class hbios_cpu;
public:
  HBIOSEmulator();
  ~HBIOSEmulator();

  // Initialization
  void reset();
  bool loadROM(const uint8_t* data, size_t size);
  bool loadROMFromFile(const std::string& path);

  // Disk management
  bool loadDisk(int unit, const uint8_t* data, size_t size);
  bool loadDiskFromFile(int unit, const std::string& path);
  void closeAllDisks();  // Close all disks before reconfiguring
  const uint8_t* getDiskData(int unit) const;
  size_t getDiskSize(int unit) const;
  bool isDiskLoaded(int unit) const;
  void setDiskSliceCount(int unit, int slices);  // Set max slices (1-8)

  // Input queue
  void queueInput(int ch);
  bool hasInput() const;

  // Boot string for auto-boot
  void setBootString(const std::string& str);

  // Execution control
  void start();
  void stop();
  bool isRunning() const { return running; }
  bool isWaitingForInput() const { return waiting_for_input; }
  void clearWaitingForInput() { waiting_for_input = false; }

  // Run a batch of instructions (call from main loop)
  void runBatch(int count = 50000);

  // Debug
  void setDebug(bool enable);
  uint16_t getPC() const { return cpu.regs.PC.get_pair16(); }
  long long getInstructionCount() const { return instruction_count; }

private:
  // CPU and memory
  banked_mem memory;
  hbios_cpu cpu;

  // HBIOS dispatcher (shared implementation)
  HBIOSDispatch hbios;

  // State
  bool running;
  bool waiting_for_input;
  bool debug;
  long long instruction_count;

  // Input queue
  std::queue<int> input_queue;
  std::string boot_string;
  size_t boot_string_pos;

  // RAM bank initialization tracking (bitmask for banks 0x80-0x8F)
  uint16_t initialized_ram_banks;

  // Initialize a RAM bank if it hasn't been initialized yet
  void initializeRamBankIfNeeded(uint8_t bank);
};

#endif // HBIOS_CORE_H
