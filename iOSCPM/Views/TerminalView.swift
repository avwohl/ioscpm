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
    private var panReportedLines: Int = 0

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

        // Pan / scroll-wheel gesture for scrollback history
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.allowedScrollTypesMask = .all  // trackpad two-finger + mouse wheel on Mac Catalyst
        addGestureRecognizer(pan)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        // One on-screen text row of vertical movement = one scrollback line.
        let rowHeight = bounds.height / CGFloat(max(rows, 1))
        guard rowHeight > 0 else { return }
        let translationY = gesture.translation(in: self).y
        // Dragging down (positive y) reveals older content -> scroll into history.
        let totalLines = Int(translationY / rowHeight)
        let delta = totalLines - panReportedLines
        if delta != 0 {
            onScroll?(delta)
            panReportedLines = totalLines
        }
        switch gesture.state {
        case .ended, .cancelled, .failed:
            panReportedLines = 0
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
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        becomeFirstResponder()

        let menuController = UIMenuController.shared
        let copyItem = UIMenuItem(title: "Copy All", action: #selector(copyText))
        menuController.menuItems = [copyItem]

        let location = gesture.location(in: self)
        let menuRect = CGRect(x: location.x, y: location.y, width: 1, height: 1)
        menuController.showMenu(from: self, rect: menuRect)
    }

    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copyText) || action == #selector(copy(_:)) {
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

        let viewWidth = bounds.width
        let viewHeight = bounds.height

        // Terminal size based on current font
        let terminalWidth = CGFloat(cols) * charWidth
        let terminalHeight = CGFloat(rows) * charHeight

        // Scale to fill view (uniform scaling to maintain aspect ratio)
        let scaleX = viewWidth / terminalWidth
        let scaleY = viewHeight / terminalHeight
        let scale = min(scaleX, scaleY)

        let scaledWidth = terminalWidth * scale
        let scaledHeight = terminalHeight * scale
        let offsetX = (viewWidth - scaledWidth) / 2 + 2  // Padding from left edge
        let offsetY = (viewHeight - scaledHeight) / 2

        context.saveGState()
        context.translateBy(x: offsetX, y: offsetY)
        context.scaleBy(x: scale, y: scale)

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

    @objc private func copyText() {
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
