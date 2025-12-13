/*
 * TerminalView.swift - VDA-style terminal display for RomWBW
 */

import SwiftUI
import UIKit

struct TerminalView: UIViewRepresentable {
    @Binding var cells: [[TerminalCell]]
    @Binding var cursorRow: Int
    @Binding var cursorCol: Int
    var onKeyInput: ((Character) -> Void)?

    let rows: Int
    let cols: Int
    let fontSize: CGFloat

    init(cells: Binding<[[TerminalCell]]>,
         cursorRow: Binding<Int>,
         cursorCol: Binding<Int>,
         rows: Int = 25,
         cols: Int = 80,
         fontSize: CGFloat = 20,
         onKeyInput: ((Character) -> Void)? = nil) {
        self._cells = cells
        self._cursorRow = cursorRow
        self._cursorCol = cursorCol
        self.rows = rows
        self.cols = cols
        self.fontSize = fontSize
        self.onKeyInput = onKeyInput
    }

    func makeUIView(context: Context) -> TerminalUIView {
        let view = TerminalUIView(rows: rows, cols: cols, fontSize: fontSize)
        view.onKeyInput = onKeyInput
        return view
    }

    func updateUIView(_ uiView: TerminalUIView, context: Context) {
        uiView.updateFontSize(fontSize)
        uiView.updateCells(cells, cursorRow: cursorRow, cursorCol: cursorCol)
    }
}

class TerminalUIView: UIView, UIKeyInput {
    var onKeyInput: ((Character) -> Void)?

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

        // Add tap gesture to become first responder
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
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

    func updateCells(_ newCells: [[TerminalCell]], cursorRow: Int, cursorCol: Int) {
        self.cells = newCells
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        let viewWidth = bounds.width
        let viewHeight = bounds.height

        // Terminal size based on current font (no scaling - font size directly affects visual size)
        let terminalWidth = CGFloat(cols) * charWidth
        let terminalHeight = CGFloat(rows) * charHeight

        // Center terminal in view (or align to top-left if larger than view)
        let offsetX = max(0, (viewWidth - terminalWidth) / 2)
        let offsetY = max(0, (viewHeight - terminalHeight) / 2)

        context.saveGState()
        context.translateBy(x: offsetX, y: offsetY)

        // Draw background
        UIColor.black.setFill()
        context.fill(CGRect(x: 0, y: 0, width: terminalWidth, height: terminalHeight))

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

        // Draw cursor (blinking block)
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

        context.restoreGState()
    }

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        for char in text {
            onKeyInput?(char)
        }
    }

    func deleteBackward() {
        onKeyInput?(Character(UnicodeScalar(8)))
    }

    // MARK: - UIResponder

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(enterPressed)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(upArrowPressed)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(downArrowPressed)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(leftArrowPressed)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(rightArrowPressed))
        ]

        // Add Ctrl+key commands for common CP/M usage
        for char in "abcdefghijklmnopqrstuvwxyz" {
            if char.asciiValue != nil {
                commands.append(UIKeyCommand(input: String(char), modifierFlags: .control, action: #selector(ctrlKeyPressed(_:))))
            }
        }

        return commands
    }

    @objc private func enterPressed() {
        onKeyInput?(Character("\r"))
    }

    @objc private func escapePressed() {
        onKeyInput?(Character(UnicodeScalar(27)))
    }

    @objc private func upArrowPressed() {
        // Send ANSI up arrow or Ctrl-E for WordStar
        onKeyInput?(Character(UnicodeScalar(5))) // Ctrl-E
    }

    @objc private func downArrowPressed() {
        onKeyInput?(Character(UnicodeScalar(24))) // Ctrl-X
    }

    @objc private func leftArrowPressed() {
        onKeyInput?(Character(UnicodeScalar(19))) // Ctrl-S
    }

    @objc private func rightArrowPressed() {
        onKeyInput?(Character(UnicodeScalar(4))) // Ctrl-D
    }

    @objc private func ctrlKeyPressed(_ command: UIKeyCommand) {
        guard let input = command.input, let firstChar = input.first else { return }
        // Convert to control character (A=1, B=2, etc.)
        if let ascii = firstChar.asciiValue {
            let ctrlCode = ascii - 96  // 'a' (97) -> 1, 'b' (98) -> 2, etc.
            onKeyInput?(Character(UnicodeScalar(ctrlCode)))
        }
    }
}

#Preview {
    let cells = Array(repeating: Array(repeating: TerminalCell(character: "A", foreground: 2, background: 0), count: 80), count: 25)
    return TerminalView(cells: .constant(cells), cursorRow: .constant(0), cursorCol: .constant(0))
}
