import SwiftUI
import VaultCore

/// Numbered fields for seed or recovery words. Pasting a whole phrase into
/// any field spreads it across the fields from there; leaving a field with a
/// prefix that only one BIP-39 word starts with completes it.
struct SeedWordGrid: View {
    @Binding var words: [String]
    var columns = 3
    /// Words shown as dots until the field is being edited.
    var concealed: Bool
    /// Marks words that are not in the BIP-39 list.
    var checkWords: Bool
    @FocusState private var focus: Int?

    /// Numbered down the columns, as on wallet backup cards and in Wasabi:
    /// with 12 words in 3 columns, 1–4, 5–8, 9–12. The keyboard (Tab,
    /// Return) goes in the same order.
    var body: some View {
        let rows = (words.count + columns - 1) / max(columns, 1)
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<columns, id: \.self) { c in
                VStack(spacing: 8) {
                    ForEach(0..<rows, id: \.self) { r in
                        let i = c * rows + r
                        if i < words.count { cell(i) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .onChange(of: focus) { old, _ in
            if let old, old < words.count { complete(old) }
        }
    }

    private func cell(_ i: Int) -> some View {
        let word = words[i]
        let unknown = checkWords && !word.isEmpty && focus != i && !BIP39.isWord(word.lowercased())
        return HStack(spacing: 6) {
            Text("\(i + 1).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
            Group {
                if concealed && focus != i && !word.isEmpty {
                    // Dots of a fixed length, so the word's length is not shown either.
                    Text("••••••")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                        .onTapGesture { focus = i }
                        .contentCard(cornerRadius: 5)
                } else {
                    TextField("", text: binding(i))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textContentType(.none)
                        .font(.body.monospaced())
                        .focused($focus, equals: i)
                        .onSubmit { focus = i + 1 < words.count ? i + 1 : nil }
                }
            }
            .overlay(alignment: .trailing) {
                if unknown {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .padding(.trailing, 5)
                        .help("“\(word)” is not a BIP-39 word")
                }
            }
        }
    }

    private func binding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < words.count ? words[i] : "" },
            set: { value in
                let parts = value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { String($0).lowercased() }
                if parts.count > 1 {
                    // A pasted phrase: one word per field from here on.
                    for (k, w) in parts.enumerated() where i + k < words.count { words[i + k] = w }
                    focus = min(i + parts.count, words.count - 1)
                } else if i < words.count {
                    words[i] = value.lowercased().trimmingCharacters(in: .whitespaces)
                }
            })
    }

    /// Four letters always pick one BIP-39 word; three often do.
    private func complete(_ i: Int) {
        guard i < words.count else { return }
        let w = words[i]
        guard checkWords, w.count >= 3, !BIP39.isWord(w) else { return }
        let options = BIP39.completions(for: w, limit: 2)
        if options.count == 1 { words[i] = options[0] }
    }
}
