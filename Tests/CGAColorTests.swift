//
//  CGAColorTests.swift
//
//  What colour a program actually gets when it asks for one.
//
//  Built from the simulator observation of 2026-08-27 that put this in
//  todo.txt: ESC[44m ESC[2J - select a blue background, clear the screen -
//  filled all 25x80 cells solid RED. The erase was right; the colour was not.
//  applySGR stored the SGR parameter's ANSI colour index straight into an
//  attribute byte that TerminalView's cgaColors reads as a CGA index, and the
//  two orderings disagree on four of the eight colours.
//
//  A second bug lived in the same expression: the foreground mask was 0xF0,
//  which also cleared bit 3 - the intensity bit SGR 1 sets - so a colour
//  arriving after a bold silently cancelled it. z80cpmw masks with 0xF8 at the
//  same site and has done since it hit the same thing.
//
//  Both are pure byte arithmetic, which is why CGAColor is a type of its own
//  and why this file can run with no display, no emulator and no UIKit. The
//  parser proper - the cursor, the cell grid and the erase that filled them -
//  moved into TerminalScreen and is covered end to end by
//  Tests/TerminalScreenTests.swift, which drives this very sequence through the
//  public write path and asserts on the cells it leaves behind.
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

/// The two orderings, written out by name so a failure says which colour.
let ansiNames = ["black", "red", "green", "yellow",
                 "blue", "magenta", "cyan", "white"]
let cgaNames = ["black", "blue", "green", "cyan",
                "red", "magenta", "brown", "light grey"]

/// The mapping this file exists to pin, stated independently of the table
/// under test: ANSI index -> CGA index.
let expected: [UInt8] = [0, 4, 2, 6, 1, 5, 3, 7]

func runAllTests() {
    // MARK: - The mapping itself

    section("Every ANSI index lands on the right CGA index")
    for ansi in 0..<8 {
        let got = CGAColor.fromANSI(UInt8(ansi))
        check(got == expected[ansi],
              "ANSI \(ansi) (\(ansiNames[ansi])) -> CGA \(expected[ansi]) "
              + "(\(cgaNames[Int(expected[ansi])])), got \(got)")
    }

    section("And back the other way, CGA index -> ANSI index")
    do {
        // The reverse direction IS the same function, because exchanging two
        // bits undoes itself - so this is not an independent check of the
        // table, and is not meant to be. It is here because a reader looking
        // up "the screen showed CGA 6, what did the program ask for?" needs
        // that direction spelled out, and because it pins the round trip if
        // fromANSI is ever replaced by something that is not an involution.
        for ansi in 0..<8 {
            let cga = Int(expected[ansi])
            check(CGAColor.fromANSI(UInt8(cga)) == UInt8(ansi),
                  "CGA \(cga) (\(cgaNames[cga])) -> ANSI \(ansi) "
                  + "(\(ansiNames[ansi]))")
        }
    }

    section("It is an involution")
    for c in 0..<8 {
        let once = CGAColor.fromANSI(UInt8(c))
        check(CGAColor.fromANSI(once) == UInt8(c),
              "mapping \(c) twice returns \(c) (via \(once))")
    }

    section("It is a permutation - nothing is lost or doubled")
    do {
        let image = Set((0..<8).map { CGAColor.fromANSI(UInt8($0)) })
        check(image == Set<UInt8>(0...7),
              "all eight indices map onto all eight indices, one to one")
        check(CGAColor.cgaForANSI.count == 8,
              "and the table has exactly eight entries")
    }

    section("Black and white are fixed points")
    do {
        check(CGAColor.fromANSI(0) == 0, "ANSI 0 black is CGA 0 black")
        check(CGAColor.fromANSI(7) == 7, "ANSI 7 white is CGA 7 light grey")
        // This is what lets the default attribute and every reset stay at 0x07
        // and every erase stay on black: neither end of the reset value moves.
        check(CGAColor.withForeground(0x07, ansi: 7) == 0x07,
              "so SGR 37 on the default attribute leaves 0x07 alone")
        check(CGAColor.withBackground(0x07, ansi: 0) == 0x07,
              "and SGR 40 on it leaves 0x07 alone too")
    }

    section("Exactly the four swapped colours move")
    do {
        let moved = (0..<8).filter { CGAColor.fromANSI(UInt8($0)) != UInt8($0) }
        check(moved == [1, 3, 4, 6],
              "1, 3, 4 and 6 move and nothing else does; moved = \(moved)")
        check(CGAColor.fromANSI(1) == 4 && CGAColor.fromANSI(4) == 1,
              "red and blue trade places - the ESC[31m/ESC[44m pair")
        check(CGAColor.fromANSI(3) == 6 && CGAColor.fromANSI(6) == 3,
              "yellow and cyan trade places - the ESC[33m/ESC[36m pair")
        for fixed in [0, 2, 5, 7] {
            check(CGAColor.fromANSI(UInt8(fixed)) == UInt8(fixed),
                  "\(ansiNames[fixed]) (\(fixed)) is the same index in both")
        }
    }

    section("The mapping is the documented bit exchange")
    for c in 0..<8 {
        let c8 = UInt8(c)
        let byBits = ((c8 & 1) << 2) | (c8 & 2) | ((c8 >> 2) & 1)
        check(CGAColor.fromANSI(c8) == byBits,
              "\(c) matches ((c & 1) << 2) | (c & 2) | ((c >> 2) & 1)")
    }

    // MARK: - The bugs, as the guest sees them

    section("The screen ESC[44m ESC[2J paints is blue, not red")
    do {
        // Straight from the todo.txt observation. The erase fills from
        // displayAttr, which is currentAttr while SGR 7 is off - as it is
        // here - so the byte this produces is the whole story.
        let attr = CGAColor.withBackground(0x07, ansi: 4)
        check((attr >> 4) & 0x07 == 1,
              "SGR 44 leaves background CGA 1 blue, not CGA 4 red")
        check(attr & 0x0F == 0x07,
              "and does not disturb the foreground")
    }

    section("The other three a user could see")
    do {
        check(CGAColor.withForeground(0x00, ansi: 1) & 0x0F == 4,
              "ESC[31m draws CGA 4 red, not CGA 1 blue")
        check(CGAColor.withForeground(0x00, ansi: 3) & 0x0F == 6,
              "ESC[33m draws CGA 6 brown/yellow, not CGA 3 cyan")
        check(CGAColor.withForeground(0x00, ansi: 6) & 0x0F == 3,
              "ESC[36m draws CGA 3 cyan, not CGA 6 brown")
    }

    section("A colour after a bold keeps the bold")
    do {
        // The 0xF0 half of the bug. SGR 1 sets bit 3, SGR 30-37 selects a
        // colour, and they are independent attributes - so the order they
        // arrive in must not matter.
        let boldThenRed = CGAColor.withForeground(0x07 | 0x08, ansi: 1)
        check(boldThenRed & 0x08 == 0x08,
              "ESC[1m then ESC[31m is still bold")
        check(boldThenRed & 0x07 == 4,
              "and is still red")
        check(boldThenRed == 0x0C,
              "ESC[1;31m ends at 0x0C, bright red")
        // The other order, actually evaluated rather than asserted in prose.
        // This is the regression the 0xF8 mask exists to prevent: with the old
        // 0xF0 the colour wiped the intensity bit and the two orders differed.
        let redThenBold = CGAColor.withForeground(0x07, ansi: 1) | 0x08
        check(redThenBold == 0x0C,
              "ESC[31;1m ends at 0x0C too, so the order cannot matter")
        check(redThenBold == boldThenRed,
              "bold and colour are independent whichever arrives first")
    }

    section("A background never disturbs the foreground or its intensity")
    do {
        let bright = CGAColor.withForeground(0x00, ansi: 6) | 0x08  // bright cyan
        let onBlue = CGAColor.withBackground(bright, ansi: 4)
        check(onBlue & 0x0F == bright & 0x0F,
              "SGR 44 after a bright foreground keeps the whole low nibble")
        check((onBlue >> 4) & 0x07 == 1, "and sets the background to blue")
    }

    section("The background is three bits and stays inside them")
    do {
        // Not just tidiness: bit 7 is CGA blink, and emulatorVDASetAttr hands a
        // raw guest byte into the same field. An SGR background that overflowed
        // into bit 7 would be inventing an attribute the guest never asked for.
        for ansi in 0..<8 {
            let attr = CGAColor.withBackground(0x00, ansi: UInt8(ansi))
            check(attr & 0x80 == 0,
                  "SGR \(40 + ansi) never sets bit 7 (CGA blink)")
            check((attr >> 4) & 0x07 == expected[ansi],
                  "SGR \(40 + ansi) sets background CGA \(expected[ansi])")
        }
    }
}

@main
enum CGAColorTestMain {
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
