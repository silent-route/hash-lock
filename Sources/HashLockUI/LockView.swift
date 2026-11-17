import SwiftUI
import VaultCore

/// What the window shows while the vault is locked: the icon, a password
/// field and, if the vault has one, the way in with the recovery key.
struct LockView: View {
    @Bindable var model: AppModel
    @State private var password = ""
    @State private var wrong = false
    @State private var attempts: CGFloat = 0
    @State private var showRecovery = false
    @FocusState private var focused: Bool
    /// Whether the window is the key window. The field takes the keyboard
    /// only then: locking happens in the background as well, and must not
    /// bring a hidden window forward.
    @Environment(\.controlActiveState) private var active

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            AppIcon(size: 96)
                .padding(.bottom, 18)
            VaultPicker(model: model, prominent: true)
            Text("Enter the vault’s password to unlock it.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            HStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .disabled(model.working)
                    .onSubmit(unlock)
                    .onChange(of: password) { wrong = false }
                Group {
                    if model.working {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(action: unlock) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 22))
                        }
                        .buttonStyle(.borderless)
                        .disabled(password.isEmpty)
                        .help("Unlock")
                        .accessibilityLabel("Unlock")
                    }
                }
                .frame(width: 24, height: 24)
            }
            .frame(width: 280)
            .padding(.top, 22)
            .modifier(Shake(animatableData: attempts))

            Text(wrong ? "Incorrect password" : model.working ? "Unlocking…" : " ")
                .font(.callout)
                .foregroundStyle(wrong ? .red : .secondary)
                .padding(.top, 8)
                .accessibilityHidden(!wrong && !model.working)
            if model.hasRecoveryKey {
                Button("Use Recovery Key…") { showRecovery = true }
                    .buttonStyle(.link)
                    .padding(.top, 10)
                    .disabled(model.working)
            }
            Spacer()
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if active == .key { focused = true } }
        .onChange(of: active) { _, now in if now == .key { focused = true } }
        .onChange(of: model.current?.id) {
            password = ""
            wrong = false
            if active == .key { focused = true }
        }
        .sheet(isPresented: $showRecovery) {
            RecoveryUnlockSheet(model: model)
        }
    }

    private func unlock() {
        guard !password.isEmpty, !model.working else { return }
        let attempt = password
        Task {
            if await model.unlock(password: attempt) {
                password = ""
            } else if model.notice == nil {
                wrong = true
                password = ""
                withAnimation(.linear(duration: 0.4)) { attempts += 1 }
                focused = true
            }
        }
    }
}

/// Unlocking with the 24-word recovery phrase.
struct RecoveryUnlockSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var words = Array(repeating: "", count: 24)
    @State private var wrong = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unlock with Recovery Key")
                .font(.headline)
            Text("Enter the 24 words you wrote down when you created the recovery key. You can paste them all into the first field.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SeedWordGrid(words: $words, columns: 4, concealed: false, checkWords: true)
            if wrong {
                Text(BIP39.validate(words) == .badChecksum
                     ? "These words contain a mistake: the last word does not match the others."
                     : "This recovery key does not open this vault.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if model.working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Unlock") {
                    Task {
                        if await model.unlock(recoveryPhrase: words) {
                            dismiss()
                        } else {
                            wrong = true
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(words.contains(where: \.isEmpty) || model.working)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onChange(of: words) { wrong = false }
    }
}

/// The vault's name, as a menu of every vault and New Vault…, like the
/// account picker of the macOS login window.
struct VaultPicker: View {
    @Bindable var model: AppModel
    /// The lock screen's large title; otherwise a toolbar-sized label.
    var prominent = false

    var body: some View {
        Menu {
            ForEach(model.vaults) { v in
                Button {
                    Task { await model.select(v) }
                } label: {
                    if v.id == model.current?.id {
                        Label(v.name, systemImage: "checkmark")
                    } else {
                        Text(v.name)
                    }
                }
            }
            Divider()
            Button("New Vault…") { model.showNewVault = true }
            Button("Import Vault…") { VaultFilePanels.importVault(model: model) }
        } label: {
            if prominent {
                // One Text, so the menu keeps the chevron after the name.
                (Text(model.current?.name ?? "Hash Lock") + Text("  ")
                    + Text(Image(systemName: "chevron.down")).font(.callout.weight(.semibold)).foregroundColor(.secondary))
                    .font(.title2.weight(.semibold))
            } else {
                Label(model.current?.name ?? "Vault", systemImage: "lock.shield")
                    .labelStyle(.titleAndIcon)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.working)
        .help("Choose a vault, or create a new one")
        .accessibilityLabel("Vault: \(model.current?.name ?? "")")
    }
}
