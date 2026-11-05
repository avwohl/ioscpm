/*
 * GdbHost.cc - the app's emulator core and GDB stub, without the app.
 *
 * Tests/gdb_stub_test.py drives this program as a debugger would. It uses the
 * same code the app uses: HBIOSEmulator::gdbListen(), gdbRun() and gdbCancel()
 * from iOSCPM/Core/hbios_core.cc, the stub from cpmemu, the target from
 * romwbw_emu, and gdb_platform_ios.cc for the sockets. What it leaves out is
 * the part that needs a screen: the Swift views and the Objective-C bridge. The
 * threading is the app's: this program calls gdbRun() on the thread that runs
 * the machine (the main thread here, the emulation queue in the app), and
 * gdbCancel() from another thread, as the Stop button does.
 *
 *   gdb_host ROM [--disk0=IMG] --port=N [--lan] [--cancel-after-ms=N]
 *            [--run-ms=N] [--keys=TEXT] [--nvram=SETTING]
 *
 * Prints one line per event on stdout, flushed:
 *   listening ADDR:PORT, connected, gdbRun returned running=0|1,
 *   ran PC=XXXX instructions=N
 * Exit status: 0, or 2 for a bad command line, 3 when the port could not be
 * opened.
 */

#include "hbios_core.h"
#include "emu_io.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <unistd.h>

static void say(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
#include <cstdarg>
static void say(const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vprintf(fmt, ap);
  va_end(ap);
  printf("\n");
  fflush(stdout);
}

int main(int argc, char** argv) {
  std::string rom, disk0, keys, nvram;
  int port = 0, cancel_ms = -1, run_ms = 0;
  bool lan = false;
  for (int i = 1; i < argc; i++) {
    const char* a = argv[i];
    if (!strncmp(a, "--disk0=", 8)) disk0 = a + 8;
    else if (!strncmp(a, "--port=", 7)) port = atoi(a + 7);
    else if (!strcmp(a, "--lan")) lan = true;
    else if (!strncmp(a, "--cancel-after-ms=", 18)) cancel_ms = atoi(a + 18);
    else if (!strncmp(a, "--run-ms=", 9)) run_ms = atoi(a + 9);
    else if (!strncmp(a, "--keys=", 7)) keys = a + 7;
    else if (!strncmp(a, "--nvram=", 8)) nvram = a + 8;
    else if (a[0] != '-' && rom.empty()) rom = a;
    else { fprintf(stderr, "gdb_host: bad argument %s\n", a); return 2; }
  }
  if (rom.empty() || port == 0) {
    fprintf(stderr, "usage: gdb_host ROM [--disk0=IMG] --port=N [--lan] "
                    "[--cancel-after-ms=N] [--run-ms=N] [--keys=TEXT] [--nvram=SETTING]\n");
    return 2;
  }

  emu_io_init();
  HBIOSEmulator emu;
  if (!emu.loadROMFromFile(rom)) { fprintf(stderr, "gdb_host: cannot load %s\n", rom.c_str()); return 2; }
  if (!disk0.empty() && !emu.loadDiskFromFile(0, disk0)) {
    fprintf(stderr, "gdb_host: cannot load %s\n", disk0.c_str());
    return 2;
  }

  // As RomWBWEmulator -start does: open the port, then start the machine.
  std::string error;
  std::shared_ptr<GdbSession> gdb = emu.gdbListen(lan ? 0u : 0x7F000001u, port, &error);
  if (!gdb) { say("listen failed: %s", error.c_str()); return 3; }
  if (!nvram.empty()) emu.getHBIOS()->setNvramSetting(nvram);   // "2" = boot disk 2 (the app: Boot Options)
  emu.start();
  say("listening %s:%d", lan ? "0.0.0.0" : "127.0.0.1", port);
  // As romwbw_emu does for a script: typed-ahead input waits until the guest asks.
  if (!keys.empty()) emu.getHBIOS()->holdInputUntilWanted(true);
  for (char c : keys) emu.queueInput(c == '\n' ? '\r' : c);

  std::thread canceller;
  if (cancel_ms >= 0) {
    canceller = std::thread([&] {
      std::this_thread::sleep_for(std::chrono::milliseconds(cancel_ms));
      emu.gdbCancel(gdb);
      emu.stop();
    });
  }

  auto t0 = std::chrono::steady_clock::now();
  emu.gdbRun(gdb, [] { say("connected"); });
  auto waited = std::chrono::duration_cast<std::chrono::milliseconds>(
                    std::chrono::steady_clock::now() - t0).count();
  say("gdbRun returned running=%d after %lld ms", emu.isRunning() ? 1 : 0, (long long)waited);

  // Then the plain loop, as RomWBWEmulator -runLoop does.
  auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(run_ms);
  while (emu.isRunning() && std::chrono::steady_clock::now() < until) {
    emu.runBatch(10000);
    usleep(1000);
  }
  say("ran PC=%04X instructions=%lld", emu.getPC(), emu.getInstructionCount());
  if (canceller.joinable()) canceller.join();
  return 0;
}
