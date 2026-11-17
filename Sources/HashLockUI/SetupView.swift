import SwiftUI
import VaultCore

/// Making a vault: its name and the password its key is made from. The
/// whole window on first launch; a sheet for each vault after that.
struct SetupView: View {
    @Bindable var model: AppModel
    /// Shown as a sheet (New Vault…), with Cancel.
    var asSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var verify = ""
    /// Created from the sheet: it goes on to offer a recovery key.
    @State private var created = false
    @AppStorage(Preferences.kdfLevelKey) private var level = Preferences.kdfLevelDefault
    @FocusState private var focused: Bool

    private var strength: PasswordStrength { PasswordStrength.estimate(password) }
    private var mismatch: Bool { !verify.isEmpty && verify != password }
    private var canCreate: Bool { !password.isEmpty && password == verify && strength >= .weak && !model.working }

    var body: some View {
        if created {
            OfferRecoverySheet(model: model)
        } else {
            form
        }
    }

    private var form: some View {
        VStack(spacing: 0) {
            if !asSheet { Spacer() }
            AppIcon(size: asSheet ? 56 : 80)
                .padding(.bottom, 14)
            Text(asSheet ? "New Vault" : "Create Your Vault")
                .font(.title2.weight(.semibold))
            Text("Everything you keep in a vault is encrypted with a key made from its password. The password itself is never stored, so no one — not even Hash Lock — can open the vault without it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 400)
                .padding(.top, 6)

            // Grouped like a System Settings form, but laid out at its natural
            // height: nothing is clipped whatever the text size.
            VStack(alignment: .leading, spacing: 6) {
                GroupedRows {
                    LabeledRow("Name") {
                        TextField("", text: $name, prompt: Text(model.vaults.isEmpty ? "Personal" : "Work"))
                            .focused($focused)
                    }
                }
                Text("Shown when choosing a vault to unlock, so it is not encrypted. Don’t put secrets in it.")
                    .rowFooter()

                GroupedRows {
                    LabeledRow("Password") {
                        SecureField("", text: $password)
                    }
                    Divider().padding(.leading, 12)
                    LabeledRow("Verify") {
                        SecureField("", text: $verify)
                            .onSubmit(create)
                    }
                }
                .padding(.top, 12)
                StrengthMeter(strength: strength, empty: password.isEmpty)
                    .font(.callout)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
                Group {
                    if mismatch {
                        Text("The passwords don’t match.").foregroundStyle(.red)
                    } else {
                        Text("A passphrase of four or more random words is both strong and easy to remember.")
                            .foregroundStyle(.secondary)
                    }
                }
                .rowFooter()
            }
            .frame(width: 420)
            .padding(.top, 22)

            Text("If you forget the password, the vault cannot be opened. You can create a recovery key next.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 420)
                .padding(.top, 18)

            HStack {
                if model.working {
                    ProgressView().controlSize(.small)
                    Text("Creating…").foregroundStyle(.secondary)
                }
                if asSheet {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.large)
                }
                Button("Create Vault", action: create)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .disabled(!canCreate)
            }
            .padding(.top, 18)
            if !asSheet {
                Spacer()
                Spacer()
            }
        }
        .padding(30)
        .frame(maxWidth: asSheet ? nil : .infinity, maxHeight: asSheet ? nil : .infinity)
        .onAppear { focused = true }
    }

    private func create() {
        guard canCreate else { return }
        let (pw, n) = (password, name.isEmpty ? (model.vaults.isEmpty ? "Personal" : "Vault") : name)
        Task {
            if await model.createVault(name: n, password: pw, level: level) {
                password = ""
                verify = ""
                if asSheet { created = true } else { model.offerRecoveryKey = true }
            }
        }
    }
}

struct StrengthMeter: View {
    let strength: PasswordStrength
    var empty = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<5) { i in
                    Capsule()
                        .fill(!empty && i <= strength.rawValue ? color : Color.primary.opacity(0.12))
                        .frame(width: 30, height: 4)
                }
            }
            Text(empty ? " " : label)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(empty ? "" : "Password strength: \(label)")
    }

    private var label: String {
        switch strength {
        case .veryWeak: "Very weak"
        case .weak: "Weak"
        case .fair: "Fair"
        case .strong: "Strong"
        case .veryStrong: "Very strong"
        }
    }

    private var color: Color {
        switch strength {
        case .veryWeak: .red
        case .weak: .orange
        case .fair: .yellow
        case .strong, .veryStrong: .green
        }
    }
}

/// Shows a new recovery phrase once, to be written down.
struct RecoveryKeySheet: View {
    let words: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var written = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your Recovery Key", systemImage: "key.horizontal")
                .font(.headline)
            Text("These 24 words open the vault if you forget the password. Write them down on paper, in order, and keep them somewhere safe. Anyone who has them can open the vault. They are shown only now.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Down the columns, in the order the words are written out.
            HStack(alignment: .top) {
                ForEach(0..<4, id: \.self) { c in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(0..<(words.count + 3) / 4, id: \.self) { r in
                            let i = c * ((words.count + 3) / 4) + r
                            if i < words.count {
                                HStack(spacing: 6) {
                                    Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                                    Text(words[i]).font(.body.monospaced()).textSelection(.disabled)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .contentCard()
            Text("This is not a crypto wallet seed, even though the words come from the same list.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Toggle("I have written down these 24 words", isOn: $written)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!written)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(!written)
    }
}

/// Offered right after the vault is created.
struct OfferRecoverySheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var words: [String]?

    var body: some View {
        if let words {
            RecoveryKeySheet(words: words)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label("Create a Recovery Key?", systemImage: "key.horizontal")
                    .font(.headline)
                Text("A recovery key is 24 words you write down on paper. With it you can open the vault if you ever forget the password. Without one, a forgotten password means the data is lost for good.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can create one later in Settings › Vault.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Not Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create Recovery Key…") {
                        Task { words = await model.createRecoveryKey() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }
}

/// Rows in a rounded group, as System Settings draws a form section.
struct GroupedRows<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .contentCard()
    }
}

/// A label on the left and a control filling the rest, in a grouped row.
struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 96, alignment: .leading)
            content
                .textFieldStyle(.plain)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

extension View {
    /// The note under a group of rows: secondary, leading, wrapping.
    func rowFooter() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }
}
