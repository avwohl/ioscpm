//
//  TerminalSelectionTests.swift
//
//  What a selection covers, what text that is, and where on a letterboxed
//  screen a cell actually is.
//
//  None of this could be checked before build 60: every one of these decisions
//  was a private method on TerminalUIView, which needs UIKit and a screen. The
//  gesture that drives them still does and is in MANUAL_CHECKS.md section 17.
//  Everything the gesture *decides* is here.
//
//  Two of the cases below are regressions that were live in the shipped code
//  and unreachable only because no selection could exist on iOS at all: the
//  half-open span that dropped the last cell (see "the span includes both
//  ends"), and the row-shorter-than-the-selection trap in text extraction (see
//  "a short row cannot trap it").
//
//  Run with Tests/run_tests.sh.
//

import Foundation
import CoreGraphics

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

// MARK: - Fixtures

/// A grid of `rows` x `cols` built from the lines given, blank-padded. Shorter
/// input lines are NOT padded when `ragged` is set - that is how the short-row
/// trap is reproduced.
func grid(_ lines: [String], cols: Int = 20, ragged: Bool = false) -> [[TerminalCell]] {
    lines.map { line in
        var row = line.map { TerminalCell(character: $0) }
        if !ragged {
            while row.count < cols { row.append(TerminalCell(character: " ")) }
            row = Array(row.prefix(cols))
        }
        return row
    }
}

func pos(_ row: Int, _ col: Int) -> GridPos { GridPos(row: row, col: col) }

/// The geometry of the real terminal at a real font: an 80x25 grid of cells
/// measured 10 x 20 points.
let terminal = TerminalGeometry(rows: 25, cols: 80, charWidth: 10, charHeight: 20)

// MARK: - Tests

func testOrdering() {
    section("GridPos orders in reading order, with no packed stride to overflow")

    check(pos(0, 0) < pos(0, 1), "same row, a lower column comes first")
    check(pos(0, 79) < pos(1, 0), "the end of a row comes before the start of the next")
    check(pos(2, 5) == pos(2, 5), "the same cell equals itself")
    check(!(pos(3, 0) < pos(3, 0)), "a cell does not precede itself")
    check(pos(1, 0) > pos(0, 99999),
          "a column wider than the old 10_000 stride cannot outrank a later row - "
          + "the packed `row * 10_000 + col` this replaced would have said otherwise")
}

func testSpan() {
    section("A span covers both its ends")

    let span = GridSpan(start: pos(1, 2), end: pos(1, 4))
    check(!span.contains(row: 1, col: 1), "before the start is out")
    check(span.contains(row: 1, col: 2), "the start cell is in")
    check(span.contains(row: 1, col: 3), "the middle is in")
    check(span.contains(row: 1, col: 4),
          "the END cell is in - z80cpmw's isCellSelected is `idx >= lo && idx <= hi`, "
          + "and the half-open span this replaces excluded it")
    check(!span.contains(row: 1, col: 5), "past the end is out")
    check(!span.contains(row: 0, col: 3), "an earlier row is out")
    check(!span.contains(row: 2, col: 3), "a later row is out")

    section("A span wraps at the row end rather than making a rectangle")

    let wrapped = GridSpan(start: pos(0, 18), end: pos(2, 1))
    check(wrapped.contains(row: 0, col: 19), "the tail of the first row is in")
    check(wrapped.contains(row: 1, col: 0), "all of the middle row is in")
    check(wrapped.contains(row: 1, col: 19), "including the far side of it, which a rectangle would exclude")
    check(wrapped.contains(row: 2, col: 1), "the head of the last row is in")
    check(!wrapped.contains(row: 2, col: 2), "and no further")
    check(!wrapped.contains(row: 0, col: 17), "nor before the start")
}

func testDragDirection() {
    section("Which way the drag went does not change what it selected")

    let forward = TerminalSelection(anchor: pos(1, 2), focus: pos(3, 4))
    let backward = TerminalSelection(anchor: pos(3, 4), focus: pos(1, 2))
    check(forward.span == backward.span, "dragging up-left selects the same cells as down-right")
    check(forward.span.start == pos(1, 2), "the span always starts at the earlier cell")
    check(forward.span.end == pos(3, 4), "and ends at the later one")

    check(forward.covers(row: 1, col: 2), "the anchor cell is covered dragging forward")
    check(backward.covers(row: 3, col: 4),
          "and dragging backward too - the old half-open span dropped whichever end was later, "
          + "so a right-to-left drag lost the cell the gesture started on")
}

func testEmptySelection() {
    section("A press that never moved is not a selection")

    let untouched = TerminalSelection(anchor: pos(2, 2))
    check(untouched.isEmpty, "anchor and focus on one cell is empty")
    check(untouched.focus == untouched.anchor, "the focus defaults to the anchor")
    check(untouched.covers(row: 2, col: 2),
          "and it still COVERS that cell, which is what paints the one-cell highlight "
          + "under a finger that has pressed but not yet dragged")

    var moved = untouched
    moved.focus = pos(2, 3)
    check(!moved.isEmpty, "one cell of movement makes it real")

    check(TerminalSelection(anchor: pos(0, 0)).text(from: grid(["hello"])) == "h",
          "an empty selection still yields its cell if asked - the view asks only when hasSelection")
}

func testText() {
    section("The text a selection yields")

    let cells = grid(["A>DIR", "FOO     COM", "BAR     TXT"])

    check(TerminalSelection(anchor: pos(0, 2), focus: pos(0, 4)).text(from: cells) == "DIR",
          "a run inside one row is exactly that run, both ends included")
    check(TerminalSelection(anchor: pos(0, 4), focus: pos(0, 2)).text(from: cells) == "DIR",
          "and dragging it right-to-left gives the same three characters")
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(0, 4)).text(from: cells) == "A>DIR",
          "from the start of the row")

    check(TerminalSelection(anchor: pos(1, 0), focus: pos(2, 10)).text(from: cells)
            == "FOO     COM\nBAR     TXT",
          "two whole rows are joined with one newline")

    check(TerminalSelection(anchor: pos(0, 2), focus: pos(1, 2)).text(from: cells)
            == "DIR\nFOO",
          "a run that crosses a row boundary takes the tail of the first and the head of the next")

    section("Trailing blanks are dropped from every row, leading ones are not")

    let padded = grid(["hi", "  there"])
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(0, 19)).text(from: padded) == "hi",
          "selecting a whole padded row gives the text, not the padding")
    check(TerminalSelection(anchor: pos(1, 0), focus: pos(1, 19)).text(from: padded) == "  there",
          "leading blanks are kept - they are indentation, and a CP/M listing is full of it")
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(1, 19)).text(from: padded) == "hi\n  there",
          "each row is trimmed on its own, so the newline survives an empty tail")

    let blankRow = grid(["one", "", "three"])
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(2, 19)).text(from: blankRow) == "one\n\nthree",
          "a blank row in the middle stays a blank line rather than collapsing")
}

func testTextBounds() {
    section("A short row cannot trap it")

    // The shipped code built `first...min(last, cells[row].count - 1)` with no
    // check that the range ran forwards. These four are the cases where it did
    // not; each of them crashed rather than returning anything.
    let ragged = grid(["ab", "abcdefgh"], ragged: true)

    check(TerminalSelection(anchor: pos(0, 5), focus: pos(1, 3)).text(from: ragged) == "\nabcd",
          "a selection starting past the end of a two-character row yields nothing for that row")
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(0, 50)).text(from: ragged) == "ab",
          "an end column past the row's width is clamped to the row")
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(9, 0)).text(from: ragged) == "ab\nabcdefgh",
          "a row index past the end of the buffer stops at the last row there is")
    check(TerminalSelection(anchor: pos(5, 0), focus: pos(9, 0)).text(from: ragged) == "",
          "a selection entirely past the buffer is empty, not a crash")
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(0, 0)).text(from: []) == "",
          "and neither is an empty buffer")

    let empty = grid([""], ragged: true)
    check(TerminalSelection(anchor: pos(0, 0), focus: pos(0, 5)).text(from: empty) == "",
          "a zero-width row yields an empty line rather than indexing into it")
}

func testAllText() {
    section("Copy All")

    let cells = grid(["A>DIR", "FOO     COM", ""])
    check(TerminalSelection.allText(from: cells) == "A>DIR\nFOO     COM\n",
          "every row, trimmed, with the run of trailing blank lines collapsed to one newline")
    check(TerminalSelection.allText(from: []) == "", "an empty screen is empty")
    check(TerminalSelection.allText(from: grid(["", "", ""])) == "\n",
          "a screen of nothing but blanks does not grow a newline per row")
}

func testLetterbox() {
    section("The letterbox: where the grid lands inside the view")

    // 80x25 cells of 10x20 points is 800x500, a 1.6 aspect. A 1600x1000 view
    // is the same shape, so it scales x2 with no bars.
    let exact = terminal.letterbox(in: CGSize(width: 1600, height: 1000))
    check(exact?.scale == 2, "a view of the grid's own aspect scales to fill it")
    check(exact?.offsetX == TerminalGeometry.leftNudge,
          "with no horizontal bar beyond the two-point nudge draw(_:) has always applied")
    check(exact?.offsetY == 0, "and no vertical bar")

    // Wider than the grid: height binds, and the spare width becomes two bars.
    let wide = terminal.letterbox(in: CGSize(width: 2000, height: 1000))
    check(wide?.scale == 2, "in a wider view the height still binds")
    check(wide?.offsetX == 200 + TerminalGeometry.leftNudge, "the spare width is split into two bars")
    check(wide?.offsetY == 0, "and the grid still fills the height")

    // Taller than the grid: width binds.
    let tall = terminal.letterbox(in: CGSize(width: 1600, height: 1400))
    check(tall?.scale == 2, "in a taller view the width binds")
    check(tall?.offsetY == 200, "and the spare height is split into two bars")

    check(terminal.letterbox(in: CGSize(width: 0, height: 1000)) == nil,
          "a view with no width has no transform")
    check(TerminalGeometry(rows: 25, cols: 80, charWidth: 0, charHeight: 20)
            .letterbox(in: CGSize(width: 100, height: 100)) == nil,
          "and neither does a font that measured nothing")
}

func testRowPitch() {
    section("The drawn row pitch is the one the user sees")

    let size = CGSize(width: 1600, height: 1400)
    check(terminal.rowPitch(in: size) == 40,
          "at scale 2 a 20-point row is drawn 40 points tall")
    check(terminal.rowPitch(in: size) != size.height / CGFloat(terminal.rows),
          "which is NOT bounds.height / rows (56 here) - build 57 scrolled at the wrong "
          + "rate for exactly that substitution, and only when width was the binding dimension")
    check(terminal.rowPitch(in: CGSize(width: 0, height: 100)) == 0,
          "an unmeasurable view has no pitch")
}

func testHitTest() {
    section("Which cell a point is in")

    let size = CGSize(width: 1600, height: 1000)   // scale 2, offsetX 2, offsetY 0
    func cell(_ x: CGFloat, _ y: CGFloat) -> GridPos? {
        terminal.cell(at: CGPoint(x: x, y: y), in: size)
    }

    check(cell(2, 0) == pos(0, 0), "the grid origin is the top-left cell")
    check(cell(21, 39) == pos(0, 0), "and so is anywhere inside it")
    check(cell(22, 0) == pos(0, 1), "one drawn character across is the next column")
    check(cell(2, 40) == pos(1, 0), "one drawn row down is the next row")
    check(cell(1602 - 20, 960) == pos(24, 79), "the far corner is the last cell")

    section("A point outside the grid clamps to the edge")

    check(cell(-500, -500) == pos(0, 0),
          "a drag that left the view above and to the left selects to the first cell")
    check(cell(9999, 9999) == pos(24, 79),
          "and one that left below and to the right selects to the last - a drag that "
          + "stopped dead at the edge could not select the end of a line")
    check(cell(0, 500) == pos(12, 0), "just left of the nudge is still column 0, not column -1")

    check(TerminalGeometry(rows: 25, cols: 80, charWidth: 10, charHeight: 20)
            .cell(at: .zero, in: .zero) == nil,
          "a view with no size has no cell under any point")
}

func testMenuRect() {
    section("The box a menu is anchored to")

    let size = CGSize(width: 1600, height: 1000)   // scale 2, offsetX 2, offsetY 0

    let oneRow = terminal.rect(of: GridSpan(start: pos(1, 2), end: pos(1, 4)), in: size)
    check(oneRow == CGRect(x: 2 + 40, y: 40, width: 60, height: 40),
          "a span inside one row is just that run, three cells wide at scale 2")

    let manyRows = terminal.rect(of: GridSpan(start: pos(1, 40), end: pos(3, 2)), in: size)
    check(manyRows == CGRect(x: 2, y: 40, width: 1600, height: 120),
          "a span that crosses rows is the full width, because it is: the run wraps")

    check(terminal.rect(of: GridSpan(start: pos(0, 0), end: pos(0, 0)), in: .zero) == nil,
          "and an unmeasurable view has no box")
}

func runAllTests() {
    print("TerminalSelection Tests")
    print(String(repeating: "=", count: 60))
    testOrdering()
    testSpan()
    testDragDirection()
    testEmptySelection()
    testText()
    testTextBounds()
    testAllText()
    testLetterbox()
    testRowPitch()
    testHitTest()
    testMenuRect()
}

@main
enum TerminalSelectionTestMain {
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
