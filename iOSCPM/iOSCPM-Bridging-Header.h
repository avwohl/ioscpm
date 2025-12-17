/*
 * iOSCPM-Bridging-Header.h - Bridging header for Swift/Objective-C++
 */

#import "RomWBWEmulator.h"

// Host file transfer functions for R8/W8 utilities
// Call emu_host_file_load() after user picks a file to read
// Call emu_host_file_cancel() if user cancels the file picker
void emu_host_file_load(const uint8_t* data, size_t size);
void emu_host_file_cancel(void);
