/*
 * RomWBW Emulator Bridge
 *
 * Objective-C wrapper for the RomWBW/HBIOS emulator core.
 * Provides interface for SwiftUI integration.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Controlify mode - convert input to control characters
typedef NS_ENUM(NSInteger, RWBControlifyMode) {
    RWBControlifyOff = 0,      // Normal input
    RWBControlifyOneChar = 1,  // Convert next char, then turn off
    RWBControlifySticky = 2    // Convert all chars until turned off
};

@protocol RomWBWEmulatorDelegate <NSObject>
@optional
// Console output
- (void)emulatorDidOutputCharacter:(unichar)ch;

// Status updates
- (void)emulatorDidChangeStatus:(NSString*)status;

// VDA (Video Display Adapter)
- (void)emulatorVDAClear;
- (void)emulatorVDASetCursorRow:(int)row col:(int)col;
- (void)emulatorVDAWriteChar:(unichar)ch;
- (void)emulatorVDAScrollUp:(int)lines;
- (void)emulatorVDASetAttr:(uint8_t)attr;

// Sound
- (void)emulatorBeep:(int)durationMs;

// Input request
- (void)emulatorDidRequestInput;

// Host file transfer (R8/W8 utilities)
- (void)emulatorHostFileRequestRead:(NSString*)suggestedFilename;
- (void)emulatorHostFileDownload:(NSString*)filename data:(NSData*)data;
@end

@interface RomWBWEmulator : NSObject

@property (weak, nonatomic) id<RomWBWEmulatorDelegate> delegate;
@property (readonly, nonatomic) BOOL isRunning;
@property (readonly, nonatomic) BOOL isWaitingForInput;

// Initialization
- (instancetype)init;

// ROM loading
- (BOOL)loadROMFromBundle:(NSString*)filename;
- (BOOL)loadROMFromPath:(NSString*)path;
- (BOOL)loadROMFromData:(NSData*)data;

// Disk management
- (BOOL)loadDisk:(int)unit fromBundle:(NSString*)filename;
- (BOOL)loadDisk:(int)unit fromPath:(NSString*)path;
- (BOOL)loadDisk:(int)unit fromData:(NSData*)data;
- (nullable NSData*)getDiskData:(int)unit;
- (BOOL)saveDisk:(int)unit toPath:(NSString*)path;
- (BOOL)isDiskLoaded:(int)unit;
- (void)closeAllDisks;  // Close all disks before reconfiguring
- (void)setDiskSliceCount:(int)unit slices:(int)slices;  // Set max slices (1-8)

// Boot string (auto-type at boot menu)
- (void)setBootString:(NSString*)bootString;

// Execution control
- (void)start;
- (void)stop;
- (void)reset;

// Input
- (void)sendCharacter:(unichar)ch;
- (void)sendString:(NSString*)string;

// Controlify mode (for Ctrl key modifier)
- (void)setControlify:(RWBControlifyMode)mode;
- (RWBControlifyMode)getControlify;

// Debug
- (void)setDebug:(BOOL)enable;
- (uint16_t)getProgramCounter;
- (long long)getInstructionCount;

@end

NS_ASSUME_NONNULL_END
