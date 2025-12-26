/*
 * iOSCPM-Bridging-Header.h - Bridging header for Swift/Objective-C++
 */

#import "RomWBWEmulator.h"

// Host file state enum
typedef enum {
    HOST_FILE_IDLE = 0,
    HOST_FILE_WAITING_READ,
    HOST_FILE_READING,
    HOST_FILE_WRITING,
    HOST_FILE_WRITE_READY
} HostFileState;

// Host file transfer functions for R8/W8 utilities
// Call emu_host_file_load() after user picks a file to read
// Call emu_host_file_cancel() if user cancels the file picker
void emu_host_file_load(const uint8_t* data, size_t size);
void emu_host_file_cancel(void);

// Get current host file state (for polling)
// Note: _c suffix functions are C wrappers for Swift (C++ linkage not accessible)
int emu_host_file_get_state_c(void);

// Get write buffer info (when state == HOST_FILE_WRITE_READY)
const uint8_t* emu_host_file_get_write_data_c(void);
size_t emu_host_file_get_write_size_c(void);
const char* emu_host_file_get_write_name_c(void);

// Clear write data after UI has saved it
void emu_host_file_write_done_c(void);
