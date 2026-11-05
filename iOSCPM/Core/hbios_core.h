/*
 * HBIOS Core - RomWBW HBIOS Emulation
 *
 * Wrapper around HBIOSDispatch for iOS/macOS compatibility.
 * This header provides the HBIOSEmulator class used by RomWBWEmulator.mm.
 */

#ifndef HBIOS_CORE_H
#define HBIOS_CORE_H

#include "hbios_cpu.h"  // Shared CPU class with port I/O handlers
#include "qkz80.h"
#include "romwbw_mem.h"
#include "hbios_dispatch.h"
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <queue>

// One run under the GDB stub (docs/gdb.md).  Defined in hbios_core.cc, so that
// no file that includes this header needs gdbstub.h.
struct GdbSession;

//=============================================================================
// Controlify Mode - convert next input char(s) to control codes
//=============================================================================

enum ControlifyMode {
  CTRL_OFF = 0,      // Normal input
  CTRL_ONE_CHAR = 1, // Convert next char to control code, then turn off
  CTRL_STICKY = 2    // Convert all chars until explicitly turned off
};

//=============================================================================
// HBIOS Emulator Class - implements HBIOSCPUDelegate for the shared CPU
//=============================================================================

class HBIOSEmulator : public HBIOSCPUDelegate {
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
  void setDiskSliceCount(int unit, int slices);  // Set slices for drive letter assignment

  // Input queue
  void queueInput(int ch);
  bool hasInput() const;

  // Controlify mode - convert input to control characters
  void setControlify(ControlifyMode mode);
  ControlifyMode getControlify() const { return controlify_mode; }

  // Boot string for auto-boot
  void setBootString(const std::string& str);

  // Execution control
  void start();
  void stop();
  bool isRunning() const { return running; }
  bool isWaitingForInput() const { return waiting_for_input; }
  void clearWaitingForInput() { waiting_for_input = false; }
  bool isIdle() const { return hbios.isConsoleIdle(); }

  // Run a batch of instructions (call from main loop)
  void runBatch(int count = 50000);

  // The GDB stub (docs/gdb.md).  Off unless the app asks.
  //
  // gdbListen() opens the socket and returns the session, or nullptr with the
  // reason in *error.  addr is gdb::kLoopback (0x7F000001) or 0 for every
  // interface, in host byte order; port is 1 to 65535.  Any thread, before
  // gdbRun().
  //
  // gdbRun() is the part that blocks.  It waits for the debugger to connect
  // and answers it until it detaches, so it must run on the EMULATION thread
  // and never on the UI thread: the machine is held while it runs.  It
  // returns when the debugger has detached or gone, when gdbCancel() was
  // called, or when the debugger killed the program.  Then the caller goes on
  // with runBatch() as without a debugger, unless isRunning() says the machine
  // has ended.  A debugger that detaches cannot attach again: the socket is
  // closed after the first connection.
  //
  // gdbCancel() may be called from any thread, and ends a wait for a debugger
  // or a session within 100 ms.  It also stops the machine.
  std::shared_ptr<GdbSession> gdbListen(uint32_t addr, int port, std::string* error);
  // on_connect, if given, is called on the emulation thread when the debugger
  // has connected.
  void gdbRun(const std::shared_ptr<GdbSession>& session,
              const std::function<void()>& on_connect = nullptr);
  void gdbCancel(const std::shared_ptr<GdbSession>& session);
  // True once a debugger is connected to the session.
  bool gdbConnected(const std::shared_ptr<GdbSession>& session) const;

  // Debug
  void setDebug(bool enable);
  uint16_t getPC() const { return cpu.regs.PC.get_pair16(); }
  long long getInstructionCount() const { return instruction_count; }

  // HBIOSCPUDelegate interface - called by shared hbios_cpu
  banked_mem* getMemory() override { return &memory; }
  HBIOSDispatch* getHBIOS() override { return &hbios; }
  void initializeRamBankIfNeeded(uint8_t bank) override;
  void onHalt() override;
  void onUnimplementedOpcode(uint8_t opcode, uint16_t pc) override;
  void logDebug(const char* fmt, ...) override;

private:
  // CPU and memory
  banked_mem memory;
  hbios_cpu cpu;

  // HBIOS dispatcher (shared implementation)
  HBIOSDispatch hbios;

  // State
  bool running;
  bool waiting_for_input;
  bool debug_enabled;
  long long instruction_count;

  // Input queue
  std::queue<int> input_queue;
  std::string boot_string;
  size_t boot_string_pos;

  // Controlify mode
  ControlifyMode controlify_mode;

  // Sends what the guest printed to the console, as runBatch() does at its end.
  void flushOutput();
};

#endif // HBIOS_CORE_H
