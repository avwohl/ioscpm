/*
 * The socket layer of the GDB stub for this port (docs/gdb.md).
 *
 * gdbstub.cc is cpmemu's and calls the platform:: functions of cpmemu's
 * os/platform.h.  gdb_platform_ios.cc defines the ones it uses.  The part that
 * is this port's own is the cancel flag: romwbw_emu's gdb_platform.cc blocks
 * in accept() and recv() until a debugger acts, which is right for a command
 * line program that ^C ends and wrong for an app whose Stop button must end a
 * wait for a debugger.
 */

#ifndef GDB_PLATFORM_IOS_H
#define GDB_PLATFORM_IOS_H

// The calling thread's cancel flag.  While the flag is true, net_accept()
// returns kNoSocket and net_recv() answers 0 (the peer closed), so the stub
// gives the program back.  Set it on the emulation thread before the stub
// waits and clear it (pass nullptr) afterwards.  A thread_local pointer, so a
// second emulation session on another thread has a flag of its own.
void gdb_platform_set_cancel(const volatile bool* flag);

// Why the last net_listen() on this thread failed, as text for the person
// ("Address already in use"), or "" when none has failed.
const char* gdb_platform_last_error();

#endif  // GDB_PLATFORM_IOS_H
