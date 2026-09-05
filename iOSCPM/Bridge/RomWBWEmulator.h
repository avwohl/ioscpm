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

/// The RomWBW releases this build of the emulator core can run, as
/// "3.5.1, 3.6.0". There is no single pinned release any more: the core reads
/// the version out of whichever ROM it loads. Disk slices built by a release
/// OTHER than the loaded ROM's still print an HBIOS/CBIOS version mismatch, so
/// this is worth showing to anyone reporting one.
///
/// For DISPLAY only. It is one formatted string and the format is not a
/// contract; the two calls below are how code asks a question.
+ (NSString*)romWBWReleases;

/// Can this build boot that release?  `ver` and `upd` are RomWBW's own packed
/// bytes - ver = major<<4 | minor, upd = update<<4 | patch, so v3.5.1 is
/// {0x35, 0x10} - which is exactly what index-v0.json publishes as the hex
/// strings `hbios.ver_byte` and `hbios.upd_byte`.
///
/// This is the filter for the release picker. Asking the core beats comparing
/// against a constant in Swift: there is no compile-time pin left to compare
/// with, and a client can be built against a newer or older core than it
/// expects. It is also why nothing parses +romWBWReleases - that would work
/// today and break the first time its format changed.
+ (BOOL)supportsRomWBWVer:(uint8_t)ver upd:(uint8_t)upd NS_SWIFT_NAME(supportsRomWBW(ver:upd:));

/// The release a ROM IMAGE declares, as "3.5.1", or nil when the bytes carry
/// no HBIOS configuration block to read it from.
///
/// Answered from the first 264 bytes (the 'W' 0xA8 marker at 0x103/0x104 and
/// the two version bytes after it), so an image can be inspected before it is
/// loaded - or, as this app uses it, so the release the bundled ROM is for can
/// be read out of the ROM itself rather than asserted by a constant that has
/// to be remembered.
+ (nullable NSString*)romWBWReleaseOfImageData:(NSData*)data
    NS_SWIFT_NAME(romWBWRelease(ofImageData:));

/// The same, for a ROM in the app bundle. `filename` is the bundle name with
/// its extension, e.g. "emu_avw.rom". Nil when it is not in the bundle, cannot
/// be read, or carries no HCB.
+ (nullable NSString*)romWBWReleaseOfBundledROM:(NSString*)filename
    NS_SWIFT_NAME(romWBWRelease(ofBundledROM:));

// ROM loading
- (BOOL)loadROMFromBundle:(NSString*)filename;
- (BOOL)loadROMFromPath:(NSString*)path;
- (BOOL)loadROMFromData:(NSData*)data;

/// Why the last ROM load failed, or nil after a successful load. The three
/// failure modes - not in the bundle, unreadable, rejected by the core's HCB
/// validation - are otherwise indistinguishable to the caller.
@property (readonly, copy, nonatomic, nullable) NSString* lastROMError;

// Disk management
- (BOOL)loadDisk:(int)unit fromBundle:(NSString*)filename;
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
