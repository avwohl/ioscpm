//
//  CGAColor.swift
//  iOSCPM
//
//  The one translation between the two colour orderings this terminal has to
//  live with, and the two attribute edits that use it.
//
//  This lives apart from the parser in EmulatorViewModel for the same reason
//  TerminalDialect does: it is a pure function of a byte - no screen, no
//  emulator, no UI - which is the only reason Tests/CGAColorTests.swift can
//  exercise it on a machine with no display.
//
//  ## Two orderings, and they are not the same
//
//      ANSI (what SGR 30-37 / 40-47 name)   CGA (what the attribute byte means)
//      0  black                             0  black
//      1  red                               1  blue
//      2  green                             2  green
//      3  yellow                            3  cyan
//      4  blue                              4  red
//      5  magenta                           5  magenta
//      6  cyan                              6  brown / dark yellow
//      7  white                             7  light grey
//
//  ANSI counts up in binary as blue-green-red; CGA counts up as red-green-blue.
//  So the translation is an exchange of bit 0 and bit 2 - equivalently
//  ((c & 1) << 2) | (c & 2) | ((c >> 2) & 1) - and four of the eight move:
//  1 <-> 4 (red/blue) and 3 <-> 6 (yellow/cyan). Storing an ANSI index straight
//  into the byte is why ESC[31m used to draw blue and ESC[44m used to fill red.
//
//  ## Why the byte stays CGA
//
//  Not an accident of this file. A CP/M guest can hand the emulator a raw CGA
//  attribute byte through RomWBW's HBIOS VDA "set attribute" call - HBF_VDASAT
//  in hbios_dispatch.cc, reaching this port through emu_video_set_attr() and
//  landing in emulatorVDASetAttr() unaltered - and TerminalView's cgaColors
//  palette is CGA-ordered. Both of those are correct as they stand. So the
//  translation belongs at the SGR parse site and nowhere else: not in the
//  renderer, not in the guest attribute path, not in the erase/blank-cell path.
//
//  The mapping happens to be an involution - applying it twice returns the
//  original, since exchanging two bits undoes itself - which is worth knowing
//  when reading the table but is not something any caller should lean on.
//

import Foundation

enum CGAColor {

    /// ANSI colour index -> CGA colour index, subscripted by the ANSI number.
    ///
    /// A table rather than the bit expression because this is the thing a
    /// reader wants to check against the two lists above, one row at a time.
    static let cgaForANSI: [UInt8] = [
        0,  // ANSI 0 black    -> CGA 0 black
        4,  // ANSI 1 red      -> CGA 4 red
        2,  // ANSI 2 green    -> CGA 2 green
        6,  // ANSI 3 yellow   -> CGA 6 brown/dark yellow
        1,  // ANSI 4 blue     -> CGA 1 blue
        5,  // ANSI 5 magenta  -> CGA 5 magenta
        3,  // ANSI 6 cyan     -> CGA 3 cyan
        7,  // ANSI 7 white    -> CGA 7 light grey
    ]

    /// Three bits in, three bits out.
    ///
    /// The intensity bit (0x08) is NOT a colour index and must never be routed
    /// through here - the mask would drop it silently. SGR 1 / 22 own that bit
    /// and the two call sites below preserve it rather than passing it in.
    static func fromANSI(_ ansi: UInt8) -> UInt8 {
        cgaForANSI[Int(ansi & 0x07)]
    }

    /// SGR 30-37: set the foreground colour, leaving everything else alone.
    ///
    /// 0xF8, not 0xF0. Bit 3 is the intensity bit SGR 1 sets, and it is not
    /// part of the colour: masking with 0xF0 cleared bold every time a colour
    /// arrived, so ESC[1;31m came out dim while ESC[31;1m came out bright.
    /// z80cpmw's TerminalView::applySGR masks with 0xF8 for exactly this
    /// reason; this port was the one still using 0xF0.
    static func withForeground(_ attr: UInt8, ansi: UInt8) -> UInt8 {
        (attr & 0xF8) | fromANSI(ansi)
    }

    /// SGR 40-47: set the background colour, leaving the whole low nibble -
    /// foreground colour and intensity together - alone.
    ///
    /// 0x0F is right as it stands: the background is three bits and has no
    /// intensity of its own, so there is no fourth bit to preserve. Bit 7 is
    /// CGA blink, which goes with the background here; nothing in this port
    /// reads it, because the cell unpack masks the background to three bits.
    static func withBackground(_ attr: UInt8, ansi: UInt8) -> UInt8 {
        (attr & 0x0F) | (fromANSI(ansi) << 4)
    }
}
