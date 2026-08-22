//
//  TerminalDialect.swift
//  iOSCPM
//
//  Which terminal the emulation is currently pretending to be, and what each
//  escape byte does to that choice.
//
//  This lives apart from the parser in EmulatorViewModel because it is pure
//  logic - no screen, no emulator, no UI - which is the only reason it can be
//  exercised directly by Tests/TerminalDialectTests.swift on a machine with no
//  display. The parser proper still owns the cursor and the cell grid.
//
//  It matters because the choice is sticky and global: once the stream is read
//  as VT52, ESC D / ESC E / ESC H change meaning and ESC Z answers with a
//  different identity, for every program in the session, until something
//  explicitly switches back or the machine cold boots.
//

import Foundation

struct TerminalDialect {

    enum Kind {
        case ansi   // VT100 / ANSI - the power-on default
        case vt52
    }

    private(set) var kind: Kind = .ansi

    var isVT52: Bool { kind == .vt52 }

    /// Bytes which, following a bare ESC, are taken as proof that the stream is
    /// VT52 and switch the whole session over.
    ///
    /// These are *inferred*, not requested: none of them is a mode-set command.
    /// Inference has to be conservative, because the two kinds of mistake do
    /// not cost the same.
    ///
    /// Guessing VT52 wrongly is destructive and permanent. It re-points ESC D
    /// from Index to cursor-left, ESC H to home, and - worst - ESC E from Next
    /// Line to *clear the screen*, for every program in the session until
    /// something explicitly switches back or the machine cold boots.
    ///
    /// Guessing ANSI wrongly costs almost nothing, because the VT52 action
    /// sequences do not consult this flag at all: ESC A/B/C/I/J/K and ESC Y
    /// direct cursor addressing are carried out whatever dialect we think we
    /// are in. Only ESC D, ESC E, ESC H and the ESC Z reply differ. So a VT52
    /// program that never trips the inference still moves its cursor, addresses
    /// it directly and erases correctly.
    ///
    /// Given that, ESC J and ESC K are deliberately absent. They are
    /// erase-to-end-of-screen and erase-to-end-of-line on the ADM-3A,
    /// Televideo, Hazeltine and Heath families as much as on the VT52, so a
    /// CP/M program installed for any of those emits them constantly while
    /// meaning nothing whatever about VT52 - which is how GitHub issue #2
    /// ended up with a session that answered ESC Z as a VT52 after one stray
    /// erase. What remains are sequences a VT100-configured program has no
    /// reason to emit: it spells cursor movement CSI A/B/C, not ESC A/B/C.
    static let vt52OnlyEscapeBytes: Set<unichar> = [
        0x41,  // 'A' cursor up
        0x42,  // 'B' cursor down
        0x43,  // 'C' cursor right
        0x46,  // 'F' enter graphics mode
        0x47,  // 'G' exit graphics mode
        0x49,  // 'I' reverse line feed
        0x59,  // 'Y' direct cursor address
    ]

    /// The byte which, following a bare ESC, explicitly leaves VT52 (ESC <).
    static let exitVT52EscapeByte: unichar = 0x3C

    /// Note a byte seen straight after ESC, and switch dialect if it settles
    /// the question. Bytes that mean the same thing in both dialects, and bytes
    /// that mean nothing, leave the choice alone.
    mutating func noteEscapeByte(_ ch: unichar) {
        if ch == Self.exitVT52EscapeByte {
            kind = .ansi
        } else if Self.vt52OnlyEscapeBytes.contains(ch) {
            kind = .vt52
        }
    }

    /// DECANM, the documented way to ask: CSI ? 2 h selects ANSI, CSI ? 2 l
    /// selects VT52.
    mutating func noteDECANM(selectsANSI: Bool) {
        kind = selectsANSI ? .ansi : .vt52
    }

    /// Power-on state. A cold boot returns the terminal to ANSI.
    mutating func reset() {
        kind = .ansi
    }

    /// What ESC Z (identify) answers with. The reply is delivered to the guest
    /// through the same queue as the keyboard, exactly as a real terminal
    /// answers over its serial line - so answering as the wrong terminal does
    /// not merely misinform the program, it hands it bytes it never typed.
    var identifyReply: String {
        switch kind {
        case .vt52: return "\u{1B}/Z"
        case .ansi: return "\u{1B}[?1;0c"
        }
    }
}
