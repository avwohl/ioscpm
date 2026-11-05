# Debug a Z80 program with GDB or udb80

The app has a GDB stub. GDB and udb80 can connect to the emulated machine
over TCP. They use the GDB remote serial protocol (RSP). The stub is the same
code as in cpmemu and romwbw_emu. The full description of the protocol and of
the monitor commands is in these documents:

- [gdb_stub.md](https://github.com/avwohl/cpmemu/blob/main/docs/gdb_stub.md) (cpmemu)
- [gdb.md](https://github.com/avwohl/um80_and_friends/blob/main/docs/gdb.md) (GDB with the Z80 target)
- [udb80.md](https://github.com/avwohl/um80_and_friends/blob/main/docs/udb80.md)

## What you need

- GDB 18.1 with the Z80 target. The Homebrew formula `gdb` has the target.
- Or udb80: `pip install "um80>=0.4.1"`. udb80 needs no GDB.
- A program that you built with `um80 --debug-info` and `ul80 --debug-info`.
  The tools write `PROG.dbg`. For GDB, run `dbg2elf PROG.dbg`.

## Turn the stub on

The stub is off. To start the stub:

1. Open Settings. Find the section "GDB Debugger".
2. Set "GDB Stub" to on.
3. Set the port. The default port is 1234.
4. Press Play.

The settings are read when you press Play. You cannot open Settings while the
machine runs.

When the stub is on, the machine does not start at once. The machine waits for
the debugger before the first instruction. The status bar and the terminal show
the address to use, for example:

```
Waiting for GDB: target remote 127.0.0.1:1234
```

When the debugger connects, the status bar shows "GDB connected". The
Stop button ends the wait, and ends the session.

If the port is in use, the app shows an error and does not start the machine.

## Connect from the same Mac

The iOS Simulator and the Mac app (Mac Catalyst) use the loopback of the Mac.
Leave "Allow Connections From the Network" off. Connect on the same Mac:

```
gdb PROG.elf
(gdb) target remote 127.0.0.1:1234
```

or:

```
udb80 PROG.dbg --connect 127.0.0.1:1234 --wait-program
```

## Connect to an iPhone or an iPad

A debugger on another computer cannot reach 127.0.0.1 of the device.

1. In Settings, set "Allow Connections From the Network" to on. The stub then
   listens on every interface (0.0.0.0).
2. Put the device and the computer on the same Wi-Fi network.
3. Press Play. The status bar shows the address of the device and the port.
   Settings shows the addresses too.
4. On the computer, connect to the Wi-Fi address of the device:

```
(gdb) target remote 192.168.1.20:1234
udb80 PROG.dbg --connect 192.168.1.20:1234 --wait-program
```

iOS can ask for permission for "Local Network". Allow the permission. The app
has the text for the question in `NSLocalNetworkUsageDescription`. If you
refused, open the Settings app of iOS, find this app, and set Local Network to on.

A Mac app can use the same switch to accept a debugger from another computer.
The app has the sandbox right to accept incoming connections.

## The risk

**The stub has no password.** With "Allow Connections From the Network" on,
anyone who can reach the port can read and write the memory of the emulated
machine and can control the machine. Use the switch only on a network that you
trust. Use the switch only while you debug. Set the switch to off after that.

With the switch off, only programs on the same device can connect. For the
Simulator, programs on the same Mac can connect. The app shows this warning in
Settings.

## Start a CP/M program with a debugger

CP/M loads a program at 0100H in bank 8EH. The program is not in memory when
the debugger connects. Use `monitor wait-program`. The stub stops when the
program starts.

With udb80, add `--wait-program`. Then press Play, and type the name of the
program in the app when the CP/M prompt shows. udb80 stops at 0100H.

With GDB, restrict the breakpoints to bank 8EH. Do this before `continue`:

```
(gdb) monitor break-bank 8E
(gdb) monitor wait-program sha256 LENGTH HEX64
(gdb) break *0x100
(gdb) continue
```

LENGTH and the SHA-256 are in `image.length` and `image.sha256` of
`PROG.dbg`. Without `monitor break-bank 8E`, GDB stops at 0100H in the ROM
before CP/M runs. Without `break *0x100`, GDB does not show the stop.

## Limits

- One debugger. After the debugger detaches, the stub does not accept a
  second one. Press Stop and Play again.
- The stub listens on IPv4 only.
- No watchpoints.
- A HLT in the program stops the program with a signal. The debugger can go on.
- The machine does not run while the debugger holds the program. The app does not
  run the program until you continue.
- Test results: the stub in the core of the app works with GDB 18.1, udb80 and
  a raw RSP client on a Mac (`Tests/gdb_stub_test.py`). Nobody has used the
  Settings screen and the Play button with a debugger. Nobody has tried a real
  iPhone or iPad, or the Local Network permission.
