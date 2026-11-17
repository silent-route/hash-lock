import AppKit
import SwiftUI

/// An editable value that wraps onto as many lines as it needs, so a long
/// password, key or address can be read whole, as in Passwords.
///
/// SwiftUI's multi-line TextField hyphenates where it breaks a line, which
/// would show a password with a "-" it doesn't have. Here a code-like value
/// breaks between any two characters, with nothing added; text breaks
/// between words. Smart quotes, dashes and other replacements are off, so
/// what is typed is what is kept.
struct ValueField: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    /// Monospaced and broken between any two characters.
    var code = false
    var onEditing: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = code ? .byCharWrapping : .byWordWrapping
        field.font = code ? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                          : .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = placeholder
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0, let cell = field.cell else { return nil }
        let height = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ValueField
        init(_ parent: ValueField) { self.parent = parent }

        func controlTextDidBeginEditing(_ note: Notification) {
            if let editor = (note.object as? NSTextField)?.currentEditor() as? NSTextView {
                editor.isContinuousSpellCheckingEnabled = false
                editor.isGrammarCheckingEnabled = false
                editor.isAutomaticSpellingCorrectionEnabled = false
                editor.isAutomaticTextReplacementEnabled = false
                editor.isAutomaticQuoteSubstitutionEnabled = false
                editor.isAutomaticDashSubstitutionEnabled = false
                editor.isAutomaticDataDetectionEnabled = false
                editor.isAutomaticLinkDetectionEnabled = false
                editor.isAutomaticTextCompletionEnabled = false
            }
            parent.onEditing(true)
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            // The new text may take more or fewer lines.
            field.invalidateIntrinsicContentSize()
        }

        func controlTextDidEndEditing(_ note: Notification) {
            parent.onEditing(false)
        }
    }
}
