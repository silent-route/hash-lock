import AppKit
import SwiftUI

/// A plain-text editor that grows with its text, for notes and descriptions.
///
/// Everything that would hand the text to another process is off: spelling
/// and grammar checking, autocorrection, text completion, substitutions, data
/// detectors and Writing Tools. Files dropped on it are not taken in as text
/// (they go to the attachments instead). When the view goes away its text
/// storage is overwritten.
struct PlainTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let tv = PlaceholderTextView()
        tv.placeholder = placeholder
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        if #available(macOS 15.0, *) {
            tv.writingToolsBehavior = .none
        }
        // Text only; dropped files are handled by the editor around it.
        tv.unregisterDraggedTypes()
        tv.registerForDraggedTypes([.string])

        tv.string = text
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        if tv.string != text {
            tv.string = text
        }
    }

    /// Measures the text for the width offered without touching the text
    /// view's own container: SwiftUI asks with several widths while laying
    /// out, and the container must keep following the view's real width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let font = tv.font ?? .systemFont(ofSize: NSFont.systemFontSize + 1)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let measured = (tv.textStorage?.copy() as? NSAttributedString ?? NSAttributedString(string: tv.string))
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        // A last empty line (after a return) is not measured but is shown.
        let trailing = tv.string.hasSuffix("\n") ? lineHeight : 0
        let height = max(measured.rounded(.up) + trailing, lineHeight * 6)
        return CGSize(width: width, height: height + tv.textContainerInset.height * 2)
    }

    static func dismantleNSView(_ tv: NSTextView, coordinator: Coordinator) {
        // Overwrite the storage so the text does not linger in it.
        tv.textStorage?.replaceCharacters(in: NSRange(location: 0, length: tv.textStorage?.length ?? 0),
                                          with: String(repeating: " ", count: tv.textStorage?.length ?? 0))
        tv.string = ""
        tv.undoManager?.removeAllActions(withTarget: tv.textStorage as Any)
        tv.undoManager?.removeAllActions()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextView
        init(_ parent: PlainTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

/// An NSTextView that shows a gray placeholder while empty.
final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholder.draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
