//
//  TerminalRendition.swift
//  iOSCPM
//
//  The current graphic rendition - the colours, the intensity, and the three
//  per-cell faces - and the whole of SGR.
//
//  Split out of EmulatorViewModel for the same reason TerminalDialect,
//  ControlKey, ExportPath and CGAColor were: it is a pure value with no screen,
//  no emulator and no UIKit behind it, which is the only reason
//  Tests/TerminalRenditionTests.swift can drive it on a machine with no
//  display. `todo.txt` has carried "the CSI parser has no unit tests" since
//  build 51; this closes the SGR half of it. The rest of the parser - the
//  cursor, the scrolling region, the screen buffer - is still untested and
//  still in that item.
//
//  ## What is stored, and why it is two things
//
//  `attr` is a packed CGA attribute byte, because a CP/M guest can set one
//  directly through RomWBW's HBIOS VDA "set attribute" call and TerminalView's
//  palette is CGA-ordered. See CGAColor.swift for that argument in full.
//
//  `flags` is the record a renderer reads for a heavier or underlined face.
//  It exists because the byte cannot carry those: eight colour bits, an
//  intensity bit, and nothing left over. z80cpmw's `TerminalCell::flags` and
//  cpmdroid's flags byte hold the same three bits with the same values, so a
//  cell from any of the three ports can be compared with a cell from another.
//
//  Reverse video is deliberately in NEITHER. It is resolved into the two
//  nibbles at the moment a cell is written (`displayAttr`), and is stored
//  nowhere else, which is what makes SGR 7 and SGR 27 exact inverses: folding
//  the swap into `attr` would be lossy, because the background is three bits
//  and the foreground is four.
//

import Foundation

/// Per-cell face bits. The values are z80cpmw's `TCELL_BOLD` /
/// `TCELL_UNDERLINE` / `TCELL_BLINK`, byte for byte, and cpmdroid adopted the
/// same three - so the three ports' cells can be diffed directly.
///
/// There is no italic bit because nothing can ask for one: SGR 3 is not
/// handled by any port in the family, and a fourth bit with no way to set it
/// would only invite a renderer to read it.
enum CellFlags {
    static let bold: UInt8      = 0x01
    static let underline: UInt8 = 0x02
    static let blink: UInt8     = 0x04
}

struct TerminalRendition: Equatable {

    /// The power-on attribute: CGA 7 (light grey) on CGA 0 (black). The same
    /// byte in both orderings, which is why no reset value moved when the
    /// ANSI/CGA translation landed in build 54.
    static let defaultAttr: UInt8 = 0x07

    var attr: UInt8 = defaultAttr
    var flags: UInt8 = 0

    /// True while SGR 7 is in effect. See the note at the top of this file for
    /// why it is not folded into `attr`.
    var reverse: Bool = false

    /// `attr` as it should actually be drawn.
    var displayAttr: UInt8 {
        reverse ? Self.swapNibbles(attr) : attr
    }

    /// Exchange the foreground and background nibbles of a CGA attribute byte.
    ///
    /// Lossy by nature - the background is three bits and the foreground four,
    /// so the intensity bit falls off the end - which is why this is only ever
    /// applied on the way to a cell and never stored back. `flags` is the only
    /// record of bold that survives it, which is half the reason it exists.
    static func swapNibbles(_ attr: UInt8) -> UInt8 {
        let fg = attr & 0x0F
        let bg = (attr >> 4) & 0x07
        return (fg << 4) | bg
    }

    /// Back to power-on: SGR 0, and what a machine-level clear installs.
    mutating func reset() {
        attr = Self.defaultAttr
        flags = 0
        reverse = false
    }

    /// Apply a whole `CSI ... m` parameter list.
    ///
    /// The list, rather than one parameter at a time, because two of the codes
    /// are only meaningful in terms of the parameters after them - see the
    /// 38/48 arm below - and a caller looping over the list itself cannot skip
    /// those. z80cpmw's executeCSI does the skipping at the call site; here it
    /// is inside, so the tests can reach it.
    ///
    /// An empty list is `ESC[m`, which is `ESC[0m`.
    mutating func applySGR(_ params: [Int]) {
        if params.isEmpty {
            apply(0)
            return
        }
        var i = 0
        while i < params.count {
            let param = params[i]
            // Extended colour: ESC[38;5;<n>m and ESC[38;2;<r>;<g>;<b>m, and 48
            // for the background. This terminal is CGA - sixteen foregrounds
            // and eight backgrounds - so there is nothing to apply, but the
            // sub-parameters still have to be stepped over. Read as parameters
            // in their own right they land as colours: the "44" of
            // ESC[38;5;44m set a red BACKGROUND, which is a colour the program
            // never asked for anywhere.
            //
            // The value is discarded rather than approximated onto the CGA
            // palette. Both siblings discard it, and a port that guessed a
            // nearest entry would put a colour on screen that no other port
            // shows for the same bytes.
            if param == 38 || param == 48 {
                if i + 1 < params.count {
                    switch params[i + 1] {
                    case 5:  i += 3   // ;5;<index>
                    case 2:  i += 5   // ;2;<r>;<g>;<b>
                    default: i += 2
                    }
                } else {
                    i += 1
                }
                continue
            }
            apply(param)
            i += 1
        }
    }

    /// Apply one SGR parameter.
    mutating func apply(_ param: Int) {
        switch param {
        case 0: // Reset
            reset()

        case 1: // Bold
            // BOTH the intensity bit and the flag, which is z80cpmw's rule.
            // The intensity bit is the only way bold shows in a colour, and the
            // flag is what the renderer reads for a heavier face - and the only
            // record that survives the reverse-video swap above.
            attr |= 0x08
            flags |= CellFlags.bold

        case 22: // Normal intensity - bold off
            attr &= ~0x08
            flags &= ~CellFlags.bold

        case 4: // Underline
            flags |= CellFlags.underline

        case 24: // Underline off
            flags &= ~CellFlags.underline

        case 5, 6: // Slow blink, rapid blink
            // One bit for both rates. Nothing here can tell them apart: there
            // is a single blink phase in the renderer and a flag reading it
            // would have exactly one speed to work with. ECMA-48 separates
            // them; one bit is the honest thing to store until something can
            // draw two.
            flags |= CellFlags.blink

        case 25: // Blink off - both rates
            flags &= ~CellFlags.blink

        case 7: // Reverse on - a toggle, not a swap: SGR 7 twice is still reverse
            reverse = true

        case 27: // Reverse off - the colours underneath were never disturbed
            reverse = false

        // The SGR parameter is an ANSI colour index and `attr` is a CGA-ordered
        // byte, so the index has to be translated on the way in - see
        // CGAColor.swift for both orderings and for why the byte is CGA. This
        // is the only place the translation happens.
        case 30...37: // Foreground colours
            attr = CGAColor.withForeground(attr, ansi: UInt8(param - 30))

        case 39: // Default foreground
            // Colour nibble back to 7, intensity left alone - exactly what a
            // 3x does. Bold and bright are the same bit inside a packed byte,
            // so the alternative would make ESC[1m ESC[39m silently drop the
            // bold. cpmdroid implements 39/49 and z80cpmw does not; this port
            // is the second of the three.
            attr = CGAColor.withForeground(attr, ansi: 7)

        case 40...47: // Background colours
            attr = CGAColor.withBackground(attr, ansi: UInt8(param - 40))

        case 49: // Default background
            attr = CGAColor.withBackground(attr, ansi: 0)

        case 90...97: // Bright foreground
            // The bright half, which this port was the last of the three to
            // have: ESC[91m used to fall through `default` and leave the byte
            // alone, so from a fresh reset it drew in CGA 7 - indistinguishable
            // from asking for no colour at all.
            //
            // Mask 0xF0, not 0xF8: the bright bit IS the intensity bit, so a
            // bright colour sets what SGR 1 would have set, exactly as SGR 1
            // followed by SGR 3x does. Preserving bit 3 here instead would
            // leave ESC[22m unable to dim a colour that was asked for bright.
            attr = (attr & 0xF0) | CGAColor.fromANSI(UInt8(param - 90)) | 0x08

        case 100...107: // Bright background
            // Folded onto the plain background. The background nibble is three
            // bits wide - bit 7 is blink on real CGA hardware, and the cell
            // unpack masks to three bits - so a bright background can only be
            // stored by borrowing that. It is not: a wrong shade beats a cell
            // that starts strobing. z80cpmw folds these the same way and for
            // the same reason; cpmdroid keeps them bright because a cell there
            // is a full ARGB value with no blink bit to borrow.
            attr = CGAColor.withBackground(attr, ansi: UInt8(param - 100))

        default:
            // SGR 21 falls through here on purpose. ECMA-48 calls it
            // double-underline; several terminals treat it as bold-off, and the
            // two readings disagree about the bit this would have to touch.
            // Nothing here can settle which a CP/M guest meant, and guessing
            // wrong is worse than ignoring it.
            break
        }
    }
}
