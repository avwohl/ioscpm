/*
 * CPMEmulator.h - Objective-C bridge for CP/M emulator
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CPMEmulatorDelegate <NSObject>
- (void)emulatorDidOutputCharacter:(unichar)character;
- (void)emulatorDidChangeStatus:(NSString *)status;
@optional
- (void)emulatorDidRequestInput;
@end

@interface CPMEmulator : NSObject

@property (nonatomic, weak, nullable) id<CPMEmulatorDelegate> delegate;
@property (nonatomic, readonly) BOOL isRunning;

// Initialization
- (instancetype)init;

// System loading
- (BOOL)loadSystemFromData:(NSData *)data;
- (BOOL)loadDiskA:(NSData *)data;
- (BOOL)loadDiskB:(NSData *)data;

// Emulation control
- (void)start;
- (void)stop;
- (void)reset;

// Console I/O
- (void)sendKey:(unichar)character;
- (void)sendString:(NSString *)string;

// Disk management
- (nullable NSData *)getDiskAData;
- (nullable NSData *)getDiskBData;
- (void)createEmptyDiskA;
- (void)createEmptyDiskB;

// CPU state
- (uint16_t)programCounter;
- (uint16_t)stackPointer;

@end

NS_ASSUME_NONNULL_END
