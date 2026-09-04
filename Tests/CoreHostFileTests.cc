/*
 *  CoreHostFileTests.cc
 *
 *  Whether R8 can find out which file it is reading, driven as the real
 *  sequence: H_OPEN_R (0xE1), then H_GETRNAME (0xEA), then H_READ (0xE3).
 *
 *  `todo.txt` carried this for several builds: "emu_host_file_get_read_name()
 *  answers truthfully now and R8 still cannot hear it". The backend recorded the
 *  resolved path and the getter returned it while HOST_FILE_READING - but R8
 *  prints its `Reading:` line BETWEEN the open and the first read, and this
 *  port's open only parked the request for the Swift layer's next main-queue
 *  turn. At the moment R8 asked, the state was still WAITING_READ and the honest
 *  answer was "".
 *
 *  So the interesting assertion is not "the getter returns the path". It is
 *  "the state is READING by the time 0xEA arrives", and that is a property of
 *  the BACKEND's open, not of the getter. This suite therefore supplies two
 *  backend shapes - synchronous and parking - and drives the identical guest
 *  sequence through both. The parking one is the bug, kept as a test so the
 *  regression is visible rather than remembered; the synchronous one is what
 *  emu_io_ios.mm now does.
 *
 *  emu_io_ios.mm itself is not compiled here. It is Objective-C++ over
 *  NSFileManager, and pulling a .mm into run_core_suite would break that
 *  script's non-Mac fallback to plain `c++`. What IS checked on a Mac is that
 *  the file compiles at all - see the EmuIOBackendCompiles suite in
 *  run_tests.sh, which is what would have caught the silent-selector-typo class
 *  of mistake.
 *
 *  Also covers storeHostName's clamping and the PC-rewind arm, neither of which
 *  had a test.
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
#include <cstring>
#include <deque>
#include <string>
#include <strings.h>

//=============================================================================
// A steerable host-file backend
//
// Stands in for emu_io_ios.mm. The two shapes differ in ONE thing - whether
// emu_host_file_open_read() has reached HOST_FILE_READING by the time it
// returns - which is the whole subject of this suite.
//=============================================================================

enum BackendShape {
  // What emu_io_ios.mm does now, and what the CLI and Windows backends have
  // always done: resolve, read and record, all before returning.
  BACKEND_SYNCHRONOUS,
  // What emu_io_ios.mm used to do: park the request and hand it to another
  // thread, returning true with nothing resolved.
  BACKEND_PARKING
};

static BackendShape g_shape = BACKEND_SYNCHRONOUS;
static emu_host_file_state g_state = HOST_FILE_IDLE;
static std::string g_read_name;
static std::string g_read_bytes;
static size_t g_read_pos = 0;

// A fake Imports folder. Brace-initialised rather than built with compound
// literals: those are a GNU extension clang accepts silently, and run_tests.sh
// falls back to plain `c++ -std=c++11 -Wall` off a Mac.
struct ImportEntry { const char* name; const char* contents; };
static const ImportEntry kImports[] = {
  { "esc.txt",  "\x1b[2J" },
  { "empty.txt", "" },
};

// The real backend refuses a file larger than this rather than truncating it:
// R8 derives the CP/M name from what was typed and cannot notice a short read,
// so a truncated copy arrives under the right name with both sides reporting
// success. The stub mirrors the rule so the guest-visible behaviour is pinned.
static const size_t kMaxHostReadBytes = 8u * 1024u * 1024u;
static size_t g_pretend_size = 0;  // 0 = use the entry's real length
static const char kImportsDir[] = "/var/mobile/Containers/Data/Application/"
                                  "0BADF00D-DEAD-BEEF-CAFE-000000000000/Documents/Imports";

// The resolver the synchronous backend uses, in the shape emu_io_ios.mm's
// resolve_in_directory() has: case-insensitive match, answering with the
// DIRECTORY ENTRY'S OWN SPELLING.
static const ImportEntry* find_import(const std::string& leaf) {
  for (size_t i = 0; i < sizeof(kImports) / sizeof(kImports[0]); i++) {
    if (strcasecmp(kImports[i].name, leaf.c_str()) == 0) return &kImports[i];
  }
  return nullptr;
}

emu_host_file_state emu_host_file_get_state() { return g_state; }

bool emu_host_file_open_read(const char* filename) {
  g_read_name.clear();
  g_read_bytes.clear();
  g_read_pos = 0;
  g_state = HOST_FILE_IDLE;

  // Both shapes keep the containment reduction. It is the guard, not a
  // convenience: without it "../SOMETHING" addresses files outside Imports.
  std::string leaf = emu_host_path_basename(filename ? filename : "", "\x01");
  if (leaf == "\x01") return false;

  if (g_shape == BACKEND_PARKING) {
    // Returns true having resolved nothing. The bytes and the name arrive later
    // from another thread.
    g_state = HOST_FILE_WAITING_READ;
    return true;
  }

  const ImportEntry* entry = find_import(leaf);
  if (!entry) return false;
  const size_t size = g_pretend_size ? g_pretend_size : strlen(entry->contents);
  if (size > kMaxHostReadBytes) return false;
  g_read_name = std::string(kImportsDir) + "/" + entry->name;
  g_read_bytes = entry->contents;
  g_read_pos = 0;
  // Unconditionally, including for a zero-byte file - guarding this on a
  // non-empty read reopens the zero-byte hole closed in build 53.
  g_state = HOST_FILE_READING;
  return true;
}

// What the parking backend's other thread eventually does.
static void parking_backend_delivers(const char* path, const char* bytes) {
  g_read_name = path ? path : "";
  g_read_bytes = bytes ? bytes : "";
  g_read_pos = 0;
  g_state = HOST_FILE_READING;
}

int emu_host_file_read_byte() {
  if (g_state != HOST_FILE_READING) return -1;
  if (g_read_pos >= g_read_bytes.size()) return -1;
  return (uint8_t)g_read_bytes[g_read_pos++];
}

void emu_host_file_close_read() {
  g_state = HOST_FILE_IDLE;
  g_read_bytes.clear();
  g_read_pos = 0;
  g_read_name.clear();
}

const char* emu_host_file_get_read_name() {
  static std::string reported;
  if (g_state != HOST_FILE_READING) {
    reported.clear();
    return reported.c_str();
  }
  reported = g_read_name;
  return reported.c_str();
}

//=============================================================================
// The rest of emu_io: enough to link, never exercised here
//=============================================================================

bool emu_console_has_input() { return false; }
int emu_console_read_char() { return -1; }
void emu_console_write_char(uint8_t) {}

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

bool emu_file_exists(const std::string&) { return false; }

bool emu_host_file_open_write(const char*) { return false; }
bool emu_host_file_write_byte(uint8_t) { return false; }
bool emu_host_file_close_write() { return true; }
const char* emu_host_file_get_write_name() { return ""; }
uint8_t emu_host_path_caps() { return EMU_HOST_CAP_SAFE_PATHS; }

//=============================================================================
// Scaffolding
//=============================================================================

// The Z80 proxy's OUT (0xEF),A sits at 0xFFF0 and is two bytes, so by the time
// the dispatcher runs PC already points past it. A call that cannot be
// satisfied has to put PC back to ENTRY.
static const uint16_t ENTRY = 0xFFF0;
static const uint16_t AFTER = ENTRY + 2;

// Somewhere in guest RAM for the path string and the answer buffer.
static const uint16_t PATH_ADDR = 0x8000;
static const uint16_t BUF_ADDR  = 0x8200;

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
    // What HBIOSEmulator::reset() does, and the arm that matters here: the
    // browser/mobile rewind only exists when blocking is not allowed.
    hbios.setBlockingAllowed(false);
  }

  void putGuestString(uint16_t addr, const char* s) {
    for (size_t i = 0; s[i]; i++) mem.store_mem((uint16_t)(addr + i), (uint8_t)s[i]);
    mem.store_mem((uint16_t)(addr + strlen(s)), 0);
  }

  std::string getGuestString(uint16_t addr) {
    std::string out;
    for (int i = 0; i < 512; i++) {
      uint8_t ch = mem.fetch_mem((uint16_t)(addr + i));
      if (!ch) break;
      out += (char)ch;
    }
    return out;
  }

  // One HBIOS call, entered exactly as the Z80 proxy enters it.
  void call(uint8_t func, uint8_t unit = 0) {
    cpu.regs.BC.set_high(func);
    cpu.regs.BC.set_low(unit);
    cpu.regs.PC.set_pair16(AFTER);
    hbios.handlePortDispatch();
  }

  // R8's own sequence. H_OPEN_R takes the path in DE.
  void openRead(const char* path) {
    putGuestString(PATH_ADDR, path);
    cpu.regs.DE.set_pair16(PATH_ADDR);
    call(HBF_HOST_OPEN_R);
  }

  // H_GETRNAME takes the buffer size in C and the buffer address in DE.
  void getReadName(uint8_t bufsize, uint16_t addr = BUF_ADDR) {
    for (int i = 0; i < 300; i++) mem.store_mem((uint16_t)(addr + i), 0xAA);
    cpu.regs.DE.set_pair16(addr);
    call(HBF_HOST_GETRNAME, bufsize);
  }

  uint8_t A() { return cpu.regs.AF.get_high(); }
  uint8_t E() { return cpu.regs.DE.get_low(); }
  uint16_t PC() { return cpu.regs.PC.get_pair16(); }
};

static void resetBackend(BackendShape shape) {
  g_shape = shape;
  g_pretend_size = 0;
  g_state = HOST_FILE_IDLE;
  g_read_name.clear();
  g_read_bytes.clear();
  g_read_pos = 0;
}

//=============================================================================

int main() {
  printf("R8's real sequence - open, ask which file, read - through both "
         "backend shapes\n");

  //-------------------------------------------------------------------------
  section("A synchronous open can answer H_GETRNAME; a parking one cannot");
  //-------------------------------------------------------------------------
  //
  // The identical guest sequence through both backends. This is the whole item.
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.openRead("ESC.TXT");
    check(r.A() == 0, "synchronous: H_OPEN_R reports success");
    check(emu_host_file_get_state() == HOST_FILE_READING,
          "synchronous: the state is READING by the time the open returns");

    r.getReadName(255);
    check(r.A() == 0, "synchronous: H_GETRNAME succeeds");
    std::string answered = r.getGuestString(BUF_ADDR);
    check(answered == std::string(kImportsDir) + "/esc.txt",
          "synchronous: and answers with the absolute resolved path");
    check(answered.find("esc.txt") != std::string::npos &&
              answered.find("ESC.TXT") == std::string::npos,
          "synchronous: in the FILE's spelling, not the shouted one the CCP made");
  }
  {
    Rig r;
    resetBackend(BACKEND_PARKING);
    r.openRead("ESC.TXT");
    check(r.A() == 0, "parking: H_OPEN_R also reports success");
    check(emu_host_file_get_state() == HOST_FILE_WAITING_READ,
          "parking: but the state is still WAITING_READ - nothing was resolved");

    r.getReadName(255);
    check(r.A() == 0xFF, "parking: H_GETRNAME FAILS - this is the bug the item was about");
    check(r.getGuestString(BUF_ADDR).empty() ||
              (uint8_t)r.mem.fetch_mem(BUF_ADDR) == 0xAA,
          "parking: and writes nothing into the guest's buffer");
  }

  //-------------------------------------------------------------------------
  section("H_GETRNAME is gated on READING, not on a name being known");
  //-------------------------------------------------------------------------
  //
  // Relaxing that gate was the idea considered and rejected: it would have the
  // backend answer with a name for a file it has not opened, which is exactly
  // the claim about the open this call exists to replace.
  {
    Rig r;
    resetBackend(BACKEND_PARKING);
    r.openRead("ESC.TXT");
    // The other thread finally delivers.
    parking_backend_delivers("/somewhere/esc.txt", "hello");
    r.getReadName(255);
    check(r.A() == 0, "once the parked request is fulfilled the name is answerable");
    check(r.getGuestString(BUF_ADDR) == "/somewhere/esc.txt",
          "and it is the delivered path");
  }
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.getReadName(255);
    check(r.A() == 0xFF, "with no open at all H_GETRNAME fails rather than inventing a name");
  }

  //-------------------------------------------------------------------------
  section("A file that is not there fails the OPEN");
  //-------------------------------------------------------------------------
  //
  // The deliberate behaviour change. It used to succeed, so R8 printed
  // `Creating:` and hit instant EOF on the first read, leaving a zero-byte CP/M
  // file behind.
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.openRead("NOSUCH.COM");
    check(r.A() == 0xFF, "H_OPEN_R reports failure for a file not in Imports");
    check(emu_host_file_get_state() == HOST_FILE_IDLE,
          "and leaves no transfer parked behind it");
  }
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.openRead("");
    check(r.A() == 0xFF, "an empty path fails rather than hunting for a fallback name");
  }
  {
    // emu_host_path_basename() substitutes its fallback for a path naming no
    // file, and an EMPTY fallback is itself replaced with "download.bin" - so
    // `basename(x, "")` cannot be tested against "" to mean "nothing named".
    // That is why the backend passes a sentinel.
    check(emu_host_path_basename("/", "") == "download.bin",
          "basename with an empty fallback answers download.bin, not \"\"");
    check(emu_host_path_basename("/", "\x01") == "\x01",
          "so a sentinel fallback is what makes 'named nothing' detectable");
    check(emu_host_path_basename("../SOMETHING", "\x01") == "SOMETHING",
          "and the reduction is still the containment guard - .. cannot escape Imports");
  }

  //-------------------------------------------------------------------------
  section("A zero-byte file is a real file");
  //-------------------------------------------------------------------------
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.openRead("EMPTY.TXT");
    check(r.A() == 0, "an empty file opens successfully");
    check(emu_host_file_get_state() == HOST_FILE_READING,
          "and reaches READING - guarding that on a non-empty read is the "
          "zero-byte hole closed in build 53");
    r.getReadName(255);
    check(r.A() == 0, "so R8 can still ask what it is reading");
    r.call(HBF_HOST_READ);
    check(r.A() == 0xFF, "the first read is EOF, which is what makes an empty CP/M file");
    check(r.PC() == AFTER, "and it does NOT rewind - there is nothing to wait for");
  }

  //-------------------------------------------------------------------------
  section("A file too large to read fails the open rather than truncating");
  //-------------------------------------------------------------------------
  //
  // The guest blocks inside one HBIOS call with no rewind now, so the read is
  // bounded. Truncating to the bound would hand CP/M a short file under the
  // right name with both sides reporting success - the same shape as the
  // "substitute an unrelated file" bug build 52 removed.
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    g_pretend_size = 12u * 1024u * 1024u;
    r.openRead("ESC.TXT");
    check(r.A() == 0xFF, "a 12 MB file fails the open");
    check(emu_host_file_get_state() == HOST_FILE_IDLE,
          "and leaves nothing parked, so the next R8 is unaffected");
    r.getReadName(255);
    check(r.A() == 0xFF, "and there is no name to report for a file that did not open");
  }
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    g_pretend_size = kMaxHostReadBytes;  // exactly at the bound
    r.openRead("ESC.TXT");
    check(r.A() == 0, "a file exactly at the bound is still allowed");
  }

  //-------------------------------------------------------------------------
  section("The PC-rewind arm, which only exists when blocking is not allowed");
  //-------------------------------------------------------------------------
  {
    Rig r;
    resetBackend(BACKEND_PARKING);
    r.openRead("ESC.TXT");
    r.cpu.regs.DE.set_low(0x5A);  // sentinel: must not pass for file data
    r.call(HBF_HOST_READ);
    check(r.PC() == ENTRY, "H_READ while WAITING_READ rewinds PC over the OUT");
    check(r.E() == 0x5A, "and leaves E untouched rather than delivering a stale byte");
    check(r.hbios.isWaitingForInput(), "and reports that we are waiting");

    parking_backend_delivers("/somewhere/esc.txt", "Z");
    r.cpu.regs.PC.set_pair16(AFTER);  // the OUT re-executes
    r.call(HBF_HOST_READ);
    check(r.A() == 0 && r.E() == 'Z', "the retried read delivers the byte");
    check(r.PC() == AFTER, "and lets the proxy RET run");
  }
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.openRead("ESC.TXT");
    r.call(HBF_HOST_READ);
    check(r.A() == 0 && r.E() == 0x1b,
          "a synchronous open needs no rewind at all - the first read has the byte");
    check(r.PC() == AFTER, "so the guest never stalls");
    check(!r.hbios.isWaitingForInput(), "and nothing reports a wait");
  }

  //-------------------------------------------------------------------------
  section("storeHostName clamps rather than overruns");
  //-------------------------------------------------------------------------
  //
  // A real device's Imports path is ~110 characters before the filename, and R8
  // passes HRSIZE = 255, so this is close to the edge in normal use.
  {
    Rig r;
    resetBackend(BACKEND_SYNCHRONOUS);
    r.openRead("ESC.TXT");
    const std::string full = std::string(kImportsDir) + "/esc.txt";

    r.getReadName(255);
    check(r.getGuestString(BUF_ADDR) == full, "a 255-byte buffer takes the whole path");

    r.getReadName(20);
    std::string clamped = r.getGuestString(BUF_ADDR);
    check(clamped.size() == 19, "a 20-byte buffer yields 19 characters plus a terminator");
    check(clamped.compare(0, 3, "...") == 0,
          "and it is marked as cut rather than silently shortened");
    check(full.compare(full.size() - 16, 16, clamped.substr(3)) == 0,
          "keeping the TAIL, which is the half that names the file");
    check((uint8_t)r.mem.fetch_mem(BUF_ADDR + 19) == 0, "terminated in range");
    check((uint8_t)r.mem.fetch_mem(BUF_ADDR + 20) == 0xAA,
          "and nothing written past the buffer the guest gave");

    r.getReadName(4);
    std::string tiny = r.getGuestString(BUF_ADDR);
    check(tiny.size() == 3, "a 4-byte buffer yields 3 characters");
    check(tiny.compare(0, 3, "...") != 0,
          "with no room for the marker plus a character of path, the tail is "
          "taken and left short - a marker alone would say nothing");

    r.getReadName(1);
    check(r.A() == 0xFF, "a buffer too small to hold anything is refused, not overrun");
    check((uint8_t)r.mem.fetch_mem(BUF_ADDR) == 0xAA, "and nothing is written into it");
  }

  //-------------------------------------------------------------------------
  printf("\n");
  for (int i = 0; i < 60; i++) putchar('=');
  printf("\nResults: %d passed, %d failed\n", checks - failures, failures);
  if (failures) {
    printf("TESTS FAILED\n");
    return 1;
  }
  printf("All tests passed\n");
  return 0;
}
