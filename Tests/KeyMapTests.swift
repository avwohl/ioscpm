//
//  KeyMapTests.swift
//
//  What the navigation and function keys send.
//
//  The point of this suite is portability as much as correctness. The escape
//  schema is shared with z80cpmw and romwbw_emu, so a map written for one should
//  mean the same thing in the others - and until build 51 it could not, because
//  this port had no F1-F12 at all. z80cpmw's FEATURE_PARITY.md item 1 tracked
//  that as the reason the ports' maps were not interchangeable.
//
//  The F-key sequences below are asserted against the exact strings in
//  z80cpmw/Keymap.h, not against "something reasonable", because a plausible but
//  different sequence is the failure that would make maps silently non-portable
//  again.
//
//  Run with Tests/run_tests.sh. No display, emulator or UI required.
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

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func runAllTests() {
    // -------------------------------------------------------------------------
    section("The escape schema")
    // -------------------------------------------------------------------------
    check(KeyMap.expand("\\E") == [0x1B], "\\E is ESC")
    check(KeyMap.expand("^A") == [0x01], "^A is 0x01")
    check(KeyMap.expand("^?") == [0x7F], "^? is DEL, not 0x3F")
    check(KeyMap.expand("\\n") == [0x0A], "\\n is LF")
    check(KeyMap.expand("\\r") == [0x0D], "\\r is CR")
    check(KeyMap.expand("\\t") == [0x09], "\\t is TAB")
    check(KeyMap.expand("\\s") == [0x20], "\\s is space")
    check(KeyMap.expand("\\\\") == [0x5C], "\\\\ is a literal backslash")
    check(KeyMap.expand("\\033") == [0x1B], "\\033 is octal ESC")
    check(KeyMap.expand("") == [], "an empty binding sends nothing")
    check(KeyMap.expand("\\E[A") == [0x1B, 0x5B, 0x41], "\\E[A is ESC [ A")
    // The one documented divergence from z80cpmw: no explicit \^ case, but the
    // default arm emits the literal, which is the same byte.
    check(KeyMap.expand("\\^") == [0x5E], "\\^ still yields a literal caret")

    // -------------------------------------------------------------------------
    section("Every key in every preset profile is bound")
    // -------------------------------------------------------------------------
    //
    // A missing entry is not a compile error - bindings is a dictionary - so a
    // key added to the enum without being added to a profile silently sends
    // nothing. That is exactly how F1-F12 would regress.
    for profile in [KeyProfile.wordStar, .vt100, .vt52] {
        guard let bindings = profile.bindings else {
            check(false, "\(profile.rawValue) has bindings")
            continue
        }
        let missing = SpecialKey.allCases.filter { bindings[$0] == nil }
        check(missing.isEmpty,
              "\(profile.rawValue) binds all \(SpecialKey.allCases.count) keys"
              + (missing.isEmpty ? "" : " - missing \(missing.map(\.rawValue))"))
    }
    check(KeyProfile.custom.bindings == nil, "Custom supplies no bindings of its own")

    // -------------------------------------------------------------------------
    section("F1-F12 match z80cpmw byte for byte, so maps stay portable")
    // -------------------------------------------------------------------------
    //
    // From z80cpmw/Keymap.h. VT220/xterm: F1-F4 are SS3, F5-F12 are CSI with a
    // number, and the numbering skips 16 and 22 - which is real VT220 history,
    // not a typo, and the reason these must be asserted rather than derived.
    let wanted: [(SpecialKey, [UInt8])] = [
        (.f1,  [0x1B, 0x4F, 0x50]),                   // ESC O P
        (.f2,  [0x1B, 0x4F, 0x51]),                   // ESC O Q
        (.f3,  [0x1B, 0x4F, 0x52]),                   // ESC O R
        (.f4,  [0x1B, 0x4F, 0x53]),                   // ESC O S
        (.f5,  [0x1B, 0x5B, 0x31, 0x35, 0x7E]),       // ESC [ 1 5 ~
        (.f6,  [0x1B, 0x5B, 0x31, 0x37, 0x7E]),       // ESC [ 1 7 ~   (16 skipped)
        (.f7,  [0x1B, 0x5B, 0x31, 0x38, 0x7E]),
        (.f8,  [0x1B, 0x5B, 0x31, 0x39, 0x7E]),
        (.f9,  [0x1B, 0x5B, 0x32, 0x30, 0x7E]),
        (.f10, [0x1B, 0x5B, 0x32, 0x31, 0x7E]),
        (.f11, [0x1B, 0x5B, 0x32, 0x33, 0x7E]),       // (22 skipped)
        (.f12, [0x1B, 0x5B, 0x32, 0x34, 0x7E]),
    ]
    for profile in [KeyProfile.vt100, .wordStar] {
        let map = KeyMap(bindings: profile.bindings ?? [:])
        var ok = true
        for (key, want) in wanted where map.bytes(for: key) != want {
            print("      \(profile.rawValue) \(key.rawValue): wanted \(hex(want))"
                  + ", got \(hex(map.bytes(for: key)))")
            ok = false
        }
        check(ok, "\(profile.rawValue) sends the VT220 F-key sequences")
    }

    // -------------------------------------------------------------------------
    section("VT52 tells the truth about what it has")
    // -------------------------------------------------------------------------
    //
    // A real VT52 has four keypad function keys, PF1-PF4, as ESC P/Q/R/S. It has
    // no F5-F12, so those send nothing rather than borrowing a VT100 sequence a
    // VT52 program cannot be expecting.
    let vt52 = KeyMap(bindings: KeyProfile.vt52.bindings ?? [:])
    check(vt52.bytes(for: .f1) == [0x1B, 0x50], "VT52 F1 is ESC P (PF1)")
    check(vt52.bytes(for: .f2) == [0x1B, 0x51], "VT52 F2 is ESC Q (PF2)")
    check(vt52.bytes(for: .f3) == [0x1B, 0x52], "VT52 F3 is ESC R (PF3)")
    check(vt52.bytes(for: .f4) == [0x1B, 0x53], "VT52 F4 is ESC S (PF4)")
    var higherAreSilent = true
    for key in [SpecialKey.f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12]
    where !vt52.bytes(for: key).isEmpty { higherAreSilent = false }
    check(higherAreSilent, "VT52 F5-F12 send nothing - a VT52 has no such keys")
    check(vt52.bytes(for: .f1) != KeyMap(bindings: KeyProfile.vt100.bindings ?? [:])
                                    .bytes(for: .f1),
          "and VT52 PF1 is not the VT100 F1 sequence")

    // -------------------------------------------------------------------------
    section("The navigation keys the profiles are named for")
    // -------------------------------------------------------------------------
    let ws = KeyMap(bindings: KeyProfile.wordStar.bindings ?? [:])
    check(ws.bytes(for: .up) == [0x05], "WordStar Up is ^E")
    check(ws.bytes(for: .down) == [0x18], "WordStar Down is ^X")
    check(ws.bytes(for: .left) == [0x13], "WordStar Left is ^S")
    check(ws.bytes(for: .right) == [0x04], "WordStar Right is ^D")
    check(ws.bytes(for: .home) == [0x11, 0x13], "WordStar Home is the two-byte ^Q^S")

    let vt100 = KeyMap(bindings: KeyProfile.vt100.bindings ?? [:])
    check(vt100.bytes(for: .up) == [0x1B, 0x5B, 0x41], "VT100 Up is ESC [ A")
    check(vt100.bytes(for: .delete) == [0x1B, 0x5B, 0x33, 0x7E], "VT100 Delete is ESC [ 3 ~")
    check(vt52.bytes(for: .up) == [0x1B, 0x41], "VT52 Up is ESC A, no bracket")

    // -------------------------------------------------------------------------
    section("Nothing a binding can say produces a byte above 0x7F")
    // -------------------------------------------------------------------------
    //
    // CP/M console input is 7-bit and WordStar uses bit 7 as its own end-of-word
    // marker inside text, so a high byte from a key would be read as document
    // data. Octal escapes are the one route that can express one.
    check(KeyMap.expand("\\377") == [0xFF],
          "an explicit \\377 does produce 0xFF - the schema allows it deliberately")
    var presetsAre7Bit = true
    for profile in [KeyProfile.wordStar, .vt100, .vt52] {
        let map = KeyMap(bindings: profile.bindings ?? [:])
        for key in SpecialKey.allCases where map.bytes(for: key).contains(where: { $0 > 0x7F }) {
            presetsAre7Bit = false
        }
    }
    check(presetsAre7Bit, "but no preset profile ever sends one")
}

@main
enum KeyMapTestMain {
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
