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

// Disk flush (called on warm boot when program ends)
- (void)emulatorShouldFlushDisks;
@end

@interface RomWBWEmulator : NSObject

@property (weak, nonatomic) id<RomWBWEmulatorDelegate> delegate;
@property (readonly, nonatomic) BOOL isRunning;
@property (readonly, nonatomic) BOOL isWaitingForInput;

// Initialization
- (instancetype)init;

/// The release the LOADED ROM declares, as "3.5.1", or nil when no ROM has
/// been loaded into this instance yet.
///
/// There is no list of releases this build "can run" to ask for instead, and
/// there has not been one since romwbw_emu v1.44: the core loads any ROM with
/// a readable HBIOS configuration block. So the only honest thing to report is
/// the release actually in memory, and before a ROM is loaded there is no
/// answer at all - which is what nil means here rather than "0.0.0".
///
/// Worth showing to anyone reporting an HBIOS/CBIOS version mismatch: that
/// warning means the disk slices in play were built by a DIFFERENT release
/// from the one this returns.
- (nullable NSString*)loadedRomWBWRelease;

/// The release a ROM IMAGE declares, as "3.5.1", or nil when the bytes carry
/// no HBIOS configuration block to read it from.
///
/// Answered from the first 264 bytes (the 'W' 0xA8 marker at 0x103/0x104 and
/// the two version bytes after it), so an image can be inspected before it is
/// loaded - or, as this app uses it, so the release a DOWNLOADED ROM is for can
/// be read out of the ROM itself rather than asserted by a constant that has
/// to be remembered.
+ (nullable NSString*)romWBWReleaseOfImageData:(NSData*)data
    NS_SWIFT_NAME(romWBWRelease(ofImageData:));

// ROM loading
//
// There is no `loadROMFromBundle:` and no `romWBWReleaseOfBundledROM:` any
// more: this app bundles no ROM, so both could only ever answer "not in the
// bundle". Every ROM arrives as bytes that have been checked against the
// catalog's sha256, which is what `loadROMFromData:` takes - and taking the
// exact bytes that were hashed is the point, since a path leaves room for the
// file to change between the check and the load.
- (BOOL)loadROMFromPath:(NSString*)path;
- (BOOL)loadROMFromData:(NSData*)data;

/// Why the last ROM load failed, or nil after a successful load. The three
/// failure modes - unreadable, rejected by the core's HCB
/// validation - are otherwise indistinguishable to the caller.
@property (readonly, copy, nonatomic, nullable) NSString* lastROMError;

// Disk management
- (BOOL)loadDisk:(int)unit fromPath:(NSString*)path;
- (BOOL)loadDisk:(int)unit fromData:(NSData*)data;
- (nullable NSData*)getDiskData:(int)unit;
- (BOOL)saveDisk:(int)unit toPath:(NSString*)path;
- (BOOL)isDiskLoaded:(int)unit;
- (void)closeAllDisks;  // Close all disks before reconfiguring
- (void)setDiskSliceCount:(int)unit slices:(int)slices;  // Set slices for drive letter assignment

// Boot string (auto-type at boot menu) - DEPRECATED: use setBootOption instead
- (void)setBootString:(NSString*)bootString;

// Boot option - configures NVRAM switches for automatic boot
// Format: "0" = disk unit 0, "0.2" = disk unit 0 slice 2, "C" = ROM app C
- (void)setBootOption:(NSString*)bootOption;

// NVRAM boot configuration - string-based interface
// Format: "C" = CP/M 2.2, "Z" = ZSDOS, "0" = disk 0, "2.3" = disk 2 slice 3, "H" = menu, "" = clear
- (void)setNvramSetting:(NSString*)setting;
- (nullable NSString*)getNvramSetting;
- (BOOL)hasNvramChange;
- (BOOL)isNvramInitialized;

// Manifest disk write warning - warns when writing to auto-updated disks
- (void)setDiskIsManifest:(int)unit isManifest:(BOOL)isManifest;
- (void)setDiskWarningSuppressed:(int)unit suppressed:(BOOL)suppressed;
- (BOOL)pollManifestWriteWarning;

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
