/*
 * RomWBW Emulator Bridge Implementation
 *
 * Objective-C++ wrapper for the RomWBW/HBIOS emulator core.
 */

#import "RomWBWEmulator.h"
#include "hbios_core.h"
#include "emu_io.h"
#include <memory>

// Forward declare the delegate setter from emu_io_ios.mm
extern "C" void emu_io_set_delegate(id delegate);

//=============================================================================
// Internal class to implement EMUIODelegate
//=============================================================================

@interface RomWBWEmulatorInternal : NSObject
@property (weak, nonatomic) RomWBWEmulator* owner;
@end

@implementation RomWBWEmulatorInternal

- (void)emuConsoleOutput:(uint8_t)ch {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorDidOutputCharacter:)]) {
    [self.owner.delegate emulatorDidOutputCharacter:(unichar)ch];
  }
}

- (void)emuStatusMessage:(NSString*)msg {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorDidChangeStatus:)]) {
    [self.owner.delegate emulatorDidChangeStatus:msg];
  }
}

- (void)emuVideoClear {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorVDAClear)]) {
    [self.owner.delegate emulatorVDAClear];
  }
}

- (void)emuVideoSetCursorRow:(int)row col:(int)col {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorVDASetCursorRow:col:)]) {
    [self.owner.delegate emulatorVDASetCursorRow:row col:col];
  }
}

- (void)emuVideoWriteChar:(uint8_t)ch {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorVDAWriteChar:)]) {
    [self.owner.delegate emulatorVDAWriteChar:(unichar)ch];
  }
}

- (void)emuVideoScrollUp:(int)lines {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorVDAScrollUp:)]) {
    [self.owner.delegate emulatorVDAScrollUp:lines];
  }
}

- (void)emuVideoSetAttr:(uint8_t)attr {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorVDASetAttr:)]) {
    [self.owner.delegate emulatorVDASetAttr:attr];
  }
}

- (void)emuBeep:(int)durationMs {
  if (self.owner.delegate && [self.owner.delegate respondsToSelector:@selector(emulatorBeep:)]) {
    [self.owner.delegate emulatorBeep:durationMs];
  }
}

@end

//=============================================================================
// RomWBWEmulator Implementation
//=============================================================================

@implementation RomWBWEmulator {
  std::unique_ptr<HBIOSEmulator> _emulator;
  dispatch_queue_t _emulatorQueue;
  RomWBWEmulatorInternal* _internal;
  BOOL _shouldRun;
  BOOL _debug;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _emulator = std::make_unique<HBIOSEmulator>();
    _emulatorQueue = dispatch_queue_create("com.romwbw.emulator", DISPATCH_QUEUE_SERIAL);
    _internal = [[RomWBWEmulatorInternal alloc] init];
    _internal.owner = self;
    _shouldRun = NO;

    // Initialize emu_io
    emu_io_init();
    emu_io_set_delegate(_internal);
  }
  return self;
}

- (void)dealloc {
  [self stop];
  emu_io_cleanup();
}

//=============================================================================
// ROM Loading
//=============================================================================

- (BOOL)loadROMFromBundle:(NSString*)filename {
  if (_debug) NSLog(@"[RomWBW] Loading ROM from bundle: %@", filename);
  NSString* name = [filename stringByDeletingPathExtension];
  NSString* ext = [filename pathExtension];
  NSString* path = [[NSBundle mainBundle] pathForResource:name ofType:ext];
  if (!path) {
    NSLog(@"[RomWBW] ROM not found in bundle: %@", filename);
    return NO;
  }
  if (_debug) NSLog(@"[RomWBW] ROM path: %@", path);
  return [self loadROMFromPath:path];
}

- (BOOL)loadROMFromPath:(NSString*)path {
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    NSLog(@"[RomWBW] Failed to read ROM file: %@", path);
    return NO;
  }
  if (_debug) NSLog(@"[RomWBW] Read %lu bytes from ROM file", (unsigned long)data.length);
  return [self loadROMFromData:data];
}

- (BOOL)loadROMFromData:(NSData*)data {
  BOOL result = _emulator->loadROM((const uint8_t*)data.bytes, data.length);
  if (_debug) NSLog(@"[RomWBW] loadROM returned: %@", result ? @"YES" : @"NO");
  return result;
}

//=============================================================================
// Disk Management
//=============================================================================

- (BOOL)loadDisk:(int)unit fromBundle:(NSString*)filename {
  NSString* name = [filename stringByDeletingPathExtension];
  NSString* ext = [filename pathExtension];
  NSString* path = [[NSBundle mainBundle] pathForResource:name ofType:ext];
  if (!path) {
    NSLog(@"[RomWBW] Disk not found in bundle: %@", filename);
    return NO;
  }
  return [self loadDisk:unit fromPath:path];
}

- (BOOL)loadDisk:(int)unit fromPath:(NSString*)path {
  NSData* data = [NSData dataWithContentsOfFile:path];
  if (!data) {
    NSLog(@"[RomWBW] Failed to read disk file: %@", path);
    return NO;
  }
  return [self loadDisk:unit fromData:data];
}

// Standard disk size for CP/M hard disk (8MB)
static const size_t DISK_SIZE_8MB = 8 * 1024 * 1024;

- (BOOL)loadDisk:(int)unit fromData:(NSData*)data {
  // Pad small disk images to 8MB with 0xE5 (empty formatted sectors)
  // This prevents garbage when CP/M reads beyond the actual data
  if (data.length < DISK_SIZE_8MB) {
    NSMutableData* paddedData = [NSMutableData dataWithLength:DISK_SIZE_8MB];
    // Fill with 0xE5 (CP/M empty/formatted disk pattern)
    memset(paddedData.mutableBytes, 0xE5, DISK_SIZE_8MB);
    // Copy actual data at the beginning
    memcpy(paddedData.mutableBytes, data.bytes, data.length);
    if (_debug) NSLog(@"[RomWBW] Padded disk %d from %lu to %zu bytes", unit, (unsigned long)data.length, DISK_SIZE_8MB);
    return _emulator->loadDisk(unit, (const uint8_t*)paddedData.bytes, paddedData.length);
  }
  return _emulator->loadDisk(unit, (const uint8_t*)data.bytes, data.length);
}

- (nullable NSData*)getDiskData:(int)unit {
  const uint8_t* data = _emulator->getDiskData(unit);
  size_t size = _emulator->getDiskSize(unit);
  if (!data || size == 0) return nil;
  return [NSData dataWithBytes:data length:size];
}

- (BOOL)saveDisk:(int)unit toPath:(NSString*)path {
  NSData* data = [self getDiskData:unit];
  if (!data) return NO;
  return [data writeToFile:path atomically:YES];
}

- (BOOL)isDiskLoaded:(int)unit {
  return _emulator->isDiskLoaded(unit);
}

//=============================================================================
// Boot String
//=============================================================================

- (void)setBootString:(NSString*)bootString {
  _emulator->setBootString(bootString ? [bootString UTF8String] : "");
}

//=============================================================================
// Execution Control
//=============================================================================

- (BOOL)isRunning {
  return _emulator->isRunning();
}

- (BOOL)isWaitingForInput {
  return _emulator->isWaitingForInput();
}

- (void)start {
  if (_debug) NSLog(@"[RomWBW] start called");
  _shouldRun = YES;
  _emulator->start();
  if (_debug) NSLog(@"[RomWBW] emulator started, isRunning=%d", _emulator->isRunning());

  // Start emulation loop on background queue
  dispatch_async(_emulatorQueue, ^{
    if (self->_debug) NSLog(@"[RomWBW] entering runLoop");
    [self runLoop];
    if (self->_debug) NSLog(@"[RomWBW] exited runLoop");
  });
}

- (void)stop {
  _shouldRun = NO;
  _emulator->stop();
}

- (void)reset {
  [self stop];
  _emulator->reset();
}

- (void)runLoop {
  int loopCount = 0;
  while (_shouldRun && _emulator->isRunning()) {
    // Run a batch of instructions
    _emulator->runBatch(10000);
    loopCount++;

    // Log progress every 1000 batches (only in debug mode)
    if (_debug && (loopCount % 1000 == 0)) {
      NSLog(@"[RomWBW] runLoop: %d batches, PC=0x%04X, instructions=%lld",
            loopCount, _emulator->getPC(), _emulator->getInstructionCount());
    }

    // If waiting for input, notify delegate and wait a bit
    if (_emulator->isWaitingForInput()) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(emulatorDidRequestInput)]) {
          [self.delegate emulatorDidRequestInput];
        }
      });

      // Small sleep to avoid spinning
      [NSThread sleepForTimeInterval:0.001];
    } else {
      // Very small yield to prevent CPU hogging
      [NSThread sleepForTimeInterval:0.0001];
    }
  }
  if (_debug) NSLog(@"[RomWBW] runLoop ended: shouldRun=%d, isRunning=%d", _shouldRun, _emulator->isRunning());
}

//=============================================================================
// Input
//=============================================================================

- (void)sendCharacter:(unichar)ch {
  _emulator->queueInput((int)ch);
}

- (void)sendString:(NSString*)string {
  for (NSUInteger i = 0; i < string.length; i++) {
    [self sendCharacter:[string characterAtIndex:i]];
  }
}

//=============================================================================
// Debug
//=============================================================================

- (void)setDebug:(BOOL)enable {
  _emulator->setDebug(enable);
}

- (uint16_t)getProgramCounter {
  return _emulator->getPC();
}

- (long long)getInstructionCount {
  return _emulator->getInstructionCount();
}

@end
