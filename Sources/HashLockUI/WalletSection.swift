import SwiftUI
import VaultCore

/// A row of the wallet section. Its buttons appear while the pointer is
/// over it, as on note fields.
struct WalletRow<Content: View>: View {
    let label: String
    let symbol: String
    let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            content
                .environment(\.rowHovered, hovering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

private struct RowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

/// A row button that shows only while its row is hovered.
struct RowButton: View {
    let symbol: String
    let help: String
    var disabled = false
    let action: () -> Void
    @Environment(\.rowHovered) private var hovered

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(help)
            .opacity(hovered ? 1 : 0)
    }
}

/// RowButton's copy button, with the checkmark once copied.
struct RowCopyButton: View {
    let help: String
    var disabled = false
    let copy: () -> Void
    @Environment(\.rowHovered) private var hovered

    var body: some View {
        CopyButton(help: help, visible: hovered, copy: copy)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(disabled)
    }
}

/// A crypto wallet backup: the coin, the seed words in whichever format the
/// wallet uses, the optional passphrase, and what helps restore it. Bitcoin
/// keeps the derivation path, xpub and birthday; Monero the address, keys
/// and restore height.
struct WalletSection: View {
    let model: AppModel
    @Binding var wallet: WalletBackup
    @State private var showWords = !Preferences.defaults.bool(forKey: Preferences.concealSecretsKey)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Seed")
            VStack(alignment: .leading, spacing: 14) {
                Picker("Coin", selection: coinBinding) {
                    ForEach(WalletBackup.Coin.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                HStack(spacing: 16) {
                    Picker("Format", selection: formatBinding) {
                        ForEach(wallet.coin.formats) { Text($0.name).tag($0) }
                    }
                    .fixedSize()
                    Picker("Words", selection: countBinding) {
                        ForEach(wallet.format.wordCounts, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                    Toggle(isOn: $showWords) { Label(showWords ? "Hide" : "Show", systemImage: showWords ? "eye.slash" : "eye") }
                        .toggleStyle(.button)
                        .help(showWords ? "Hide the words" : "Show the words")
                    CopyButton(title: "Copy", help: "Copy all words, separated by spaces") {
                        model.clipboard.copy(wallet.words.joined(separator: " "), label: "Seed words", secret: true)
                    }
                    .disabled(wallet.words.allSatisfy(\.isEmpty))
                }
                SeedWordGrid(words: $wallet.words, columns: columns,
                             concealed: !showWords, checkWords: wallet.format.usesBIP39Words)
                status
            }
            .padding(14)
            .contentCard()

            SectionTitle("Wallet").padding(.top, 12)
            VStack(spacing: 0) {
                row("Passphrase", symbol: "key") {
                    SecretValue(model: model, label: "Passphrase", placeholder: "Optional", text: $wallet.passphrase)
                }
                Divider().padding(.leading, 12)
                row("Software", symbol: "laptopcomputer") {
                    TextField("", text: $wallet.software).textFieldStyle(.plain)
                }
                switch wallet.coin {
                case .bitcoin:
                    Divider().padding(.leading, 12)
                    derivationRow
                    Divider().padding(.leading, 12)
                    row("xpub", symbol: "binoculars") {
                        PublicValue(model: model, label: "xpub", text: $wallet.extendedPublicKey)
                    }
                    Divider().padding(.leading, 12)
                    birthdayRow("Birthday")
                case .monero:
                    Divider().padding(.leading, 12)
                    addressRow
                    Divider().padding(.leading, 12)
                    row("View key", symbol: "eye") {
                        SecretValue(model: model, label: "View key", text: $wallet.viewKey)
                    }
                    Divider().padding(.leading, 12)
                    row("Spend key", symbol: "key.horizontal") {
                        SecretValue(model: model, label: "Spend key", text: $wallet.spendKey)
                    }
                    Divider().padding(.leading, 12)
                    birthdayRow("Restore height")
                case .other:
                    Divider().padding(.leading, 12)
                    derivationRow
                    Divider().padding(.leading, 12)
                    addressRow
                    Divider().padding(.leading, 12)
                    birthdayRow("Birthday")
                }
            }
            .contentCard()
        }
    }

    private var derivationRow: some View {
        row("Derivation", symbol: "point.3.connected.trianglepath.dotted") {
            TextField(wallet.coin == .bitcoin ? "m/84'/0'/0'" : "", text: $wallet.derivationPath)
                .textFieldStyle(.plain)
                .font(.body.monospaced())
        }
    }

    private var addressRow: some View {
        row("Address", symbol: "qrcode") {
            PublicValue(model: model, label: "Address", text: $wallet.address)
        }
    }

    private func birthdayRow(_ label: String) -> some View {
        row(label, symbol: "calendar") {
            TextField("", text: $wallet.birthday)
                .textFieldStyle(.plain)
        }
    }

    /// Wasabi's layout: numbered down the columns, in as many as make even
    /// rows.
    private var columns: Int {
        switch wallet.words.count {
        case 16: 4
        case 25: 5
        case let n where n > 24: 4
        default: 3
        }
    }

    private func row<Content: View>(_ label: String, symbol: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        WalletRow(label: label, symbol: symbol, content: content())
    }

    @ViewBuilder
    private var status: some View {
        let filled = wallet.words.filter { !$0.isEmpty }.count
        if wallet.format == .bip39 && filled == wallet.words.count {
            switch BIP39.validate(wallet.words) {
            case nil:
                Label("The words and their checksum are valid.", systemImage: "checkmark.seal.fill")
                    .font(.callout).foregroundStyle(.green)
            case .badChecksum:
                Label("The checksum doesn’t match: a word is wrong or out of order.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            case .unknownWords(let idx):
                Label("Not BIP-39 words: " + idx.map { "\($0 + 1)" }.joined(separator: ", ") + ".",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            case .wrongCount:
                EmptyView()
            }
        } else {
            Text("\(filled) of \(wallet.words.count) words")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// A coin that has no use for the current format starts with its own
    /// first one; the words typed are kept.
    private var coinBinding: Binding<WalletBackup.Coin> {
        Binding(get: { wallet.coin }, set: { c in
            wallet.coin = c
            if !c.formats.contains(wallet.format) { formatBinding.wrappedValue = c.formats[0] }
        })
    }

    private var formatBinding: Binding<WalletBackup.SeedFormat> {
        Binding(get: { wallet.format }, set: { f in
            wallet.format = f
            if !f.wordCounts.contains(wallet.words.count) { resize(to: f.wordCounts[0]) }
        })
    }

    private var countBinding: Binding<Int> {
        Binding(get: { wallet.words.count }, set: { resize(to: $0) })
    }

    /// Keeps the words already typed.
    private func resize(to n: Int) {
        if n < wallet.words.count {
            wallet.words = Array(wallet.words.prefix(n))
        } else {
            wallet.words += Array(repeating: "", count: n - wallet.words.count)
        }
    }
}

/// A secret in a wallet row: dots until shown, with show and copy buttons
/// that appear on hover.
struct SecretValue: View {
    let model: AppModel
    let label: String
    var placeholder = ""
    @Binding var text: String
    @State private var shown = false

    var body: some View {
        if shown {
            ValueField(text: $text, placeholder: placeholder, code: true)
        } else {
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
        }
        RowButton(symbol: shown ? "eye.slash" : "eye", help: shown ? "Hide" : "Show") { shown.toggle() }
        RowCopyButton(help: "Copy \(label)", disabled: text.isEmpty) {
            model.clipboard.copy(text, label: label, secret: true)
        }
    }
}

/// A public value in a wallet row (an xpub, an address): shown, with a
/// copy button.
struct PublicValue: View {
    let model: AppModel
    let label: String
    @Binding var text: String

    var body: some View {
        ValueField(text: $text, code: true)
        RowCopyButton(help: "Copy \(label)", disabled: text.isEmpty) {
            model.clipboard.copy(text, label: label, secret: false)
        }
    }
}
