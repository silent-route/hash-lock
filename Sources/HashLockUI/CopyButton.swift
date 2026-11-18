import SwiftUI

/// A copy button whose icon turns into a checkmark for a moment once the
/// value is on the clipboard, so a click visibly did something. The icon
/// keeps the width of the copy symbol, so nothing next to it moves.
struct CopyButton: View {
    /// Shown next to the icon, as in the seed words' Copy.
    var title: String?
    let help: String
    /// Hidden until the row is hovered; the checkmark shows regardless.
    var visible = true
    let copy: () -> Void
    @State private var copies = 0
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
            copies += 1
        } label: {
            if let title {
                Label { Text(title) } icon: { icon }
            } else {
                icon
            }
        }
        .help(help)
        .accessibilityLabel(copied ? "Copied" : help)
        .opacity(visible || copied ? 1 : 0)
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { copied = false }
        }
    }

    private var icon: some View {
        ZStack {
            Image(systemName: "doc.on.doc").hidden()
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
    }
}
