#!/usr/bin/env python3
"""simdrive.py - drive the booted iOS Simulator with synthetic touches.

WHY THIS EXISTS.  MANUAL_CHECKS.md is a list of things "that need a person", and
several of them do not: they need a *gesture*, and a gesture can be synthesised.
On 2026-09-04 the press-and-drag text selection added in build 61 was verified
end to end this way - selection, the edit menu, Copy, Paste, and the proof that
one-finger scrolling still worked - with no device and nobody watching.  That
check would otherwise have shipped as a tick nobody had taken.

Coordinates are SCREENSHOT PIXELS: exactly the numbers you read off

    xcrun simctl io booted screenshot shot.png

There is deliberately no "device points" mode.  Every mistake made while writing
this was a unit confusion - crop pixels read as device points, device points as
window points - and a screenshot pixel is the one coordinate you can actually
see.  Take a screenshot, find the thing, use those numbers.

WHAT MAKES THIS HARD, AND WHY IT VERIFIES ITSELF.  The Simulator window is not
the device screen: there is a title bar above it and a device bezel around it,
and the bezel is the same pure black as a CP/M terminal, so the obvious "find
the black bands" reading happily returns a rect that is inside the app's own
content.  That failure is silent - you get plausible coordinates that land in
the wrong place, and taps that do nothing look exactly like a broken feature.
So calibrate() measures the rect and then CHECKS it, by cropping the window
capture to what it just computed and comparing that against the device's own
screenshot.  A calibration that disagrees is an error, not a result.

    tools/simdrive.py calibrate           measure, verify, print the rect
    tools/simdrive.py shot FILE           device screenshot (a simctl wrapper)
    tools/simdrive.py tap X Y             a tap
    tools/simdrive.py press X Y           press and hold, no drag
    tools/simdrive.py press X Y X2 Y2     press, hold, then drag: a selection
    tools/simdrive.py swipe X1 Y1 X2 Y2   a flick: a scroll
    tools/simdrive.py where X Y           what global point X Y maps to

Options:  --udid UDID    target a specific device
          --hold SECS    press-and-hold duration (default 0.9; UIKit wants 0.5)
          --quiet        print nothing on success

Exit 0 = done.  Exit 1 = it ran and the answer was wrong (calibration disagreed
with the device screenshot).  Exit 2 = could not run at all: no booted device,
no Simulator window, a missing module, a capture that came back blank.  A tool
that cannot verify must not say yes.

PERMISSIONS.  Posting synthetic events needs Accessibility, and capturing the
window needs Screen Recording; both are granted to the *terminal*, not to this
script.  If taps move the cursor but nothing happens, it is Accessibility; if
the capture is uniform, it is Screen Recording.

TWO TRAPS THAT COST AN HOUR EACH, now handled here:

  * The Simulator must be ACTIVATED before the first event, or macOS spends that
    click raising the window and the app never sees it.  A tap that "does
    nothing" is almost always this.
  * `simctl boot "iPhone 17 Pro"` can leave a DIFFERENT device booted, and a
    different device has a different screen, so every coordinate silently
    shifts.  This boots nothing and refuses to guess: it fails unless exactly
    one device is booted, or --udid names one.

AND ONE THIS FILE CANNOT HANDLE.  **Xcode 27 ships no Simulator.app.**  The
device is drawn inside DeviceHub, which this file now finds and calibrates
inside correctly - but DeviceHub's mirror IGNORES synthetic mouse events.
Measured 2026-09-21 against kCGHIDEventTap, kCGSessionEventTap and
kCGAnnotatedSessionEventTap, and with CGEventSources for all three source
states, while a click on DeviceHub's OWN toolbar in the same run worked.  So on
such a machine `calibrate`, `shot` and `where` answer and `tap`, `press` and
`swipe` post events nothing receives - with no error, because there is nothing
to detect.  Drive the Mac Catalyst build instead: it is an ordinary Mac app,
it takes these same events and System Events keystrokes, and it runs the same
views.  See MANUAL_CHECKS.md.

Synthetic KEY events are a separate matter and still do not reach the app - see
MANUAL_CHECKS.md check 3.  Type by tapping the on-screen keyboard instead, which
is what this drives.
"""

import subprocess
import sys
import time

# The command list alone. A usage error wants the commands, not the essay;
# --help prints the whole docstring.
USAGE = "\n".join([
    "usage: simdrive.py COMMAND [ARGS]   (coordinates are SCREENSHOT PIXELS)",
    "",
    "  calibrate            measure, verify and print the screen rect",
    "  shot FILE            device screenshot (a simctl wrapper)",
    "  tap X Y              a tap",
    "  press X Y            press and hold, no drag",
    "  press X Y X2 Y2      press, hold, then drag: a selection",
    "  swipe X1 Y1 X2 Y2    a flick: a scroll",
    "  where X Y            what global point X Y maps to",
    "",
    "  --udid UDID   --hold SECS   --quiet   --help",
])

EXIT_OK, EXIT_WRONG, EXIT_CANNOT = 0, 1, 2


def die(code, message):
    print(f"simdrive: {message}", file=sys.stderr)
    sys.exit(code)


try:
    import Quartz
except ImportError:
    die(EXIT_CANNOT, "no Quartz module. pyobjc is needed:\n"
                     "  python3 -m pip install --user --break-system-packages pyobjc-framework-Quartz")
try:
    from PIL import Image, ImageChops
except ImportError:
    die(EXIT_CANNOT, "no PIL module. Pillow is needed:\n"
                     "  python3 -m pip install --user --break-system-packages Pillow")


# --- the device -------------------------------------------------------------

def simctl(*args, check=True):
    """Run xcrun simctl with Xcode selected, which xcode-select may not be."""
    env_prefix = ["env", "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"]
    proc = subprocess.run(env_prefix + ["xcrun", "simctl", *args],
                          capture_output=True, text=True)
    if check and proc.returncode != 0:
        die(EXIT_CANNOT, f"simctl {' '.join(args)} failed:\n{proc.stderr.strip()}")
    return proc.stdout


def booted_device(udid=None):
    """The one booted device, or the one named. Never boots anything."""
    listing = simctl("list", "devices", "booted")
    devices = []
    for line in listing.splitlines():
        line = line.strip()
        if "(Booted)" not in line or "(" not in line:
            continue
        name = line.split("(")[0].strip()
        ident = line.split("(")[1].split(")")[0]
        devices.append((name, ident))
    if not devices:
        die(EXIT_CANNOT, "no booted device. Boot one BY UDID and check it took:\n"
                         "  xcrun simctl boot <udid> && xcrun simctl list devices booted")
    if udid:
        for name, ident in devices:
            if ident == udid:
                return name, ident
        die(EXIT_CANNOT, f"{udid} is not booted. Booted: "
                         + ", ".join(f"{n} {i}" for n, i in devices))
    if len(devices) > 1:
        die(EXIT_CANNOT, "more than one device is booted, so the screen is ambiguous.\n"
                         "Pass --udid, or shut the others down. Booted: "
                         + ", ".join(f"{n} {i}" for n, i in devices))
    return devices[0]


def device_screenshot(path, udid="booted"):
    simctl("io", udid, "screenshot", "--type=png", path)
    return Image.open(path).convert("RGB")


# --- the window -------------------------------------------------------------

# WHICH APP DRAWS THE DEVICE IS NOT A CONSTANT.  Simulator.app was the answer
# through Xcode 26; Xcode 27 does not ship it at all and draws the screen inside
# DeviceHub instead.  The two are not interchangeable geometry: Simulator.app's
# window IS the device, DeviceHub's has a sidebar of devices down the left, so
# the screen sits off to one side of it.  Everything below therefore NAMES the
# owner rather than assuming it, and calibrate() no longer derives the width
# from the screen being centred - see _seed_centred and _seed_searched.
#
# Matched with the spaces taken out and the case folded, because the two
# spellings of the same app do not agree with each other: the bundle and the
# System Events process are "DeviceHub", and kCGWindowOwnerName is "Device Hub".
WINDOW_OWNERS = ("simulator", "devicehub")


def device_window():
    """The window showing the device: (pid, x, y, w, h), bounds in points."""
    listing = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements,
        Quartz.kCGNullWindowID)
    windows = [w for w in listing
               if (w.get("kCGWindowOwnerName") or "").replace(" ", "").lower()
                  in WINDOW_OWNERS
               and (w.get("kCGWindowName") or "")
               and dict(w.get("kCGWindowBounds") or {}).get("Height", 0) > 200]
    if not windows:
        die(EXIT_CANNOT,
            "no device window on screen. Open whichever one your Xcode ships and\n"
            "select the booted device in it:\n"
            "  open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app\n"
            "  open -a Simulator          # Xcode 26 and earlier only")
    if len(windows) > 1:
        names = ", ".join(str(w.get("kCGWindowName")) for w in windows)
        die(EXIT_CANNOT, f"more than one device window: {names}. Close the others.")
    bounds = dict(windows[0]["kCGWindowBounds"])
    return (int(windows[0].get("kCGWindowOwnerPID") or 0),
            bounds["X"], bounds["Y"], bounds["Width"], bounds["Height"])


def activate():
    """Raise the app that owns the window, or the first event raises it.

    By PID, not by name: `tell application "Device Hub"` does not resolve, and
    the one thing the window listing gives that cannot be spelled two ways is
    the process it belongs to.
    """
    pid = device_window()[0]
    subprocess.run(["osascript", "-e",
                    'tell application "System Events" to set frontmost of '
                    f'(first process whose unix id is {pid}) to true'],
                   capture_output=True)
    time.sleep(1.0)


def capture_window(path):
    _pid, x, y, w, h = device_window()
    subprocess.run(["screencapture", "-x", "-R", f"{x},{y},{w},{h}", path], check=True)
    image = Image.open(path).convert("RGB")
    extrema = image.convert("L").getextrema()
    if extrema[1] - extrema[0] < 8:
        die(EXIT_CANNOT, "the window capture is a flat colour. That is normally the\n"
                         "Screen Recording permission missing for this terminal.")
    return image, (x, y, w, h)


# --- calibration ------------------------------------------------------------

def _first_black_run(row, threshold=45, minimum=8):
    """Start and end of the first dark run - the left bezel."""
    start = None
    for i, value in enumerate(row):
        if value <= threshold and start is None:
            start = i
        elif value > threshold and start is not None:
            if i - start >= minimum:
                return start, i - 1
            start = None
    return None


# The comparison used everywhere below: mean absolute difference between a
# rectangle of the window capture and the device's own screenshot, 0 = identical
# and 1 = black against white.  It goes through a histogram rather than a Python
# loop because calibrate() now calls it tens of thousands of times.
_FINE = (48, 104)       # the size the answer is judged at
_COARSE = (24, 52)      # the size the coarse search is run at


def _mad(window_grey, target, left, top, width, height, size):
    box = (int(round(left)), int(round(top)),
           int(round(left + width)), int(round(top + height)))
    box = (max(0, box[0]), max(0, box[1]),
           min(window_grey.width, box[2]), min(window_grey.height, box[3]))
    if box[2] - box[0] < 8 or box[3] - box[1] < 8:
        return 1.0
    crop = window_grey.crop(box).resize(size)
    hist = ImageChops.difference(crop, target).histogram()
    return sum(i * n for i, n in enumerate(hist)) / (size[0] * size[1] * 255.0)


def _seed_centred(window, device):
    """Simulator.app's reading: the screen is centred, so one bezel is enough.

    Kept because it is the reading that was measured to work, and because it
    costs nothing.  It returns None rather than a guess when the window is not
    that shape, which is what DeviceHub's - with a sidebar down the left - is.
    """
    grey = window.convert("L")
    W, H = grey.size
    pixels = grey.load()

    # The LEFT bezel is the one edge that is never ambiguous: the app paints
    # something against it. The RIGHT one is not - a black terminal runs into
    # the bezel and reads as one run - so width comes from the screen being
    # centred in the window rather than from finding the far edge.
    run = _first_black_run([pixels[x, int(H * 0.5)] for x in range(W)])
    if run is None:
        return None
    left = run[1] + 1
    width = W - 2 * left
    if width <= 8:
        return None
    height = width * device.height / device.width

    # The bottom bezel gives the vertical position. The top cannot: the window
    # title bar is dark too and merges into the top bezel.
    #
    # It has to be the START of the bottom bezel's dark run, not the first dark
    # pixel scanning up from the window's edge. Below the bezel is the DESKTOP,
    # which is bright, so scanning up finds the desktop and puts the screen
    # flush with the window - a 14-point error that still scored 91% agreement,
    # which is exactly why the agreement check alone is not enough.
    column = [pixels[left + width // 2, y] for y in range(H)]
    dark_runs, start = [], None
    for y, value in enumerate(column):
        if value <= 45 and start is None:
            start = y
        elif value > 45 and start is not None:
            if y - start >= 6:
                dark_runs.append((start, y - 1))
            start = None
    if start is not None and len(column) - start >= 6:
        dark_runs.append((start, len(column) - 1))
    trailing = [r for r in dark_runs if r[0] > H * 0.80]
    if not trailing:
        return None
    bottom = min(trailing, key=lambda r: r[0])[0] - 1
    return left, bottom - height + 1, width


def _seed_searched(window, device):
    """Assume nothing about where the screen is; find the rect that matches it.

    DeviceHub places the phone beside a list of devices, so no edge of the
    window places the screen and no bezel reading survives being wrong about
    which side the chrome is on.  What DOES place it is the screen itself: the
    device screenshot is the answer, and the rect is whichever one reproduces
    it.  Run coarse and small - a 320-pixel copy and a 24x52 comparison - since
    this only has to land close enough for _refine() to finish the job.
    """
    scale = 320.0 / window.width
    small = window.convert("L").resize(
        (320, max(1, int(round(window.height * scale)))))
    target = device.convert("L").resize(_COARSE)
    ratio = device.height / device.width
    W, H = small.size

    best = None
    widest = min(W, int(H / ratio))
    if widest < 24:
        return None
    for width in range(max(24, int(W * 0.10)), widest + 1, 3):
        height = width * ratio
        for left in range(0, W - width + 1, 3):
            for top in range(0, int(H - height) + 1, 3):
                error = _mad(small, target, left, top, width, height, _COARSE)
                if best is None or error < best[0]:
                    best = (error, left, top, width)
    if best is None:
        return None
    _error, left, top, width = best
    return left / scale, top / scale, width / scale


def _refine(window_grey, target, left, top, width, ratio):
    """Hill-climb the rect at full judging size. Width is free, not centred."""
    best = (_mad(window_grey, target, left, top, width, width * ratio, _FINE),
            left, top, width)
    for span, step in ((16, 4), (4, 1)):
        for _round in range(6):
            _error, bl, bt, bw = best
            for dleft in range(-span, span + 1, step):
                for dtop in range(-span, span + 1, step):
                    for dwidth in range(-span, span + 1, step):
                        width2 = bw + dwidth
                        if width2 < 16:
                            continue
                        left2, top2 = bl + dleft, bt + dtop
                        error = _mad(window_grey, target, left2, top2,
                                     width2, width2 * ratio, _FINE)
                        if error < best[0] - 1e-9:
                            best = (error, left2, top2, width2)
            if best[1:] == (bl, bt, bw):
                break
    return best


def calibrate(verbose=True):
    """The device screen's rect in global screen points, measured and checked."""
    shot_path, window_path = "/tmp/_simdrive_dev.png", "/tmp/_simdrive_win.png"
    device = device_screenshot(shot_path)
    window, (wx, wy, ww, wh) = capture_window(window_path)

    window_grey = window.convert("L")
    target = device.convert("L").resize(_FINE)
    ratio = device.height / device.width
    per_point = window.width / ww

    # REFINE, don't just report. Both readings above are estimates, and the
    # bezel one was wrong by 14 points the first time it was written, so each is
    # treated as a starting point and the answer is the rect that best matches
    # the device's own screenshot. This is what makes the agreement number
    # meaningful: a calibration that is merely plausible loses to one that is
    # right, instead of being accepted because it scored well enough.
    seeds = [s for s in (_seed_centred(window, device),
                         _seed_searched(window, device)) if s is not None]
    if not seeds:
        die(EXIT_CANNOT, "could not find the device screen anywhere in the window.")

    best = None
    for left, top, width in seeds:
        candidate = _refine(window_grey, target, left, top, width, ratio)
        if best is None or candidate[0] < best[0]:
            best = candidate
    error, left, top, width = best
    height = width * ratio

    rect = (wx + left / per_point, wy + top / per_point,
            width / per_point, height / per_point)

    if verbose:
        print(f"window  {wx:.0f},{wy:.0f} {ww:.0f}x{wh:.0f}")
        print(f"screen  {rect[0]:.1f},{rect[1]:.1f} {rect[2]:.1f}x{rect[3]:.1f} pt")
        print(f"device  {device.width}x{device.height} px")
        print(f"agreement  {(1 - error) * 100:.1f}%")
    # A correct calibration scores ~99% here and the 14-point error that shipped
    # in the first draft of this file scored 91%, so the bar sits between them.
    if error > 0.05:
        die(EXIT_WRONG,
            f"calibration disagrees with the device screenshot ({(1-error)*100:.1f}% agreement).\n"
            "The refined rect is still not where the screen is, so every coordinate would\n"
            "be wrong. Usually the screen is showing something nearly uniform - a boot\n"
            "logo, a blank terminal - and there is nothing to match against. Bring up a\n"
            "screen with light content and retry; do NOT use the numbers above.")
    return rect, device.size


# --- events -----------------------------------------------------------------

class Screen:
    def __init__(self, rect, device_size):
        self.rect = rect
        self.device_size = device_size

    def to_global(self, px, py):
        """A screenshot pixel -> a point on the Mac's screen."""
        x, y, w, h = self.rect
        dw, dh = self.device_size
        return (x + (px / dw) * w, y + (py / dh) * h)


def post(kind, x, y):
    Quartz.CGEventPost(Quartz.kCGHIDEventTap,
        Quartz.CGEventCreateMouseEvent(None, kind, (x, y), Quartz.kCGMouseButtonLeft))


def tap(screen, px, py):
    x, y = screen.to_global(px, py)
    post(Quartz.kCGEventMouseMoved, x, y); time.sleep(0.25)
    post(Quartz.kCGEventLeftMouseDown, x, y); time.sleep(0.09)
    post(Quartz.kCGEventLeftMouseUp, x, y); time.sleep(0.6)


def press(screen, px, py, px2=None, py2=None, hold=0.9, steps=25):
    """Press, hold past minimumPressDuration, optionally drag, lift."""
    x1, y1 = screen.to_global(px, py)
    x2, y2 = screen.to_global(px2, py2) if px2 is not None else (x1, y1)
    post(Quartz.kCGEventMouseMoved, x1, y1); time.sleep(0.35)
    post(Quartz.kCGEventLeftMouseDown, x1, y1)
    time.sleep(hold)                       # hold STILL: movement fails the press
    if (x2, y2) != (x1, y1):
        for i in range(1, steps + 1):
            t = i / steps
            post(Quartz.kCGEventLeftMouseDragged,
                 x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
            time.sleep(0.035)
        time.sleep(0.4)
    post(Quartz.kCGEventLeftMouseUp, x2, y2); time.sleep(0.8)


def swipe(screen, px1, py1, px2, py2, steps=20):
    """A flick. Fast enough that the pan wins the gesture, not the long press."""
    x1, y1 = screen.to_global(px1, py1)
    x2, y2 = screen.to_global(px2, py2)
    post(Quartz.kCGEventMouseMoved, x1, y1); time.sleep(0.25)
    post(Quartz.kCGEventLeftMouseDown, x1, y1); time.sleep(0.05)
    for i in range(1, steps + 1):
        t = i / steps
        post(Quartz.kCGEventLeftMouseDragged, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t)
        time.sleep(0.02)
    post(Quartz.kCGEventLeftMouseUp, x2, y2); time.sleep(0.7)


# --- cli --------------------------------------------------------------------

def main(argv):
    udid, hold, quiet = None, 0.9, False
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--udid":
            udid = argv[i + 1]; i += 2
        elif argv[i] == "--hold":
            hold = float(argv[i + 1]); i += 2
        elif argv[i] == "--quiet":
            quiet = True; i += 1
        elif argv[i] in ("-h", "--help"):
            print(__doc__); return EXIT_OK
        else:
            args.append(argv[i]); i += 1

    if not args:
        print(USAGE, file=sys.stderr)
        return EXIT_CANNOT
    command = args[0]

    name, ident = booted_device(udid)
    if not quiet:
        print(f"device  {name} {ident}")

    # `shot` takes a FILENAME; everything else takes numbers. Coercing the
    # arguments before dispatching turned `shot out.png` into a ValueError.
    if command == "shot":
        path = args[1] if len(args) > 1 else "shot.png"
        simctl("io", ident, "screenshot", "--type=png", path)
        if not quiet:
            print(f"wrote   {path}")
        return EXIT_OK

    try:
        rest = [int(float(v)) for v in args[1:]]
    except ValueError:
        die(EXIT_CANNOT, f"{command} takes screenshot pixel coordinates, not {args[1:]!r}")

    activate()
    rect, device_size = calibrate(verbose=not quiet)
    screen = Screen(rect, device_size)

    if command == "calibrate":
        return EXIT_OK
    if command == "where":
        print("global  %.1f,%.1f" % screen.to_global(rest[0], rest[1]))
        return EXIT_OK
    if command == "tap":
        tap(screen, rest[0], rest[1])
    elif command == "press":
        press(screen, *rest[:4], hold=hold) if len(rest) >= 4 \
            else press(screen, rest[0], rest[1], hold=hold)
    elif command == "swipe":
        swipe(screen, *rest[:4])
    else:
        print(USAGE, file=sys.stderr)
        return EXIT_CANNOT
    if not quiet:
        print(f"did     {command} {' '.join(str(v) for v in rest)}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
