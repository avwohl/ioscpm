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
  if (ch == '\n') ch = '\r';  // LF -> CR for CP/M
  g_input_queue.push(ch);
}

void emu_console_clear_queue() {
  std::lock_guard<std::mutex> lock(g_input_mutex);
  while (!g_input_queue.empty()) g_input_queue.pop();
}

static int g_char_count = 0;

void emu_console_write_char(uint8_t ch) {
  g_char_count++;
  // Log first 100 chars to see output
  if (g_char_count <= 100) {
    if (ch >= 0x20 && ch < 0x7F) {
      NSLog(@"[EMU] Console output #%d: '%c' (0x%02X)", g_char_count, ch, ch);
    } else {
      NSLog(@"[EMU] Console output #%d: 0x%02X", g_char_count, ch);
    }
  }

  id<EMUIODelegate> delegate = g_delegate;
  if (delegate && [delegate respondsToSelector:@selector(emuConsoleOutput:)]) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [delegate emuConsoleOutput:ch];
    });
  }
}

bool emu_console_check_escape(char escape_char) {
  // Not implemented for iOS - escape handled in UI
  return false;
}

bool emu_console_check_ctrl_c_exit(int ch, int count) {
  // Not implemented for iOS
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
  va_list args;
  va_start(args, fmt);
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  NSLog(@"[EMU] %s", buf);
}

void emu_error(const char* fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char buf[1024];
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  NSLog(@"[EMU ERROR] %s", buf);
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
// File I/O
//=============================================================================

bool emu_file_load(const std::string& path, std::vector<uint8_t>& data) {
  @autoreleasepool {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSData* nsData = [NSData dataWithContentsOfFile:nsPath];
    if (!nsData) {
      // Try in bundle
      NSString* filename = [nsPath lastPathComponent];
      NSString* bundlePath = [[NSBundle mainBundle] pathForResource:[filename stringByDeletingPathExtension]
                                                             ofType:[filename pathExtension]];
      if (bundlePath) {
        nsData = [NSData dataWithContentsOfFile:bundlePath];
      }
    }
    if (!nsData) return false;

    data.resize(nsData.length);
    memcpy(data.data(), nsData.bytes, nsData.length);
    return true;
  }
}

size_t emu_file_load_to_mem(const std::string& path, uint8_t* mem, size_t mem_size, size_t offset) {
  std::vector<uint8_t> data;
  if (!emu_file_load(path, data)) return 0;
  size_t copy_size = std::min(data.size(), mem_size - offset);
  memcpy(mem + offset, data.data(), copy_size);
  return copy_size;
}

bool emu_file_save(const std::string& path, const std::vector<uint8_t>& data) {
  @autoreleasepool {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
    NSData* nsData = [NSData dataWithBytes:data.data() length:data.size()];
    return [nsData writeToFile:nsPath atomically:YES];
  }
}

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
// Disk Image I/O
//=============================================================================

struct DiskHandle {
  NSFileHandle* handle;
  NSString* path;
  size_t size;
  bool readonly;
};

emu_disk_handle emu_disk_open(const std::string& path, const char* mode) {
  @autoreleasepool {
    NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];

    // Check if file exists
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:nsPath];

    // Create if needed
    if (!exists && strchr(mode, '+')) {
      [[NSFileManager defaultManager] createFileAtPath:nsPath contents:nil attributes:nil];
    }

    NSFileHandle* handle = nil;
    bool readonly = (strcmp(mode, "r") == 0);

    if (readonly) {
      handle = [NSFileHandle fileHandleForReadingAtPath:nsPath];
    } else {
      handle = [NSFileHandle fileHandleForUpdatingAtPath:nsPath];
    }

    if (!handle) return nullptr;

    DiskHandle* dh = new DiskHandle();
    dh->handle = handle;
    dh->path = nsPath;
    dh->readonly = readonly;

    // Get size
    [handle seekToEndOfFile];
    dh->size = [handle offsetInFile];
    [handle seekToFileOffset:0];

    return (emu_disk_handle)dh;
  }
}

void emu_disk_close(emu_disk_handle disk) {
  if (!disk) return;
  @autoreleasepool {
    DiskHandle* dh = (DiskHandle*)disk;
    [dh->handle closeFile];
    delete dh;
  }
}

size_t emu_disk_read(emu_disk_handle disk, size_t offset, uint8_t* buffer, size_t count) {
  if (!disk) return 0;
  @autoreleasepool {
    DiskHandle* dh = (DiskHandle*)disk;
    [dh->handle seekToFileOffset:offset];
    NSData* data = [dh->handle readDataOfLength:count];
    if (!data) return 0;
    memcpy(buffer, data.bytes, data.length);
    return data.length;
  }
}

size_t emu_disk_write(emu_disk_handle disk, size_t offset, const uint8_t* buffer, size_t count) {
  if (!disk) return 0;
  @autoreleasepool {
    DiskHandle* dh = (DiskHandle*)disk;
    if (dh->readonly) return 0;
    [dh->handle seekToFileOffset:offset];
    NSData* data = [NSData dataWithBytes:buffer length:count];
    @try {
      [dh->handle writeData:data];
      if (offset + count > dh->size) dh->size = offset + count;
      return count;
    } @catch (NSException* e) {
      return 0;
    }
  }
}

void emu_disk_flush(emu_disk_handle disk) {
  if (!disk) return;
  @autoreleasepool {
    DiskHandle* dh = (DiskHandle*)disk;
    [dh->handle synchronizeFile];
  }
}

size_t emu_disk_size(emu_disk_handle disk) {
  if (!disk) return 0;
  DiskHandle* dh = (DiskHandle*)disk;
  return dh->size;
}

//=============================================================================
// Time
//=============================================================================

void emu_get_time(emu_time* t) {
  @autoreleasepool {
    NSDate* now = [NSDate date];
    NSCalendar* calendar = [NSCalendar currentCalendar];
    NSDateComponents* components = [calendar components:(NSCalendarUnitYear | NSCalendarUnitMonth |
                                                         NSCalendarUnitDay | NSCalendarUnitHour |
                                                         NSCalendarUnitMinute | NSCalendarUnitSecond |
                                                         NSCalendarUnitWeekday)
                                               fromDate:now];
    t->year = (int)components.year;
    t->month = (int)components.month;
    t->day = (int)components.day;
    t->hour = (int)components.hour;
    t->minute = (int)components.minute;
    t->second = (int)components.second;
    t->weekday = ((int)components.weekday + 6) % 7;  // Convert to 0=Sunday
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
