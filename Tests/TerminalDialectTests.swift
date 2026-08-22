//
//  TerminalDialectTests.swift
//
//  What the emulation decides it is, and what it answers when asked.
//
//  Built from GitHub issue #2, where WordStar drew its screen correctly but
//  behaved as though the keyboard were dead. The mechanism these tests pin
//  down: the VT52 choice is inferred from ordinary output, is global, and never
//  expires - so one byte emitted by one program re-points every program that
//  runs after it, until something switches back or the machine cold boots. The
//  identify reply then goes to the guest through the same queue as the
//  keyboard, so a program that asks what terminal it has is handed bytes it
//  never typed.
//
//  Measured against build 46 on Mac Catalyst before this file existed: in one
//  MBASIC session, ESC Z answered <27>[?1;0c at the prompt, an unrelated
//  statement printed ESC K, and thirty seconds later the same ESC Z answered
//  <27>/Z.
//
//  Run with Tests/run_tests.sh. No display, emulator or UI required - which is
//  the whole reason TerminalDialect is a separate type.
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

/// Feed a run of bytes as if each followed an ESC.
func dialectAfter(escapeBytes: [unichar]) -> TerminalDialect {
    var d = TerminalDialect()
    for b in escapeBytes { d.noteEscapeByte(b) }
    return d
}

func byte(_ c: Character) -> unichar {
    unichar(c.asciiValue!)
}

func runAllTests() {
    // MARK: - The power-on state

    section("A terminal starts as ANSI")
    do {
        let d = TerminalDialect()
        check(!d.isVT52, "the default dialect is ANSI, not VT52")
        check(d.identifyReply == "\u{1B}[?1;0c",
              "and identifies as a VT100 with no options")
    }

    // MARK: - What switches it, and what does not

    section("Only VT52-exclusive bytes switch the dialect")
    do {
        // Every byte the parser treats as proof of VT52. A VT100-configured
        // program has no reason to emit any of these: it spells cursor
        // movement CSI A/B/C, not ESC A/B/C.
        for c in "ABCFGIY" {
            let d = dialectAfter(escapeBytes: [byte(c)])
            check(d.isVT52, "ESC \(c) switches the session to VT52")
        }

        // Bytes that appear after ESC in ordinary output and must not switch it.
        // ESC D, E and H are dangerous because they exist in both dialects and
        // mean different things, so inferring from them would be
        // self-fulfilling. ESC J and ESC K are dangerous because they are the
        // erase commands of the ADM-3A, Televideo, Hazeltine and Heath families
        // too, and say nothing about VT52 - see the regression section below.
        for c in "DEHJKMZ78<=>" {
            let d = dialectAfter(escapeBytes: [byte(c)])
            check(!d.isVT52, "ESC \(c) leaves the dialect alone")
        }
    }

    // MARK: - The documented way in and out

    section("DECANM selects the dialect explicitly")
    do {
        var d = TerminalDialect()
        d.noteDECANM(selectsANSI: false)          // CSI ? 2 l
        check(d.isVT52, "CSI ? 2 l selects VT52")
        d.noteDECANM(selectsANSI: true)           // CSI ? 2 h
        check(!d.isVT52, "CSI ? 2 h selects ANSI again")
    }

    section("ESC < leaves VT52")
    do {
        // The question issue #2 could not settle from the outside: once the
        // session has switched, does the documented escape hatch work?
        var d = dialectAfter(escapeBytes: [byte("Y")])
        check(d.isVT52, "precondition: ESC Y has switched the session to VT52")

        d.noteEscapeByte(byte("<"))
        check(!d.isVT52, "ESC < returns the session to ANSI")
        check(d.identifyReply == "\u{1B}[?1;0c",
              "and the identify reply goes back to the VT100 one")
    }

    section("A cold boot returns to ANSI")
    do {
        var d = dialectAfter(escapeBytes: [byte("Y")])
        check(d.isVT52, "precondition: in VT52")
        d.reset()
        check(!d.isVT52, "reset() returns the dialect to ANSI")
    }

    // MARK: - The identify reply

    section("ESC Z answers as whichever terminal we currently claim to be")
    do {
        check(TerminalDialect().identifyReply == "\u{1B}[?1;0c",
              "ANSI answers ESC [ ? 1 ; 0 c (VT100 DECID)")
        check(dialectAfter(escapeBytes: [byte("Y")]).identifyReply == "\u{1B}/Z",
              "VT52 answers ESC / Z")

        // Spelled out as bytes, because these reach the guest as though typed and
        // a program reading them cannot tell them from keystrokes.
        let vt52 = Array(dialectAfter(escapeBytes: [byte("Y")]).identifyReply.unicodeScalars).map { $0.value }
        check(vt52 == [27, 47, 90],
              "the VT52 reply is the three bytes 27 47 90 - what issue #2 measured")
    }

    // MARK: - The regression

    section("An erase does not change what terminal we claim to be - issue #2")
    do {
        // Exactly what was measured against build 46: print ESC K, then ask
        // ESC Z. The reply used to come back <27>/Z, telling a VT100-configured
        // program it had a VT52, thirty seconds and one unrelated statement
        // after the erase.
        var d = TerminalDialect()
        d.noteEscapeByte(byte("K"))
        check(!d.isVT52, "ESC K erase-to-end-of-line does not switch the session")
        check(d.identifyReply == "\u{1B}[?1;0c",
              "and ESC Z still answers as a VT100")

        d.noteEscapeByte(byte("J"))
        check(!d.isVT52, "nor does ESC J erase-to-end-of-screen")

        // A whole screen painted by an ADM-3A/Televideo-style program: erase
        // the line, erase down, write, repeat. None of it is about VT52.
        for _ in 0..<25 {
            d.noteEscapeByte(byte("K"))
            d.noteEscapeByte(byte("J"))
        }
        check(!d.isVT52, "and neither does a screenful of them")
        check(d.identifyReply == "\u{1B}[?1;0c",
              "the session is still a VT100 afterwards")

        check(!TerminalDialect.vt52OnlyEscapeBytes.contains(byte("K")) &&
              !TerminalDialect.vt52OnlyEscapeBytes.contains(byte("J")),
              "the ambiguous erase bytes are not treated as proof of VT52")
    }

    section("A real VT52 program still gets VT52")
    do {
        // The other half of the bargain: narrowing the inference must not stop
        // an actual VT52 program working. Direct cursor addressing is the
        // sequence such a program cannot avoid, and it is unambiguous.
        var d = TerminalDialect()
        d.noteEscapeByte(byte("Y"))
        check(d.isVT52, "ESC Y direct cursor addressing still switches the session")
        check(d.identifyReply == "\u{1B}/Z", "and ESC Z then answers as a VT52")

        // Even a program that never trips the inference is not stranded: the
        // VT52 action sequences are carried out whatever dialect we believe,
        // so only ESC D / E / H and this reply ever depend on the flag.
        var plain = TerminalDialect()
        plain.noteEscapeByte(byte("K"))
        check(!plain.isVT52,
              "a VT52 program that only erases stays nominally ANSI - and its "
              + "erases still work, because ESC J/K do not consult the dialect")
    }
}

@main
enum TerminalDialectTestMain {
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
