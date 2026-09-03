//
//  TerminalScreen.swift
//  iOSCPM
//
//  The terminal itself: the cell grid, the cursor, the scrolling region, the
//  scrollback buffer, and the whole VT100/ANSI/VT52 escape parser that drives
//  them.
//
//  This is the last and largest of the extractions that TerminalDialect,
//  ControlKey, ExportPath, CGAColor and TerminalRendition were each the earlier
//  steps of, and it is made for the same one reason: nothing in this file
//  imports UIKit, SwiftUI, AVFoundation or the emulator, so
//  Tests/TerminalScreenTests.swift can drive it with `xcrun --sdk macosx
//  swiftc` on a machine that has no simulator and no display.
//
//  `todo.txt` carried "the CSI parser has no unit tests" from build 51.
//  TerminalRendition closed the SGR half of it. This closes the rest: the
//  cursor, the erase family, insert/delete, the scrolling region, deferred
//  autowrap, the answerbacks, the VT52 dialect and the scrollback.
//
//  ## What stays outside
//
//  A terminal is not a pure value - it beeps, and it answers questions. Both
//  of those used to be a direct call into the emulator or the audio engine from
//  the middle of the parser, which is precisely what made the parser
//  untestable. They are queues now:
//
//    * `pendingResponses` collects the bytes a device report owes the guest
//      (CPR, DSR, DA, the ESC Z identify reply). The host drains it with
//      `takeResponses()` and writes them back to the emulator.
//    * `pendingBells` counts the BELs seen. The host drains it with
//      `takeBells()` and decides - by consulting a setting the screen knows
//      nothing about - whether to make a noise.
//
//  Draining rather than calling means the parser can be run with no host at
//  all, and a test can assert on what the terminal *would* have said.
//
//  ## Coordinates
//
//  Everything here is 0-based and clamped to the grid. The 1-based numbers in
//  the wire protocol are converted at the edge, in `executeCSI`, exactly where
//  they arrive.
//

import Foundation

// MARK: - Terminal Cell

struct TerminalCell: Equatable {
    var character: Character = " "
    var foreground: UInt8 = 7  // White
    var background: UInt8 = 0  // Black

    /// CellFlags.bold / .underline / .blink - the per-cell face, which the
    /// packed CGA byte above has no room for. See TerminalRendition.swift for
    /// the bit values, which are z80cpmw's and cpmdroid's byte for byte.
    ///
    /// Reverse video is deliberately absent: it is resolved into the two
    /// colours at the write, which is what makes SGR 7 and 27 exact inverses.
    var flags: UInt8 = 0
}

// MARK: - Terminal Screen

struct TerminalScreen {

    // MARK: Geometry

    let rows: Int
    let cols: Int

    init(rows: Int = 25, cols: Int = 80, scrollbackCapacity: Int = 1000, bellEnabled: Bool = true) {
        self.rows = rows
        self.cols = cols
        self.scrollbackCapacity = min(max(0, scrollbackCapacity), TerminalScreen.maxScrollbackCapacity)
        self.bellEnabled = bellEnabled
        self.cells = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)
        self.scrollBottom = rows - 1
    }

    // MARK: The grid

    /// The live viewport. `private(set)` because every write has to go through
    /// a method that keeps the cursor, the wrap state and the scrollback
    /// consistent with it; `place(_:row:col:)` is the one direct-poke door and
    /// it exists for the pre-boot banner.
    private(set) var cells: [[TerminalCell]]

    var cursorRow: Int = 0
    var cursorCol: Int = 0

    /// DECTCEM (ESC[?25h / l). Full-screen programs hide the cursor while they
    /// redraw so it does not strobe around the screen. Kept separate from the
    /// blink phase and from `isScrolledBack`, which suppress drawing for their
    /// own reasons.
    var cursorVisible = true

    private var savedCursorRow: Int = 0
    private var savedCursorCol: Int = 0

    /// Top of the scrolling region (0-based).
    private(set) var scrollTop: Int = 0
    /// Bottom of the scrolling region (0-based, inclusive).
    private(set) var scrollBottom: Int

    /// DECAWM (ESC[?7h / l). On - the default, and what a VT100 powers up as -
    /// writing the last column arms `pendingWrap`. Off, the cursor stays put and
    /// each further character overwrites the last cell.
    private(set) var autoWrap = true

    /// Deferred autowrap (VT100 "last column" behavior): after a glyph is written
    /// to the rightmost column the cursor stays put and we only wrap when the next
    /// printable character arrives. Without this, writing to the bottom-right corner
    /// scrolls the screen and corrupts any full-screen layout (WordStar, Zork, the
    /// TERMDEF border test, etc.).
    private(set) var pendingWrap: Bool = false

    /// The current graphic rendition: the CGA attribute byte, the three
    /// per-cell face flags, and the reverse-video toggle. The whole of SGR
    /// lives in TerminalRendition.swift.
    private(set) var rendition = TerminalRendition()

    /// Which terminal we are pretending to be. Default is ANSI/VT100; see
    /// TerminalDialect for how a stream switches it and why that is delicate.
    /// Only ESC D / E / H and the ESC Z reply differ by dialect, so ANSI
    /// behavior is unchanged while this stays .ansi.
    private(set) var dialect = TerminalDialect()

    // MARK: Side-effect queues

    /// Bytes the terminal owes the guest in reply to a device report. Drained
    /// by the host with `takeResponses()`.
    private(set) var pendingResponses: [String] = []

    /// How many BELs the terminal has decided are worth making a noise about
    /// since the host last looked. Drained by the host with `takeBells()`,
    /// which is the only thing that owns an audio engine.
    private(set) var pendingBells: Int = 0

    /// Whether BEL (0x07) counts at all.
    ///
    /// A guest that BELs in a loop could not be shut up. cpmdroid made this a
    /// setting first and z80cpmw followed in 480edcb; the gate lives here, next
    /// to the counter, so that suppression is testable with no audio engine
    /// anywhere near it - which is where z80cpmw put it, for the same reason.
    ///
    /// It is the USER'S setting, not the guest's, so `resetToPowerOn()`
    /// deliberately leaves it alone: a program must not be able to switch the
    /// bell back on for someone who turned it off. z80cpmw's clear() makes the
    /// same exception and its test suite asserts it.
    ///
    /// Suppressing the bell suppresses the bell and nothing else. BEL has never
    /// moved the cursor or touched a cell, and it still does not.
    var bellEnabled: Bool

    mutating func takeResponses() -> [String] {
        defer { pendingResponses = [] }
        return pendingResponses
    }

    mutating func takeBells() -> Int {
        defer { pendingBells = 0 }
        return pendingBells
    }

    // MARK: Scrollback

    static let maxScrollbackCapacity = 100000

    /// Full lines that have scrolled off the top of the live viewport.
    private var scrollbackLines: [[TerminalCell]] = []

    /// Scrollback capacity in lines; 0 disables capture. Clamped 0...100000,
    /// matching the z80cpmw `display.scrollbackLines` schema. Persistence is
    /// the host's job - see EmulatorViewModel.scrollbackCapacity.
    var scrollbackCapacity: Int {
        didSet {
            let clamped = min(max(0, scrollbackCapacity), TerminalScreen.maxScrollbackCapacity)
            if clamped != scrollbackCapacity { scrollbackCapacity = clamped; return }
            applyScrollbackCapacity()
        }
    }

    /// How many lines the user has scrolled up from the live bottom (0 = live).
    private(set) var scrollbackOffset: Int = 0

    var isScrolledBack: Bool { scrollbackOffset > 0 }
    var scrollbackAvailable: Int { scrollbackLines.count }

    /// The `rows` rows currently visible: the live grid when at the bottom, or
    /// a window into (scrollback + live) when scrolled up.
    var displayCells: [[TerminalCell]] {
        guard scrollbackOffset > 0 else { return cells }
        let total = scrollbackLines + cells
        let bottomExclusive = max(0, total.count - scrollbackOffset)
        let start = max(0, bottomExclusive - rows)
        var slice = Array(total[start..<bottomExclusive])
        if slice.count > rows { slice = Array(slice.suffix(rows)) }
        while slice.count < rows {
            slice.append(Array(repeating: TerminalCell(), count: cols))
        }
        return slice
    }

    /// Scroll the viewport by `lines` (positive = back into history, negative =
    /// toward the live bottom). Clamped to the available scrollback.
    mutating func adjustScrollback(byLines lines: Int) {
        let clamped = min(max(0, scrollbackOffset + lines), scrollbackLines.count)
        if clamped != scrollbackOffset { scrollbackOffset = clamped }
    }

    /// Snap back to the live bottom of the terminal.
    mutating func scrollToLiveBottom() {
        if scrollbackOffset != 0 { scrollbackOffset = 0 }
    }

    /// Drop the transcript of the session that just ended.
    ///
    /// Called from both places a fresh session begins, rather than written out
    /// at each, because only one of them used to do it: reset() cleared the
    /// history and startEmulator() did not, so Stop then Play left the dead
    /// machine's output above the new banner and could open already parked in
    /// history. z80cpmw calls resetScrollback() from both of its own, and this
    /// carries the name for that reason.
    mutating func resetScrollback() {
        if !scrollbackLines.isEmpty { scrollbackLines.removeAll() }
        if scrollbackOffset != 0 { scrollbackOffset = 0 }
    }

    /// Apply a changed capacity to the existing buffer: 0 clears history, a
    /// smaller cap trims the oldest lines. New captures honour the cap in scrollUp.
    private mutating func applyScrollbackCapacity() {
        let cap = scrollbackCapacity
        if cap == 0 {
            if !scrollbackLines.isEmpty { scrollbackLines.removeAll() }
            if scrollbackOffset != 0 { scrollbackOffset = 0 }
        } else if scrollbackLines.count > cap {
            scrollbackLines.removeFirst(scrollbackLines.count - cap)
            if scrollbackOffset > cap { scrollbackOffset = cap }
        }
    }

    // MARK: Attributes

    /// The current attribute as it should actually be drawn.
    private var displayAttr: UInt8 { rendition.displayAttr }

    /// The cell every erase leaves behind: a space in the CURRENT rendition,
    /// not a default one. This is background-colour-erase, what a real VT and
    /// xterm do, and it is why a program can set a colour, clear, and get a
    /// screen of that colour.
    ///
    /// The nibbles are unpacked exactly as the glyph-write path unpacks them,
    /// so an erased cell and a character written into it afterwards always
    /// agree - which is the whole point. Filling with a hardcoded fg 7 / bg 0
    /// was only survivable while the erase also reset the rendition to that
    /// same default, and this terminal's erases never did.
    ///
    /// z80cpmw's TerminalView::blankCell() is the same function; cpmdroid's
    /// ED/EL already fill from the current rendition, and the web frontend gets
    /// it from xterm.js. This port was the last one filling with a default.
    ///
    /// The machine-level paths (`clearTerminal`, `resetToPowerOn`) must put the
    /// rendition back to 0x07 BEFORE they clear, or a fresh boot inherits the
    /// colour the dead session ended on.
    /// The flags are deliberately NOT carried. Underline and blink are visible
    /// on a space, so an erase that kept them would draw a rule under all 2000
    /// cells after ESC[4m ESC[2J - z80cpmw zeroes them at the same site and for
    /// the same reason. The colours are carried, which is the whole point of
    /// this being background-colour-erase.
    private var blankCell: TerminalCell {
        let attr = displayAttr
        return TerminalCell(character: " ",
                            foreground: attr & 0x0F,
                            background: (attr >> 4) & 0x07,
                            flags: 0)
    }

    // MARK: - Machine-level operations

    /// Erase the whole screen and home the cursor. Nothing else: not the
    /// rendition, not the parser state, not the scrolling region.
    ///
    /// This is what ESC[2J, VT52 ESC E and the HBIOS VDA clear mean.
    /// Erase-in-display says what to do with the cells and says nothing about
    /// the terminal's modes, so a program that sets a colour, sets a scrolling
    /// region and then clears its screen must come back to both still in force.
    /// The scrolling-region reset that used to live here was a bug of exactly
    /// that kind - ED is not DECSTBM - and it belongs to clearTerminal() alone.
    /// z80cpmw split the same two jobs apart for the same reason; see its
    /// TerminalView::eraseScreen().
    ///
    /// Homing the cursor IS the one thing here a strict VT100 would not do, and
    /// it stays: both sibling ports home it, and CP/M software written against
    /// ANSI.SYS expects ESC[2J to home.
    mutating func eraseScreen() {
        let blank = blankCell
        for row in 0..<rows {
            for col in 0..<cols {
                cells[row][col] = blank
            }
        }
        cursorRow = 0
        cursorCol = 0
        pendingWrap = false
    }

    /// Erase the screen AND put the terminal back to power-on state. This is
    /// the machine-level clear - Start and Reset - and no guest sequence
    /// reaches it.
    ///
    /// The rendition goes back to the default FIRST, because eraseScreen()
    /// paints the current one: reset it afterwards and a fresh boot would be
    /// filled with whatever colour the last session happened to end on.
    mutating func clearTerminal() {
        rendition.reset()
        eraseScreen()
        scrollTop = 0
        scrollBottom = rows - 1
    }

    /// Everything a cold boot puts back, in the order it has to happen.
    ///
    /// The dialect, the parser state and the two sticky DEC modes come first
    /// and the clear comes last, because an erase paints the CURRENT
    /// background: clearing first and resetting the rendition second would
    /// leave the screen in the dying session's colour. A guest that hid the
    /// cursor and then died must not leave it hidden for the next session, and
    /// DECAWM off is just as sticky.
    mutating func resetToPowerOn() {
        dialect.reset()
        escapeState = .normal
        escapeParams = []
        escapeCurrentParam = ""
        escapePrivateMode = false
        autoWrap = true
        pendingWrap = false
        cursorVisible = true
        savedCursorRow = 0
        savedCursorCol = 0
        pendingResponses = []
        pendingBells = 0
        clearTerminal()
        resetScrollback()
    }

    // MARK: - Direct writes (host banners, not guest output)

    /// Place text at an absolute position without moving the cursor or
    /// disturbing the parser. The pre-boot banner is the only caller: it paints
    /// a screen nobody is typing at yet.
    mutating func place(_ text: String, row: Int, col: Int) {
        guard row >= 0, row < rows else { return }
        var c = col
        for char in text {
            guard c >= 0 else { c += 1; continue }
            guard c < cols else { return }
            cells[row][c].character = char
            c += 1
        }
    }

    /// Write a string to the terminal at the current cursor position.
    ///
    /// This is the host's own printf, not the guest's data path: it takes a
    /// Swift string, treats "\n" as CR+LF, and does not run the escape parser.
    mutating func write(_ text: String) {
        for char in text {
            if char == "\n" {
                cursorRow += 1
                cursorCol = 0
                if cursorRow >= rows {
                    cursorRow = rows - 1
                }
            } else {
                if cursorCol < cols {
                    cells[cursorRow][cursorCol].character = char
                    cells[cursorRow][cursorCol].foreground = 7  // White
                    cursorCol += 1
                }
            }
        }
    }

    // MARK: - HBIOS VDA entry points

    /// eraseScreen(), not clearTerminal(): this is the guest asking HBIOS to
    /// clear the display, which fills with the attribute the guest last set
    /// through `vdaSetAttr`. It is not a machine reset, so it must not take the
    /// rendition or the scrolling region with it.
    mutating func vdaClear() {
        eraseScreen()
    }

    mutating func vdaSetCursor(row: Int, col: Int) {
        cursorRow = min(max(row, 0), rows - 1)
        cursorCol = min(max(col, 0), cols - 1)
    }

    mutating func vdaScrollUp(_ lines: Int) {
        scrollUp(lines)
    }

    /// Attr is CGA-style: bits 0-3 = foreground, bits 4-6 = background,
    /// bit 7 = blink. This replaces the whole byte, so any SGR 7 swap is gone
    /// with it - and so are the face flags, which the byte cannot express.
    mutating func vdaSetAttr(_ attr: UInt8) {
        rendition.attr = attr
        rendition.flags = 0
        rendition.reverse = false
    }

    // MARK: - Escape sequence parser

    private enum EscapeState {
        case normal
        case escape          // Received ESC
        case csi             // Received ESC [
        case csiParam        // Collecting CSI parameters
        case vt52Row         // Received ESC Y, expecting the row byte (value + 0x20)
        case vt52Col         // Received ESC Y <row>, expecting the col byte (value + 0x20)
        case escConsumeOne   // Swallow one byte (charset/line-size designation)
    }
    private var escapeState: EscapeState = .normal
    private var escapeParams: [Int] = []
    private var escapeCurrentParam: String = ""
    /// True once a private-parameter marker - '?', '<', '=' or '>' - has been
    /// seen in the current CSI sequence.
    private var escapePrivateMode: Bool = false
    private var vt52CursorRow: Int = 0     // Row latched while parsing ESC Y <row> <col>

    /// True while a sequence is part-parsed. Only tests and diagnostics need
    /// this; the parser itself branches on the private state.
    var isMidSequence: Bool { escapeState != .normal }

    /// Feed one byte of guest output through the VT100/ANSI escape parser.
    /// This is the terminal's whole public data path.
    mutating func receive(_ ch: unichar) {
        switch escapeState {
        case .normal:
            processNormalChar(ch)

        case .escape:
            processEscapeChar(ch)

        case .csi, .csiParam:
            processCSIChar(ch)

        case .vt52Row:
            // VT52 direct cursor address: row is the byte value biased by 0x20
            vt52CursorRow = min(max(Int(ch) - 0x20, 0), rows - 1)
            escapeState = .vt52Col

        case .vt52Col:
            // VT52 direct cursor address: col is the byte value biased by 0x20
            cursorRow = vt52CursorRow
            cursorCol = min(max(Int(ch) - 0x20, 0), cols - 1)
            pendingWrap = false
            escapeState = .normal

        case .escConsumeOne:
            // Swallow the single parameter byte of a charset/line-size designation.
            escapeState = .normal
        }
    }

    /// Convenience for tests and for host strings that carry escapes: feed a
    /// whole string through `receive`, one UTF-16 unit at a time.
    mutating func receive(string: String) {
        for unit in Array(string.utf16) { receive(unit) }
    }

    /// Process character in normal (non-escape) state
    private mutating func processNormalChar(_ ch: unichar) {
        switch ch {
        case 0x07: // Bell
            if bellEnabled { pendingBells += 1 }

        case 0x08: // Backspace
            pendingWrap = false
            if cursorCol > 0 {
                cursorCol -= 1
            }

        case 0x09: // Tab
            pendingWrap = false
            cursorCol = min((cursorCol + 8) & ~7, cols - 1)

        case 0x0A: // Line feed (with implicit CR for compatibility)
            pendingWrap = false
            cursorCol = 0  // Reset column for Unix-style LF-only files
            if cursorRow < scrollTop {
                // Above scrolling region - just move down
                cursorRow += 1
            } else if cursorRow < scrollBottom {
                // Within scrolling region but not at bottom - move down
                cursorRow += 1
            } else if cursorRow == scrollBottom {
                // At bottom of scrolling region - scroll the region
                scrollRegion(scrollTop, scrollBottom, 1)
                // cursorRow stays at scrollBottom
            }
            // If cursorRow > scrollBottom (below region), do nothing

        case 0x0D: // Carriage return
            pendingWrap = false
            cursorCol = 0

        case 0x1B: // ESC - start escape sequence
            escapeState = .escape
            escapeParams = []
            escapeCurrentParam = ""
            escapePrivateMode = false

        default:
            // Printable character
            if ch >= 0x20 && ch <= 0x7E {
                // Resolve a deferred wrap left armed by the previous last-column write.
                if pendingWrap {
                    cursorCol = 0
                    cursorRow += 1
                    if cursorRow >= rows {
                        scrollUp(1)
                        cursorRow = rows - 1
                    }
                    pendingWrap = false
                }
                let char = Character(UnicodeScalar(ch) ?? UnicodeScalar(32))
                cells[cursorRow][cursorCol].character = char
                let attr = displayAttr
                cells[cursorRow][cursorCol].foreground = attr & 0x0F
                cells[cursorRow][cursorCol].background = (attr >> 4) & 0x07
                cells[cursorRow][cursorCol].flags = rendition.flags
                if cursorCol >= cols - 1 {
                    // At the rightmost column: arm a deferred wrap instead of
                    // moving now, so writing the corner cell does not scroll the
                    // screen. With DECAWM off there is no wrap to arm and the
                    // cursor simply stays on the last column, overwriting it.
                    if autoWrap { pendingWrap = true }
                } else {
                    cursorCol += 1
                }
            }
        }
    }

    /// Process character after ESC received
    private mutating func processEscapeChar(_ ch: unichar) {
        // Settle the dialect first, so the cases below read a current answer.
        // This subsumes the per-case assignments the VT52 branches used to
        // make; TerminalDialect owns which bytes are taken as proof.
        dialect.noteEscapeByte(ch)

        // Any escape sequence that follows resolves/cancels a pending autowrap.
        switch ch {
        case 0x5B: // '[' - CSI (Control Sequence Introducer)
            escapeState = .csi
            return  // CSI handler runs; keep collecting, do not fall through

        case 0x37: // '7' - DECSC (Save Cursor)
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol

        case 0x38: // '8' - DECRC (Restore Cursor)
            pendingWrap = false
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol

        case 0x44: // 'D'
            pendingWrap = false
            if dialect.isVT52 {
                // VT52 cursor left
                if cursorCol > 0 { cursorCol -= 1 }
            } else {
                // VT100 Index (move cursor down, scroll if needed)
                cursorRow += 1
                if cursorRow >= rows {
                    scrollUp(1)
                    cursorRow = rows - 1
                }
            }

        case 0x4D: // 'M' - Reverse Index (move cursor up, scroll if needed)
            pendingWrap = false
            if cursorRow > 0 {
                cursorRow -= 1
            }

        case 0x45: // 'E'
            pendingWrap = false
            if dialect.isVT52 {
                // Heath/Zenith VT52: clear screen and home
                eraseScreen()
            } else {
                // VT100 Next Line
                cursorCol = 0
                cursorRow += 1
                if cursorRow >= rows {
                    scrollUp(1)
                    cursorRow = rows - 1
                }
            }

        // ---- VT52 escape sequences ----
        case 0x41: // 'A' - VT52 cursor up
            pendingWrap = false
            if cursorRow > 0 { cursorRow -= 1 }

        case 0x42: // 'B' - VT52 cursor down
            pendingWrap = false
            cursorRow = min(cursorRow + 1, rows - 1)

        case 0x43: // 'C' - VT52 cursor right
            pendingWrap = false
            cursorCol = min(cursorCol + 1, cols - 1)

        case 0x48: // 'H' - VT52 cursor home (no VT100 effect; HTS unsupported)
            if dialect.isVT52 {
                pendingWrap = false
                cursorRow = 0
                cursorCol = 0
            }

        case 0x49: // 'I' - VT52 reverse line feed
            pendingWrap = false
            if cursorRow > 0 {
                cursorRow -= 1
            }
            // At the top row we have no downward-scroll helper; clamp rather than
            // scrolling the wrong way.

        case 0x4A: // 'J' - VT52 erase to end of screen
            clearFromCursor()

        case 0x4B: // 'K' - VT52 erase to end of line
            let blank = blankCell
            for col in cursorCol..<cols {
                cells[cursorRow][col] = blank
            }

        case 0x59: // 'Y' - VT52 direct cursor address (two bytes follow)
            escapeState = .vt52Row
            return  // stay in escape parsing for the row/col bytes

        case 0x46, 0x47: // 'F'/'G' - VT52 enter/exit graphics mode (no glyph remap here)
            break

        case 0x5A: // 'Z' - identify
            pendingResponses.append(dialect.identifyReply)

        case 0x3C: // '<' - exit VT52, enter ANSI mode (handled above)
            break

        case 0x3D, 0x3E: // '='/'>' - keypad application/numeric mode (ignored)
            break

        case 0x28, 0x29, 0x2A, 0x2B, 0x23, 0x20:
            // '(' ')' '*' '+' designate a character set; '#' a line size; ' ' the
            // 7/8-bit control set. Each takes one trailing byte we don't act on but
            // must consume so it is not printed as a stray glyph.
            escapeState = .escConsumeOne
            return

        default:
            // Only process control characters, discard unknown printable chars
            if ch < 0x20 {
                escapeState = .normal
                processNormalChar(ch)
                return
            }
        }
        escapeState = .normal
    }

    /// A guest can emit an unbounded CSI parameter run. Bound both the digit
    /// count and the parameter count, and clamp the parsed value, so a runaway
    /// or hostile stream cannot grow the parser's state without limit or hand a
    /// wild row/column count to a handler. Same limits as z80cpmw.
    private static let maxCSIParamDigits = 6
    private static let maxCSIParams = 16

    /// Parse the accumulated parameter digits, clamped.
    private func takeCSIParam() -> Int {
        let value = Int(escapeCurrentParam) ?? 0
        return min(value, 9999)
    }

    /// Process character in CSI sequence
    private mutating func processCSIChar(_ ch: unichar) {
        // Control characters abort the sequence and are processed normally
        if ch < 0x20 {
            escapeState = .normal
            processNormalChar(ch)
            return
        }

        // Private-parameter markers. '?' introduces the DEC private modes;
        // '<', '=' and '>' introduce the secondary and tertiary device-attribute
        // forms and xterm's modifyOtherKeys. None of them is a FINAL byte, and
        // treating the last three as one is what made ESC[>c end at the '>' and
        // print its own tail as glyphs - the same shape of bug '?' had in
        // z80cpmw before it learned the whole set.
        if ch >= 0x3C && ch <= 0x3F { // '<' '=' '>' '?'
            escapePrivateMode = true
            escapeState = .csiParam
            return
        }

        // Intermediate bytes, space through '/'. They belong to the sequence
        // and are not acted on here, but they must not end it either: ESC[!p
        // (DECSTR) and ESC[<n> q (DECSCUSR, which is what a program sends to
        // pick a cursor shape) both carry one, and both used to terminate at it
        // and leave the final byte to print as a glyph.
        if ch >= 0x20 && ch <= 0x2F {
            escapeState = .csiParam
            return
        }

        // Check if it's a parameter digit or separator
        if ch >= 0x30 && ch <= 0x39 { // '0'-'9'
            // Leading zeros are padding, not magnitude - dropping them keeps a
            // zero-padded parameter from spending the digit budget and being
            // truncated to a small number. Past the cap the value saturates at
            // the clamp takeCSIParam applies, rather than losing its high digits.
            if escapeCurrentParam.isEmpty && ch == 0x30 {
                escapeState = .csiParam
                return
            }
            if escapeCurrentParam.count < TerminalScreen.maxCSIParamDigits {
                escapeCurrentParam.append(Character(UnicodeScalar(ch)!))
            }
            escapeState = .csiParam
            return
        }

        if ch == 0x3B { // ';' - parameter separator
            if escapeParams.count < TerminalScreen.maxCSIParams {
                escapeParams.append(takeCSIParam())
            }
            escapeCurrentParam = ""
            escapeState = .csiParam
            return
        }

        // Final character - execute the sequence
        if !escapeCurrentParam.isEmpty, escapeParams.count < TerminalScreen.maxCSIParams {
            escapeParams.append(takeCSIParam())
        }

        executeCSI(ch)
        escapeState = .normal
    }

    /// Execute a CSI sequence
    private mutating func executeCSI(_ finalChar: unichar) {
        let p1 = escapeParams.count > 0 ? escapeParams[0] : 0
        let p2 = escapeParams.count > 1 ? escapeParams[1] : 0

        switch finalChar {
        case 0x41: // 'A' - Cursor Up
            pendingWrap = false
            let n = max(p1, 1)
            cursorRow = max(cursorRow - n, 0)

        case 0x42: // 'B' - Cursor Down
            pendingWrap = false
            let n = max(p1, 1)
            cursorRow = min(cursorRow + n, rows - 1)

        case 0x43: // 'C' - Cursor Forward
            pendingWrap = false
            let n = max(p1, 1)
            cursorCol = min(cursorCol + n, cols - 1)

        case 0x44: // 'D' - Cursor Back
            pendingWrap = false
            let n = max(p1, 1)
            cursorCol = max(cursorCol - n, 0)

        case 0x47, 0x60: // 'G' or '`' - Cursor Horizontal Absolute (column)
            pendingWrap = false
            let col = max(p1, 1) - 1
            cursorCol = min(max(col, 0), cols - 1)

        case 0x64: // 'd' - Vertical Position Absolute (row)
            pendingWrap = false
            let row = max(p1, 1) - 1
            cursorRow = min(max(row, 0), rows - 1)

        case 0x48, 0x66: // 'H' or 'f' - Cursor Position
            pendingWrap = false
            let row = max(p1, 1) - 1  // 1-based to 0-based
            let col = max(p2, 1) - 1
            cursorRow = min(max(row, 0), rows - 1)
            cursorCol = min(max(col, 0), cols - 1)

        case 0x4A: // 'J' - Erase in Display
            switch p1 {
            case 0: // Clear from cursor to end of screen
                clearFromCursor()
            case 1: // Clear from beginning to cursor
                clearToCursor()
            case 2: // Clear entire screen
                // eraseScreen(), not clearTerminal(): ED 2 erases cells and
                // says nothing about the rendition or the scrolling region.
                eraseScreen()
            default:
                break
            }

        case 0x4B: // 'K' - Erase in Line
            let blank = blankCell
            switch p1 {
            case 0: // Clear from cursor to end of line
                for col in cursorCol..<cols {
                    cells[cursorRow][col] = blank
                }
            case 1: // Clear from beginning to cursor
                for col in 0...cursorCol {
                    cells[cursorRow][col] = blank
                }
            case 2: // Clear entire line
                for col in 0..<cols {
                    cells[cursorRow][col] = blank
                }
            default:
                break
            }

        case 0x4D: // 'M' - DL (Delete Line) - delete lines at cursor, scroll up
            // Delete n lines starting at cursor row, scroll remaining lines up
            let startRow = cursorRow
            let endRow = scrollBottom  // Use scrolling region bottom, or rows-1 if no region
            if startRow <= endRow {
                // Clamp to the region: deleting more lines than there are just
                // clears it. Unclamped, endRow - n + 1 falls below startRow and
                // the Range below traps - a live crash for an editor that asks
                // to delete to the bottom from near it.
                let n = min(max(p1, 1), endRow - startRow + 1)
                for row in startRow..<(endRow - n + 1) {
                    if row + n <= endRow {
                        cells[row] = cells[row + n]
                    }
                }
                // Clear the bottom n lines
                let blank = blankCell
                for row in max(endRow - n + 1, startRow)...endRow {
                    cells[row] = Array(repeating: blank, count: cols)
                }
            }

        case 0x4C: // 'L' - IL (Insert Line) - insert lines at cursor, scroll down
            // Insert n blank lines at cursor row, scroll remaining lines down
            let startRow = cursorRow
            let endRow = scrollBottom
            if startRow <= endRow {
                // Clamped for the same reason as DL above; the loops here happen
                // to survive an over-large n, but not by design.
                let n = min(max(p1, 1), endRow - startRow + 1)
                for row in stride(from: endRow, through: startRow + n, by: -1) {
                    if row - n >= startRow {
                        cells[row] = cells[row - n]
                    }
                }
                // Clear the top n lines (at cursor position)
                let blank = blankCell
                for row in startRow..<min(startRow + n, endRow + 1) {
                    cells[row] = Array(repeating: blank, count: cols)
                }
            }

        // The five editing finals below blank cells with `blankCell`, i.e. the
        // current SGR background, matching clearFromCursor/clearToCursor and the
        // rest of the erase family in this file. That decision was taken for the
        // whole family at once rather than introduced in half of it; see
        // blankCell for what it means and why.
        case 0x40: // '@' - ICH (Insert Character)
            // Shift the rest of the line right by n, blanking what opens up.
            // Characters pushed past the last column are lost, not wrapped:
            // ICH is defined within the line.
            if cursorRow < rows, cursorCol < cols {
                let n = min(max(p1, 1), cols - cursorCol)
                var row = cells[cursorRow]
                if cols - cursorCol - n > 0 {
                    for col in stride(from: cols - 1, through: cursorCol + n, by: -1) {
                        row[col] = row[col - n]
                    }
                }
                let blank = blankCell
                for col in cursorCol..<(cursorCol + n) {
                    row[col] = blank
                }
                cells[cursorRow] = row
            }

        case 0x50: // 'P' - DCH (Delete Character)
            // Shift the rest of the line left by n; the tail becomes blanks.
            if cursorRow < rows, cursorCol < cols {
                let n = min(max(p1, 1), cols - cursorCol)
                var row = cells[cursorRow]
                for col in cursorCol..<(cols - n) {
                    row[col] = row[col + n]
                }
                let blank = blankCell
                for col in max(cols - n, cursorCol)..<cols {
                    row[col] = blank
                }
                cells[cursorRow] = row
            }

        case 0x58: // 'X' - ECH (Erase Character)
            // Blank n cells from the cursor without moving anything: unlike DCH
            // the rest of the line stays where it is, and unlike EL the erase
            // stops after n.
            if cursorRow < rows, cursorCol < cols {
                let n = min(max(p1, 1), cols - cursorCol)
                let blank = blankCell
                for col in cursorCol..<(cursorCol + n) {
                    cells[cursorRow][col] = blank
                }
            }

        case 0x53: // 'S' - SU (Scroll Up)
            // Scroll the region up n lines. Content leaving the top of a full
            // screen goes to scrollback; content leaving a partial region does
            // not, matching what LF does - lines pushed out of a status-line
            // window were never history.
            // Whole screen goes through scrollUp() so the top line reaches
            // scrollback; a partial region goes through scrollRegion(), which
            // deliberately does not.
            let lines = max(p1, 1)
            if scrollTop == 0 && scrollBottom == rows - 1 {
                scrollUp(lines)
            } else {
                scrollRegion(scrollTop, scrollBottom, min(lines, scrollBottom - scrollTop + 1))
            }

        case 0x54: // 'T' - SD (Scroll Down)
            // The reverse: blank lines enter at the top of the region and the
            // bottom line falls off. Never touches scrollback in either
            // direction - nothing is leaving the top.
            for _ in 0..<max(p1, 1) {
                let top = scrollTop, bottom = scrollBottom
                if top <= bottom {
                    for row in stride(from: bottom, through: top + 1, by: -1) {
                        cells[row] = cells[row - 1]
                    }
                    cells[top] = Array(repeating: blankCell, count: cols)
                }
            }

        case 0x6D: // 'm' - SGR (Select Graphic Rendition)
            // A private marker makes this something else entirely. ESC[>4;2m
            // and ESC[>4m are xterm's modifyOtherKeys and say nothing about
            // colour; without this guard the bare one reached SGR as ESC[m and
            // reset the whole rendition. z80cpmw guards the same final for the
            // same reason.
            if !escapePrivateMode {
                // An empty list is ESC[m, which is ESC[0m; applySGR handles it.
                rendition.applySGR(escapeParams)
            }

        case 0x73: // 's' - Save cursor position (SCO)
            savedCursorRow = cursorRow
            savedCursorCol = cursorCol

        case 0x75: // 'u' - Restore cursor position (SCO)
            pendingWrap = false
            cursorRow = savedCursorRow
            cursorCol = savedCursorCol

        case 0x72: // 'r' - Set scrolling region (DECSTBM)
            // ESC[top;bottomr - set scrolling region (1-based)
            // ESC[r - reset to full screen
            pendingWrap = false
            let top = (escapeParams.count > 0 && escapeParams[0] > 0) ? escapeParams[0] - 1 : 0
            let bottom = (escapeParams.count > 1 && escapeParams[1] > 0) ? escapeParams[1] - 1 : rows - 1
            if top < bottom && bottom < rows {
                scrollTop = top
                scrollBottom = bottom
                // Cursor moves to home position after setting region
                cursorRow = 0
                cursorCol = 0
            }

        case 0x6E: // 'n' - Device Status Report (answerback)
            if !escapePrivateMode {
                if p1 == 6 {
                    // CPR: report cursor position, 1-based
                    pendingResponses.append("\u{1B}[\(cursorRow + 1);\(cursorCol + 1)R")
                } else if p1 == 5 {
                    // DSR: terminal OK
                    pendingResponses.append("\u{1B}[0n")
                }
            }

        case 0x63: // 'c' - Device Attributes (answerback)
            if !escapePrivateMode && p1 == 0 {
                // Identify as a VT100 with no options
                pendingResponses.append("\u{1B}[?1;0c")
            }

        case 0x68: // 'h' - Set Mode
            if escapePrivateMode {
                if escapeParams.contains(2) {
                    // DECANM set: select ANSI (VT100) mode
                    dialect.noteDECANM(selectsANSI: true)
                }
                if escapeParams.contains(7) {
                    autoWrap = true     // DECAWM
                }
                if escapeParams.contains(25) {
                    cursorVisible = true  // DECTCEM
                }
            }
            // Other DEC private modes are acknowledged but not acted upon.

        case 0x6C: // 'l' - Reset Mode
            if escapePrivateMode {
                if escapeParams.contains(2) {
                    // DECANM reset: select VT52 mode
                    dialect.noteDECANM(selectsANSI: false)
                }
                if escapeParams.contains(7) {
                    // DECAWM off: writing the last column overwrites it instead
                    // of wrapping. Clear any wrap already armed, or a pending
                    // one from before the mode change would still fire.
                    autoWrap = false
                    pendingWrap = false
                }
                if escapeParams.contains(25) {
                    cursorVisible = false  // DECTCEM
                }
            }
            // Other DEC private modes are acknowledged but not acted upon.

        default:
            // Unknown CSI sequence, ignore
            break
        }
    }

    // MARK: - Erase and scroll helpers

    /// Clear from cursor to end of screen
    private mutating func clearFromCursor() {
        let blank = blankCell
        // Clear rest of current line
        for col in cursorCol..<cols {
            cells[cursorRow][col] = blank
        }
        // Clear remaining lines
        for row in (cursorRow + 1)..<rows {
            for col in 0..<cols {
                cells[row][col] = blank
            }
        }
    }

    /// Clear from beginning to cursor
    private mutating func clearToCursor() {
        let blank = blankCell
        // Clear lines before current
        for row in 0..<cursorRow {
            for col in 0..<cols {
                cells[row][col] = blank
            }
        }
        // Clear current line up to cursor
        for col in 0...cursorCol {
            cells[cursorRow][col] = blank
        }
    }

    private mutating func scrollUp(_ lines: Int) {
        guard lines > 0 else { return }

        // Preserve the rows scrolling off the top into the scrollback buffer.
        // Capacity 0 disables capture entirely (z80cpmw parity).
        let cap = scrollbackCapacity
        if cap > 0 {
            let captured = min(lines, rows)
            for row in 0..<captured {
                scrollbackLines.append(cells[row])
            }
            if scrollbackLines.count > cap {
                scrollbackLines.removeFirst(scrollbackLines.count - cap)
            }
            // Keep the visible window anchored to the same content while the user
            // is reading history (up to the buffer cap).
            if scrollbackOffset > 0 {
                scrollbackOffset = min(scrollbackOffset + captured, scrollbackLines.count)
            }
        }

        let keep = max(0, rows - lines)
        for row in 0..<keep {
            cells[row] = cells[row + lines]
        }
        let blank = blankCell
        for row in keep..<rows {
            cells[row] = Array(repeating: blank, count: cols)
        }
    }

    private mutating func scrollRegion(_ top: Int, _ bottom: Int, _ lines: Int) {
        guard lines > 0 && top >= 0 && bottom < rows && top < bottom else { return }

        // A region that is the whole screen IS the screen scrolling, and the
        // lines leaving the top are history. scrollUp() is the one path that
        // captures them. Routing that case here rather than at each call site
        // is the point: the LF handler called scrollRegion() directly, so every
        // ordinary newline-driven scroll - which is nearly all of them - threw
        // its top line away, and the scrollback buffer stayed empty for the
        // whole life of the feature. The SU handler had this test inline and so
        // was the only path that ever captured anything.
        if top == 0 && bottom == rows - 1 {
            scrollUp(lines)
            return
        }

        // Scroll lines within the region [top, bottom]
        for row in top..<(bottom - lines + 1) {
            cells[row] = cells[row + lines]
        }
        // Clear the bottom lines of the region
        let blank = blankCell
        for row in (bottom - lines + 1)...bottom {
            cells[row] = Array(repeating: blank, count: cols)
        }
    }
}
