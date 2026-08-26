/*
 *  CoreKeyboardTests.cc
 *
 *  What the shared emulator core does with a keystroke, compiled the way this
 *  app compiles it.
 *
 *  Everything under iOSCPM/Core/ is a symlink into ../romwbw_emu/src and
 *  ../cpmemu/src, so this port has no copy of the core to review - it builds
 *  whatever those working trees currently hold. That is efficient and it is a
 *  hazard: the symlinks have been flattened into stale copies once already
 *  (see docs/notes_to_windos.md), and they resolve into sibling *working
 *  trees*, so a sibling repo left on a feature branch silently changes what
 *  ships here.
 *
 *  This suite compiles the core through those symlink paths and asserts the
 *  console contract this app depends on. It is deliberately not a copy of
 *  romwbw_emu's own tests/vda_keyboard.cc: upstream asserts the dispatcher is
 *  correct, and this asserts that the core *this port resolves to* is the one
 *  with those fixes in it, in the non-blocking mode iOSCPM actually runs.
 *
 *  The mode matters. HBIOSEmulator::reset() calls setBlockingAllowed(false)
 *  (iOSCPM/Core/hbios_core.cc) because the UI thread cannot block on a key.
 *  That is the arm where a console read has to rewind PC over the two-byte
 *  OUT (0xEF),A so the call re-runs when a key arrives - and it is the arm the
 *  CLI never exercises, so the CLI passing proves nothing for us.
 *
 *  Run with Tests/run_tests.sh. No simulator, display or UIKit involved.
 */

#include "hbios_dispatch.h"
#include "romwbw_mem.h"
#include "qkz80.h"
#include "emu_io.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <strings.h>

//=============================================================================
// Console stub
//
// Stands in for emu_io_ios.mm, whose real implementation is a std::queue
// behind a mutex fed by the Swift layer. Same shape, steerable from a test.
//=============================================================================

static std::deque<int> g_keys;

bool emu_console_has_input() { return !g_keys.empty(); }

int emu_console_read_char() {
  if (g_keys.empty()) return -1;
  int ch = g_keys.front();
  g_keys.pop_front();
  return ch;
}

static std::string g_output;
void emu_console_write_char(uint8_t ch) { g_output.push_back((char)ch); }

//=============================================================================
// The rest of emu_io: enough to link, never exercised here
//=============================================================================

void emu_dsky_beep(int) {}
void emu_error(const char*, ...) {}
void emu_log(const char*, ...) {}
void emu_status(const char*, ...) {}
void emu_video_clear() {}
void emu_video_scroll_up(int) {}
void emu_video_set_attr(uint8_t) {}
void emu_video_set_cursor(int, int) {}
void emu_video_write_char(uint8_t) {}

void emu_fatal(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  vfprintf(stderr, fmt, args);
  va_end(args);
  abort();
}

int emu_strncasecmp(const char* a, const char* b, size_t n) {
  return strncasecmp(a, b, n);
}

// Declared in emu_io.h, implemented per backend rather than in
// emu_io_common.cc - emu_io_ios.mm has the NSFileManager version.
bool emu_file_exists(const std::string&) { return false; }

emu_host_file_state emu_host_file_get_state() { return HOST_FILE_IDLE; }
bool emu_host_file_open_read(const char*) { return false; }
bool emu_host_file_open_write(const char*) { return false; }
int emu_host_file_read_byte() { return -1; }
bool emu_host_file_write_byte(uint8_t) { return false; }
void emu_host_file_close_read() {}
bool emu_host_file_close_write() { return true; }
// New with the core's HBF_HOST_GETNAME (0xE8): handleEXT() calls this to tell
// the guest where its export really landed. It asks the state first and this
// stub is never WRITING, so the name is never read - but the symbol has to
// exist or the dispatcher does not link.
const char* emu_host_file_get_write_name() { return ""; }
// The read twin, new with HBF_HOST_GETRNAME. emu_io.h marks it a REQUIRED
// backend function for exactly this reason: the core references it
// unconditionally from handleEXT(), so a port that syncs the core and does not
// define it fails to link. That is what happened here - this suite stopped
// linking the moment the symlinked core moved, and nothing else in the repo
// would have said so.
const char* emu_host_file_get_read_name() { return ""; }
// HBF_HOST_CAPS forwards this; the core no longer defines it, so a linkable
// backend (or test) must. This suite never exports, so the value is inert.
uint8_t emu_host_path_caps() { return EMU_HOST_CAP_SAFE_PATHS; }

//=============================================================================
// Scaffolding
//=============================================================================

// The Z80 proxy's OUT (0xEF),A sits at 0xFFF0 and is two bytes, so by the time
// the dispatcher runs PC already points past it. A read that cannot be
// satisfied has to put PC back to ENTRY.
static const uint16_t ENTRY = 0xFFF0;
static const uint16_t AFTER = ENTRY + 2;

static int failures = 0;
static int checks = 0;

static void check(bool ok, const char* what) {
  checks++;
  printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
  if (!ok) failures++;
}

static void section(const char* title) {
  printf("\n%s\n", title);
  for (int i = 0; i < 60; i++) putchar('-');
  putchar('\n');
}

struct Rig {
  banked_mem mem;
  qkz80 cpu;
  HBIOSDispatch hbios;

  Rig() : cpu(&mem) {
    hbios.setCPU(&cpu);
    hbios.setMemory(&mem);
    // What HBIOSEmulator::reset() does. The UI thread cannot block on a key.
    hbios.setBlockingAllowed(false);
  }

  // One HBIOS call, entered exactly as the Z80 proxy enters it.
  void call(uint8_t func, uint8_t unit = 0) {
    cpu.regs.BC.set_high(func);
    cpu.regs.BC.set_low(unit);
    cpu.regs.PC.set_pair16(AFTER);
    hbios.handlePortDispatch();
  }

  uint8_t A() { return cpu.regs.AF.get_high(); }
  uint8_t E() { return cpu.regs.DE.get_low(); }
  uint16_t PC() { return cpu.regs.PC.get_pair16(); }
};

//=============================================================================

int main() {
  printf("The core this port resolves to, driven the way iOSCPM drives it\n");

  //-------------------------------------------------------------------------
  section("A keystroke reaches the guest through CIO");
  //-------------------------------------------------------------------------
  {
    Rig r;
    g_keys.clear();
    g_keys.push_back('A');
    r.call(HBF_CIOIN);
    check(r.E() == 'A', "CIOIN hands a queued key to the guest in E");
    check(r.PC() == AFTER, "CIOIN with a key pending lets the proxy RET run");
  }
  {
    Rig r;
    g_keys.clear();
    g_keys.push_back('X');
    r.call(HBF_CIOIST);
    check(r.A() != 0, "CIOIST reports a pending key in A");
    check(r.E() != 0, "CIOIST reports a pending count in E");
  }
  {
    Rig r;
    g_keys.clear();
    r.call(HBF_CIOIST);
    check(r.A() == 0, "CIOIST reports an empty queue as zero in A");
  }

  //-------------------------------------------------------------------------
  section("Nothing to read rewinds PC instead of returning a stale byte");
  //-------------------------------------------------------------------------
  //
  // This is the whole reason the non-blocking arm exists. Returning without
  // the rewind lets the proxy's own RET fire immediately, and the guest reads
  // whatever E happened to hold.
  {
    Rig r;
    g_keys.clear();
    r.cpu.regs.DE.set_low(0x5A);  // sentinel: must not pass for a keystroke
    r.call(HBF_CIOIN);
    check(r.PC() == ENTRY, "CIOIN with no key rewinds PC over the OUT");
    check(r.hbios.isWaitingForInput(), "CIOIN with no key marks us waiting");
    check(r.E() == 0x5A, "CIOIN with no key leaves E untouched");

    g_keys.push_back('Q');
    r.cpu.regs.PC.set_pair16(AFTER);  // the OUT re-executes
    r.hbios.handlePortDispatch();
    check(r.E() == 'Q', "the retried CIOIN delivers the key");
    check(!r.hbios.isWaitingForInput(), "the retried CIOIN clears the wait");
  }

  //-------------------------------------------------------------------------
  section("The VDA keyboard answers the same way (romwbw_emu bf03758)");
  //-------------------------------------------------------------------------
  //
  // SYSGET_VDACNT reports one VDA to every port, so a guest can reach these
  // whatever the front end. Before bf03758 VDAKST left A at zero however much
  // was queued, and VDAKRD skipped the rewind. If this section fails, the
  // symlinks are resolving to a core that predates that fix - check what
  // ../romwbw_emu has checked out.
  {
    Rig r;
    g_keys.clear();
    g_keys.push_back('X');
    r.call(HBF_VDAKST);
    check(r.A() != 0, "VDAKST reports a pending key in A, not only in E");
    check(r.E() != 0, "VDAKST reports a pending count in E");
  }
  {
    Rig r;
    g_keys.clear();
    r.call(HBF_VDAKST);
    check(r.A() == 0, "VDAKST reports an empty queue as zero in A");
  }
  {
    Rig r;
    g_keys.clear();
    r.cpu.regs.DE.set_low(0x5A);
    r.call(HBF_VDAKRD);
    check(r.PC() == ENTRY, "VDAKRD with no key rewinds PC over the OUT");
    check(r.E() == 0x5A, "VDAKRD with no key leaves E untouched");

    g_keys.push_back('Q');
    r.cpu.regs.PC.set_pair16(AFTER);
    r.hbios.handlePortDispatch();
    check(r.E() == 'Q', "the retried VDAKRD delivers the key");
    check(!r.hbios.isWaitingForInput(), "the retried VDAKRD clears the wait");
  }
  {
    Rig r;
    g_keys.clear();
    g_keys.push_back('A');
    r.call(HBF_VDAKRD);
    check(r.E() == 'A', "VDAKRD with a key pending returns it in E");
    check(r.A() == 0, "VDAKRD with a key pending reports success in A");
  }

  //-------------------------------------------------------------------------
  section("Ctrl bytes are carried, not filtered");
  //-------------------------------------------------------------------------
  //
  // The v1.36 contract: Ctrl+A..Ctrl+Z belong to the guest. Nothing in the
  // shared core has ever filtered a control byte, and the ^R sweep turned on
  // keeping it that way. The WordStar diamond plus the bytes build 49 added a
  // fold for, end to end through the dispatcher.
  {
    Rig r;
    const uint8_t wanted[] = {
      0x01, 0x04, 0x05, 0x06, 0x12, 0x13, 0x18, 0x0B,  // ^A ^D ^E ^F ^R ^S ^X ^K
      0x10, 0x16, 0x19, 0x11, 0x0F,                    // ^P ^V ^Y ^Q ^O
      0x00, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x7F,        // NUL ESC FS GS RS US DEL
      0x0A, 0x0D,                                      // Ctrl+J and Enter, distinct
    };
    bool all_ok = true;
    for (size_t i = 0; i < sizeof(wanted) / sizeof(wanted[0]); i++) {
      g_keys.clear();
      g_keys.push_back(wanted[i]);
      r.call(HBF_CIOIN);
      if (r.E() != wanted[i]) {
        printf("      byte 0x%02X came back as 0x%02X\n", wanted[i], r.E());
        all_ok = false;
      }
    }
    check(all_ok, "every control byte survives CIOIN unchanged");
  }
  {
    // 0x1A is the core's EOF marker. A real ^Z typed by the user still has to
    // arrive as a keystroke rather than be mistaken for end-of-input.
    Rig r;
    g_keys.clear();
    g_keys.push_back(0x1A);
    r.call(HBF_CIOIN);
    check(r.E() == 0x1A, "a typed ^Z arrives as ^Z");
  }

  //-------------------------------------------------------------------------
  section("Output is buffered for the UI thread, not written behind its back");
  //-------------------------------------------------------------------------
  {
    Rig r;
    g_output.clear();
    r.cpu.regs.DE.set_low('h');
    r.call(HBF_CIOOUT);
    check(r.hbios.hasOutputChars(),
          "CIOOUT queues the byte for the host to drain");
    std::vector<uint8_t> out = r.hbios.getOutputChars();
    check(out.size() == 1 && out[0] == 'h', "and the byte drained is the one written");
    check(g_output.empty(), "nothing was written straight to the console");
  }

  //-------------------------------------------------------------------------
  printf("\n");
  for (int i = 0; i < 60; i++) putchar('=');
  printf("\nResults: %d passed, %d failed\n", checks - failures, failures);
  printf("%s\n", failures ? "TESTS FAILED" : "All tests passed");
  return failures ? 1 : 0;
}
