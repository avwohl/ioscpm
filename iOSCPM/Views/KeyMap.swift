//
//  KeyMap.swift
//
//  Binding the keys CP/M does not have.
//
//  CP/M is pure ASCII with no navigation or function keys; each terminal defined
//  its own escape bytes for them. These types let the user bind those keys to
//  arbitrary byte sequences, in the same termcap-style schema z80cpmw and
//  romwbw_emu use, so a map means the same thing in all three.
//
//  Split out of TerminalView for the reason TerminalDialect and ControlKey were:
//  none of it touches UIKit, and the part that does - reading a
//  UIKeyboardHIDUsage off a UIKey - stays in the view. See Tests/KeyMapTests.swift.
//

import Foundation

// MARK: - Configurable Key Mapping
//
// CP/M is pure ASCII and has no navigation/function keys; each terminal defines
// its own escape bytes. These types let the user bind the navigation keys to
// arbitrary byte sequences, using the same termcap-style escape-string schema as
// the z80cpmw / romwbw_emu family so configs stay conceptually portable.

/// Special (non-ASCII) keys from a hardware/external keyboard that can be
/// remapped to arbitrary byte sequences sent to the guest.
enum SpecialKey: String, CaseIterable, Identifiable {
    case up, down, left, right
    /// Ctrl-modified arrows. A modified press is a binding of its own, not the
    /// same one as the plain key - without these four the Ctrl was simply
    /// discarded and Ctrl+Left was indistinguishable from Left. z80cpmw's
    /// Keymap.h carries the same four ("Ctrl+Up" .. "Ctrl+Left") for the same
    /// reason; keeping the names one-to-one is what keeps a map portable.
    ///
    /// iPadOS only. On Mac Catalyst, Ctrl+arrow is claimed by WindowServer for
    /// Mission Control / Spaces before the app ever sees the press, so these
    /// bindings exist there but never fire.
    case ctrlUp, ctrlDown, ctrlLeft, ctrlRight
    case home, end, pageUp, pageDown, insert, delete
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    var id: String { rawValue }

    /// The unmodified key a modified variant falls back to when it has no
    /// binding of its own. z80cpmw's KeyMap::find() does the same fallback,
    /// and here it also covers migration: a Custom profile saved before the
    /// Ctrl+arrow slots existed has no entry for them, and must keep behaving
    /// exactly as it did rather than suddenly sending nothing.
    var unmodifiedBase: SpecialKey? {
        switch self {
        case .ctrlUp: return .up
        case .ctrlDown: return .down
        case .ctrlLeft: return .left
        case .ctrlRight: return .right
        default: return nil
        }
    }

    /// The Ctrl-modified slot for a plain key, if it has one. The inverse of
    /// `unmodifiedBase`, and the lookup the view does when a nav key arrives
    /// with Ctrl held. Only the four arrows have one: Ctrl+Home and Ctrl+End are
    /// already spoken for as host-side scrollback jumps, and nothing has asked
    /// for the rest.
    var controlModified: SpecialKey? {
        switch self {
        case .up: return .ctrlUp
        case .down: return .ctrlDown
        case .left: return .ctrlLeft
        case .right: return .ctrlRight
        default: return nil
        }
    }

    /// The function keys, in order, for UI that wants them as a group.
    static let functionKeys: [SpecialKey] = [.f1, .f2, .f3, .f4, .f5, .f6,
                                             .f7, .f8, .f9, .f10, .f11, .f12]
    var label: String {
        switch self {
        case .up: return "Up Arrow"
        case .down: return "Down Arrow"
        case .left: return "Left Arrow"
        case .right: return "Right Arrow"
        case .ctrlUp: return "Ctrl+Up"
        case .ctrlDown: return "Ctrl+Down"
        case .ctrlLeft: return "Ctrl+Left"
        case .ctrlRight: return "Ctrl+Right"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .insert: return "Insert"
        case .delete: return "Forward Delete"
        case .f1: return "F1"
        case .f2: return "F2"
        case .f3: return "F3"
        case .f4: return "F4"
        case .f5: return "F5"
        case .f6: return "F6"
        case .f7: return "F7"
        case .f8: return "F8"
        case .f9: return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }
}

/// A named keyboard profile. Preset profiles supply termcap-style bindings;
/// `.custom` means the user has edited them.
enum KeyProfile: String, CaseIterable, Identifiable {
    case wordStar = "WordStar"
    case vt100 = "VT100/ANSI"
    case vt52 = "VT52"
    case custom = "Custom"
    var id: String { rawValue }

    /// Termcap-style bindings for preset profiles, or nil for `.custom`.
    var bindings: [SpecialKey: String]? {
        switch self {
        case .wordStar:
            // WordStar "diamond" — the port's historical default arrow behavior.
            return [.up: "^E", .down: "^X", .left: "^S", .right: "^D",
                    // Ctrl+arrow is the xterm modified form even here, matching
                    // z80cpmw byte for byte, rather than WordStar's word-left/
                    // word-right ^A/^F. The diamond is the *unmodified* arrows'
                    // convention; the modified ones have a cross-terminal
                    // meaning and there is no WordStar sequence that would mean
                    // the same thing in the other ports. A user who wants
                    // ^A/^F has them one edit away in the Custom profile.
                    .ctrlUp: "\\E[1;5A", .ctrlDown: "\\E[1;5B",
                    .ctrlRight: "\\E[1;5C", .ctrlLeft: "\\E[1;5D",
                    .home: "^Q^S", .end: "^Q^D", .pageUp: "^R", .pageDown: "^C",
                    .insert: "^V", .delete: "^G",
                    // WordStar has no function-key convention of its own, so the
                    // F-keys carry the same VT220 sequences here as elsewhere -
                    // a program that reads them gets something sensible, and a
                    // program that does not is unaffected.
                    .f1: "\\EOP", .f2: "\\EOQ", .f3: "\\EOR", .f4: "\\EOS",
                    .f5: "\\E[15~", .f6: "\\E[17~", .f7: "\\E[18~", .f8: "\\E[19~",
                    .f9: "\\E[20~", .f10: "\\E[21~", .f11: "\\E[23~", .f12: "\\E[24~"]
        case .vt100:
            return [.up: "\\E[A", .down: "\\E[B", .right: "\\E[C", .left: "\\E[D",
                    // CSI 1 ; 5 <final> - the xterm convention, where the 5 is
                    // the Ctrl modifier. Identical to z80cpmw/Keymap.h.
                    .ctrlUp: "\\E[1;5A", .ctrlDown: "\\E[1;5B",
                    .ctrlRight: "\\E[1;5C", .ctrlLeft: "\\E[1;5D",
                    .home: "\\E[H", .end: "\\E[F", .pageUp: "\\E[5~", .pageDown: "\\E[6~",
                    .insert: "\\E[2~", .delete: "\\E[3~",
                    .f1: "\\EOP", .f2: "\\EOQ", .f3: "\\EOR", .f4: "\\EOS",
                    .f5: "\\E[15~", .f6: "\\E[17~", .f7: "\\E[18~", .f8: "\\E[19~",
                    .f9: "\\E[20~", .f10: "\\E[21~", .f11: "\\E[23~", .f12: "\\E[24~"]
        case .vt52:
            return [.up: "\\EA", .down: "\\EB", .right: "\\EC", .left: "\\ED",
                    // A VT52 has no modifier convention at all - there is no
                    // parameterised CSI to put a 5 in - so Ctrl+arrow is just
                    // the arrow, which is also what this port did before the
                    // modified slots existed. Sending the xterm form here would
                    // be the same lie as giving a VT52 F5-F12.
                    .ctrlUp: "\\EA", .ctrlDown: "\\EB",
                    .ctrlRight: "\\EC", .ctrlLeft: "\\ED",
                    .home: "\\EH", .end: "", .pageUp: "", .pageDown: "",
                    .insert: "", .delete: "^?",
                    // A real VT52 has only PF1-PF4, on the keypad, as ESC P..S.
                    // F5-F12 have no VT52 meaning and send nothing rather than
                    // borrowing a VT100 sequence the guest cannot be expecting.
                    .f1: "\\EP", .f2: "\\EQ", .f3: "\\ER", .f4: "\\ES",
                    .f5: "", .f6: "", .f7: "", .f8: "",
                    .f9: "", .f10: "", .f11: "", .f12: ""]
        case .custom:
            return nil
        }
    }
}

/// Resolves termcap-style escape strings into the byte sequences sent to the
/// guest. Schema (matches the z80cpmw / romwbw_emu family):
///   \E = 0x1B, \n \r \t \b \f, \s = space, \\ = backslash, \NNN = octal byte,
///   ^X = control (X & 0x1F), ^? = 0x7F (DEL); any other char is a literal.
struct KeyMap {
    var bindings: [SpecialKey: String]

    /// Byte sequence for a key press.
    ///
    /// A modified key with no binding of its own falls back to the unmodified
    /// one - z80cpmw's KeyMap::find() does exactly this - so a map that predates
    /// the Ctrl+arrow slots keeps sending what it always sent. The distinction
    /// an absent entry has from an empty one matters and is deliberate: an
    /// empty binding means "send nothing" and does NOT fall back, which is what
    /// lets a profile say a modified key is unbound.
    func bytes(for key: SpecialKey) -> [UInt8] {
        if let s = bindings[key] { return KeyMap.expand(s) }
        if let base = key.unmodifiedBase, let s = bindings[base] { return KeyMap.expand(s) }
        return []
    }

    static func expand(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\" && i + 1 < chars.count {
                let n = chars[i + 1]
                switch n {
                case "E", "e": out.append(0x1B); i += 2
                case "n": out.append(0x0A); i += 2
                case "r": out.append(0x0D); i += 2
                case "t": out.append(0x09); i += 2
                case "b": out.append(0x08); i += 2
                case "f": out.append(0x0C); i += 2
                case "s": out.append(0x20); i += 2
                case "\\": out.append(0x5C); i += 2
                case "0", "1", "2", "3", "4", "5", "6", "7":
                    var j = i + 1, val = 0, count = 0
                    while j < chars.count, count < 3, chars[j].isASCII,
                          let d = chars[j].wholeNumberValue, (0...7).contains(d) {
                        val = val * 8 + d; j += 1; count += 1
                    }
                    out.append(UInt8(val & 0xFF)); i = j
                default:
                    if let a = n.asciiValue { out.append(a) }
                    i += 2
                }
            } else if c == "^" && i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "?" {
                    out.append(0x7F); i += 2
                } else if let a = n.asciiValue {
                    out.append(a & 0x1F); i += 2
                } else {
                    i += 2
                }
            } else {
                if let a = c.asciiValue { out.append(a) }
                i += 1
            }
        }
        return out
    }
}
