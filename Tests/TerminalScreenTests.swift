//
//  TerminalScreenTests.swift
//
//  What a program actually gets when it drives this terminal: the cursor, the
//  erase family, insert/delete, the scrolling region, deferred autowrap, the
//  answerbacks, the VT52 dialect and the scrollback.
//
//  `todo.txt` carried "the CSI parser still has no unit tests OUTSIDE SGR" from
//  build 51. TerminalRenditionTests closed the SGR half. This closes the rest,
//  and it exists at all because TerminalScreen was pulled out of
//  EmulatorViewModel: nothing in it imports UIKit, SwiftUI, AVFoundation or the
//  emulator, so the whole parser can be driven on a machine with no simulator.
//
//  Everything goes in through the ONE public data path a guest has -
//  `receive(_:)`, one UTF-16 unit at a time - and comes out through the public
//  accessors. No test reaches into the parser's private state to set it up,
//  which is what makes these checks say something about the terminal rather
//  than about this file. That is the shape z80cpmw's tests/test_vt52.cpp uses,
//  and several cases below are its cases.
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

/// `section` takes its body so a suite reads as its own table of contents.
func section(_ title: String, _ body: () -> Void) {
    section(title)
    body()
}

// MARK: - Fixtures

let ESC = "\u{1B}"

/// A fresh 25x80 terminal fed one string. The shape every check is written in,
/// so a failing line reads as the escape sequence that produced it.
func term(_ input: String = "") -> TerminalScreen {
    var s = TerminalScreen()
    s.receive(string: input)
    return s
}

extension TerminalScreen {
    /// One row as text, trailing blanks trimmed - what you would see on it.
    func line(_ row: Int) -> String {
        let text = String(cells[row].map { $0.character })
        return String(text.reversed().drop { $0 == " " }.reversed())
    }

    /// The same for a row of the visible window, which is the live grid or a
    /// window into history depending on where the user has scrolled to.
    func displayLine(_ row: Int) -> String {
        let text = String(displayCells[row].map { $0.character })
        return String(text.reversed().drop { $0 == " " }.reversed())
    }

    var cursor: (row: Int, col: Int) { (cursorRow, cursorCol) }

    /// Every cell on the screen, for the whole-screen assertions.
    var allCells: [TerminalCell] { cells.flatMap { $0 } }

    mutating func feed(_ s: String) { receive(string: s) }
}

func == (lhs: (row: Int, col: Int), rhs: (Int, Int)) -> Bool {
    lhs.row == rhs.0 && lhs.col == rhs.1
}

func at(_ s: TerminalScreen, _ row: Int, _ col: Int) -> Bool {
    s.cursorRow == row && s.cursorCol == col
}

// MARK: - The suite

func runAllTests() {

    section("Power-on state") {
        let s = term()
        check(s.rows == 25 && s.cols == 80, "a fresh terminal is 25x80")
        check(at(s, 0, 0), "the cursor is homed")
        check(s.cursorVisible, "the cursor is visible")
        check(s.scrollTop == 0 && s.scrollBottom == 24, "the scrolling region is the whole screen")
        check(s.autoWrap, "DECAWM is on, as a VT100 powers up")
        check(!s.pendingWrap, "with no wrap armed")
        check(s.rendition.attr == 0x07, "the rendition is CGA 7 on CGA 0")
        check(s.allCells.allSatisfy { $0.character == " " }, "every cell is a space")
        check(s.scrollbackAvailable == 0, "and there is no history behind it")
        check(!s.isScrolledBack, "so the view is at the live bottom")
        check(!s.isMidSequence, "and the parser is idle")
    }

    section("Printable characters and the cursor that follows them") {
        let s = term("HELLO")
        check(s.line(0) == "HELLO", "text lands on the top line")
        check(at(s, 0, 5), "and the cursor sits after it")

        let t = term("A\u{7F}B")
        check(t.line(0) == "AB", "DEL (0x7F) is not printable and is dropped")

        var u = term()
        u.receive(0x00)
        check(u.line(0) == "", "NUL prints nothing")
        check(at(u, 0, 0), "and moves nothing")
    }

    section("The C0 controls") {
        check(term("ABC\u{08}").cursor == (0, 2), "BS steps the cursor left")
        check(term("\u{08}").cursor == (0, 0), "BS at column 0 stays at column 0")
        check(term("ABC\u{08}X").line(0) == "ABX", "and the next glyph overwrites")

        check(term("\u{09}").cursor == (0, 8), "TAB from column 0 lands on 8")
        check(term("ABC\u{09}").cursor == (0, 8), "TAB from column 3 lands on 8")
        check(term("\u{09}\u{09}").cursor == (0, 16), "and the next TAB on 16")
        check(term("\(ESC)[1;77H\u{09}").cursor == (0, 79), "TAB never leaves the line")

        check(term("ABC\u{0D}").cursor == (0, 0), "CR homes the column")
        check(term("ABC\u{0D}X").line(0) == "XBC", "and does not erase what was there")

        check(term("ABC\u{0A}").cursor == (1, 0), "LF moves down and carries an implicit CR")
        check(term("ABC\u{0A}X").line(1) == "X", "so the next glyph starts the next line")
    }

    section("Deferred autowrap - the VT100 last column") {
        var s = term("\(ESC)[1;80H")
        check(at(s, 0, 79), "the cursor can be put on the last column")
        s.feed("X")
        check(s.line(0).count == 80, "a glyph written there lands in it")
        check(at(s, 0, 79), "and the cursor does NOT move")
        check(s.pendingWrap, "it arms a deferred wrap instead")
        s.feed("Y")
        check(at(s, 1, 1), "which the NEXT glyph resolves, onto the line below")
        check(s.line(1) == "Y", "putting that glyph at the start of it")

        // The whole point: writing the bottom-right cell must not scroll.
        var b = term("\(ESC)[25;80HX")
        check(b.scrollbackAvailable == 0, "writing the bottom-right corner does not scroll the screen")
        check(at(b, 24, 79), "and leaves the cursor on it")
        b.feed("Y")
        check(b.scrollbackAvailable == 1, "the glyph AFTER it is what scrolls")
        check(at(b, 24, 1), "the cursor stays on the bottom line, after the glyph it wrapped to")

        // A control character resolves nothing; it cancels.
        var c = term("\(ESC)[1;80HX\u{0D}")
        check(!c.pendingWrap, "CR disarms a pending wrap")
        c.feed("Y")
        check(at(c, 0, 1), "so the next glyph starts the SAME line")

        // DECAWM off
        var d = term("\(ESC)[?7l\(ESC)[1;80HXY")
        check(!d.autoWrap, "ESC[?7l turns DECAWM off")
        check(at(d, 0, 79), "and the last column stops wrapping")
        check(d.line(0).hasSuffix("Y"), "each further glyph overwrites the last cell")
        d.feed("\(ESC)[?7h")
        check(d.autoWrap, "ESC[?7h turns it back on")

        // A wrap armed before DECAWM was switched off must not fire after.
        var e = term("\(ESC)[1;80HX")
        check(e.pendingWrap, "a wrap is armed")
        e.feed("\(ESC)[?7l")
        check(!e.pendingWrap, "and switching DECAWM off disarms it")
    }

    section("Cursor motion") {
        check(term("\(ESC)[10;20H").cursor == (9, 19), "CUP is 1-based and lands where it says")
        check(term("\(ESC)[10;20f").cursor == (9, 19), "HVP ('f') is the same sequence")
        check(term("\(ESC)[H").cursor == (0, 0), "a bare ESC[H homes")
        check(term("\(ESC)[10;20H\(ESC)[H").cursor == (0, 0), "from anywhere")
        check(term("\(ESC)[0;0H").cursor == (0, 0), "and parameter 0 means 1")

        check(term("\(ESC)[10;10H\(ESC)[3A").cursor == (6, 9), "CUU moves up n rows")
        check(term("\(ESC)[10;10H\(ESC)[3B").cursor == (12, 9), "CUD moves down n rows")
        check(term("\(ESC)[10;10H\(ESC)[3C").cursor == (9, 12), "CUF moves right n columns")
        check(term("\(ESC)[10;10H\(ESC)[3D").cursor == (9, 6), "CUB moves left n columns")

        check(term("\(ESC)[10;10H\(ESC)[A").cursor == (8, 9), "an omitted count is 1")
        check(term("\(ESC)[10;10H\(ESC)[0A").cursor == (8, 9), "and a zero count is 1")

        check(term("\(ESC)[99A").cursor == (0, 0), "CUU clamps at the top")
        check(term("\(ESC)[99B").cursor == (24, 0), "CUD clamps at the bottom")
        check(term("\(ESC)[99D").cursor == (0, 0), "CUB clamps at the left")
        check(term("\(ESC)[99C").cursor == (0, 79), "CUF clamps at the right")
        check(term("\(ESC)[99;99H").cursor == (24, 79), "and CUP clamps in both")

        check(term("\(ESC)[10;10H\(ESC)[40G").cursor == (9, 39), "CHA sets the column alone")
        check(term("\(ESC)[10;10H\(ESC)[40`").cursor == (9, 39), "and '`' is the same final")
        check(term("\(ESC)[10;10H\(ESC)[3d").cursor == (2, 9), "VPA sets the row alone")

        // Cursor motion cancels a pending wrap - it is a position, not a nudge.
        var s = term("\(ESC)[1;80HX")
        s.feed("\(ESC)[C")
        check(!s.pendingWrap, "CUF disarms a pending wrap")
    }

    section("ESC D, ESC E and ESC M - index, next line, reverse index") {
        check(term("\(ESC)D").cursor == (1, 0), "ESC D indexes down")
        check(term("\(ESC)[5;10H\(ESC)D").cursor == (5, 9), "keeping the column")
        check(term("\(ESC)[5;10H\(ESC)E").cursor == (5, 0), "ESC E is next-line: down AND to column 0")
        check(term("\(ESC)[5;10H\(ESC)M").cursor == (3, 9), "ESC M reverse-indexes up")
        check(term("\(ESC)M").cursor == (0, 0), "and clamps at the top row")

        var s = term("TOP\(ESC)[25;1H")
        s.feed("\(ESC)D")
        check(s.scrollbackAvailable == 1, "ESC D on the bottom row scrolls the screen")
        check(at(s, 24, 0), "and leaves the cursor on it")
    }

    section("Erase in Display") {
        var s = term()
        s.feed("\(ESC)[1;1HAAA\(ESC)[13;1HBBB\(ESC)[25;1HCCC")
        s.feed("\(ESC)[13;2H\(ESC)[0J")
        check(s.line(0) == "AAA", "ED 0 leaves everything above the cursor")
        check(s.line(12) == "B", "clears the rest of the cursor's own line")
        check(s.line(24) == "", "and everything below it")

        var t = term()
        t.feed("\(ESC)[1;1HAAA\(ESC)[13;1HBBB\(ESC)[25;1HCCC")
        t.feed("\(ESC)[13;2H\(ESC)[1J")
        check(t.line(0) == "", "ED 1 clears everything above the cursor")
        check(t.line(12) == "  B", "and its own line up to and including the cursor cell")
        check(t.line(24) == "CCC", "leaving everything below it")

        var u = term()
        u.feed("\(ESC)[1;1HAAA\(ESC)[13;1HBBB\(ESC)[25;1HCCC")
        u.feed("\(ESC)[13;2H\(ESC)[2J")
        check(u.allCells.allSatisfy { $0.character == " " }, "ED 2 clears the whole screen")
        check(at(u, 0, 0), "and homes the cursor, as ANSI.SYS software expects")

        let v = term("\(ESC)[5;10r\(ESC)[2J")
        check(v.scrollTop == 4 && v.scrollBottom == 9,
              "ED 2 does NOT reset the scrolling region - it is not DECSTBM")

        check(term("AAA\(ESC)[9J").line(0) == "AAA", "an unknown ED parameter erases nothing")
    }

    section("Erase in Line") {
        var s = term("ABCDEFGH\(ESC)[1;4H\(ESC)[0K")
        check(s.line(0) == "ABC", "EL 0 clears from the cursor to the end of the line")

        s = term("ABCDEFGH\(ESC)[1;4H\(ESC)[1K")
        check(s.line(0) == "    EFGH", "EL 1 clears the start of the line through the cursor cell")

        s = term("ABCDEFGH\(ESC)[1;4H\(ESC)[2K")
        check(s.line(0) == "", "EL 2 clears the whole line")
        check(at(s, 0, 3), "and none of them move the cursor")

        s = term("AAA\u{0A}BBB\(ESC)[1;1H\(ESC)[2K")
        check(s.line(1) == "BBB", "EL touches only the cursor's own line")

        check(term("ABC\(ESC)[9K").line(0) == "ABC", "an unknown EL parameter erases nothing")
    }

    section("ECH - erase without moving anything") {
        var s = term("ABCDEFGH\(ESC)[1;3H\(ESC)[3X")
        check(s.line(0) == "AB   FGH", "ECH blanks n cells and leaves the tail where it is")
        check(at(s, 0, 2), "and does not move the cursor")

        s = term("ABCDEFGH\(ESC)[1;3H\(ESC)[X")
        check(s.line(0) == "AB CDEFGH".replacingOccurrences(of: "C", with: ""),
              "an omitted count erases one cell")

        s = term("\(ESC)[1;79HABCDEF\(ESC)[1;79H\(ESC)[99X")
        check(s.line(0) == "", "and an over-large count stops at the end of the line")
    }

    section("ICH and DCH - insert and delete within the line") {
        var s = term("ABCDEF\(ESC)[1;3H\(ESC)[2@")
        check(s.line(0) == "AB  CDEF", "ICH opens n blank cells at the cursor")
        check(at(s, 0, 2), "without moving the cursor")

        s = term("\(ESC)[1;76HABCDE\(ESC)[1;76H\(ESC)[3@")
        check(s.line(0).count == 80, "characters pushed past the last column are lost, not wrapped")

        s = term("ABCDEF\(ESC)[1;3H\(ESC)[2P")
        check(s.line(0) == "ABEF", "DCH closes n cells and pulls the tail left")
        check(at(s, 0, 2), "without moving the cursor")

        s = term("ABCDEF\(ESC)[1;3H\(ESC)[99P")
        check(s.line(0) == "AB", "an over-large DCH clears to the end of the line")

        s = term("ABCDEF\(ESC)[1;3H\(ESC)[99@")
        check(s.line(0) == "AB", "and an over-large ICH pushes the whole tail off it")
    }

    section("IL and DL - insert and delete lines") {
        var s = term()
        s.feed("L0\u{0A}L1\u{0A}L2\u{0A}L3")
        s.feed("\(ESC)[2;1H\(ESC)[1L")
        check(s.line(0) == "L0", "IL leaves the lines above the cursor")
        check(s.line(1) == "", "opens a blank line at it")
        check(s.line(2) == "L1", "and pushes the rest down")

        s = term()
        s.feed("L0\u{0A}L1\u{0A}L2\u{0A}L3")
        s.feed("\(ESC)[2;1H\(ESC)[1M")
        check(s.line(0) == "L0", "DL leaves the lines above the cursor")
        check(s.line(1) == "L2", "removes the cursor's own line")
        check(s.line(2) == "L3", "and pulls the rest up")

        // The clamp that stops a live crash: an editor deleting to the bottom
        // from near it used to hand Range a lower bound above its upper bound.
        s = term("\(ESC)[25;1HBOTTOM\(ESC)[99M")
        check(s.line(24) == "", "DL past the bottom of the region clears rather than trapping")
        s = term("\(ESC)[25;1HBOTTOM\(ESC)[99L")
        check(s.line(24) == "", "and so does IL")

        // Both are defined against the scrolling region, not the screen.
        s = term()
        s.feed("\(ESC)[5;10r")
        s.feed("\(ESC)[10;1HLAST\(ESC)[11;1HOUTSIDE")
        s.feed("\(ESC)[5;1H\(ESC)[1L")
        check(s.line(10) == "OUTSIDE", "IL never pushes a line past the bottom of the region")
    }

    section("The scrolling region (DECSTBM)") {
        var s = term("\(ESC)[5;10r")
        check(s.scrollTop == 4 && s.scrollBottom == 9, "ESC[t;br sets the region, 1-based")
        check(at(s, 0, 0), "and homes the cursor")

        s = term("\(ESC)[5;10r\(ESC)[r")
        check(s.scrollTop == 0 && s.scrollBottom == 24, "a bare ESC[r puts it back to the whole screen")

        s = term("\(ESC)[10;5r")
        check(s.scrollTop == 0 && s.scrollBottom == 24, "an inverted region is refused")
        s = term("\(ESC)[5;5r")
        check(s.scrollTop == 0 && s.scrollBottom == 24, "and so is a one-line region")
        s = term("\(ESC)[5;99r")
        check(s.scrollTop == 0 && s.scrollBottom == 24, "and one that runs off the screen")

        // LF at the bottom of the region scrolls the region and nothing else.
        s = term("\(ESC)[5;10r")
        s.feed("\(ESC)[5;1HR0\(ESC)[10;1HR5\(ESC)[11;1HBELOW")
        s.feed("\(ESC)[10;1H\u{0A}")
        check(at(s, 9, 0), "LF on the last row of the region stays on it")
        check(s.line(4) == "", "the region scrolls")
        check(s.line(10) == "BELOW", "and the lines below it do not move")
        check(s.scrollbackAvailable == 0,
              "a line pushed out of a status-line window was never history")

        // Above and below the region.
        s = term("\(ESC)[10;20r\(ESC)[1;1H\u{0A}")
        check(at(s, 1, 0), "above the region LF just moves down")
        s = term("\(ESC)[5;10r\(ESC)[15;5H\u{0A}")
        check(at(s, 14, 0), "below it LF carries the CR and nothing else")
    }

    section("SU and SD") {
        var s = term("TOP\u{0A}SECOND\(ESC)[2S")
        check(s.line(0) == "", "SU scrolls the screen up n lines")
        check(s.scrollbackAvailable == 2, "and what leaves the top of a FULL screen is history")

        s = term("\(ESC)[5;10r\(ESC)[5;1HR0\(ESC)[2S")
        check(s.scrollbackAvailable == 0, "what leaves a partial region is not")

        s = term("TOP\u{0A}SECOND\(ESC)[1T")
        check(s.line(0) == "", "SD opens a blank line at the top of the region")
        check(s.line(1) == "TOP", "and pushes the rest down")
        check(s.scrollbackAvailable == 0, "SD never touches history - nothing is leaving the top")
    }

    section("Save and restore the cursor") {
        check(term("\(ESC)[10;20H\(ESC)7\(ESC)[1;1H\(ESC)8").cursor == (9, 19),
              "DECSC/DECRC (ESC 7 / ESC 8) round-trip the position")
        check(term("\(ESC)[10;20H\(ESC)[s\(ESC)[1;1H\(ESC)[u").cursor == (9, 19),
              "and so do the SCO forms, ESC[s and ESC[u")
        check(term("\(ESC)8").cursor == (0, 0), "restoring what was never saved homes the cursor")

        var s = term("\(ESC)[1;80HX\(ESC)7")
        s.feed("\(ESC)8")
        check(!s.pendingWrap, "restoring the cursor disarms a pending wrap")
    }

    section("Device reports - what the terminal says back") {
        var s = term("\(ESC)[6n")
        check(s.takeResponses() == ["\(ESC)[1;1R"], "DSR 6 reports the cursor position, 1-based")
        check(s.takeResponses().isEmpty, "and draining it twice yields nothing")

        s = term("\(ESC)[10;20H\(ESC)[6n")
        check(s.takeResponses() == ["\(ESC)[10;20R"], "from wherever the cursor is")

        s = term("\(ESC)[5n")
        check(s.takeResponses() == ["\(ESC)[0n"], "DSR 5 answers that the terminal is well")

        s = term("\(ESC)[c")
        check(s.takeResponses() == ["\(ESC)[?1;0c"], "DA identifies as a VT100 with no options")
        s = term("\(ESC)[0c")
        check(s.takeResponses() == ["\(ESC)[?1;0c"], "and ESC[0c is the same request")

        s = term("\(ESC)Z")
        check(s.takeResponses() == ["\(ESC)[?1;0c"], "ESC Z answers as a VT100 while in ANSI mode")

        s = term("\(ESC)[?6n")
        check(s.takeResponses().isEmpty, "a private-marker DSR is not the DSR we answer")
        s = term("\(ESC)[>c")
        check(s.takeResponses().isEmpty, "and ESC[>c is not the DA we answer")

        // Nothing is said unless something asked.
        s = term("HELLO\u{0A}WORLD")
        check(s.takeResponses().isEmpty, "ordinary output puts nothing on the wire")
    }

    section("Private markers and intermediate bytes end nothing") {
        // ESC[>c used to end at the '>' and print "c" as a glyph.
        check(term("\(ESC)[>cX").line(0) == "X", "ESC[>c consumes its own final byte")
        check(term("\(ESC)[?25lX").line(0) == "X", "and so does ESC[?25l")
        check(term("\(ESC)[=cX").line(0) == "X", "and ESC[=c")
        check(term("\(ESC)[<cX").line(0) == "X", "and ESC[<c")

        // ESC[!p (DECSTR) and ESC[<n> q (DECSCUSR) carry an intermediate byte.
        check(term("\(ESC)[!pX").line(0) == "X", "ESC[!p consumes its final byte")
        check(term("\(ESC)[2 qX").line(0) == "X", "and ESC[2 q consumes its own")

        // The guard that keeps xterm's modifyOtherKeys out of SGR.
        var s = term("\(ESC)[31m")
        let red = s.rendition.attr
        s.feed("\(ESC)[>4m")
        check(s.rendition.attr == red, "ESC[>4m is modifyOtherKeys and must not reset the rendition")
        s.feed("\(ESC)[>4;2m")
        check(s.rendition.attr == red, "nor may ESC[>4;2m")
        s.feed("\(ESC)[m")
        check(s.rendition.attr == 0x07, "a bare ESC[m still is SGR 0")
    }

    section("DEC private modes") {
        check(!term("\(ESC)[?25l").cursorVisible, "ESC[?25l hides the cursor (DECTCEM)")
        check(term("\(ESC)[?25l\(ESC)[?25h").cursorVisible, "ESC[?25h shows it again")
        check(term("\(ESC)[25l").cursorVisible,
              "the same numbers without '?' are ANSI modes and do not touch it")

        let s = term("\(ESC)[?1049h\(ESC)[?12hX")
        check(s.line(0) == "X", "an unhandled private mode is acknowledged and consumed")
    }

    section("The VT52 dialect") {
        var s = term("\(ESC)[?2l")
        check(s.dialect.isVT52, "ESC[?2l selects VT52 (DECANM reset)")
        check(s.takeResponses().isEmpty, "quietly")

        s = term("\(ESC)[?2l\(ESC)Z")
        check(s.takeResponses() == ["\(ESC)/Z"], "and ESC Z then answers as a VT52")

        s = term("\(ESC)[?2l\(ESC)[?2h")
        check(!s.dialect.isVT52, "ESC[?2h selects ANSI again")

        // The three bytes whose MEANING depends on the dialect.
        s = term("\(ESC)[?2l\(ESC)[5;10H")
        check(at(s, 4, 9), "CSI still addresses the cursor in VT52 mode")
        s.feed("\(ESC)D")
        check(at(s, 4, 8), "ESC D is cursor-left on a VT52, not Index")
        s = term("\(ESC)[?2l\(ESC)[5;10HZZZ\(ESC)E")
        check(s.allCells.allSatisfy { $0.character == " " }, "and ESC E is clear-screen, not Next Line")
        s = term("\(ESC)[?2l\(ESC)[5;10H\(ESC)H")
        check(at(s, 0, 0), "ESC H homes on a VT52")
        s = term("\(ESC)[5;10H\(ESC)H")
        check(at(s, 4, 9), "and does nothing in ANSI mode")

        // Direct cursor addressing, biased by 0x20.
        s = term("\(ESC)Y\u{25}\u{2A}")
        check(at(s, 5, 10), "ESC Y <row+0x20> <col+0x20> addresses the cursor directly")
        check(s.dialect.isVT52, "and ESC Y is itself proof the stream is VT52")
        s = term("\(ESC)Y\u{FF}\u{FF}")
        check(at(s, 24, 79), "an out-of-range ESC Y clamps to the screen")

        // The action sequences work whatever we think the dialect is.
        check(term("\(ESC)[5;10H\(ESC)A").cursor == (3, 9), "ESC A is cursor-up in either dialect")
        check(term("\(ESC)[5;10H\(ESC)B").cursor == (5, 9), "ESC B is cursor-down")
        check(term("\(ESC)[5;10H\(ESC)C").cursor == (4, 10), "ESC C is cursor-right")
        check(term("\(ESC)[5;10H\(ESC)I").cursor == (3, 9), "ESC I is reverse line feed")
        check(term("AAA\u{0A}BBB\(ESC)[1;1H\(ESC)J").line(1) == "",
              "ESC J erases to the end of the screen")
        check(term("ABCDEF\(ESC)[1;3H\(ESC)K").line(0) == "AB",
              "ESC K erases to the end of the line")

        // ESC < leaves VT52 explicitly; ESC J and ESC K deliberately prove nothing.
        check(!term("\(ESC)A\(ESC)<").dialect.isVT52, "ESC < leaves VT52")
        check(!term("\(ESC)J").dialect.isVT52,
              "a stray ESC J is not taken as proof of VT52 - too many CP/M terminals send it")
        check(!term("\(ESC)K").dialect.isVT52, "and neither is ESC K")
        check(term("\(ESC)A").dialect.isVT52, "ESC A is: a VT100 program spells that CSI A")
    }

    section("Character-set and line-size designations are consumed, not printed") {
        check(term("\(ESC)(BX").line(0) == "X", "ESC ( B takes its trailing byte")
        check(term("\(ESC))0X").line(0) == "X", "and so does ESC ) 0")
        check(term("\(ESC)#8X").line(0) == "X", "and the DECALN line-size form ESC # 8")
        check(term("\(ESC) FX").line(0) == "X", "and the 7/8-bit control-set form ESC SP F")
    }

    section("Background-colour erase") {
        // ESC[41m is ANSI red background, which is CGA 4.
        var s = term("\(ESC)[41m\(ESC)[2J")
        check(s.allCells.allSatisfy { $0.background == 4 },
              "an erase paints the CURRENT background, as a real VT does")
        check(s.allCells.allSatisfy { $0.foreground == 7 }, "carrying the foreground with it")

        // A glyph written into an erased cell must agree with it.
        s.feed("X")
        check(s.cells[0][0].background == 4, "and a glyph written afterwards agrees with the cell")

        // The faces are deliberately NOT carried: an underline on a space is
        // visible, and ESC[4m ESC[2J would rule all 2000 cells.
        s = term("\(ESC)[4m\(ESC)[2J")
        check(s.allCells.allSatisfy { $0.flags == 0 }, "but an erase never carries the face flags")

        // Every member of the family, not half of it.
        s = term("\(ESC)[41m\(ESC)[0K")
        check(s.cells[0][0].background == 4, "EL fills the same way")
        s = term("\(ESC)[41m\(ESC)[3X")
        check(s.cells[0][0].background == 4, "and ECH")
        s = term("ABC\(ESC)[41m\(ESC)[1;1H\(ESC)[3P")
        check(s.cells[0][79].background == 4, "and the tail DCH opens")
        s = term("ABC\(ESC)[41m\(ESC)[1;1H\(ESC)[3@")
        check(s.cells[0][0].background == 4, "and the gap ICH opens")
        s = term("\(ESC)[41m\(ESC)[1;1H\(ESC)[3L")
        check(s.cells[0][0].background == 4, "and the lines IL opens")
        s = term("\(ESC)[41m\(ESC)[1T")
        check(s.cells[0][0].background == 4, "and the line SD opens")
        s = term("\(ESC)[41m\(ESC)[1S")
        check(s.cells[24][0].background == 4, "and the line SU opens")
    }

    section("Scrollback") {
        // The bug that made the whole feature dead from build 42 to build 56:
        // the LF path called scrollRegion(), which shifts rows without keeping
        // them, and only scrollUp() appends. Nothing was ever captured.
        var s = term("KEEPME\(ESC)[25;1H\u{0A}")
        check(s.scrollbackAvailable == 1, "an ordinary newline-driven scroll captures its top line")
        check(s.displayCells.count == 25, "and the visible window is still 25 rows")
        s.adjustScrollback(byLines: 1)
        check(s.isScrolledBack, "scrolling back reports itself")
        check(s.displayLine(0) == "KEEPME", "and the captured line comes back into view")
        s.scrollToLiveBottom()
        check(!s.isScrolledBack, "snapping back returns to the live bottom")
        check(s.displayLine(0) == "", "showing the live grid again")

        // Capacity 0 disables capture entirely (z80cpmw parity).
        var z = TerminalScreen(scrollbackCapacity: 0)
        z.feed("KEEPME\(ESC)[25;1H\u{0A}")
        check(z.scrollbackAvailable == 0, "capacity 0 captures nothing")
        z.adjustScrollback(byLines: 5)
        check(!z.isScrolledBack, "and there is nothing to scroll back into")

        // The cap trims the oldest, and a shrink applies to what is already held.
        var c = TerminalScreen(scrollbackCapacity: 3)
        for i in 0..<10 { c.feed("L\(i)\(ESC)[25;1H\u{0A}") }
        check(c.scrollbackAvailable == 3, "a full buffer stays at its cap")
        var d = TerminalScreen(scrollbackCapacity: 100)
        for i in 0..<10 { d.feed("L\(i)\(ESC)[25;1H\u{0A}") }
        check(d.scrollbackAvailable == 10, "under the cap it keeps everything")
        d.scrollbackCapacity = 4
        check(d.scrollbackAvailable == 4, "shrinking the cap trims the oldest lines")
        d.scrollbackCapacity = 0
        check(d.scrollbackAvailable == 0, "and setting it to 0 drops the history")
        d.scrollbackCapacity = -5
        check(d.scrollbackCapacity == 0, "a negative capacity clamps to 0")
        d.scrollbackCapacity = 10_000_000
        check(d.scrollbackCapacity == TerminalScreen.maxScrollbackCapacity, "and a runaway one to the cap")

        // Reading history while output keeps arriving must not slide the view.
        var a = TerminalScreen()
        a.feed("ANCHOR\(ESC)[25;1H\u{0A}")
        a.adjustScrollback(byLines: 1)
        check(a.displayLine(0) == "ANCHOR", "the view is parked on a line")
        a.feed("\(ESC)[25;1H\u{0A}")
        check(a.displayLine(0) == "ANCHOR", "and stays on it while more output scrolls past")

        // adjustScrollback clamps at both ends.
        var e = TerminalScreen()
        e.feed("X\(ESC)[25;1H\u{0A}")
        e.adjustScrollback(byLines: 99)
        check(e.scrollbackOffset == 1, "scrolling back past the oldest line clamps")
        e.adjustScrollback(byLines: -99)
        check(e.scrollbackOffset == 0, "and scrolling forward past the live bottom clamps too")

        // A fresh session drops the dead one's transcript.
        var f = TerminalScreen()
        f.feed("OLD\(ESC)[25;1H\u{0A}")
        f.adjustScrollback(byLines: 1)
        f.resetScrollback()
        check(f.scrollbackAvailable == 0, "resetScrollback drops the history")
        check(f.scrollbackOffset == 0, "and cannot leave the view parked in it")
    }

    section("The bell") {
        var s = term("\u{07}")
        check(s.takeBells() == 1, "one BEL rings once")
        check(s.takeBells() == 0, "and draining it twice yields nothing")
        var three = term("\u{07}\u{07}\u{07}")
        check(three.takeBells() == 3, "three BELs ring three times")

        var off = TerminalScreen(bellEnabled: false)
        off.feed("\u{07}\u{07}\u{07}")
        check(off.takeBells() == 0, "a disabled bell rings not at all")
        off.bellEnabled = true
        off.feed("\u{07}")
        check(off.takeBells() == 1, "switching it back on rings again")

        // Suppressing the bell suppresses the bell and nothing else.
        var q = TerminalScreen(bellEnabled: false)
        q.feed("\(ESC)[1;5HAB\u{07}")
        check(at(q, 0, 6), "BEL has never moved the cursor, and still does not")
        check(q.line(0) == "    AB", "nor written a cell")

        // The setting is the user's, not the guest's - z80cpmw asserts the same.
        var r = TerminalScreen(bellEnabled: false)
        r.resetToPowerOn()
        r.feed("\u{07}")
        check(!r.bellEnabled, "a machine reset does not re-enable the bell")
        check(r.takeBells() == 0, "and no bell rings after it")
    }

    section("Parameter parsing, and the limits on a hostile stream") {
        check(term("\(ESC)[00000010;00000010H").cursor == (9, 9),
              "leading zeros are padding and do not spend the digit budget")
        check(term("\(ESC)[999999999999A").cursor == (0, 0), "a runaway digit run is clamped, not wrapped")

        // Sixteen parameters is the cap; the seventeenth is dropped, and the
        // sequence still ends where its final byte says.
        let many = (0..<40).map { _ in "1" }.joined(separator: ";")
        check(term("\(ESC)[\(many)mX").line(0) == "X", "a runaway parameter list still terminates")

        check(term("\(ESC)[;5H").cursor == (0, 4), "an empty first parameter is 1")
        check(term("\(ESC)[5;H").cursor == (4, 0), "and an empty second is 1")
    }

    section("Aborting a part-parsed sequence") {
        // A control character inside a CSI aborts it and is acted on. z80cpmw
        // eats it as the final byte instead; this port has always taken the
        // other reading, and the difference is recorded here rather than left
        // for someone to discover on a screen.
        var s = term("\(ESC)[12\u{0D}X")
        check(at(s, 0, 1), "a CR inside a CSI aborts the sequence and is carried out")
        check(s.line(0) == "X", "and the following byte prints")
        check(!s.isMidSequence, "leaving the parser idle")

        s = term("\(ESC)[12\u{07}")
        check(s.takeBells() == 1, "a BEL inside a CSI rings")

        // An unknown final byte is swallowed whole.
        check(term("\(ESC)[1;2ZX").line(0) == "X", "an unknown CSI final is ignored, not printed")
        check(term("\(ESC)qX").line(0) == "X", "and so is an unknown ESC-anything")
    }

    section("The three clears are three different jobs") {
        // eraseScreen is what ED 2 and the VDA clear mean; clearTerminal is the
        // machine-level clear; resetToPowerOn is a cold boot.
        var s = term("\(ESC)[41m\(ESC)[5;10r\(ESC)[10;20HZZZ")
        s.eraseScreen()
        check(s.allCells.allSatisfy { $0.character == " " }, "eraseScreen clears the cells")
        check(at(s, 0, 0), "homes the cursor")
        check(s.rendition.attr != 0x07, "and leaves the rendition alone")
        check(s.scrollTop == 4 && s.scrollBottom == 9, "and the scrolling region alone")

        s = term("\(ESC)[41m\(ESC)[5;10r\(ESC)[10;20HZZZ")
        s.clearTerminal()
        check(s.rendition.attr == 0x07, "clearTerminal puts the rendition back first")
        check(s.allCells.allSatisfy { $0.background == 0 },
              "so a fresh screen is not painted in the dying session's colour")
        check(s.scrollTop == 0 && s.scrollBottom == 24, "and it does reset the scrolling region")

        var t = term("\(ESC)[?2l\(ESC)[?7l\(ESC)[?25l\(ESC)[41mZZZ\(ESC)[25;1H\u{0A}")
        check(t.scrollbackAvailable == 1, "given a session with history")
        t.resetToPowerOn()
        check(!t.dialect.isVT52, "a cold boot returns to ANSI")
        check(t.autoWrap, "puts DECAWM back on")
        check(t.cursorVisible, "shows the cursor again")
        check(t.rendition.attr == 0x07, "resets the rendition")
        check(t.scrollbackAvailable == 0, "and drops the dead session's transcript")
        check(!t.isMidSequence, "leaving the parser idle")
    }

    section("The HBIOS VDA entry points") {
        var s = term("ZZZ\(ESC)[5;10r")
        s.vdaSetAttr(0x4E)
        s.vdaClear()
        check(s.allCells.allSatisfy { $0.character == " " }, "the VDA clear erases")
        check(s.cells[0][0].background == 4, "in the attribute the guest last set")
        check(s.cells[0][0].foreground == 0x0E, "foreground and background both")
        check(s.scrollTop == 4 && s.scrollBottom == 9,
              "and it is not a machine reset, so the scrolling region survives")

        s.vdaSetCursor(row: 3, col: 7)
        check(at(s, 3, 7), "the VDA cursor call addresses the cursor")
        s.vdaSetCursor(row: 99, col: 99)
        check(at(s, 24, 79), "and clamps to the screen")

        // Setting the attribute byte replaces the whole rendition, faces and all.
        var t = term("\(ESC)[4;7m")
        t.vdaSetAttr(0x07)
        check(t.rendition.flags == 0, "a VDA attribute byte cannot carry the face flags, so it clears them")
        check(t.rendition.displayAttr == 0x07, "and it clears any SGR 7 swap with them")

        var u = term("TOP\(ESC)[25;1H")
        u.vdaScrollUp(1)
        check(u.scrollbackAvailable == 1, "and the VDA scroll captures history like any other")
    }

    section("The host's own writes") {
        var s = TerminalScreen()
        s.place("BANNER", row: 3, col: 10)
        check(s.line(3) == "          BANNER", "place() paints where it is told")
        check(at(s, 0, 0), "and moves nothing - the banner is painted before anyone is typing")
        s.place("XXX", row: 3, col: 78)
        check(s.line(3).count == 80, "a string running off the line is truncated, not wrapped")
        s.place("XXX", row: 99, col: 0)
        check(s.line(3).count == 80, "and a row off the screen paints nothing at all")

        var t = TerminalScreen()
        t.write("one\ntwo")
        check(t.line(0) == "one", "write() takes a host string")
        check(t.line(1) == "two", "treating \\n as CR+LF")
        check(at(t, 1, 3), "and leaves the cursor after it")
        t.write("\u{1B}[2J")
        check(t.line(0) == "one",
              "and it does NOT run the escape parser - ESC[2J written this way clears nothing")
    }
}

@main
enum TerminalScreenTestMain {
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
