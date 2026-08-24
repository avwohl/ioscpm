/*
 * TerminalView.swift - VDA-style terminal display for RomWBW
 */

import SwiftUI
import UIKit

// MARK: - Configurable Key Mapping
//
// CP/M is pure ASCII and has no navigation/function keys; each terminal defines
// its own escape bytes. These types let the user bind the navigation keys to
// arbitrary byte sequences, using the same termcap-style escape-string schema as
// the z80cpmw / romwbw_emu family so configs stay conceptually portable.

/// Special (non-ASCII) keys from a hardware/external keyboard that can be
/// remapped to arbitrary byte sequences sent to the guest.
enum SpecialKey: String, CaseIterable, Identifiable {
    case up, down, left, right, home, end, pageUp, pageDown, insert, delete
    var id: String { rawValue }
    var label: String {
        switch self {
        case .up: return "Up Arrow"
        case .down: return "Down Arrow"
        case .left: return "Left Arrow"
        case .right: return "Right Arrow"
        case .home: return "Home"
        case .end: return "End"
        case .pageUp: return "Page Up"
        case .pageDown: return "Page Down"
        case .insert: return "Insert"
        case .delete: return "Forward Delete"
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
                    .home: "^Q^S", .end: "^Q^D", .pageUp: "^R", .pageDown: "^C",
                    .insert: "^V", .delete: "^G"]
        case .vt100:
            return [.up: "\\E[A", .down: "\\E[B", .right: "\\E[C", .left: "\\E[D",
                    .home: "\\E[H", .end: "\\E[F", .pageUp: "\\E[5~", .pageDown: "\\E[6~",
                    .insert: "\\E[2~", .delete: "\\E[3~"]
        case .vt52:
            return [.up: "\\EA", .down: "\\EB", .right: "\\EC", .left: "\\ED",
                    .home: "\\EH", .end: "", .pageUp: "", .pageDown: "",
                    .insert: "", .delete: "^?"]
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

    func bytes(for key: SpecialKey) -> [UInt8] { KeyMap.expand(bindings[key] ?? "") }

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
    private var currentFontSize: CGFloat

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
        setNeedsDisplay()
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

                // Draw character
                let fgColor = cgaColors[Int(cell.foreground) & 0x0F]
                let charAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: fgColor
                ]

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
    /// charactersIgnoringModifiers keeps Shift, so Ctrl+A gives "a" and
    /// Ctrl+Shift+A gives "A"; upper-casing first lands both on 0x01. Same
    /// arithmetic as the on-screen Ctrl button (hbios_core.cc queueInput) and as
    /// KeyMap's `^X` / `^?` escapes.
    private static func controlByte(for key: UIKey) -> UInt8? {
        // Backspace composes "\u{8}", which never reaches the 0x40...0x5F range.
        if key.keyCode == .keyboardDeleteOrBackspace { return 0x7F }  // Ctrl+BS -> DEL
        guard var value = key.charactersIgnoringModifiers.unicodeScalars.first?.value else {
            return nil
        }
        // Fold ASCII only. String.uppercased() applies full Unicode case
        // mapping, which would turn a German "ß" into "SS" and hand the guest
        // ^S - a key that produced nothing before, now producing the wrong byte.
        if value >= 0x61 && value <= 0x7A { value -= 0x20 }  // a-z -> A-Z
        switch value {
        case 0x40...0x5F: return UInt8(value & 0x1F)         // @ A-Z [ \ ] ^ _ -> 0x00-0x1F
        case 0x3F:        return 0x7F                        // Ctrl+?     -> DEL
        case 0x2F:        return 0x1F                        // Ctrl+/     -> US
        case 0x20:        return 0x00                        // Ctrl+Space -> NUL
        default:          return nil
        }
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
                onSpecialKey?(special)
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
