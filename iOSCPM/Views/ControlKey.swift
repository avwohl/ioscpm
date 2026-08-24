//
//  ControlKey.swift
//
//  Folding a Ctrl-modified key to the ASCII control byte CP/M expects.
//
//  Split out of TerminalUIView for the same reason TerminalDialect was split
//  out of EmulatorViewModel: the arithmetic is pure, it is the kind of thing
//  that goes subtly wrong, and a UIKey cannot be constructed in a test. What
//  stays in the view is the part that needs UIKit - reading the key code and
//  charactersIgnoringModifiers off a UIKey. What lives here is the decision.
//
//  See Tests/ControlKeyTests.swift.
//

import Foundation

/// The Ctrl fold, as a pure function of the character the key produces.
enum ControlKey {

    /// DEL (0x7F). Ctrl+Backspace and Ctrl+? both mean this.
    ///
    /// Backspace composes "\u{8}", which never reaches the 0x40...0x5F range
    /// the fold below covers, so the caller has to special-case the key code
    /// before consulting the character.
    static let delete: UInt8 = 0x7F

    /// Fold one Unicode scalar - the character a key produces with Shift
    /// applied but Ctrl ignored - to the control byte the guest should receive,
    /// or nil if the key has no control meaning and should send nothing.
    ///
    /// `charactersIgnoringModifiers` keeps Shift, so Ctrl+A gives "a" and
    /// Ctrl+Shift+A gives "A"; upper-casing first lands both on 0x01. Same
    /// arithmetic as the on-screen Ctrl button (hbios_core.cc queueInput) and
    /// as KeyMap's `^X` / `^?` escapes.
    static func byte(forScalar value: UInt32) -> UInt8? {
        var value = value
        // Fold ASCII only. String.uppercased() applies full Unicode case
        // mapping, which would turn a German "ß" into "SS" and hand the guest
        // ^S - a key that produced nothing before, now producing the wrong
        // byte. The same trap catches "ﬁ" -> "FI" and Cherokee lower case.
        if value >= 0x61 && value <= 0x7A { value -= 0x20 }  // a-z -> A-Z
        switch value {
        case 0x40...0x5F: return UInt8(value & 0x1F)         // @ A-Z [ \ ] ^ _ -> 0x00-0x1F
        case 0x3F:        return delete                      // Ctrl+?     -> DEL
        case 0x2F:        return 0x1F                        // Ctrl+/     -> US
        case 0x20:        return 0x00                        // Ctrl+Space -> NUL
        default:          return nil
        }
    }
}
