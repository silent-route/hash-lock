import ServiceManagement
import SwiftUI
import VaultCore

/// Settings, laid out like System Settings: one grouped form per tab.
public struct SettingsView: View {
    public enum Tab: String, CaseIterable, Sendable {
        case general, lock, privacy, vault, about
    }

    @Bindable var model: AppModel
    let actions: AppActions
    @State private var tab: Tab

    public init(model: AppModel, actions: AppActions, tab: Tab = .general) {
        self.model = model
        self.actions = actions
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { SettingsTab.label("General", "gearshape") }
                .tag(Tab.general)
            LockSettings(model: model)
                .tabItem { SettingsTab.label("Lock", "lock.rectangle") }
                .tag(Tab.lock)
            PrivacySettings(model: model)
                .tabItem { SettingsTab.label("Privacy", "hand.raised") }
                .tag(Tab.privacy)
            VaultSettings(model: model, actions: actions)
                .tabItem { SettingsTab.label("Vault", "lock.shield") }
                .tag(Tab.vault)
            AboutSettings()
                .tabItem { SettingsTab.label("About", "info.circle") }
                .tag(Tab.about)
        }
        // One size for every tab, as in Silent Route; a tab that holds more
        // scrolls.
        .frame(width: 600, height: 480)
    }
}

extension SettingsView {
    /// One tab's page on its own, for ui-snapshots: outside a Settings
    /// window a TabView would draw segmented tabs, which the app never shows.
    @MainActor
    public static func page(_ tab: Tab, model: AppModel, actions: AppActions) -> AnyView {
        switch tab {
        case .general: AnyView(GeneralSettings())
        case .lock: AnyView(LockSettings(model: model))
        case .privacy: AnyView(PrivacySettings(model: model))
        case .vault: AnyView(VaultSettings(model: model, actions: actions))
        case .about: AnyView(AboutSettings())
        }
    }
}

/// What an exported vault file means, in red: it is protected by the
/// password alone, and it does not follow later changes to the vault.
struct ExportWarnings: View {
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            warning(compact
                    ? "Only the password protects the file: whoever has it can guess at it, without limit."
                    : "Only the password protects this file. Whoever has a copy can try to guess the password on their own computer, as many times as they like — the limit on incorrect passwords does not apply there.")
            warning(compact
                    ? "A copy lives on its own: a later password change or deletion here does not touch it."
                    : "The file lives on its own. Changing this vault’s password or recovery key, or deleting the vault, does not change copies already exported: they still open with the password and recovery key they were made with.")
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(compact ? .callout : .body)
        .foregroundStyle(.red)
    }
}

/// Shown before the Save panel when exporting a vault.
struct ExportWarningSheet: View {
    let proceed: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Vault").font(.headline)
            ExportWarnings()
            Text("Use a strong password for a vault you export (Settings › Vault › Change Password, and a Strong key).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: proceed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// A tab's icon as Finder's Settings draw theirs: SF Symbols at the large
/// scale and regular weight, each in a box of the same width, so narrow
/// glyphs (a shield, a hand) don't look thinner than wide ones.
enum SettingsTab {
    static func label(_ title: String, _ symbol: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(nsImage: icon(symbol))
        }
    }

    static func icon(_ symbol: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular, scale: .large)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSImage() }
        let box = NSSize(width: max(glyph.size.width, 30), height: max(glyph.size.height, 26))
        let image = NSImage(size: box, flipped: false) { rect in
            glyph.draw(in: NSRect(x: (rect.width - glyph.size.width) / 2, y: (rect.height - glyph.size.height) / 2,
                                  width: glyph.size.width, height: glyph.size.height))
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// What Settings asks the app itself to do.
public struct AppActions: Sendable {
    public var uninstall: @MainActor @Sendable (_ withData: Bool) async -> Void
    public init(uninstall: @escaping @MainActor @Sendable (Bool) async -> Void) {
        self.uninstall = uninstall
    }
}

struct GeneralSettings: View {
    @AppStorage(Preferences.dockIconKey) private var dock = Preferences.dockIconDefault
    @AppStorage(Preferences.openWindowAtLaunchKey) private var openWindow = true
    @AppStorage(Preferences.menuBarIconKey) private var menuBarIcon = Preferences.menuBarIconDefault
    @AppStorage(Preferences.sortOrderKey) private var sort = Preferences.sortOrderDefault
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Show in Dock", selection: $dock) {
                    ForEach(Preferences.DockIcon.allCases) { Text($0.title).tag($0) }
                }
                Picker("Menu bar icon", selection: $menuBarIcon) {
                    ForEach(MenuBarIcon.allCases, id: \.self) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            if let img = style.image(unlocked: false) { Image(nsImage: img) }
                        }
                        .tag(style)
                    }
                }
                Toggle("Open the window when Hash Lock starts", isOn: $openWindow)
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: { setLoginItem($0) }))
            } footer: {
                if let loginError {
                    Text(loginError).foregroundStyle(.red)
                } else {
                    Text("Hash Lock is always in the menu bar, where it can be opened and locked whatever the Dock shows.")
                        .formFooter()
                }
            }
            Section {
                Picker("Sort items by", selection: $sort) {
                    ForEach(Preferences.SortOrder.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Pinned items stay at the top.").formFooter()
            }
        }
        .formStyle(.grouped)
    }

    private func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginItem = SMAppService.mainApp.status == .enabled
    }
}

/// Security settings change only with a vault unlocked: someone at the Mac
/// while it is locked must not be able to, say, turn automatic locking off
/// before its owner next opens it. With no vault yet there is nothing to
/// protect.
struct VaultGuard: ViewModifier {
    let model: AppModel
    private var allowed: Bool { model.phase == .unlocked || model.phase == .setup }

    func body(content: Content) -> some View {
        content
            .disabled(!allowed)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !allowed {
                    Label("Unlock a vault to change these settings.", systemImage: "lock.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
            }
    }
}

struct LockSettings: View {
    let model: AppModel
    @AppStorage(Preferences.eraseAfterFailuresKey) private var erase = false
    @AppStorage(Preferences.eraseAfterLimitKey) private var eraseLimit = Preferences.eraseAfterLimitDefault
    @State private var confirmErase = false
    @AppStorage(Preferences.idleLockKey) private var idle = Preferences.idleLockDefault
    @AppStorage(Preferences.backgroundLockKey) private var background = 0
    @AppStorage(Preferences.lockOnSleepKey) private var sleep = true
    @AppStorage(Preferences.lockOnScreenLockKey) private var screen = true
    @AppStorage(Preferences.lockOnUserSwitchKey) private var userSwitch = true
    @AppStorage(Preferences.lockOnWindowCloseKey) private var windowClose = false

    var body: some View {
        Form {
            Section {
                Picker("Lock after not using Hash Lock for", selection: $idle) {
                    ForEach(Preferences.idleLockChoices, id: \.self) { Text(Preferences.minutes($0)).tag($0) }
                }
                Picker("Lock after Hash Lock is in the background for", selection: $background) {
                    ForEach(Preferences.backgroundLockChoices, id: \.self) { Text(Preferences.minutes($0)).tag($0) }
                }
            } footer: {
                Text("Locking never quits Hash Lock: the window stays where it is and asks for the password again.")
                    .formFooter()
            }
            Section("Also lock when") {
                Toggle("The Mac goes to sleep", isOn: $sleep)
                Toggle("The screen locks or the screen saver starts", isOn: $screen)
                Toggle("You switch to another user", isOn: $userSwitch)
                Toggle("The Hash Lock window is closed", isOn: $windowClose)
            }
            Section {
                Toggle("Erase a vault after too many incorrect passwords", isOn: Binding(
                    get: { erase },
                    set: { on in if on { confirmErase = true } else { erase = false } }))
                if erase {
                    Picker("Incorrect passwords allowed", selection: $eraseLimit) {
                        ForEach(Preferences.eraseAfterLimitChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                }
            } header: {
                Text("Incorrect Passwords")
            } footer: {
                Text("Counted per vault, in a row; unlocking resets the count, and the lock screen warns before the last attempts. This stops guessing in Hash Lock, not guessing at a copy of the vault's files on another computer: against that, only a strong password helps.")
                    .formFooter()
            }
        }
        .confirmationDialog("Erase vaults after incorrect passwords?", isPresented: $confirmErase) {
            Button("Turn On", role: .destructive) { erase = true }
        } message: {
            Text("Anyone at this Mac could then erase a vault on purpose by typing wrong passwords, and a vault erased this way cannot be recovered — not even with its recovery key. Keep a backup of the vault's folder.")
        }
        .formStyle(.grouped)
        .modifier(VaultGuard(model: model))
    }
}

struct PrivacySettings: View {
    let model: AppModel
    @AppStorage(Preferences.clipboardClearKey) private var clear = Preferences.clipboardClearDefault
    @AppStorage(Preferences.clipboardLocalOnlyKey) private var localOnly = true
    @AppStorage(Preferences.clearClipboardOnLockKey) private var clearOnLock = true
    @AppStorage(Preferences.hideFromCaptureKey) private var hideFromCapture = false
    @AppStorage(Preferences.concealSecretsKey) private var conceal = true
    @AppStorage(Preferences.allowDragOutKey) private var dragOut = true

    var body: some View {
        Form {
            Section {
                Picker("Clear copied values after", selection: $clear) {
                    ForEach(Preferences.clipboardClearChoices, id: \.self) { Text(Preferences.seconds($0)).tag($0) }
                }
                Toggle("Clear the clipboard when Hash Lock locks", isOn: $clearOnLock)
                Toggle("Keep copied values on this Mac", isOn: $localOnly)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("The clipboard is cleared only if it still holds what Hash Lock put there. Copied passwords are marked so that clipboard history apps don’t record them; kept on this Mac, they don’t reach your other devices through Universal Clipboard.")
                    .formFooter()
            }
            Section {
                Toggle("Hide passwords and seed words until shown", isOn: $conceal)
                Toggle("Hide Hash Lock’s windows from screenshots and screen sharing", isOn: $hideFromCapture)
                Toggle("Allow dragging files out to Finder", isOn: $dragOut)
            } header: {
                Text("Screen and Files")
            } footer: {
                Text("A file dragged out or exported is saved decrypted where you put it.")
                    .formFooter()
            }
        }
        .formStyle(.grouped)
        .modifier(VaultGuard(model: model))
    }
}

struct VaultSettings: View {
    @Bindable var model: AppModel
    let actions: AppActions
    @State private var changePassword = false
    @State private var newRecovery: [String]?
    @State private var confirmRecovery = false
    @State private var confirmRemoveRecovery = false
    @State private var report: Vault.IntegrityReport?
    @State private var checking = false
    @State private var deleteSheet: DeleteSheet.Mode?
    @State private var name = ""
    @State private var showExportWarning = false
    /// A recovery phrase made by re-encrypting, shown once the password
    /// sheet has closed.
    @State private var pendingRecovery: [String]?
    @State private var confirmRemoveParts = false

    private var unlocked: Bool { model.phase == .unlocked }

    var body: some View {
        Form {
            if model.phase == .setup {
                Section {
                    Text("There is no vault yet.").foregroundStyle(.secondary)
                }
            } else {
                Section {
                    LabeledContent("Vault") {
                        Picker("", selection: Binding(get: { model.current?.id }, set: { id in
                            if let v = model.vaults.first(where: { $0.id == id }) { Task { await model.select(v) } }
                        })) {
                            ForEach(model.vaults) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.working)
                    }
                    TextField("Name", text: $name)
                        .disabled(!unlocked)
                        .onSubmit { model.renameCurrent(to: name) }
                        .onChange(of: model.current?.id) { name = model.current?.name ?? "" }
                        .onAppear { name = model.current?.name ?? "" }
                        .onDisappear { if name != model.current?.name { model.renameCurrent(to: name) } }
                } footer: {
                    Text("These settings are for the vault chosen here; each vault has its own password and recovery key. The name is not encrypted.")
                        .formFooter()
                }
                Section {
                    LabeledContent("Password") {
                        Button("Change Password…") { changePassword = true }
                            .disabled(!unlocked)
                    }
                    LabeledContent("Key strength") {
                        Text(strengthText).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Password")
                } footer: {
                    Text(unlocked
                         ? "The password is never stored. It is turned into a key with Argon2id, which takes the memory and time shown above for every guess, here and on any computer trying to guess it."
                         : "Unlock this vault to change its password or recovery key.")
                        .formFooter()
                }
                Section {
                    LabeledContent("Recovery key") {
                        HStack {
                            Text(model.hasRecoveryKey ? "Set up" : "None").foregroundStyle(.secondary)
                            if model.hasRecoveryKey {
                                Button("Remove…") { confirmRemoveRecovery = true }.disabled(!unlocked)
                            }
                            Button(model.hasRecoveryKey ? "Replace…" : "Create…") {
                                if model.hasRecoveryKey { confirmRecovery = true } else { makeRecovery() }
                            }
                            .disabled(!unlocked)
                        }
                    }
                } footer: {
                    Text("24 words that open the vault if the password is forgotten. Replacing it makes the old words stop working.")
                        .formFooter()
                }
                Section {
                    LabeledContent("Integrity") {
                        HStack {
                            if checking { ProgressView().controlSize(.small) }
                            if let report {
                                Text(report.damaged.isEmpty ? "All \(report.checked) parts are intact"
                                     : "\(report.damaged.count) damaged item(s)")
                                    .foregroundStyle(report.damaged.isEmpty ? Color.secondary : Color.red)
                            }
                            Button("Verify") {
                                checking = true
                                Task {
                                    report = await model.verify()
                                    checking = false
                                }
                            }
                            .disabled(!unlocked || checking)
                        }
                    }
                    if let report, report.unreferenced > 0 {
                        LabeledContent {
                            HStack {
                                Button("Remove…") { confirmRemoveParts = true }
                                Button("Recover") {
                                    Task {
                                        _ = await model.recoverUnreferenced()
                                        self.report = await model.verify()
                                    }
                                }
                            }
                            .disabled(!unlocked)
                        } label: {
                            Text("Parts without an item")
                            Text(report.unreferenced == 1 ? "1 part belongs to no item." : "\(report.unreferenced) parts belong to no item.")
                        }
                    }
                    LabeledContent("Vault file") {
                        HStack {
                            Button("Import…") { VaultFilePanels.importVault(model: model) }
                            Button("Export…") { showExportWarning = true }
                                .disabled(!unlocked)
                        }
                    }
                    LabeledContent("Location") {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.current?.directory ?? VaultLocation.library])
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Verify decrypts every part of the vault to make sure nothing is damaged or was changed outside Hash Lock. Export writes the vault, still encrypted, to one .hashlock file: a backup, or a way to open it on another Mac.")
                            .formFooter()
                        ExportWarnings(compact: true)
                    }
                }
            }
            Section {
                if model.phase != .setup {
                    LabeledContent("Delete “\(model.current?.name ?? "")”") {
                        Button("Delete Vault…", role: .destructive) { deleteSheet = .deleteVault }
                    }
                }
                LabeledContent("Uninstall") {
                    Button("Uninstall Hash Lock…", role: .destructive) { deleteSheet = .uninstall }
                }
            } header: {
                Text("Remove")
            }
        }
        .formStyle(.grouped)
        // Locking closes whatever this tab had open: above all, a new
        // recovery phrase must not stay on screen.
        .onChange(of: model.phase) { _, phase in
            guard phase != .unlocked else { return }
            changePassword = false
            showExportWarning = false
            newRecovery = nil
            confirmRecovery = false
            confirmRemoveRecovery = false
            report = nil
            if deleteSheet == .deleteVault { deleteSheet = nil }
        }
        .sheet(isPresented: $changePassword, onDismiss: {
            // One sheet at a time: the new phrase waits for this one to go.
            if let words = pendingRecovery {
                pendingRecovery = nil
                newRecovery = words
            }
        }) {
            ChangePasswordSheet(model: model) { pendingRecovery = $0 }
        }
        .sheet(isPresented: $showExportWarning) {
            ExportWarningSheet {
                showExportWarning = false
                VaultFilePanels.exportVault(model: model)
            }
        }
        .sheet(item: Binding(get: { newRecovery.map(Words.init) }, set: { if $0 == nil { newRecovery = nil } })) { w in
            RecoveryKeySheet(words: w.words)
        }
        .sheet(item: $deleteSheet) { mode in
            DeleteSheet(model: model, actions: actions, mode: mode)
        }
        .confirmationDialog("Replace the recovery key?", isPresented: $confirmRecovery) {
            Button("Replace") { makeRecovery() }
        } message: {
            Text("The words you wrote down before will no longer open the vault. A backup made earlier still opens with them; if someone may have seen the words, change the password with “Re-encrypt” on instead, which also makes a new recovery key.")
        }
        .confirmationDialog("Remove the recovery key?", isPresented: $confirmRemoveRecovery) {
            Button("Remove", role: .destructive) { Task { await model.removeRecoveryKey() } }
        } message: {
            Text("Only the password will open the vault. If you forget it, the data is lost. A backup made earlier still opens with the words.")
        }
        .confirmationDialog("Remove the parts that belong to no item?", isPresented: $confirmRemoveParts) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.removeUnreferenced()
                    report = await model.verify()
                }
            }
        } message: {
            Text("They are left by a crash while something was being saved, or by putting back an older copy of the vault’s files. They may be the only copy of something: Recover lists them as items to look at first. Removing them cannot be undone.")
        }
    }

    private struct Words: Identifiable {
        let words: [String]
        var id: String { words.joined() }
    }

    private func makeRecovery() {
        Task { newRecovery = await model.createRecoveryKey() }
    }

    private var strengthText: String {
        guard let p = model.kdfParameters else { return unlocked ? "—" : "Unlock to see" }
        let mem = ByteCountFormatter.string(fromByteCount: Int64(p.memLimit), countStyle: .memory)
        let name = p.level.map { KDFLevelText.name($0) } ?? "Custom"
        return "\(name) · Argon2id, \(mem), \(p.opsLimit) passes"
    }
}

enum KDFLevelText {
    static func name(_ l: KDFParameters.Level) -> String {
        switch l {
        case .standard: "Standard"
        case .strong: "Strong"
        case .maximum: "Maximum"
        }
    }

    static func detail(_ l: KDFParameters.Level) -> String {
        let mem = ByteCountFormatter.string(fromByteCount: Int64(l.parameters.memLimit), countStyle: .memory)
        switch l {
        case .standard: return "\(mem) · about half a second to unlock"
        case .strong: return "\(mem) · one to two seconds"
        case .maximum: return "\(mem) · two to five seconds; needs free memory"
        }
    }
}

struct ChangePasswordSheet: View {
    @Bindable var model: AppModel
    /// After unlocking with the recovery key: no current password is asked.
    var reset = false
    /// Re-encrypting made a new recovery phrase, to be shown.
    var newRecoveryKey: ([String]) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var verify = ""
    @State private var wrong = false
    @State private var level = KDFParameters.Level.standard
    @State private var reencrypt = true

    private var canSave: Bool {
        (reset || !current.isEmpty) && !new.isEmpty && new == verify && PasswordStrength.estimate(new) >= .weak && !model.working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(reset ? "Choose a New Password" : "Change Password").font(.headline).padding([.top, .horizontal], 20)
                .padding(.bottom, reset ? 0 : -8)
            if reset {
                Text("You unlocked “\(model.current?.name ?? "the vault")” with its recovery key. Choose a new password for it; the recovery key keeps working.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !reset {
                    GroupedRows {
                        LabeledRow("Current") {
                            SecureField("", text: $current)
                                .onChange(of: current) { wrong = false }
                        }
                    }
                    if wrong {
                        Text("The current password is incorrect.").foregroundStyle(.red).rowFooter()
                    }
                }
                GroupedRows {
                    LabeledRow("New") { SecureField("", text: $new) }
                    Divider().padding(.leading, 12)
                    LabeledRow("Verify") { SecureField("", text: $verify) }
                }
                .padding(.top, reset ? 0 : 10)
                StrengthMeter(strength: PasswordStrength.estimate(new), empty: new.isEmpty)
                    .font(.callout)
                    .padding(.horizontal, 2)
                if !verify.isEmpty && verify != new {
                    Text("The passwords don’t match.").foregroundStyle(.red).rowFooter()
                }
                GroupedRows {
                    LabeledRow("Key strength") {
                        Picker("", selection: $level) {
                            ForEach(KDFParameters.Level.allCases) { l in Text(KDFLevelText.name(l)).tag(l) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                }
                .padding(.top, 10)
                Text(KDFLevelText.detail(level) + (reset ? ". Stronger settings make every guess slower for an attacker, and unlocking slower for you." : "."))
                    .rowFooter()
                if !reset {
                    GroupedRows {
                        Toggle("Re-encrypt the vault with a new key", isOn: $reencrypt)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                    }
                    .padding(.top, 10)
                    Text(reencrypt
                         ? "The old password then opens nothing, even with a backup of the vault. Needs room for a second copy."
                           + (model.hasRecoveryKey ? " The recovery key is replaced too." : "")
                         : "Faster, but a backup of the vault and the old password still open what is here now.")
                        .rowFooter()
                }
            }
            .padding(20)
            HStack {
                if model.working {
                    ProgressView().controlSize(.small)
                    if reencrypt && !reset { Text("Re-encrypting…").foregroundStyle(.secondary) }
                }
                Spacer()
                Button(reset ? "Later" : "Cancel", role: .cancel) {
                    model.mustSetPassword = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(reset ? "Set Password" : "Change Password") {
                    let (c, n, l, r) = (current, new, level, reencrypt)
                    Task {
                        if reset {
                            guard await model.resetPassword(new: n, level: l) else { return }
                        } else {
                            switch await model.changePassword(current: c, new: n, level: l, reencrypt: r) {
                            case .done(let words):
                                if let words { newRecoveryKey(words) }
                            case .wrongPassword:
                                wrong = true
                                return
                            case .failed:
                                return
                            }
                        }
                        Preferences.defaults.set(l.rawValue, forKey: Preferences.kdfLevelKey)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .onAppear { level = model.kdfParameters?.level ?? .standard }
    }
}

/// Deleting the vault, or uninstalling Hash Lock with or without it.
struct DeleteSheet: View {
    enum Mode: String, Identifiable {
        case deleteVault, uninstall
        var id: String { rawValue }
    }

    @Bindable var model: AppModel
    let actions: AppActions
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var withData = false
    @State private var password = ""
    @State private var forgot = false
    @State private var typed = ""
    @State private var wrong = false
    @State private var busy = false

    private static let phrase = "Delete Vault"
    private var deletesData: Bool { mode == .deleteVault || withData }
    private var hasVault: Bool { model.phase != .setup }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(mode == .deleteVault ? "Delete “\(model.current?.name ?? "Vault")”?" : "Uninstall Hash Lock?",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(deletesData ? .red : .primary)

            if mode == .uninstall {
                Picker("", selection: $withData) {
                    Text(model.vaults.count > 1 ? "Remove the app, keep the vaults" : "Remove the app, keep the vault").tag(false)
                    Text(model.vaults.count > 1 ? "Remove the app and all \(model.vaults.count) vaults" : "Remove the app and the vault").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!hasVault)
                Text(withData
                     ? "Hash Lock is moved to the Trash and every vault, with everything in it, is deleted for good."
                     : "Hash Lock is moved to the Trash. The vaults stay encrypted on this Mac; install Hash Lock again to open them with the same passwords.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Every note, password, wallet and file in this vault is deleted for good: the key that decrypts them is overwritten first. Backups made earlier (Time Machine, exported files) are not touched, and still open with their password. Other vaults are not touched either.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if deletesData && hasVault {
                if forgot {
                    Text("Type “\(Self.phrase)” to confirm:")
                    TextField(Self.phrase, text: $typed).textFieldStyle(.roundedBorder)
                } else {
                    SecureField(mode == .uninstall && model.vaults.count > 1 ? "Password of “\(model.current?.name ?? "")”" : "Vault password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: password) { wrong = false }
                    HStack {
                        if wrong { Text("Incorrect password").foregroundStyle(.red).font(.callout) }
                        Spacer()
                        Button("I forgot the password") { forgot = true }.buttonStyle(.link).font(.callout)
                    }
                }
            }

            HStack {
                if busy || model.working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .deleteVault ? "Delete Vault" : "Uninstall", role: .destructive, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || busy)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var ready: Bool {
        guard deletesData && hasVault else { return true }
        return forgot ? typed == Self.phrase : !password.isEmpty
    }

    private func run() {
        busy = true
        Task {
            defer { busy = false }
            if deletesData && hasVault && !forgot {
                guard await model.checkPassword(password) else {
                    if model.notice == nil { wrong = true }
                    return
                }
            }
            switch mode {
            case .deleteVault:
                if await model.destroyVault() { dismiss() }
            case .uninstall:
                dismiss()
                await actions.uninstall(deletesData && hasVault)
            }
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    AppIcon(size: 72)
                    Text("Hash Lock").font(.title2.weight(.semibold))
                    Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
                    Text("An encrypted vault for passwords, keys, wallets and files. Nothing leaves this Mac: Hash Lock has no network access at all.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            Section {
                LabeledContent("Encryption", value: "XChaCha20-Poly1305")
                LabeledContent("Password", value: "Argon2id, never stored")
                LabeledContent("Library", value: "libsodium \(AppInfo.sodiumVersion)")
            }
        }
        .formStyle(.grouped)
    }
}

public enum AppInfo {
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "HLVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public static var sodiumVersion: String { VaultCore.sodiumVersion }
}
