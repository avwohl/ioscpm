/*
 * TerminalView.swift - Terminal display for CP/M console
 */

import SwiftUI
import UIKit

struct TerminalView: UIViewRepresentable {
    @Binding var text: String
    var onKeyInput: ((Character) -> Void)?

    func makeUIView(context: Context) -> TerminalUIView {
        let view = TerminalUIView()
        view.onKeyInput = onKeyInput
        return view
    }

    func updateUIView(_ uiView: TerminalUIView, context: Context) {
        uiView.terminalText = text
    }
}

class TerminalUIView: UIView, UIKeyInput {
    var terminalText: String = "" {
        didSet {
            textView.text = terminalText
            scrollToBottom()
        }
    }

    var onKeyInput: ((Character) -> Void)?

    private let textView: UITextView = {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .black
        tv.textColor = .green
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.spellCheckingType = .no
        return tv
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        // Add tap gesture to become first responder
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap() {
        becomeFirstResponder()
    }

    private func scrollToBottom() {
        guard textView.text.count > 0 else { return }
        let range = NSRange(location: textView.text.count - 1, length: 1)
        textView.scrollRangeToVisible(range)
    }

    // MARK: - UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        for char in text {
            onKeyInput?(char)
        }
    }

    func deleteBackward() {
        // Send backspace (ASCII 8) or DEL (127)
        onKeyInput?(Character(UnicodeScalar(8)))
    }

    // MARK: - UIResponder

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        // Handle special keys
        return [
            UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(enterPressed)),
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escapePressed))
        ]
    }

    @objc private func enterPressed() {
        onKeyInput?(Character("\r"))
    }

    @objc private func escapePressed() {
        onKeyInput?(Character(UnicodeScalar(27)))
    }
}

#Preview {
    TerminalView(text: .constant("A>DIR\r\n\r\nNo file"))
}
