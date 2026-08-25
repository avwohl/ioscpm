/*
 * iOS/macOS Implementation of emu_io.h
 *
 * Bridges the C++ emu_io interface to Objective-C delegates for SwiftUI.
 */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include "emu_io.h"
#include <cstdarg>
#include <cstdio>
#include <queue>
#include <mutex>
#include <unistd.h>
#include <strings.h>

//=============================================================================
// Delegate Protocol
//=============================================================================

@protocol EMUIODelegate <NSObject>
@optional
// Console I/O
- (void)emuConsoleOutput:(uint8_t)ch;
- (void)emuStatusMessage:(NSString*)msg;

// Video/VDA
- (void)emuVideoClear;
- (void)emuVideoSetCursorRow:(int)row col:(int)col;
- (void)emuVideoWriteChar:(uint8_t)ch;
- (void)emuVideoScrollUp:(int)lines;
- (void)emuVideoSetAttr:(uint8_t)attr;

// Sound
- (void)emuBeep:(int)durationMs;

// Disk flush (called on warm boot)
- (void)emuDiskFlush;
@end

//=============================================================================
// Global State
//=============================================================================

static __weak id<EMUIODelegate> g_delegate = nil;
static std::queue<int> g_input_queue;
static std::mutex g_input_mutex;
static int g_cursor_row = 0;
static int g_cursor_col = 0;
static uint8_t g_attr = 0x07;
static bool g_debug_enabled = false;

// Audio engine for beep
static AVAudioEngine* g_audioEngine = nil;
static AVAudioPlayerNode* g_playerNode = nil;

//=============================================================================
// Delegate Management
//=============================================================================

extern "C" void emu_io_set_delegate(id<EMUIODelegate> delegate) {
  g_delegate = delegate;
}

extern "C" id<EMUIODelegate> emu_io_get_delegate(void) {
  return g_delegate;
}

//=============================================================================
// Utility Functions
//=============================================================================

void emu_sleep_ms(int ms) {
  usleep(ms * 1000);
}

int emu_strcasecmp(const char* s1, const char* s2) {
  return strcasecmp(s1, s2);
}

int emu_strncasecmp(const char* s1, const char* s2, size_t n) {
  return strncasecmp(s1, s2, n);
}

//=============================================================================
// Console I/O
//=============================================================================

void emu_io_init() {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  while (!g_input_queue.empty()) g_input_queue.pop();
  g_cursor_row = 0;
  g_cursor_col = 0;
  g_attr = 0x07;
}

void emu_io_cleanup() {
  if (g_audioEngine) {
    [g_audioEngine stop];
    g_audioEngine = nil;
    g_playerNode = nil;
  }
}

bool emu_console_has_input() {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  return !g_input_queue.empty();
}

int emu_console_read_char() {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  if (g_input_queue.empty()) return -1;
  int ch = g_input_queue.front();
  g_input_queue.pop();
  return ch;
}

void emu_console_queue_char(int ch) {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  // No LF -> CR rewrite here. Every producer that means Enter already sends CR
  // (TerminalView's insertText, enterPressed and pasteText all do the mapping
  // at the source), so a 0x0A arriving at this depth is a genuine Ctrl+J - or a
  // key map binding spelled "\n" - and rewriting it would make the two keys
  // indistinguishable. Same audit romwbw_emu v1.36 did for its tty read path;
  // see docs/DOWNSTREAM_2026-08-23.md section 2.
  g_input_queue.push(ch);
}

void emu_console_clear_queue() {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  while (!g_input_queue.empty()) g_input_queue.pop();
}

// v1.34 platform contract: these only mean something to a CLI reading a
// closed pipe/file. An interactive GUI can always receive more input, so both
// return false (matching the Windows/Android sister ports). They must still be
// defined or the link against the shared core fails.
bool emu_console_input_exhausted() {
  return false;  // GUI: more input can always arrive
}

bool emu_console_input_eof() {
  return false;  // GUI: no piped stdin
}

void emu_console_write_char(uint8_t ch) {
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuConsoleOutput:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuConsoleOutput:ch];
    });
  }
}

bool emu_console_check_escape(char escape_char) {
  // iOSCPM reserves no key for the emulator. Every Ctrl-letter is folded to
  // 0x01-0x1A and handed to the guest, and nothing in the UI intercepts an
  // emulator escape, so this consumes nothing and returns false for every
  // escape_char - which is exactly what the v1.36 contract requires of the
  // escape_char == 0 case. Only the CLI frontend calls this; the stub is here
  // to satisfy the shared-core platform contract.
  return false;
}

//=============================================================================
// Auxiliary Device I/O (stubs for now)
//=============================================================================

void emu_printer_set_file(const char* path) {}
void emu_printer_out(uint8_t ch) {}
bool emu_printer_ready() { return false; }
void emu_aux_set_input_file(const char* path) {}
void emu_aux_set_output_file(const char* path) {}
int emu_aux_in() { return 0x1A; }  // EOF
void emu_aux_out(uint8_t ch) {}

//=============================================================================
// Debug/Log Output
//=============================================================================

void emu_log(const char* fmt, ...) {
  if (!g_debug_enabled) return;
  va_list args;
  va_start(args, fmt);
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  NSLog(@"[EMU] %s", buf);
}

void emu_set_debug(bool enable) {
  g_debug_enabled = enable;
}

void emu_error(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  NSLog(@"[EMU ERROR] %s", buf);
}

void emu_fatal(const char* fmt, ...) {
  NSLog(@"*** FATAL ERROR ***");
  va_list args;
  va_start(args, fmt);
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  NSLog(@"[EMU FATAL] %s", buf);
  NSLog(@"*** ABORTING ***");
  abort();
}

void emu_status(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);

  NSString* msg = [NSString stringWithUTF8String:buf];
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuStatusMessage:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuStatusMessage:msg];
    });
  }
}

//=============================================================================
// File I/O (platform-specific functions; common functions in emu_io_common.cc)
//=============================================================================

bool emu_file_exists(const std::string& path) {
  @autoreleasepool {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    return [[NSFileManager defaultManager] fileExistsAtPath:nsPath];
  }
}

size_t emu_file_size(const std::string& path) {
  @autoreleasepool {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:nsPath error:nil];
    return attrs ? [attrs fileSize] : 0;
  }
}

//=============================================================================
// Random Numbers
//=============================================================================

unsigned int emu_random(unsigned int min, unsigned int max) {
  return min + arc4random_uniform(max - min + 1);
}

//=============================================================================
// Video/Display
//=============================================================================

void emu_video_get_caps(emu_video_caps* caps) {
  caps->has_text_display = true;
  caps->has_pixel_display = false;
  caps->has_dsky = false;
  caps->text_rows = 25;
  caps->text_cols = 80;
  caps->pixel_width = 0;
  caps->pixel_height = 0;
}

void emu_video_clear() {
  g_cursor_row = 0;
  g_cursor_col = 0;
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuVideoClear)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuVideoClear];
    });
  }
}

void emu_video_set_cursor(int row, int col) {
  g_cursor_row = row;
  g_cursor_col = col;
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuVideoSetCursorRow:col:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuVideoSetCursorRow:row col:col];
    });
  }
}

void emu_video_get_cursor(int* row, int* col) {
  *row = g_cursor_row;
  *col = g_cursor_col;
}

void emu_video_write_char(uint8_t ch) {
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuVideoWriteChar:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuVideoWriteChar:ch];
    });
  }
}

void emu_video_write_char_at(int row, int col, uint8_t ch) {
  emu_video_set_cursor(row, col);
  emu_video_write_char(ch);
}

void emu_video_scroll_up(int lines) {
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuVideoScrollUp:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuVideoScrollUp:lines];
    });
  }
}

void emu_video_set_attr(uint8_t attr) {
  g_attr = attr;
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuVideoSetAttr:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuVideoSetAttr:attr];
    });
  }
}

uint8_t emu_video_get_attr() {
  return g_attr;
}

//=============================================================================
// DSKY (stubs)
//=============================================================================

void emu_dsky_show_hex(uint8_t position, uint8_t value) {}
void emu_dsky_show_segments(uint8_t position, uint8_t segments) {}
void emu_dsky_set_leds(uint8_t leds) {}

void emu_dsky_beep(int duration_ms) {
  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuBeep:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuBeep:duration_ms];
    });
  }
}

int emu_dsky_get_key() {
  return -1;
}

//=============================================================================
// Host File Transfer (R8/W8 utilities)
//=============================================================================

// Extended delegate protocol for host file transfer
@protocol EMUIOHostFileDelegate <EMUIODelegate>
@optional
- (void)emuHostFileRequestRead:(NSString*)suggestedFilename;
- (void)emuHostFileDownload:(NSString*)filename data:(NSData*)data;
@end

// Host file state
static emu_host_file_state g_host_file_state = HOST_FILE_IDLE;
static std::vector<uint8_t> g_host_read_buffer;
static size_t g_host_read_pos = 0;
static std::vector<uint8_t> g_host_write_buffer;
static std::string g_host_write_filename;

emu_host_file_state emu_host_file_get_state() {
  return g_host_file_state;
}

// C wrappers for Swift bridging (Swift can't call C++ functions)
extern "C" int emu_host_file_get_state_c() {
  return (int)g_host_file_state;
}

// Where W8 exports really land. Duplicated from EmulatorViewModel's
// saveToExportsFolder rather than passed in, because there is no init order in
// which a setter is guaranteed to have run before the guest's first W8 - and
// the two computing the same path from the same two constants cannot drift
// apart the way a stale cached setter value could. If the Swift side ever moves
// the folder, this moves with it.
static std::string exports_dir() {
  NSArray<NSString*>* dirs =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
  if (dirs.count == 0) return std::string();
  NSString* path = [dirs[0] stringByAppendingPathComponent:@"Exports"];
  return std::string([path UTF8String]);
}

bool emu_host_file_open_read(const char* filename) {
  // Close any existing read operation
  g_host_read_buffer.clear();
  g_host_read_pos = 0;

  // Request file from user via delegate
  g_host_file_state = HOST_FILE_WAITING_READ;

  id<EMUIOHostFileDelegate> delegate = (id<EMUIOHostFileDelegate>)g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuHostFileRequestRead:)]) {
    // R8 takes a host path and sends it verbatim, so what arrives here can be
    // "/USERS/ME/DESKTOP/FOO.COM". Imports is a flat folder and there is no
    // outer-OS path to honour inside the sandbox, so reduce to the leaf before
    // the delegate ever sees it: passing the whole string on made the Swift
    // layer look for Imports/USERS/ME/DESKTOP/FOO.COM, miss, and (before this
    // release) substitute an unrelated file. It also kept "../SOMETHING" able
    // to address files outside Imports.
    std::string leaf =
        filename ? emu_host_path_basename(filename, "") : std::string();
    NSString* suggestedName = leaf.empty() ? @"" : [NSString stringWithUTF8String:leaf.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuHostFileRequestRead:suggestedName];
    });
  }

  return true;  // Request initiated (will wait for emu_host_file_provide_data)
}

// iOS confines every export to the app's Exports folder: emu_host_file_open_write
// reduces the guest path to a single leaf with emu_host_path_basename, the Swift
// layer (ExportPath) reduces again and refuses anything that resolves outside
// Exports, and nothing calls removeItem on a guest-derived path any more. So it
// writes only the named file inside one folder and never uses the path
// destructively - it sets EMU_HOST_CAP_SAFE_PATHS. Build 52 is the build that
// made this true; this function existing at all is what lets the core assert it
// only when a backend has (a port that has not been updated fails to link).
uint8_t emu_host_path_caps() {
  return EMU_HOST_CAP_SAFE_PATHS;
}

bool emu_host_file_open_write(const char* filename) {
  // Close any existing write operation
  g_host_write_buffer.clear();
  // Reduce to a single leaf component. W8 can be given a host path and sends it
  // verbatim; this used to be stored whole and handed to the Swift layer as the
  // export *filename*, which then built a destination with
  // appendingPathComponent - and that does not escape "..". "W8 ANYFILE.TXT .."
  // therefore resolved to Documents/Exports/.., which removeItem deleted
  // recursively: the whole Documents folder, disk library included.
  //
  // The reduction is the fix; the containment check in saveToExportsFolder is
  // the belt behind it. emu_host_path_basename accepts both separators and
  // never returns "", "." or ".." - see emu_io.h.
  g_host_write_filename =
      emu_host_path_basename(filename ? filename : "download.bin", "download.bin");
  g_host_file_state = HOST_FILE_WRITING;
  return true;
}

int emu_host_file_read_byte() {
  if (g_host_file_state != HOST_FILE_READING) return -1;
  if (g_host_read_pos >= g_host_read_buffer.size()) return -1;
  return g_host_read_buffer[g_host_read_pos++];
}

bool emu_host_file_write_byte(uint8_t byte) {
  if (g_host_file_state != HOST_FILE_WRITING) return false;
  g_host_write_buffer.push_back(byte);
  return true;
}

void emu_host_file_close_read() {
  g_host_read_buffer.clear();
  g_host_read_pos = 0;
  g_host_file_state = HOST_FILE_IDLE;
}

// v1.34: returns bool. A false return would tell the guest (via HBF_HOST_CLOSE)
// that the export may be truncated. iOS buffers the write and hands it to the
// OS asynchronously (the Swift layer polls HOST_FILE_WRITE_READY and writes to
// the Exports folder / share sheet), so the synchronous close always succeeds
// here -- return true, the same as the browser backend. A late write failure in
// the Swift layer is surfaced to the user there, not through this return value.
bool emu_host_file_close_write() {
  if (g_host_file_state == HOST_FILE_WRITING && !g_host_write_buffer.empty()) {
    // Set state to WRITE_READY - UI will poll for this and show save picker
    // Data stays in buffer until emu_host_file_write_done() is called
    g_host_file_state = HOST_FILE_WRITE_READY;
  } else {
    g_host_write_buffer.clear();
    g_host_write_filename.clear();
    g_host_file_state = HOST_FILE_IDLE;
  }
  return true;
}

void emu_host_file_write_done() {
  // Called by UI after file has been saved (or cancelled)
  g_host_write_buffer.clear();
  g_host_write_filename.clear();
  g_host_file_state = HOST_FILE_IDLE;
}

extern "C" void emu_host_file_write_done_c() {
  emu_host_file_write_done();
}

void emu_host_file_provide_data(const uint8_t* data, size_t size) {
  g_host_read_buffer.assign(data, data + size);
  g_host_read_pos = 0;
  g_host_file_state = HOST_FILE_READING;
}

const uint8_t* emu_host_file_get_write_data() {
  return g_host_write_buffer.empty() ? nullptr : g_host_write_buffer.data();
}

size_t emu_host_file_get_write_size() {
  return g_host_write_buffer.size();
}

// The effective destination, not an echo of what the guest asked for - see the
// contract in emu_io.h. W8 prints this (HBF_HOST_GETNAME), so on this port the
// useful answer is the Exports path the file will really reach, not the bare
// name: a CP/M user with no visible filesystem otherwise has no way to find it.
//
// Valid while WRITING *and* while WRITE_READY. The second half is load-bearing
// here and not on the other backends: close_write() moves to WRITE_READY and
// the Swift layer reads this afterwards to do the actual save, so gating on
// WRITING alone would return "" to the code that performs the export.
const char* emu_host_file_get_write_name() {
  static std::string reported;
  if (g_host_file_state != HOST_FILE_WRITING &&
      g_host_file_state != HOST_FILE_WRITE_READY) {
    reported.clear();
    return reported.c_str();
  }
  const std::string dir = exports_dir();
  reported = dir.empty() ? g_host_write_filename : dir + "/" + g_host_write_filename;
  return reported.c_str();
}

// The leaf name on its own, for the Swift layer, which joins it to the Exports
// URL itself and must not be handed an absolute path to join.
extern "C" const char* emu_host_file_get_write_leaf_c() {
  return g_host_write_filename.c_str();
}

// C wrappers for Swift
extern "C" const uint8_t* emu_host_file_get_write_data_c() {
  return emu_host_file_get_write_data();
}

extern "C" size_t emu_host_file_get_write_size_c() {
  return emu_host_file_get_write_size();
}

extern "C" const char* emu_host_file_get_write_name_c() {
  return emu_host_file_get_write_name();
}

// C function for Swift to provide file data after picker selection
extern "C" void emu_host_file_load(const uint8_t* data, size_t size) {
  emu_host_file_provide_data(data, size);
}

// C function for Swift to cancel a file read operation
extern "C" void emu_host_file_cancel() {
  g_host_file_state = HOST_FILE_IDLE;
  g_host_read_buffer.clear();
  g_host_read_pos = 0;
}
