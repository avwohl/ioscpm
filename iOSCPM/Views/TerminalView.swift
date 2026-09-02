/*
 * TerminalView.swift - VDA-style terminal display for RomWBW
 */

import SwiftUI
import UIKit

// The key-map types (SpecialKey, KeyProfile, KeyMap) live in KeyMap.swift -
// they are pure and therefore testable. specialKey(for:) below is the half that
// needs UIKit and stays here.

struct TerminalView: UIViewRepresentable {
    @Binding var cells: [[TerminalCell]]
    @Binding var cursorRow: Int
    @Binding var cursorCol: Int
    @Binding var shouldFocus: Bool
    var onKeyInput: ((Character) -> Void)?
    // Called when the user pans / scroll-wheels the terminal. Positive = back
    // into scrollback history, negative = toward the live bottom.
    var onScroll: ((Int) -> Void)?
    // Called when a remappable navigation key is pressed on a hardware keyboard.
    var onSpecialKey: ((SpecialKey) -> Void)?
    var captureKeyboard: Bool = true
    var showCursor: Bool = true

    let rows: Int
    let cols: Int
    let fontSize: CGFloat

    init(cells: Binding<[[TerminalCell]]>,
         cursorRow: Binding<Int>,
         cursorCol: Binding<Int>,
         rows: Int = 25,
         cols: Int = 80,
         fontSize: CGFloat = 20,
         shouldFocus: Binding<Bool> = .constant(false),
         captureKeyboard: Bool = true,
         showCursor: Bool = true,
         onKeyInput: ((Character) -> Void)? = nil,
         onScroll: ((Int) -> Void)? = nil,
         onSpecialKey: ((SpecialKey) -> Void)? = nil) {
        self._cells = cells
        self._cursorRow = cursorRow
        self._cursorCol = cursorCol
        self._shouldFocus = shouldFocus
        self.rows = rows
        self.cols = cols
        self.fontSize = fontSize
        self.captureKeyboard = captureKeyboard
        self.showCursor = showCursor
        self.onKeyInput = onKeyInput
        self.onScroll = onScroll
        self.onSpecialKey = onSpecialKey
    }

    func makeUIView(context: Context) -> TerminalUIView {
        let view = TerminalUIView(rows: rows, cols: cols, fontSize: fontSize)
        view.onKeyInput = onKeyInput
        view.onScroll = onScroll
        view.onSpecialKey = onSpecialKey
        view.captureKeyboard = captureKeyboard
        view.showCursor = showCursor
        return view
    }

    func updateUIView(_ uiView: TerminalUIView, context: Context) {
        uiView.updateFontSize(fontSize)
        uiView.onKeyInput = onKeyInput
        uiView.onScroll = onScroll
        uiView.onSpecialKey = onSpecialKey
        uiView.showCursor = showCursor
        uiView.updateCells(cells, cursorRow: cursorRow, cursorCol: cursorCol)
        uiView.captureKeyboard = captureKeyboard

        // Auto-focus when shouldFocus becomes true
        if shouldFocus && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        }
    }
}

// MARK: - Terminal with Control Toolbar

struct TerminalWithToolbar: View {
    @Binding var cells: [[TerminalCell]]
    @Binding var cursorRow: Int
    @Binding var cursorCol: Int
    @Binding var shouldFocus: Bool
    var onKeyInput: ((Character) -> Void)?
    var onSetControlify: ((RWBControlifyMode) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onSpecialKey: ((SpecialKey) -> Void)?
    var isControlifyActive: Bool = false
    var captureKeyboard: Bool = true
    var showCursor: Bool = true

    let rows: Int
    let cols: Int
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            // Control key toolbar (vertical, left side)
            VStack(spacing: 6) {
                ToolbarButton(title: "Ctrl", isActive: isControlifyActive) {
                    // Toggle: if active turn off, if off turn on (one-char mode)
                    onSetControlify?(isControlifyActive ? .off : .oneChar)
                }
                ToolbarButton(title: "Esc", isActive: false) {
                    onSetControlify?(.off)
                    onKeyInput?(Character(UnicodeScalar(27)))
                }
                ToolbarButton(title: "Tab", isActive: false) {
                    onSetControlify?(.off)
                    onKeyInput?(Character(UnicodeScalar(9)))
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .background(Color(UIColor.systemGray5))

            TerminalView(
                cells: $cells,
                cursorRow: $cursorRow,
                cursorCol: $cursorCol,
                rows: rows,
                cols: cols,
                fontSize: fontSize,
                shouldFocus: $shouldFocus,
                captureKeyboard: captureKeyboard,
                showCursor: showCursor,
                onKeyInput: onKeyInput,
                onScroll: onScroll,
                onSpecialKey: onSpecialKey
            )
        }
    }
}

struct ToolbarButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 36)
                .padding(.vertical, 6)
                .background(isActive ? Color.blue : Color(UIColor.systemGray4))
                .foregroundColor(isActive ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}


/// A pan recognizer that records whether actual touches drove it. A scroll
/// wheel or trackpad scroll reaches a pan recognizer as an *indirect scroll*
/// and never delivers a UITouch; a finger or pointer drag always does. Counting
/// `numberOfTouches` does not separate the two on Mac Catalyst - a pointer drag
/// reports zero there, exactly like the wheel - so the flag is set from the
/// touch callbacks themselves, which only one of the two ever reaches.
class TouchAwarePanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var sawTouches = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        sawTouches = true
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        sawTouches = false
        super.reset()
    }
}

// MARK: - Terminal UI View

class TerminalUIView: UIView, UIKeyInput {
    var onKeyInput: ((Character) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onSpecialKey: ((SpecialKey) -> Void)?
    var captureKeyboard: Bool = true
    var showCursor: Bool = true {
        didSet { if oldValue != showCursor { setNeedsDisplay() } }
    }
    // Accumulated whole-row translation already reported during the current pan.
    // Pan/scroll bookkeeping. `panResidual` is the sub-row remainder and it
    // deliberately survives the end of a gesture: a scroll wheel delivers each
    // notch as its own short gesture, so a per-gesture reset threw the whole
    // notch away and the wheel scrolled nothing at all.
    private var panLastTranslation: CGFloat = 0
    private var panResidual: CGFloat = 0
    /// Lines per wheel notch, matching z80cpmw's WM_MOUSEWHEEL handler.
    private static let wheelLineMultiplier: CGFloat = 3

    // Text selection. Anchor is where the drag started, focus where it is now;
    // the span between them is linear (anchor cell to focus cell, wrapping at
    // the row end) rather than rectangular, which is what every terminal does
    // and what makes copying a wrapped line give you the line.
    private var selAnchor: GridPos?
    private var selFocus: GridPos?
    struct GridPos: Equatable { var row: Int; var col: Int
        var linear: Int { row * 10_000 + col }   // cols is bounded well under this
    }
    var hasSelection: Bool {
        guard let a = selAnchor, let f = selFocus else { return false }
        return a != f
    }

    private let rows: Int
    private let cols: Int

    private var cells: [[TerminalCell]] = []
    private var cursorRow: Int = 0
    private var cursorCol: Int = 0

    private var charWidth: CGFloat = 0
    private var charHeight: CGFloat = 0
    private var font: UIFont
    /// The face a cell carrying CellFlags.bold is drawn in. A second UIFont
    /// rather than a heavier weight applied per draw, because that is the only
    /// way UIKit can vary weight for a single `draw(at:)` - z80cpmw keeps four
    /// HFONTs for exactly the same reason.
    ///
    /// The grid is measured from the PLAIN face alone (updateCharDimensions),
    /// so a wider bold face cannot move the grid; it cannot smear either,
    /// because every glyph is positioned individually below.
    private var boldFont: UIFont
    private var currentFontSize: CGFloat

    /// The blink phase, shared by every cell carrying CellFlags.blink. Off
    /// means those cells draw their background and no glyph.
    ///
    /// The timer is created only while a blinking cell is actually on screen
    /// and torn down the moment the last one goes - see updateCells. A CP/M
    /// session that never sends ESC[5m therefore costs exactly what it always
    /// did: no timer, no repaint. There is nothing else in this view to hang a
    /// phase on, because this port's cursor is a solid block and does not blink.
    private var blinkOn: Bool = true
    private var blinkTimer: Timer?
    private static let blinkPeriod: TimeInterval = 0.5

    // CGA color palette
    private let cgaColors: [UIColor] = [
        UIColor(red: 0/255, green: 0/255, blue: 0/255, alpha: 1),       // 0: Black
        UIColor(red: 0/255, green: 0/255, blue: 170/255, alpha: 1),     // 1: Blue
        UIColor(red: 0/255, green: 170/255, blue: 0/255, alpha: 1),     // 2: Green
        UIColor(red: 0/255, green: 170/255, blue: 170/255, alpha: 1),   // 3: Cyan
        UIColor(red: 170/255, green: 0/255, blue: 0/255, alpha: 1),     // 4: Red
        UIColor(red: 170/255, green: 0/255, blue: 170/255, alpha: 1),   // 5: Magenta
        UIColor(red: 170/255, green: 85/255, blue: 0/255, alpha: 1),    // 6: Brown
        UIColor(red: 170/255, green: 170/255, blue: 170/255, alpha: 1), // 7: Light Gray
        UIColor(red: 85/255, green: 85/255, blue: 85/255, alpha: 1),    // 8: Dark Gray
        UIColor(red: 85/255, green: 85/255, blue: 255/255, alpha: 1),   // 9: Light Blue
        UIColor(red: 85/255, green: 255/255, blue: 85/255, alpha: 1),   // 10: Light Green
        UIColor(red: 85/255, green: 255/255, blue: 255/255, alpha: 1),  // 11: Light Cyan
        UIColor(red: 255/255, green: 85/255, blue: 85/255, alpha: 1),   // 12: Light Red
        UIColor(red: 255/255, green: 85/255, blue: 255/255, alpha: 1),  // 13: Light Magenta
        UIColor(red: 255/255, green: 255/255, blue: 85/255, alpha: 1),  // 14: Yellow
        UIColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)  // 15: White
    ]

    init(rows: Int, cols: Int, fontSize: CGFloat = 20) {
        self.rows = rows
        self.cols = cols
        self.currentFontSize = fontSize
        self.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

        super.init(frame: .zero)

        // Calculate character dimensions
        updateCharDimensions()

        // Initialize cells
        cells = Array(repeating: Array(repeating: TerminalCell(), count: cols), count: rows)

        backgroundColor = .black
        contentMode = .redraw  // Redraw when bounds change
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Add tap gesture to become first responder
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)

        // Add long press gesture for copy menu
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)

        // One pan recognizer serves both scrolling and selecting; which one a
        // gesture means is decided in handlePan from whether it carries touches.
        // Splitting them by allowedTouchTypes looked cleaner and did not work:
        // a Catalyst mouse drag matched neither .direct nor .indirectPointer,
        // so both recognizers went silent.
        let pan = TouchAwarePanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = .all  // trackpad two-finger + mouse wheel on Mac Catalyst
        addGestureRecognizer(pan)
    }

    /// The letterbox transform draw(_:) applies: uniform scale plus the offset
    /// that centres the grid. Hit-testing has to use the very same numbers, so
    /// they live in one place rather than being re-derived at each site - the
    /// pan step used to re-derive them wrongly and scrolled at the wrong rate.
    private var gridTransform: (scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat)? {
        let terminalWidth = CGFloat(cols) * charWidth
        let terminalHeight = CGFloat(rows) * charHeight
        guard terminalWidth > 0, terminalHeight > 0, bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let scale = min(bounds.width / terminalWidth, bounds.height / terminalHeight)
        return (scale,
                (bounds.width - terminalWidth * scale) / 2 + 2,
                (bounds.height - terminalHeight * scale) / 2)
    }

    /// The cell under a point in view coordinates, clamped to the grid so a drag
    /// that leaves the view still selects to the edge instead of stopping dead.
    private func cell(at point: CGPoint) -> GridPos? {
        guard let t = gridTransform, charWidth > 0, charHeight > 0 else { return nil }
        let gx = (point.x - t.offsetX) / t.scale
        let gy = (point.y - t.offsetY) / t.scale
        let col = min(max(0, Int(gx / charWidth)), cols - 1)
        let row = min(max(0, Int(gy / charHeight)), rows - 1)
        return GridPos(row: row, col: col)
    }

    /// Selection ordered start-to-end regardless of which way the drag went.
    private var selectionSpan: (start: GridPos, end: GridPos)? {
        guard let a = selAnchor, let f = selFocus, a != f else { return nil }
        return a.linear <= f.linear ? (a, f) : (f, a)
    }

    private func isSelected(row: Int, col: Int) -> Bool {
        guard let span = selectionSpan else { return false }
        let l = GridPos(row: row, col: col).linear
        return l >= span.start.linear && l < span.end.linear
    }

    func clearSelection() {
        guard selAnchor != nil || selFocus != nil else { return }
        selAnchor = nil
        selFocus = nil
        setNeedsDisplay()
    }

    @objc private func handleSelectPan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            becomeFirstResponder()
            selAnchor = cell(at: point)
            selFocus = selAnchor
            setNeedsDisplay()
        case .changed:
            let f = cell(at: point)
            if f != selFocus { selFocus = f; setNeedsDisplay() }
        case .ended:
            selFocus = cell(at: point)
            setNeedsDisplay()
            // A drag that never left its starting cell is a click, not a
            // selection; leaving a zero-width selection behind would make the
            // next Cmd+C copy nothing at all.
            if !hasSelection { clearSelection() }
        case .cancelled, .failed:
            clearSelection()
        default:
            break
        }
    }

    /// The selected text: linear from start to end, one "\n" per row boundary,
    /// trailing blanks on each row dropped. Because `cells` is whatever is on
    /// screen, this copies out of scrollback when the view is scrolled back.
    private func selectedText() -> String? {
        guard let span = selectionSpan else { return nil }
        var out = ""
        for row in span.start.row...span.end.row {
            guard row < cells.count else { break }
            let first = (row == span.start.row) ? span.start.col : 0
            let last = (row == span.end.row) ? span.end.col - 1 : cols - 1
            guard first <= last else { if row != span.end.row { out += "\n" }; continue }
            var line = ""
            for col in first...min(last, cells[row].count - 1) {
                line.append(cells[row][col].character)
            }
            out += String(line.reversed().drop(while: { $0 == " " }).reversed())
            if row != span.end.row { out += "\n" }
        }
        return out
    }

    /// Height of one *drawn* text row, in view points - the pitch the user
    /// actually sees, not bounds.height / rows, which overstates it whenever
    /// width is the binding dimension.
    private var drawnRowPitch: CGFloat {
        guard let t = gridTransform else { return 0 }
        return charHeight * t.scale
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // Did touches drive this gesture, or is it a wheel/trackpad scroll?
        let droveByTouch = (gesture as? TouchAwarePanGestureRecognizer)?.sawTouches ?? false
        let indirect = !droveByTouch

        #if targetEnvironment(macCatalyst)
        // On a Mac a pointer drag selects text, the way every desktop terminal
        // behaves, and the wheel does the scrolling. On iOS a finger drag is the
        // only way to scroll at all, so it keeps that job.
        if droveByTouch {
            handleSelectPan(gesture)
            return
        }
        #endif

        let rowPitch = drawnRowPitch
        guard rowPitch > 0 else { return }

        if gesture.state == .began { panLastTranslation = 0 }

        let translationY = gesture.translation(in: self).y
        let step = translationY - panLastTranslation
        panLastTranslation = translationY

        // One notch is a fraction of a row, so give indirect scrolls the coarser
        // step the Windows port uses (3 lines/notch); a finger drag stays 1:1.
        panResidual += step * (indirect ? Self.wheelLineMultiplier : 1)

        // Dragging down (positive y) reveals older content -> back into history.
        let lines = Int(panResidual / rowPitch)
        if lines != 0 {
            panResidual -= CGFloat(lines) * rowPitch
            // The selection is in screen coordinates and the content under it is
            // about to move, so it would otherwise come to cover different text
            // than the user highlighted.
            clearSelection()
            onScroll?(lines)
        }

        switch gesture.state {
        case .ended, .cancelled, .failed:
            panLastTranslation = 0   // residual survives on purpose
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()  // Redraw when layout changes
    }

    private func updateCharDimensions() {
        let testString = "M" as NSString
        let size = testString.size(withAttributes: [.font: font])
        charWidth = size.width
        charHeight = size.height
    }

    func updateFontSize(_ newSize: CGFloat) {
        guard newSize != currentFontSize else { return }
        currentFontSize = newSize
        font = UIFont.monospacedSystemFont(ofSize: newSize, weight: .regular)
        boldFont = UIFont.monospacedSystemFont(ofSize: newSize, weight: .bold)
        updateCharDimensions()
        setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    @objc private func handleTap() {
        becomeFirstResponder()
        clearSelection()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        becomeFirstResponder()

        let menuController = UIMenuController.shared
        var items = [UIMenuItem(title: "Copy All", action: #selector(copyAllText))]
        if hasSelection {
            items.insert(UIMenuItem(title: "Copy", action: #selector(copyText)), at: 0)
        }
        menuController.menuItems = items

        let location = gesture.location(in: self)
        let menuRect = CGRect(x: location.x, y: location.y, width: 1, height: 1)
        menuController.showMenu(from: self, rect: menuRect)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copyText) || action == #selector(copyAllText)
            || action == #selector(copy(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc override func copy(_ sender: Any?) {
        copyText()
    }

    func updateCells(_ newCells: [[TerminalCell]], cursorRow: Int, cursorCol: Int) {
        self.cells = newCells
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        syncBlinkTimer()
        setNeedsDisplay()
    }

    /// Run the blink phase only while something on screen is asking for it.
    ///
    /// The scan is one pass over 2000 cells testing one bit, against a repaint
    /// twice a second that would otherwise run for the whole session - and for
    /// an ordinary CP/M session the answer is "no blinking cells" and there is
    /// no timer at all. Stopping it also parks the phase back at ON, so the
    /// last blinking cell to leave the screen cannot freeze a later glyph out.
    private func syncBlinkTimer() {
        let wantsBlink = cells.contains { row in
            row.contains { $0.flags & CellFlags.blink != 0 }
        }
        if wantsBlink {
            guard blinkTimer == nil else { return }
            blinkTimer = Timer.scheduledTimer(withTimeInterval: Self.blinkPeriod,
                                              repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.blinkOn.toggle()
                self.setNeedsDisplay()
            }
        } else if blinkTimer != nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
    }

    deinit {
        blinkTimer?.invalidate()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // Fill entire view with black first
        UIColor.black.setFill()
        context.fill(bounds)

        // The one letterbox transform, shared with hit-testing and the pan step.
        guard let t = gridTransform else { return }

        context.saveGState()
        context.translateBy(x: t.offsetX, y: t.offsetY)
        context.scaleBy(x: t.scale, y: t.scale)

        // Draw cells
        for row in 0..<min(rows, cells.count) {
            for col in 0..<min(cols, cells[row].count) {
                let cell = cells[row][col]
                let x = CGFloat(col) * charWidth
                let y = CGFloat(row) * charHeight

                // Draw background if not black
                if cell.background != 0 {
                    let bgColor = cgaColors[Int(cell.background) & 0x0F]
                    bgColor.setFill()
                    context.fill(CGRect(x: x, y: y, width: charWidth, height: charHeight))
                }

                // Selection sits over the cell's own background and under its
                // glyph, so selected text stays readable whatever colours the
                // guest picked for it.
                if isSelected(row: row, col: col) {
                    UIColor.systemBlue.withAlphaComponent(0.45).setFill()
                    context.fill(CGRect(x: x, y: y, width: charWidth, height: charHeight))
                }

                // Draw character. A blinking cell in the off phase keeps its
                // background and loses the glyph - and loses its underline with
                // it, because the rule is the font's own and goes with the
                // text, which is what z80cpmw's rendering suite pins.
                if cell.flags & CellFlags.blink != 0 && !blinkOn {
                    continue
                }

                let fgColor = cgaColors[Int(cell.foreground) & 0x0F]
                var charAttrs: [NSAttributedString.Key: Any] = [
                    .font: cell.flags & CellFlags.bold != 0 ? boldFont : font,
                    .foregroundColor: fgColor
                ]
                if cell.flags & CellFlags.underline != 0 {
                    charAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    // Without this the rule is drawn in the label colour, which
                    // is near-white on this black view whatever the glyph is.
                    charAttrs[.underlineColor] = fgColor
                }

                let str = String(cell.character) as NSString
                str.draw(at: CGPoint(x: x, y: y), withAttributes: charAttrs)
            }
        }

        // Draw cursor (blinking block) — hidden while viewing scrollback history
        if showCursor {
            let cursorX = CGFloat(cursorCol) * charWidth
            let cursorY = CGFloat(cursorRow) * charHeight

            // Simple block cursor
            UIColor.green.withAlphaComponent(0.7).setFill()
            context.fill(CGRect(x: cursorX, y: cursorY, width: charWidth, height: charHeight))

            // Redraw character at cursor position in black so it's visible
            if cursorRow < cells.count && cursorCol < cells[cursorRow].count {
                let cell = cells[cursorRow][cursorCol]
                let charAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.black
                ]
                let str = String(cell.character) as NSString
                str.draw(at: CGPoint(x: cursorX, y: cursorY), withAttributes: charAttrs)
            }
        }

        context.restoreGState()
    }

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        for char in text {
            // The software keyboard's Return arrives here as LF. CP/M wants CR,
            // and this is the only place that knows the LF meant "Enter" - the
            // byte-level paths below must leave a real 0x0A (Ctrl+J) alone.
            onKeyInput?(char == "\n" ? "\r" : char)
        }
    }

    func deleteBackward() {
        onKeyInput?(Character(UnicodeScalar(8)))  // Backspace
    }

    // MARK: - Key Commands

    override var keyCommands: [UIKeyCommand]? {
        // Arrow / navigation keys are handled in pressesBegan via key codes so
        // they can be remapped (see onSpecialKey).
        //
        // While a dialog has taken the keyboard, claim nothing: a priority
        // Escape here would outrank the alert it is meant to dismiss.
        guard captureKeyboard else { return nil }

        // ESC is a live CP/M key. On Mac Catalyst it is also the system's
        // leave-full-screen gesture, so it has to be asked for explicitly.
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape,
                                  modifierFlags: [],
                                  action: #selector(escapePressed))
        escape.wantsPriorityOverSystemBehavior = true

        var commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(enterPressed)),
            escape,
            // Copy/Paste support
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copyText)),
            UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(pasteText))
        ]

        // Ctrl+letter is also folded generally in pressesBegan, so these 26 are
        // redundant on iOS. They are kept for Mac Catalyst, where an explicitly
        // claimed key command is the reliable way to be sure AppKit's own
        // Ctrl-letter bindings never get a chance at the WordStar diamond.
        // UIKit matches key commands before pressesBegan, so there is no
        // double-send: a matched letter never reaches the fold.
        for char in "abcdefghijklmnopqrstuvwxyz" {
            commands.append(UIKeyCommand(input: String(char),
                                         modifierFlags: .control,
                                         action: #selector(ctrlKeyPressed(_:))))
        }

        return commands
    }

    /// Copy the selection if there is one, otherwise the whole screen. Cmd+C
    /// and the menu both land here, so "copy" means what it means everywhere
    /// else once a selection exists.
    @objc private func copyText() {
        if let selected = selectedText(), !selected.isEmpty {
            UIPasteboard.general.string = selected
            return
        }
        copyAllText()
    }

    @objc private func copyAllText() {
        // Copy all terminal content to clipboard
        var text = ""
        for row in cells {
            var line = ""
            for cell in row {
                line.append(cell.character)
            }
            // Trim trailing spaces
            line = String(line.reversed().drop(while: { $0 == " " }).reversed())
            text += line + "\n"
        }
        // Remove trailing empty lines
        while text.hasSuffix("\n\n") {
            text.removeLast()
        }
        UIPasteboard.general.string = text
    }

    @objc private func pasteText() {
        // Paste clipboard content as keyboard input
        guard let text = UIPasteboard.general.string else { return }
        for char in text {
            // Convert newlines to carriage return for CP/M
            if char == "\n" {
                onKeyInput?(Character("\r"))
            } else {
                onKeyInput?(char)
            }
        }
    }

    @objc private func enterPressed() {
        onKeyInput?(Character("\r"))
    }

    @objc private func escapePressed() {
        onKeyInput?(Character(UnicodeScalar(27)))
    }

    /// Map a hardware key code to a remappable navigation key, if applicable.
    private static func specialKey(for code: UIKeyboardHIDUsage) -> SpecialKey? {
        switch code {
        case .keyboardUpArrow: return .up
        case .keyboardDownArrow: return .down
        case .keyboardLeftArrow: return .left
        case .keyboardRightArrow: return .right
        case .keyboardHome: return .home
        case .keyboardEnd: return .end
        case .keyboardPageUp: return .pageUp
        case .keyboardPageDown: return .pageDown
        case .keyboardInsert: return .insert
        case .keyboardDeleteForward: return .delete
        case .keyboardF1: return .f1
        case .keyboardF2: return .f2
        case .keyboardF3: return .f3
        case .keyboardF4: return .f4
        case .keyboardF5: return .f5
        case .keyboardF6: return .f6
        case .keyboardF7: return .f7
        case .keyboardF8: return .f8
        case .keyboardF9: return .f9
        case .keyboardF10: return .f10
        case .keyboardF11: return .f11
        case .keyboardF12: return .f12
        default: return nil
        }
    }

    @objc private func ctrlKeyPressed(_ command: UIKeyCommand) {
        guard let input = command.input, let firstChar = input.first,
              let ascii = firstChar.asciiValue else { return }
        // Registered lower-case, so 'a' (97) -> 0x01, 'b' (98) -> 0x02, ...
        onKeyInput?(Character(UnicodeScalar(ascii - 96)))
    }

    /// Fold a Ctrl-modified hardware key to the ASCII control byte CP/M expects.
    ///
    /// The decision itself is `ControlKey.byte(forScalar:)`, which is pure and
    /// tested (Tests/ControlKeyTests.swift). What is left here is the part that
    /// needs UIKit: a UIKey cannot be built in a test.
    private static func controlByte(for key: UIKey) -> UInt8? {
        // Backspace composes "\u{8}", which never reaches the 0x40...0x5F range
        // the fold covers, so it has to be caught by key code first.
        if key.keyCode == .keyboardDeleteOrBackspace { return ControlKey.delete }
        guard let value = key.charactersIgnoringModifiers.unicodeScalars.first?.value else {
            return nil
        }
        return ControlKey.byte(forScalar: value)
    }

    // MARK: - Hardware Keyboard Support

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // When keyboard capture is disabled (e.g., alert showing), pass to responder chain
        guard captureKeyboard else {
            super.pressesBegan(presses, with: event)
            return
        }

        var handled = false

        for press in presses {
            guard let key = press.key else { continue }

            // Host-side scrollback navigation from a hardware keyboard. Consumed
            // here and never forwarded to the guest; plain (unmodified) Page/Home/
            // End keys fall through to onSpecialKey so they still reach CP/M
            // (matching the z80cpmw behaviour). adjustScrollback() clamps the
            // delta, so an out-of-range magnitude lands exactly on an edge.
            if !key.modifierFlags.contains(.command) {
                let mods = key.modifierFlags
                let page = max(rows - 1, 1)   // one screen = rows-1 lines
                switch key.keyCode {
                case .keyboardPageUp where mods.contains(.shift):
                    onScroll?(page)          // page back into history
                    handled = true
                    continue
                case .keyboardPageDown where mods.contains(.shift):
                    onScroll?(-page)         // page toward live
                    handled = true
                    continue
                case .keyboardHome where mods.contains(.control):
                    onScroll?(Int.max / 2)   // clamp -> oldest retained line
                    handled = true
                    continue
                case .keyboardEnd where mods.contains(.control):
                    onScroll?(Int.min / 2)   // clamp -> live bottom
                    handled = true
                    continue
                default:
                    break
                }
            }

            // Remappable navigation keys (arrows, Home/End, Page Up/Down,
            // Insert, Forward Delete) — resolved to a configurable byte sequence.
            // Command-modified nav keys are left to the system.
            if !key.modifierFlags.contains(.command),
               let special = Self.specialKey(for: key.keyCode) {
                // Ctrl+arrow is a binding of its own, not the plain arrow with
                // the modifier thrown away. This branch used to test only for
                // .command, so the Ctrl was discarded here and the general Ctrl
                // fold below never got a chance at it. Only the four arrows have
                // a modified slot (SpecialKey.controlModified); Ctrl+Home and
                // Ctrl+End were consumed above as scrollback jumps, and every
                // other nav key still falls through unmodified.
                //
                // iPadOS only, and deliberately so: on Mac Catalyst WindowServer
                // takes Ctrl+arrow for Mission Control / Spaces before the app
                // is ever asked, so this resolves there but never fires.
                let resolved = key.modifierFlags.contains(.control)
                    ? (special.controlModified ?? special)
                    : special
                onSpecialKey?(resolved)
                handled = true
                continue
            }

            // Command belongs to the app and the system (Cmd+C, Cmd+V, Cmd+?);
            // let keyCommands and the responder chain have it.
            if key.modifierFlags.contains(.command) { continue }

            // Control belongs to the guest, whatever it is combined with.
            if key.modifierFlags.contains(.control) {
                if let byte = Self.controlByte(for: key) {
                    onKeyInput?(Character(UnicodeScalar(byte)))
                    handled = true
                }
                // Never fall through as text: Ctrl+A must not type "a".
                continue
            }

            // Get the characters from the key press
            let chars = key.characters

            // Handle regular character input from hardware keyboard
            if !chars.isEmpty {
                for char in chars {
                    onKeyInput?(char)
                    handled = true
                }
            }
        }

        // If we didn't handle the press, pass it up the chain
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
}

#Preview {
    let cells = Array(repeating: Array(repeating: TerminalCell(character: "A", foreground: 2, background: 0), count: 80), count: 25)
    return TerminalWithToolbar(
        cells: .constant(cells),
        cursorRow: .constant(0),
        cursorCol: .constant(0),
        shouldFocus: .constant(false),
        rows: 25,
        cols: 80,
        fontSize: 20
    )
}
