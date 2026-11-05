#!/usr/bin/env python3
"""gdb_stub_test.py - the GDB stub in this app's core (docs/gdb.md).

Drives Tests/GdbHost.cc, which is the app's HBIOSEmulator with gdbListen(),
gdbRun() and gdbCancel(), as a debugger would: a small client of the GDB remote
serial protocol, so the test needs no GDB.  Checks:

  * connect: the stop reply, the 26-byte register reply, PC 0000 in ROM bank 00
    with no instruction run, and "monitor status";
  * a step, a memory write into the common RAM (8000H up), a breakpoint in the
    program written there, a second stop at the same breakpoint, a HLT that
    stops with T05 and does not end the machine;
  * ^C (the 03H byte) while the ROM runs and polls the console: T02, and
    D (detach) hands the running machine back to the plain loop;
  * gdbCancel() ends a wait for a debugger, and a session, within a second
    (this is what the Stop button depends on);
  * a port in use is refused, and the stub listens on 127.0.0.1 only unless
    --lan is given (checked with this machine's LAN address, when it has one).

Needs a cached ROM (the CLI of romwbw_emu fetches it: tools/romwbw-get in that
repository).  Skips, with the reason, when the ROM is missing.

Usage: gdb_stub_test.py GDB_HOST_BINARY
"""

import glob
import os
import socket
import subprocess
import sys
import time

failures = []


def check(ok, what):
    print(("PASS" if ok else "FAIL") + ": " + what)
    if not ok:
        failures.append(what)


class Rsp:
    def __init__(self, port, host="127.0.0.1", timeout=15):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.buf = b""

    def send_packet(self, payload):
        d = payload.encode("latin-1")
        self.sock.sendall(b"$" + d + b"#%02x" % (sum(d) & 0xFF))

    def recv(self, timeout=15):
        self.sock.settimeout(timeout)
        while True:
            i = self.buf.find(b"$")
            j = self.buf.find(b"#", i + 1) if i >= 0 else -1
            if i >= 0 and j >= 0 and len(self.buf) >= j + 3:
                body = self.buf[i + 1:j].decode("latin-1")
                self.buf = self.buf[j + 3:]
                self.sock.sendall(b"+")
                return body
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("the stub closed the connection")
            self.buf += chunk

    def cmd(self, payload, timeout=15):
        self.send_packet(payload)
        return self.recv(timeout)

    def monitor(self, text):
        return bytes.fromhex(self.cmd("qRcmd," + text.encode().hex())).decode("latin-1")

    def reg(self, index):
        return int.from_bytes(bytes.fromhex(self.cmd("p%x" % index)), "little")

    def write_mem(self, addr, data):
        return self.cmd("M%x,%x:%s" % (addr, len(data), data.hex()))

    def read_mem(self, addr, n):
        return bytes.fromhex(self.cmd("m%x,%x" % (addr, n)))

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


REG_AF, REG_PC = 0, 5


class Host:
    def __init__(self, binary, rom, disk, port, extra=()):
        argv = [binary, rom, "--port=%d" % port] + list(extra)
        if disk:
            argv.append("--disk0=" + disk)
        self.port = port
        self.t0 = time.time()
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = []

    def wait_listening(self, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline().decode()
            if not line:
                return False
            self.lines.append(line.strip())
            if line.startswith("listening"):
                return True
            if line.startswith("listen failed"):
                return False
        return False

    def finish(self, timeout=30):
        try:
            out, err = self.proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            out, err = self.proc.communicate()
            self.lines.append("(killed after %d s)" % timeout)
        self.lines += out.decode().splitlines()
        self.err = err.decode()
        return self.lines

    def text(self):
        return "\n".join(self.lines)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def lan_address():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.0.2.1", 9))   # no packet is sent; this picks the route
        a = s.getsockname()[0]
        s.close()
        return None if a.startswith("127.") else a
    except OSError:
        return None


def main():
    binary = sys.argv[1] if len(sys.argv) > 1 else None
    if not binary or not os.access(binary, os.X_OK):
        print("FAIL: gdb_stub_test.py needs the gdb_host binary as its argument")
        return 1
    roms = sorted(glob.glob(os.path.expanduser("~/.cache/romwbw_emu/v0/*/assets/emu_avw-v0-*.rom")))
    disks = sorted(glob.glob(os.path.expanduser("~/.cache/romwbw_emu/v0/*/assets/hd1k_cpm22-v0-*.img")))
    if not roms:
        print("SKIP: gdb stub: no cached ROM under ~/.cache/romwbw_emu (romwbw_emu's tools/romwbw-get fetches one)")
        return 0
    rom = roms[-1]
    disk = disks[-1] if disks else None

    # ---- one session: connect, step, breakpoint, HLT, ^C, detach ----
    port = free_port()
    h = Host(binary, rom, disk, port, ["--run-ms=300"])
    check(h.wait_listening(), "the host opens its port (%s)" % (h.lines[-1:] or ["no output"],))
    r = Rsp(port)
    check(r.cmd("?") == "T05", "the stop reply on connect is T05")
    regs = r.cmd("g")
    check(len(regs) == 52, "the register reply is 26 bytes (%d hex digits)" % len(regs))
    check(r.reg(REG_PC) == 0, "no instruction has run: PC is 0000")
    st = r.monitor("status")
    check("pc 0000, CPU bank 00" in st, "monitor status: PC 0000 in ROM bank 00")
    check(r.cmd("s").startswith("T05") and r.reg(REG_PC) != 0, "a step stops with T05 and moves PC")

    # a program in the common RAM, which every bank sees: A counts up in a loop
    prog = bytes([0x3E, 0x00, 0x3C, 0xC3, 0x02, 0x81])   # 8100: LD A,0  8102: INC A  8103: JP 8102
    check(r.write_mem(0x8100, prog) == "OK", "M writes the program into common RAM")
    check(r.read_mem(0x8100, len(prog)) == prog, "m reads the program back")
    check(r.cmd("P%x=%s" % (REG_PC, "0081")) == "OK", "P sets PC to 8100")
    check(r.cmd("Z0,8103,1") == "OK", "Z0 sets a breakpoint at the JP")
    check(r.cmd("c").startswith("T05") and r.reg(REG_PC) == 0x8103, "continue stops at the breakpoint, PC 8103")
    a1 = r.reg(REG_AF) >> 8
    check(a1 == 1, "A is 1 at the first stop (%d)" % a1)
    check(r.cmd("c").startswith("T05") and (r.reg(REG_AF) >> 8) == 2, "continue stops there again, A is 2")
    check(r.cmd("z0,8103,1") == "OK", "z0 removes the breakpoint")
    bt = r.monitor("bt")
    check(bt.startswith("#0"), "monitor bt answers (%r)" % bt[:30])

    # a HLT stops with T05 and the machine is not ended
    check(r.write_mem(0x8200, bytes([0x76, 0x00])) == "OK", "M writes a HLT")
    check(r.cmd("P%x=%s" % (REG_PC, "0082")) == "OK", "P sets PC to 8200")
    check(r.cmd("c").startswith("T05") and r.reg(REG_PC) == 0x8201, "continue stops at the HLT with PC 8201")

    # ^C while the ROM runs: from reset, the boot loader polls the console
    check(r.cmd("P%x=%s" % (REG_PC, "0000")) == "OK", "P sets PC to 0000")
    r.send_packet("c")
    time.sleep(1.5)
    r.sock.sendall(b"\x03")
    t = time.time()
    try:
        reply = r.recv(5)
    except Exception as e:
        reply = "error: %s" % e
    check(reply.startswith("T02"), "^C stops the running ROM with T02 (%s, %.2f s)" % (reply[:8], time.time() - t))
    r.send_packet("D")
    check(r.recv() == "OK", "D detaches")
    r.close()
    h.finish()
    check("gdbRun returned running=1" in h.text(), "after D the machine is still running")
    check("ran PC=" in h.text() and "instructions=0" not in h.text(),
          "the plain loop ran on after the debugger left (%s)" % (h.lines[-1:],))

    # ---- Stop while the stub waits for a debugger ----
    port = free_port()
    h = Host(binary, rom, disk, port, ["--cancel-after-ms=600"])
    h.wait_listening()
    h.finish(20)
    ms = [int(w) for line in h.lines if "gdbRun returned" in line for w in line.split() if w.isdigit()]
    check("gdbRun returned running=0" in h.text() and ms and ms[-1] < 1500,
          "gdbCancel() ends the wait for a debugger (%s)" % ([l for l in h.lines if "gdbRun" in l],))

    # ---- Stop while a debugger has the machine ----
    port = free_port()
    h = Host(binary, rom, disk, port, ["--cancel-after-ms=1500"])
    h.wait_listening()
    r = Rsp(port)
    r.cmd("?")
    t = time.time()
    closed = False
    try:
        reply = r.recv(10)     # nothing is sent to the stub: it is idle, waiting for a packet
        closed = reply.startswith("W")
    except ConnectionError:
        closed = True
    except Exception:
        closed = False
    check(closed, "gdbCancel() ends a session: the debugger is told or the socket closes (%.2f s)" % (time.time() - t))
    r.close()
    h.finish(20)
    check("gdbRun returned running=0" in h.text(), "and the machine stops")

    # ---- a port in use ----
    port = free_port()
    h1 = Host(binary, rom, disk, port, ["--cancel-after-ms=4000"])
    h1.wait_listening()
    h2 = Host(binary, rom, disk, port)
    h2.finish(15)
    check(h2.proc.returncode == 3 and "listen failed" in h2.text() and "in use" in h2.text(),
          "a port in use is refused with the reason (%s)" % (h2.lines[:1],))
    h1.finish(20)

    # ---- loopback only, unless --lan ----
    lan = lan_address()
    if lan is None:
        print("SKIP: no LAN address on this machine: the loopback-only check")
    else:
        port = free_port()
        h = Host(binary, rom, disk, port, ["--cancel-after-ms=2500"])
        h.wait_listening()
        try:
            socket.create_connection((lan, port), timeout=3).close()
            refused = False
        except OSError:
            refused = True
        check(refused, "without --lan the stub refuses %s:%d" % (lan, port))
        h.finish(20)
        port = free_port()
        h = Host(binary, rom, disk, port, ["--lan", "--cancel-after-ms=2500"])
        h.wait_listening()
        try:
            r = Rsp(port, host=lan, timeout=5)
            ok = r.cmd("?") == "T05"
            r.close()
        except OSError:
            ok = False
        check(ok, "with --lan a client on %s:%d connects and gets T05" % (lan, port))
        h.finish(20)

    print("")
    if failures:
        print("%d FAILED" % len(failures))
        return 1
    print("gdb stub: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
