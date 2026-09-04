//
//  TerminalSelection.swift
//  iOSCPM
//
//  Where a selection is, what it covers and what text that is - plus the
//  letterbox arithmetic that turns a point on the screen into a cell.
//
//  Split out of TerminalView for the reason KeyMap, ControlKey and WindowFrame
//  were: none of it touches UIKit, and the half that does - the state of a
//  UILongPressGestureRecognizer, a UIMenuController - stays in the view. See
//  Tests/TerminalSelectionTests.swift.
//
//  ## Why the geometry came with it
//
//  `cell(at:)`, the pan step and `draw(_:)` have to agree to the pixel, and
//  they have not always. Build 57 found the pan step deriving the row pitch
//  from `bounds.height / rows`, which overstates it whenever width is the
//  binding dimension, and the wheel scrolled at the wrong rate for it. The
//  answer then was to put the transform in one property; the answer now is to
//  put it somewhere a suite can drive it, because a letterboxed bounds is a
//  pure input and needs no screen to check.
//
//  ## The span is inclusive, and that is a fix
//
//  z80cpmw decides membership with `idx >= lo && idx <= hi`
//  (`TerminalView.cpp` `isCellSelected`) and copies with `col <= ce`. This port
//  had a half-open span - `l >= start.linear && l < end.linear` - so the cell
//  the pointer was actually over was highlighted nowhere and copied never.
//  Drag across `DIR` on the Mac today and you get `DI`.
//
//  Inclusive is the sibling's rule, and it is also the only rule that can give
//  a touch any feedback: a press that has not moved yet covers exactly the one
//  cell under the finger, which is the "select cursor" a finger needs and a
//  pointer does not, because a pointer has an arrow.
//
//  ## Coordinates
//
//  Rows and columns are 0-based and index the VISIBLE grid, not the scrollback
//  buffer - `cells` is whatever is on screen, so a selection made while scrolled
//  back reads out of history, and any scroll invalidates it. The view clears it
//  for exactly that reason; see `handlePan`.
//

import Foundation
import CoreGraphics

// MARK: - A cell on the visible grid

struct GridPos: Equatable, Comparable {
    var row: Int
    var col: Int

    init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    /// Reading order: down the rows first, then along the columns.
    ///
    /// This replaces a packed `row * 10_000 + col` whose own comment conceded
    /// that it held only because "cols is bounded well under this", and which
    /// nothing checked. Comparing the pair has no bound to exceed and no
    /// stride to get wrong.
    static func < (lhs: GridPos, rhs: GridPos) -> Bool {
        lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
    }
}

// MARK: - An inclusive run of cells

/// A run from `start` to `end` in reading order, both ends INCLUDED. Linear
/// rather than rectangular: the run wraps at the row end, which is what every
/// terminal does and what makes copying a wrapped line give you the line.
struct GridSpan: Equatable {
    var start: GridPos
    var end: GridPos

    func contains(_ pos: GridPos) -> Bool { pos >= start && pos <= end }

    func contains(row: Int, col: Int) -> Bool {
        contains(GridPos(row: row, col: col))
    }
}

// MARK: - The selection

/// An anchor and a focus. The anchor is where the gesture started, the focus
/// where it is now; either may be the earlier of the two.
struct TerminalSelection: Equatable {
    var anchor: GridPos
    var focus: GridPos

    init(anchor: GridPos, focus: GridPos? = nil) {
        self.anchor = anchor
        self.focus = focus ?? anchor
    }

    /// A press that never moved off its starting cell.
    ///
    /// z80cpmw's `handleLButtonUp` keeps a selection only when the drag moved
    /// (`m_hasSelection = anchor != active`) and this agrees. It matters more
    /// here than there: `copyText()` falls back to copying the whole screen
    /// when nothing is selected, so a one-cell selection left behind by a tap
    /// would turn Copy from "the screen" into "one character" with nothing on
    /// screen to explain why.
    var isEmpty: Bool { anchor == focus }

    /// The covered cells, ordered, whichever way the drag went.
    var span: GridSpan {
        anchor <= focus ? GridSpan(start: anchor, end: focus)
                        : GridSpan(start: focus, end: anchor)
    }

    func covers(row: Int, col: Int) -> Bool { span.contains(row: row, col: col) }

    /// The selected text: reading order, one "\n" per row boundary, trailing
    /// blanks dropped from each row. That is z80cpmw's
    /// `copySelectionToClipboard` rule with its "\r\n" made a "\n".
    ///
    /// Every bound is clamped against the row actually handed in, not against a
    /// stored column count. The view's `cols` is fixed at `init` and the grid it
    /// describes is not, and the old code built `first...min(last, count - 1)`
    /// from it with no check that the range ran forwards - so a row shorter
    /// than the selection's first column trapped. That was unreachable only
    /// because no selection could exist on iOS at all.
    func text(from cells: [[TerminalCell]]) -> String {
        let s = span
        guard !cells.isEmpty else { return "" }
        let firstRow = max(0, s.start.row)
        let lastRow = min(s.end.row, cells.count - 1)
        guard firstRow <= lastRow else { return "" }

        var lines: [String] = []
        for row in firstRow...lastRow {
            let width = cells[row].count
            let from = (row == s.start.row) ? max(0, s.start.col) : 0
            let through = min((row == s.end.row) ? s.end.col : width - 1, width - 1)
            var line = ""
            if from <= through {
                for col in from...through { line.append(cells[row][col].character) }
            }
            lines.append(TerminalSelection.trimmingTrailingSpaces(line))
        }
        return lines.joined(separator: "\n")
    }

    /// The whole visible screen, same rules. What Copy means with nothing
    /// selected, and what "Copy All" means always.
    static func allText(from cells: [[TerminalCell]]) -> String {
        var text = ""
        for row in cells {
            var line = ""
            for cell in row { line.append(cell.character) }
            text += trimmingTrailingSpaces(line) + "\n"
        }
        while text.hasSuffix("\n\n") { text.removeLast() }
        return text
    }

    static func trimmingTrailingSpaces(_ line: String) -> String {
        String(line.reversed().drop(while: { $0 == " " }).reversed())
    }
}

// MARK: - Where the grid sits inside the view

/// The letterbox: the uniform scale and the offsets that centre a fixed
/// character grid inside whatever bounds the view was given.
///
/// One type answers for drawing, for hit-testing and for the scroll step, so
/// they cannot disagree - which is the bug build 57 fixed and this makes
/// checkable.
struct TerminalGeometry: Equatable {
    var rows: Int
    var cols: Int
    var charWidth: CGFloat
    var charHeight: CGFloat

    /// The two points `draw(_:)` has always nudged the grid right by. It is
    /// carried here rather than dropped because hit-testing must apply exactly
    /// what drawing applies, and dropping it would put every column half a
    /// character out at small font sizes.
    static let leftNudge: CGFloat = 2

    struct Letterbox: Equatable {
        var scale: CGFloat
        var offsetX: CGFloat
        var offsetY: CGFloat
    }

    func letterbox(in size: CGSize) -> Letterbox? {
        let gridWidth = CGFloat(cols) * charWidth
        let gridHeight = CGFloat(rows) * charHeight
        guard gridWidth > 0, gridHeight > 0, size.width > 0, size.height > 0 else {
            return nil
        }
        let scale = min(size.width / gridWidth, size.height / gridHeight)
        return Letterbox(scale: scale,
                         offsetX: (size.width - gridWidth * scale) / 2 + Self.leftNudge,
                         offsetY: (size.height - gridHeight * scale) / 2)
    }

    /// The cell under a point in view coordinates, clamped to the grid so a
    /// drag that leaves the view still selects to the edge instead of stopping
    /// dead.
    func cell(at point: CGPoint, in size: CGSize) -> GridPos? {
        guard let box = letterbox(in: size), charWidth > 0, charHeight > 0 else {
            return nil
        }
        let gx = (point.x - box.offsetX) / box.scale
        let gy = (point.y - box.offsetY) / box.scale
        return GridPos(row: clamp(Int(floor(gy / charHeight)), to: rows),
                       col: clamp(Int(floor(gx / charWidth)), to: cols))
    }

    /// Height of one *drawn* row in view points - the pitch the user actually
    /// sees, not `size.height / rows`, which overstates it whenever width is
    /// the binding dimension.
    func rowPitch(in size: CGSize) -> CGFloat {
        guard let box = letterbox(in: size) else { return 0 }
        return charHeight * box.scale
    }

    /// The box a span occupies on screen, for anchoring a menu to it. A span
    /// that crosses a row boundary is the full width, because it is: the run
    /// wraps.
    func rect(of span: GridSpan, in size: CGSize) -> CGRect? {
        guard let box = letterbox(in: size) else { return nil }
        let oneRow = span.start.row == span.end.row
        let left = oneRow ? CGFloat(clamp(span.start.col, to: cols)) * charWidth : 0
        let right = oneRow ? CGFloat(clamp(span.end.col, to: cols) + 1) * charWidth
                           : CGFloat(cols) * charWidth
        let top = CGFloat(clamp(span.start.row, to: rows)) * charHeight
        let bottom = CGFloat(clamp(span.end.row, to: rows) + 1) * charHeight
        return CGRect(x: box.offsetX + left * box.scale,
                      y: box.offsetY + top * box.scale,
                      width: (right - left) * box.scale,
                      height: (bottom - top) * box.scale)
    }

    private func clamp(_ value: Int, to count: Int) -> Int {
        min(max(0, value), max(0, count - 1))
    }
}
