//
//  TerminalRenditionTests.swift
//
//  What a program actually gets when it sends an SGR sequence.
//
//  `todo.txt` has carried "the CSI parser has no unit tests" since build 51,
//  and build 54's colour fix was found on a simulator rather than by a test.
//  This closes the SGR half of that item: TerminalRendition is a pure value
//  with no screen, no emulator and no UIKit behind it, so the whole of
//  `CSI ... m` can be driven here.
//
//  Three of the four things pinned below were absent or wrong in build 54 and
//  came from the sibling ports:
//
//    - the bright half, SGR 90-97 and 100-107, which this port was the last of
//      the three to have (z80cpmw found it with a suite that reads pixels;
//      cpmdroid has carried 90-97 since its own ANSI fix)
//    - the extended-colour forms, ESC[38;5;<n>m and ESC[38;2;<r>;<g>;<b>m,
//      whose sub-parameters were read as colours in their own right, so the
//      "44" of ESC[38;5;44m set a red background
//    - the per-cell face flags, which SGR 1, 4, 5 and 7 were parsed into
//      nothing for
//
//  Run with Tests/run_tests.sh.
//

import Foundation

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

/// Drive a fresh rendition with one parameter list and hand back the result -
/// the shape every check below is written in, so a failing line reads as the
/// escape sequence that produced it.
func afterSGR(_ params: [Int]) -> TerminalRendition {
    var r = TerminalRendition()
    r.applySGR(params)
    return r
}

/// ANSI index -> CGA index, stated here independently of CGAColor's own table.
let cgaForANSI: [UInt8] = [0, 4, 2, 6, 1, 5, 3, 7]

func runAllTests() {

    section("Power-on, and what SGR 0 goes back to") {
        let r = TerminalRendition()
        check(r.attr == 0x07, "a fresh rendition is CGA 7 on CGA 0")
        check(r.flags == 0, "with no face flags")
        check(!r.reverse, "and not reversed")

        // Every stateful bit set at once, then cleared by one reset.
        var dirty = TerminalRendition()
        dirty.applySGR([1, 4, 5, 7, 31, 44])
        check(dirty != TerminalRendition(), "the dirty rendition really differs")
        dirty.applySGR([0])
        check(dirty == TerminalRendition(), "SGR 0 restores every field")

        // ESC[m is ESC[0m. Assigning the attribute alone used to leave the
        // reverse flag set, so a later ESC[27m swapped a byte that had never
        // been swapped and put the whole screen into reverse.
        var reversed = TerminalRendition()
        reversed.applySGR([7])
        reversed.applySGR([])
        check(reversed == TerminalRendition(), "ESC[m is ESC[0m, reverse included")
    }

    section("Colours are ANSI going in and CGA once stored") {
        for ansi in 0..<8 {
            let fg = afterSGR([30 + ansi])
            check(fg.attr & 0x07 == cgaForANSI[ansi],
                  "SGR \(30 + ansi) stores CGA \(cgaForANSI[ansi])")
            let bg = afterSGR([40 + ansi])
            check((bg.attr >> 4) & 0x07 == cgaForANSI[ansi],
                  "SGR \(40 + ansi) stores background CGA \(cgaForANSI[ansi])")
        }
        // The four that moved. These are the ones build 54 was drawing wrong.
        check(afterSGR([31]).attr & 0x0F == 4, "ESC[31m is red, not blue")
        check(afterSGR([44]).attr >> 4 == 1, "ESC[44m is blue, not red")
        check(afterSGR([33]).attr & 0x0F == 6, "ESC[33m is brown, not cyan")
        check(afterSGR([36]).attr & 0x0F == 3, "ESC[36m is cyan, not brown")
    }

    section("The bright half - SGR 90-97 and 100-107") {
        for ansi in 0..<8 {
            let r = afterSGR([90 + ansi])
            check(r.attr & 0x0F == cgaForANSI[ansi] | 0x08,
                  "SGR \(90 + ansi) is CGA \(cgaForANSI[ansi]) with intensity")
        }
        // The whole point: before this existed, ESC[91m left the byte alone.
        check(afterSGR([91]).attr != TerminalRendition().attr,
              "ESC[91m changes the attribute at all")
        check(afterSGR([91]).attr & 0x0F == 12, "ESC[91m is CGA 12, light red")

        // The bright bit IS the intensity bit, so 22 dims a bright colour.
        var dim = TerminalRendition()
        dim.applySGR([91])
        dim.applySGR([22])
        check(dim.attr & 0x0F == 4, "ESC[22m after ESC[91m leaves plain red")

        // And a plain colour after a bright one deliberately stays bright,
        // because 3x preserves bit 3.
        var keep = TerminalRendition()
        keep.applySGR([91, 32])
        check(keep.attr & 0x0F == 2 | 0x08, "ESC[91;32m is bright green")

        // 100-107 fold onto the plain background: the nibble is three bits and
        // the fourth is CGA blink, which nothing here may set by accident.
        for ansi in 0..<8 {
            let r = afterSGR([100 + ansi])
            check((r.attr >> 4) & 0x07 == cgaForANSI[ansi],
                  "SGR \(100 + ansi) folds onto background CGA \(cgaForANSI[ansi])")
            check(r.attr & 0x80 == 0, "SGR \(100 + ansi) never sets bit 7 (CGA blink)")
        }
    }

    section("Bold, and the order a colour arrives in") {
        check(afterSGR([1]).attr & 0x08 == 0x08, "SGR 1 sets the intensity bit")
        check(afterSGR([1]).flags & CellFlags.bold != 0, "SGR 1 sets the bold flag")
        check(afterSGR([1, 31]).attr == afterSGR([31, 1]).attr,
              "ESC[1;31m and ESC[31;1m agree")
        check(afterSGR([1, 31]).attr & 0x0F == 12, "and both are bright red")

        var off = TerminalRendition()
        off.applySGR([1, 31])
        off.applySGR([22])
        check(off.attr & 0x08 == 0, "SGR 22 clears the intensity bit")
        check(off.flags & CellFlags.bold == 0, "SGR 22 clears the bold flag")
        check(off.attr & 0x07 == 4, "and leaves the colour alone")
    }

    section("Underline and blink - the two the byte cannot carry") {
        check(afterSGR([4]).flags & CellFlags.underline != 0, "SGR 4 sets underline")
        check(afterSGR([4]).attr == 0x07, "SGR 4 does not touch the colours")
        check(afterSGR([5]).flags & CellFlags.blink != 0, "SGR 5 sets blink")
        check(afterSGR([6]).flags & CellFlags.blink != 0, "SGR 6 sets blink too")

        var r = TerminalRendition()
        r.applySGR([1, 4, 5])
        check(r.flags == CellFlags.bold | CellFlags.underline | CellFlags.blink,
              "the three flags are independent bits")
        r.applySGR([24])
        check(r.flags == CellFlags.bold | CellFlags.blink, "SGR 24 clears only underline")
        r.applySGR([25])
        check(r.flags == CellFlags.bold, "SGR 25 clears only blink")

        // The values are z80cpmw's TCELL_* byte for byte, and cpmdroid's, so a
        // cell from any of the three ports can be compared with another's.
        check(CellFlags.bold == 0x01, "bold is 0x01, as z80cpmw's TCELL_BOLD")
        check(CellFlags.underline == 0x02, "underline is 0x02, as TCELL_UNDERLINE")
        check(CellFlags.blink == 0x04, "blink is 0x04, as TCELL_BLINK")
    }

    section("Reverse video is a toggle, not an edit") {
        var r = TerminalRendition()
        r.applySGR([31, 47])
        let before = r.attr
        r.applySGR([7])
        check(r.attr == before, "SGR 7 does not disturb the stored colours")
        check(r.displayAttr != before, "but the drawn attribute is swapped")
        r.applySGR([7])
        check(r.displayAttr != before, "SGR 7 twice is still reverse, not back")
        r.applySGR([27])
        check(r.displayAttr == before, "SGR 27 restores exactly what was set")

        // The intensity bit falls off the end of a three-bit background, which
        // is half of why the bold flag exists at all.
        var bright = TerminalRendition()
        bright.applySGR([1, 37, 7])
        check(bright.flags & CellFlags.bold != 0,
              "the bold flag survives the reverse swap the intensity bit cannot")
    }

    section("Extended colour: the sub-parameters are stepped over") {
        // ESC[38;5;44m asks for 256-colour 44 and this terminal has sixteen.
        // Read as parameters in their own right, the 44 set a red BACKGROUND -
        // a colour the program named nowhere.
        check(afterSGR([38, 5, 44]) == TerminalRendition(),
              "ESC[38;5;44m changes nothing at all")
        check(afterSGR([48, 5, 31]) == TerminalRendition(),
              "ESC[48;5;31m changes nothing at all")
        check(afterSGR([38, 2, 255, 0, 0]) == TerminalRendition(),
              "ESC[38;2;255;0;0m changes nothing at all")
        check(afterSGR([48, 2, 0, 0, 255]) == TerminalRendition(),
              "ESC[48;2;0;0;255m changes nothing at all")

        // What follows the form still applies, which is what makes the skip a
        // skip rather than a swallow of the rest of the list.
        check(afterSGR([38, 5, 44, 31]).attr & 0x0F == 4,
              "ESC[38;5;44;31m still ends up red")
        check(afterSGR([1, 38, 2, 1, 2, 3, 44]).attr >> 4 == 1,
              "a truecolour form in the middle does not eat the background after it")
        check(afterSGR([1, 38, 2, 1, 2, 3, 44]).flags & CellFlags.bold != 0,
              "nor the bold before it")

        // A truncated form must not read past the end of the list.
        check(afterSGR([38]) == TerminalRendition(), "a bare ESC[38m is inert")
        check(afterSGR([38, 5]) == TerminalRendition(), "a truncated ESC[38;5m is inert")
        check(afterSGR([31, 38]).attr & 0x0F == 4, "and a bare 38 keeps what came before")
    }

    section("SGR 39 and 49 - the defaults") {
        var r = TerminalRendition()
        r.applySGR([31, 44])
        r.applySGR([39])
        check(r.attr & 0x0F == 7, "SGR 39 puts the foreground back to CGA 7")
        check(r.attr >> 4 == 1, "and leaves the background where it was")
        r.applySGR([49])
        check(r.attr == 0x07, "SGR 49 puts the background back to CGA 0")

        // Bold and bright are the same bit inside a packed byte, so 39 has to
        // preserve it or ESC[1m ESC[39m would silently drop the bold.
        var bold = TerminalRendition()
        bold.applySGR([1, 31])
        bold.applySGR([39])
        check(bold.attr & 0x08 == 0x08, "SGR 39 leaves the intensity bit alone")
        check(bold.flags & CellFlags.bold != 0, "and the bold flag with it")
    }

    section("Parameters nothing here should act on") {
        // SGR 21 is double-underline in ECMA-48 and bold-off in several
        // terminals; the two readings disagree about the bit this would touch,
        // so it is a documented no-op rather than a guess.
        var r = TerminalRendition()
        r.applySGR([1])
        let bold = r
        r.applySGR([21])
        check(r == bold, "SGR 21 is a no-op, not a bold-off")
        check(afterSGR([3]) == TerminalRendition(), "SGR 3 (italic) is a no-op")
        check(afterSGR([53]) == TerminalRendition(), "SGR 53 (overline) is a no-op")
        check(afterSGR([9999]) == TerminalRendition(), "a clamped runaway parameter is a no-op")
    }
}

/// `section` takes its body so a suite reads as its own table of contents.
func section(_ title: String, _ body: () -> Void) {
    section(title)
    body()
}

@main
enum TerminalRenditionTestMain {
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
