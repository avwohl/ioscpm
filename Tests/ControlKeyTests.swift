//
//  ControlKeyTests.swift
//
//  What a Ctrl combination sends to CP/M.
//
//  Build 49 replaced 26 UIKeyCommands - which were the whole mechanism, and so
//  the reason Ctrl with anything that was not a letter reached nothing - with a
//  general fold. That commit calls out one hazard by name and nothing verified
//  it: String.uppercased() applies full Unicode case mapping, so a German "ß"
//  becomes "SS" and the fold would hand the guest ^S from a key that used to
//  send nothing. ^S is WordStar cursor-left, so the failure is silent and it
//  moves the cursor.
//
//  These tests pin the fold down: every byte of the WordStar diamond, the
//  non-letter Ctrl combinations build 49 added, and the keys that must keep
//  sending nothing at all.
//
//  Run with Tests/run_tests.sh. No display, emulator or UI required - which is
//  why ControlKey is a separate type.
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

/// The byte Ctrl + this character produces, or nil for "sends nothing".
func fold(_ c: Character) -> UInt8? {
    ControlKey.byte(forScalar: c.unicodeScalars.first!.value)
}

func hex(_ b: UInt8?) -> String {
    guard let b else { return "nil" }
    return String(format: "0x%02X", b)
}

func runAllTests() {
    // -----------------------------------------------------------------------------
    section("The WordStar diamond, from the unshifted letters")
    // -----------------------------------------------------------------------------
    //
    // The keys a WordStar user presses constantly. ^S/^D cursor left/right, ^E/^X
    // up/down, ^A/^F word left/right, ^R/^C page up/down, ^Q the prefix for the
    // whole ^Qx family, ^K the block prefix, ^P the print-control prefix, ^O the
    // onscreen-format prefix, ^Y delete line, ^V insert toggle.
    let diamond: [(Character, UInt8)] = [
        ("s", 0x13), ("d", 0x04), ("e", 0x05), ("x", 0x18),
        ("a", 0x01), ("f", 0x06), ("r", 0x12), ("c", 0x03),
        ("q", 0x11), ("k", 0x0B), ("p", 0x10), ("o", 0x0F),
        ("y", 0x19), ("v", 0x16),
    ]
    for (ch, want) in diamond {
        check(fold(ch) == want, "Ctrl+\(ch) -> \(hex(want))")
    }

    // -----------------------------------------------------------------------------
    section("Every letter, both cases, lands on the same byte")
    // -----------------------------------------------------------------------------
    //
    // charactersIgnoringModifiers keeps Shift, so Ctrl+Shift+A arrives as "A" and
    // Ctrl+A as "a". Both must fold to 0x01: a user holding Shift by accident, or
    // with caps lock on, still gets the WordStar key they meant.
    var lowerOK = true
    var caseOK = true
    for i in 0..<26 {
        let lower = Character(UnicodeScalar(UInt8(0x61 + i)))
        let upper = Character(UnicodeScalar(UInt8(0x41 + i)))
        let want = UInt8(i + 1)
        if fold(lower) != want { lowerOK = false }
        if fold(upper) != fold(lower) { caseOK = false }
    }
    check(lowerOK, "Ctrl+a through Ctrl+z give 0x01 through 0x1A")
    check(caseOK, "Ctrl+Shift+letter gives the same byte as Ctrl+letter")

    // -----------------------------------------------------------------------------
    section("The non-letter combinations build 49 added")
    // -----------------------------------------------------------------------------
    //
    // None of these reached CP/M before build 49: the 26 key commands covered only
    // letters and pressesBegan dropped every other Ctrl press.
    check(fold("[") == 0x1B, "Ctrl+[ -> ESC (0x1B)")
    check(fold("\\") == 0x1C, "Ctrl+\\ -> FS (0x1C)")
    check(fold("]") == 0x1D, "Ctrl+] -> GS (0x1D)")
    check(fold("^") == 0x1E, "Ctrl+^ -> RS (0x1E)")
    check(fold("_") == 0x1F, "Ctrl+_ -> US (0x1F)")
    check(fold("@") == 0x00, "Ctrl+@ -> NUL (0x00)")
    check(fold(" ") == 0x00, "Ctrl+Space -> NUL, because terminals send NUL there")
    check(fold("?") == 0x7F, "Ctrl+? -> DEL (0x7F)")
    check(fold("/") == 0x1F, "Ctrl+/ -> US, the other common spelling of 0x1F")
    check(ControlKey.delete == 0x7F, "Ctrl+Backspace -> DEL, via the key code")

    // -----------------------------------------------------------------------------
    section("ASCII-only folding - the German keyboard trap")
    // -----------------------------------------------------------------------------
    //
    // The reason the fold is hand-written arithmetic rather than uppercased(). A
    // wrong answer here is worse than no answer: the key used to send nothing, and
    // a full Unicode fold would make it send a WordStar cursor movement.
    check(fold("ß") == nil, "Ctrl+ß sends nothing")
    check(fold("ß") != 0x13, "Ctrl+ß is specifically not ^S - uppercased() gives \"SS\"")
    check(fold("ﬁ") == nil, "Ctrl+ﬁ sends nothing - uppercased() gives \"FI\"")
    check(fold("é") == nil, "Ctrl+é sends nothing")
    check(fold("ö") == nil, "Ctrl+ö sends nothing")
    check(fold("®") == nil, "Ctrl+® sends nothing - US Option+R composes this")
    check(fold("π") == nil, "Ctrl+π sends nothing")

    // -----------------------------------------------------------------------------
    section("Keys with no control meaning stay silent")
    // -----------------------------------------------------------------------------
    //
    // CP/M console input is 7-bit and a stray byte is indistinguishable from a
    // typed one, so anything the fold does not recognise must send nothing rather
    // than guess.
    for ch in "0123456789" {
        check(fold(ch) == nil, "Ctrl+\(ch) sends nothing")
    }
    check(fold("`") == nil, "Ctrl+` sends nothing")
    check(fold("{") == nil, "Ctrl+{ sends nothing")
    check(fold("~") == nil, "Ctrl+~ sends nothing")
    check(fold("-") == nil, "Ctrl+- sends nothing")
    check(fold("=") == nil, "Ctrl+= sends nothing")

    // -----------------------------------------------------------------------------
    section("Nothing folds outside the 7-bit range")
    // -----------------------------------------------------------------------------
    //
    // Whatever the fold returns goes to a guest that reads 7-bit console input, and
    // WordStar uses bit 7 as its own end-of-word marker inside text. A byte with
    // the high bit set would be read as document data.
    var inRange = true
    for scalar in UInt32(0)...UInt32(0x2FFFF) {
        if let b = ControlKey.byte(forScalar: scalar), b > 0x7F { inRange = false }
    }
    check(inRange, "no scalar in 0x0000-0x2FFFF folds to a byte above 0x7F")

    var onlyControls = true
    for scalar in UInt32(0)...UInt32(0x2FFFF) {
        if let b = ControlKey.byte(forScalar: scalar), b > 0x1F, b != 0x7F { onlyControls = false }
    }
    check(onlyControls, "every folded byte is a control code or DEL, never a glyph")

}

@main
enum ControlKeyTestMain {
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
