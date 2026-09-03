//
//  WindowFrameTests.swift
//
//  What happens to a remembered Mac Catalyst window frame when the machine it
//  comes back on is not the machine it was saved on.
//
//  `todo.txt` had "no Catalyst window-state persistence" as a parity gap: the
//  app opened at the system default every launch. Remembering the frame is
//  easy; the part worth testing is refusing to restore one, because every way
//  that goes wrong goes wrong on a Mac, where a window placed off every display
//  cannot be dragged back and the app looks like it failed to launch.
//
//  The UIKit calls that read and move the window are in CatalystWindow.swift
//  and cannot be run here - there is no Mac Catalyst build on this machine.
//  What CAN be checked is every decision they make, which is why those
//  decisions are in WindowFrame and not in the UIKit file.
//
//  Run with Tests/run_tests.sh.
//

import Foundation
import CoreGraphics

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition { failures += 1 }
    print("\(condition ? "PASS" : "FAIL"): \(label)")
}

func section(_ title: String) {
    print("\n\(title)")
    print(String(repeating: "-", count: 60))
}

func section(_ title: String, _ body: () -> Void) {
    section(title)
    body()
}

/// A 1920x1080 display at the origin - the frame every case below is judged in
/// unless it says otherwise.
let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

func frame(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> WindowFrame {
    WindowFrame(CGRect(x: x, y: y, width: w, height: h))
}

func runAllTests() {

    section("Round-tripping through UserDefaults") {
        let f = frame(120, 80, 1000, 700)
        let back = WindowFrame(defaultsValue: f.defaultsValue)
        check(back == f, "a frame survives being written and read back")
        check(f.defaultsValue.count == 4, "as four plain numbers a person can read in the plist")

        check(WindowFrame(defaultsValue: nil) == nil, "a missing value is not a frame")
        check(WindowFrame(defaultsValue: "1000x700") == nil, "and neither is a string")
        check(WindowFrame(defaultsValue: [1.0, 2.0, 3.0]) == nil, "nor three numbers")
        check(WindowFrame(defaultsValue: [1.0, 2.0, 3.0, 4.0, 5.0]) == nil, "nor five")
        check(WindowFrame(defaultsValue: [0.0, 0.0, Double.nan, 700.0]) == nil,
              "nor one with a NaN in it")
        check(WindowFrame(defaultsValue: [0.0, 0.0, Double.infinity, 700.0]) == nil,
              "nor an infinite one")
    }

    section("What is worth saving at all") {
        check(frame(0, 0, 1200, 800).isWorthSaving, "an ordinary window is saved")
        check(frame(0, 0, 640, 480).isWorthSaving, "and one exactly at the minimum")
        check(!frame(0, 0, 0, 0).isWorthSaving,
              "a zero frame is not - that is what a scene reports before it is laid out")
        check(!frame(0, 0, 320, 240).isWorthSaving, "nor anything under the minimum")
        check(!frame(0, 0, 1200, 100).isWorthSaving, "a window can be too short as well as too narrow")
        check(!frame(.nan, 0, 1200, 800).isWorthSaving, "nor one at a nonsensical position")
    }

    section("Restoring onto the same display") {
        let f = frame(200, 150, 1200, 800)
        check(f.restorable(in: screen) == CGRect(x: 200, y: 150, width: 1200, height: 800),
              "a frame that still fits comes back exactly as it was")
    }

    section("Restoring onto a smaller display") {
        // Saved on a 6K display, opened on a laptop.
        let big = frame(0, 0, 5120, 2880)
        let laptop = CGRect(x: 0, y: 0, width: 1440, height: 900)
        guard let got = big.restorable(in: laptop) else {
            check(false, "a too-large frame still restores, clamped"); return
        }
        check(got.width <= laptop.width && got.height <= laptop.height,
              "a window larger than the display is clamped to it")
        check(got.minX >= laptop.minX && got.maxX <= laptop.maxX, "and stays within it horizontally")
        check(got.minY >= laptop.minY && got.maxY <= laptop.maxY, "and vertically")
    }

    section("Restoring onto a display the window is no longer on") {
        // The second monitor is gone: the frame is far off to the right.
        let offscreen = frame(3000, 200, 1200, 800)
        guard let got = offscreen.restorable(in: screen) else {
            check(false, "an off-screen frame is pulled back rather than discarded"); return
        }
        let visible = got.intersection(screen)
        check(visible.width >= WindowFrame.minimumVisible.width,
              "a window off the right of every display is pulled back onto one")
        check(visible.height >= WindowFrame.minimumVisible.height, "in both directions")
        check(got.size == CGSize(width: 1200, height: 800),
              "and keeps the size it was saved at - only the position had stopped making sense")

        let above = frame(200, -2000, 1200, 800)
        let gotAbove = above.restorable(in: screen)
        check(gotAbove != nil && gotAbove!.intersection(screen).height >= WindowFrame.minimumVisible.height,
              "a window above the top of the display is pulled back too")

        // A window mostly off the edge but with enough left to grab is left
        // where the user put it: they may have parked it there deliberately.
        let mostlyOff = frame(1820, 100, 1200, 800)
        check(mostlyOff.restorable(in: screen) == mostlyOff.rect,
              "a window hanging off the edge with a grabbable corner is left alone")
    }

    section("Frames that are refused outright") {
        check(frame(0, 0, 100, 100).restorable(in: screen) == nil,
              "a frame below the minimum size is not restored - the app would open unusable")
        check(frame(0, 0, 0, 0).restorable(in: screen) == nil, "nor a zero one")
        check(frame(0, 0, 1200, 800).restorable(in: .zero) == nil,
              "and nothing is restored onto a display of no size")
    }

    section("The minimum survives the clamps") {
        // A tiny display is the one case where the minimum cannot be honoured;
        // the result must still be no bigger than the display.
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let got = frame(0, 0, 1200, 800).restorable(in: tiny) else {
            check(false, "a frame still restores onto a tiny display"); return
        }
        check(got.width <= tiny.width && got.height <= tiny.height,
              "on a display smaller than the minimum, the display wins")

        guard let ok = frame(0, 0, 700, 500).restorable(in: screen) else {
            check(false, "an ordinary frame restores"); return
        }
        check(ok.width >= WindowFrame.minimumSize.width, "otherwise the minimum width is honoured")
        check(ok.height >= WindowFrame.minimumSize.height, "and the minimum height")
    }

    section("The minimum is big enough for what it is protecting") {
        // 80 columns is the whole point of the window; the minimum has to leave
        // room for them alongside the side toolbar and the key row.
        check(WindowFrame.minimumSize.width >= 640, "the minimum is at least 640 points wide")
        check(WindowFrame.minimumSize.height >= 400, "and tall enough for 25 rows and the chrome")
        check(WindowFrame.minimumVisible.width < WindowFrame.minimumSize.width,
              "and what must stay visible is smaller than the window itself")
    }

    section("Restoring onto a display that does not start at the origin") {
        // A second monitor to the right of the main one.
        let second = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let f = frame(2000, 100, 1200, 800)
        check(f.restorable(in: second) == f.rect, "a window on the second display is left where it is")

        let stray = frame(-3000, 100, 1200, 800)
        guard let got = stray.restorable(in: second) else {
            check(false, "a stray frame restores onto the second display"); return
        }
        check(got.intersection(second).width >= WindowFrame.minimumVisible.width,
              "and one nowhere near it is pulled onto it, not to the origin")
    }
}

@main
enum WindowFrameTestMain {
    static func main() {
        runAllTests()
        print("\n" + String(repeating: "=", count: 60))
        print("Results: \(checks - failures) passed, \(failures) failed")
        if failures > 0 {
            print("Some tests failed")
            exit(1)
        }
        print("All tests passed")
        exit(0)
    }
}
