import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import VaultCore

/// The app's state: whether there is a vault, whether it is open, what it
/// lists, and the item being edited. All changes to the vault pass through
/// here, so that locking can save the open edit and then forget everything.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable {
        /// Reading the vault's header.
        case starting
        /// No vault yet: the setup screen.
        case setup
        case locked
        case unlocked
    }

    public struct Notice: Identifiable, Equatable {
        public let id = UUID()
        public var title: String
        public var message: String
    }

    public enum Filter: String, CaseIterable, Identifiable {
        case all, notes, files, wallets
        public var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All Items"
            case .notes: "Notes"
            case .files: "Files"
            case .wallets: "Wallets"
            }
        }
        func matches(_ item: Item) -> Bool {
            switch self {
            case .all: true
            case .notes: item.kind == .note
            case .files: item.kind == .file
            case .wallets: item.kind == .wallet
            }
        }
    }

    public private(set) var phase: Phase = .starting
    /// Unlocking, creating, saving a password: the lock screen shows a spinner.
    public private(set) var working = false
    public private(set) var items: [Item] = []
    public private(set) var hasRecoveryKey = false
    public private(set) var kdfParameters: KDFParameters?
    public var notice: Notice?
    /// Set once a vault is created: the window offers a recovery key.
    public var offerRecoveryKey = false

    /// Where the Add Files sheet puts what it is given.
    public enum AddTarget: Identifiable, Hashable {
        case newItems
        case attach(UUID)
        public var id: Self { self }
    }
    /// The Add Files sheet, while open.
    public var addFilesTarget: AddTarget?
    /// Asked from a menu command; the window confirms it.
    public var deleteRequest: Set<UUID>?
    /// Asked from the sidebar's Rename: the editor focuses the title.
    public var focusTitle = false

    public var search = ""
    public var filter: Filter = .all
    public var selection: UUID? {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }

    /// The open item's body, edited in place by the views and saved shortly
    /// after each change.
    public var draft: NoteBody? {
        didSet { if draft != oldValue, draftLoaded { scheduleSave() } }
    }
    private var draftItem: UUID?
    private var draftLoaded = false
    private var saveTask: Task<Void, Never>?
    private var pendingTitle: (UUID, String)?
    private var titleTask: Task<Void, Never>?
    private var saveChain: Task<Void, Never>?
    /// The selected item could not be decrypted.
    public private(set) var openFailed: UUID?
    /// Unlocked with the recovery key: the window asks for a new password.
    public var mustSetPassword = false
    /// Files being added: the sidebar shows progress.
    public private(set) var adding = 0

    public let library: VaultLibrary
    /// Every vault on this Mac, by name.
    public private(set) var vaults: [VaultEntry] = []
    /// The vault shown: unlocked, or the one the lock screen asks about.
    public private(set) var current: VaultEntry?
    /// The current vault itself; only one is ever unlocked.
    private(set) var vault: Vault?
    public let clipboard = Clipboard()
    /// The New Vault sheet, while open.
    public var showNewVault = false

    static let lastVaultKey = "lastVault"

    public init(library: VaultLibrary) {
        self.library = library
    }

    public static func standard() -> AppModel {
        AppModel(library: VaultLibrary(root: VaultLocation.library))
    }

    public func start() async {
        let lib = library
        await Task.detached { lib.removeLeftovers() }.value
        vaults = library.list()
        let last = Preferences.defaults.string(forKey: Self.lastVaultKey).flatMap(UUID.init)
        if let entry = vaults.first(where: { $0.id == last }) ?? vaults.first {
            await choose(entry)
        } else {
            phase = .setup
        }
    }

    // MARK: Choosing, creating, unlocking, locking

    /// Shows `entry` on the lock screen; the vault open until now is locked.
    /// Refused while a password is being checked: the answer belongs to the
    /// vault it was typed for.
    public func select(_ entry: VaultEntry) async {
        guard !working else { return }
        await choose(entry)
    }

    private func choose(_ entry: VaultEntry) async {
        if entry.id == current?.id, phase != .setup { return }
        await lockAndWait()
        current = entry
        vault = Vault(root: entry.directory)
        Preferences.defaults.set(entry.id.uuidString, forKey: Self.lastVaultKey)
        hasRecoveryKey = await vault?.headerHasRecoveryKey() ?? false
        kdfParameters = nil
        phase = .locked
    }

    /// Makes a new vault and opens it; the vault open until now is locked.
    public func createVault(name: String, password: String, level: KDFParameters.Level) async -> Bool {
        working = true
        defer { working = false }
        await lockAndWait()
        do {
            let (entry, newVault) = try await library.create(name: name, password: password, parameters: level.parameters)
            vaults = library.list()
            current = entry
            vault = newVault
            Preferences.defaults.set(entry.id.uuidString, forKey: Self.lastVaultKey)
            await opened(newVault, catalog: Catalog())
            return true
        } catch {
            show(error, title: "The vault could not be created")
            return false
        }
    }

    public func renameCurrent(to name: String) {
        guard let current else { return }
        do {
            let renamed = try library.rename(current, to: name)
            self.current = renamed
            vaults = library.list()
        } catch {
            show(error, title: "The vault could not be renamed")
        }
    }

    /// `false` for a wrong password (the lock screen shakes); other errors
    /// are shown as a notice.
    public func unlock(password: String) async -> Bool {
        guard let v = vault, !working else { return false }
        working = true
        defer { working = false }
        do {
            return await opened(v, catalog: try await v.unlock(password: password))
        } catch VaultError.wrongPassword {
            return false
        } catch {
            show(error, title: "Hash Lock could not be unlocked")
            return false
        }
    }

    public func unlock(recoveryPhrase words: [String]) async -> Bool {
        guard let v = vault, !working else { return false }
        working = true
        defer { working = false }
        do {
            guard await opened(v, catalog: try await v.unlock(recoveryPhrase: words)) else { return false }
            mustSetPassword = true
            return true
        } catch VaultError.wrongPassword {
            return false
        } catch {
            show(error, title: "Hash Lock could not be unlocked")
            return false
        }
    }

    /// Shows `v`, just unlocked. Should another vault have been chosen
    /// meanwhile, `v` is locked again instead.
    @discardableResult
    private func opened(_ v: Vault, catalog: Catalog) async -> Bool {
        guard v === vault else {
            await v.lock()
            return false
        }
        items = catalog.items
        hasRecoveryKey = await v.hasRecoveryKey
        kdfParameters = await v.kdfParameters
        phase = .unlocked
        return true
    }

    /// What is left to do once the window shows the lock screen.
    private struct Closing {
        let vault: Vault
        let saves: Task<Void, Never>?
    }

    /// Locks at once: the window shows the lock screen immediately, the open
    /// edit is saved, then the keys are wiped and every decrypted thing is
    /// let go.
    public func lock() {
        guard let c = beginLock() else { return }
        closing = Task { await finish(c) }
    }

    /// Locks and returns once the keys are gone and the last edit is saved:
    /// before quitting, switching vaults, importing or deleting one. Waits
    /// as well for a lock already under way.
    public func lockAndWait() async {
        if let c = beginLock() { closing = Task { await finish(c) } }
        await closing?.value
    }

    /// The end of the last lock: saving, then wiping the keys.
    private var closing: Task<Void, Never>?

    /// Saves the open edit and locks, for quitting.
    public func lockForQuit() async {
        clipboard.clearIfOurs()
        await lockAndWait()
    }

    private func beginLock() -> Closing? {
        guard phase == .unlocked, let vault else { return nil }
        flushEdits()
        let closing = Closing(vault: vault, saves: saveChain)
        phase = .locked
        titleTask?.cancel()
        pendingTitle = nil
        openFailed = nil
        mustSetPassword = false
        // Every sheet that shows or changes the vault closes with it.
        offerRecoveryKey = false
        addFilesTarget = nil
        deleteRequest = nil
        saveTask?.cancel()
        saveTask = nil
        draftLoaded = false
        draft = nil
        draftItem = nil
        selection = nil
        items = []
        search = ""
        kdfParameters = nil
        if Preferences.defaults.bool(forKey: Preferences.clearClipboardOnLockKey) { clipboard.clearIfOurs() }
        return closing
    }

    private func finish(_ c: Closing) async {
        await c.saves?.value
        await c.vault.lock()
        if c.vault === vault { hasRecoveryKey = await c.vault.headerHasRecoveryKey() }
    }

    // MARK: The list

    public var visibleItems: [Item] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let order = Preferences.SortOrder(rawValue: Preferences.defaults.string(forKey: Preferences.sortOrderKey) ?? "")
            ?? Preferences.sortOrderDefault
        return items
            .filter { filter.matches($0) && (q.isEmpty || $0.title.localizedStandardContains(q)) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                switch order {
                case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
                case .modified: return a.modified > b.modified
                case .created: return a.created > b.created
                }
            }
    }

    public var selectedItem: Item? {
        selection.flatMap { id in items.first { $0.id == id } }
    }

    /// Re-sorts after the sort setting changes.
    public func sortChanged() { items = items }

    // MARK: Changing items

    @discardableResult
    public func newNote() async -> Item? {
        await perform("The note could not be created") {
            try await self.active().addItem(kind: .note, title: self.uniqueTitle("New Note"))
        }.map { item in
            insert(item)
            return item
        }
    }

    @discardableResult
    public func newWallet() async -> Item? {
        let body = NoteBody(wallet: WalletBackup())
        return await perform("The wallet could not be created") {
            try await self.active().addItem(kind: .wallet, title: self.uniqueTitle("Crypto Wallet"), body: body)
        }.map { item in
            insert(item)
            return item
        }
    }

    /// Adds each file as an item of its own.
    public func addFiles(_ files: [FileImport]) async {
        guard !files.isEmpty else { return }
        adding += files.count
        defer { adding -= files.count }
        var last: Item?
        for f in files {
            let item = await perform("“\(f.name)” could not be added") {
                try await self.active().addItem(kind: .file, title: f.name, files: [f])
            }
            if let item {
                items.append(item)
                last = item
            }
        }
        if let last { selection = last.id }
    }

    /// Adds files to the open item.
    public func attach(_ files: [FileImport], to id: UUID) async {
        guard !files.isEmpty else { return }
        adding += files.count
        defer { adding -= files.count }
        if let item = await perform("The files could not be added", { try await self.active().addAttachments(files, to: id) }) {
            replace(item)
        }
    }

    public func rename(_ id: UUID, to title: String) async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, items.first(where: { $0.id == id })?.title != t else { return }
        if let item = await perform("The item could not be renamed", { try await self.active().updateItem(id, title: t) }) {
            replace(item)
        }
    }

    public func togglePin(_ id: UUID) async {
        guard let pinned = items.first(where: { $0.id == id })?.pinned else { return }
        if let item = await perform("The item could not be changed", { try await self.active().updateItem(id, pinned: !pinned) }) {
            replace(item)
        }
    }

    public func delete(_ ids: Set<UUID>) async {
        if let s = selection, ids.contains(s) {
            // Nothing to save for an item about to go.
            saveTask?.cancel()
            saveTask = nil
            if let p = pendingTitle, ids.contains(p.0) { pendingTitle = nil }
            draftLoaded = false
            draft = nil
            draftItem = nil
            selection = nil
        }
        // Saves already queued finish first, so none lands on a deleted item.
        await saveChain?.value
        if await perform("The items could not be deleted", { try await self.active().deleteItems(ids) }) != nil {
            items.removeAll { ids.contains($0.id) }
        }
    }

    public func renameAttachment(_ a: Attachment, of id: UUID, to name: String) async {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let item = await perform("The file could not be renamed", { try await self.active().renameAttachment(a.id, of: id, to: n) }) {
            replace(item)
        }
    }

    public func removeAttachment(_ a: Attachment, of id: UUID) async {
        if let item = await perform("The file could not be removed", { try await self.active().removeAttachment(a.id, of: id) }) {
            replace(item)
        }
    }

    /// The decrypted content of an attachment, for the viewer.
    public func content(of a: Attachment, limit: UInt64) async throws -> Data {
        try await active().data(of: a, limit: limit)
    }

    /// Writes an attachment to `url`, throwing (for a drag's file promise).
    public func write(_ a: Attachment, to url: URL) async throws {
        try await active().export(a, to: url)
    }

    /// The unlocked vault, or `.locked`.
    func active() throws -> Vault {
        guard phase == .unlocked, let vault else { throw VaultError.locked }
        return vault
    }

    public func export(_ a: Attachment, to url: URL) async {
        _ = await perform("“\(a.name)” could not be exported") { try await self.active().export(a, to: url) }
    }

    // MARK: The open item

    private func selectionChanged(from old: UUID?) {
        flushEdits()
        draftLoaded = false
        draft = nil
        draftItem = nil
        openFailed = nil
        guard let new = selection, phase == .unlocked, let v = vault else { return }
        Task {
            do {
                let body = try await v.body(of: new)
                guard selection == new, v === vault else { return }
                draftItem = new
                draft = body
                draftLoaded = true
            } catch VaultError.locked {
                // Locked meanwhile.
            } catch {
                guard selection == new else { return }
                openFailed = new
                show(error, title: "The item could not be opened")
            }
        }
    }

    /// The open item's unsaved edit, if any.
    private func pendingDraft() -> (UUID, NoteBody)? {
        guard draftLoaded, saveTask != nil, let id = draftItem, let body = draft else { return nil }
        return (id, body)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard draftItem != nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            flushEdits()
        }
    }

    /// A title typed in the editor; saved shortly after, or when the item
    /// is left or the vault locked, whichever comes first.
    public func titleEdited(_ id: UUID, _ title: String) {
        pendingTitle = (id, title)
        titleTask?.cancel()
        titleTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            flushEdits()
        }
    }

    /// Queues every unsaved edit (body and title) for the current vault.
    private func flushEdits() {
        guard let v = vault, phase == .unlocked else { return }
        if let (id, body) = pendingDraft() {
            saveTask?.cancel()
            saveTask = nil
            enqueue(on: v, failure: "The changes could not be saved") { try await v.setBody(body, of: id) }
        }
        if let (id, title) = pendingTitle {
            pendingTitle = nil
            titleTask?.cancel()
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, items.first(where: { $0.id == id })?.title != t {
                enqueue(on: v, failure: "The item could not be renamed") { try await v.updateItem(id, title: t) }
            }
        }
    }

    /// Runs saves one after another on the vault they were made for, so that
    /// locking (or switching vaults) can wait for every one of them.
    private func enqueue(on v: Vault, failure: String, _ save: @escaping @Sendable () async throws -> Item) {
        let previous = saveChain
        saveChain = Task {
            await previous?.value
            do {
                let item = try await save()
                if v === vault { replace(item) }
            } catch {
                show(error, title: failure)
            }
        }
    }

    /// Saves the open edit now (before an export, a check, quitting).
    public func saveNow() async {
        flushEdits()
        await saveChain?.value
    }

    // MARK: Password and recovery

    /// The new recovery phrase, when re-encrypting replaced it.
    public enum PasswordChange: Equatable {
        case done(recovery: [String]?)
        case wrongPassword
        case failed
    }

    public func changePassword(current: String, new: String, level: KDFParameters.Level,
                               reencrypt: Bool) async -> PasswordChange {
        working = true
        defer { working = false }
        await saveNow()
        do {
            let words = try await active().changePassword(current: current, new: new, parameters: level.parameters,
                                                          reencrypt: reencrypt)
            kdfParameters = level.parameters
            return .done(recovery: words)
        } catch VaultError.wrongPassword {
            return .wrongPassword
        } catch {
            show(error, title: reencrypt ? "The vault could not be re-encrypted" : "The password could not be changed")
            return .failed
        }
    }

    /// A new password after unlocking with the recovery key.
    public func resetPassword(new: String, level: KDFParameters.Level) async -> Bool {
        working = true
        defer { working = false }
        do {
            try await active().resetPassword(new: new, parameters: level.parameters)
            kdfParameters = level.parameters
            mustSetPassword = false
            return true
        } catch {
            show(error, title: "The password could not be set")
            return false
        }
    }

    /// A password check outside the lock screen (deleting, uninstalling).
    /// `false` for a wrong password; any other error is shown, and is no
    /// answer either way.
    public func checkPassword(_ password: String) async -> Bool {
        guard let v = vault, !working else { return false }
        working = true
        defer { working = false }
        do {
            try await v.checkPassword(password)
            return true
        } catch VaultError.wrongPassword {
            return false
        } catch {
            show(error, title: "The password could not be checked")
            return false
        }
    }

    public func createRecoveryKey() async -> [String]? {
        let words = await perform("The recovery key could not be created") { try await self.active().createRecoveryKey() }
        hasRecoveryKey = await vault?.hasRecoveryKey ?? false
        return words
    }

    public func removeRecoveryKey() async {
        _ = await perform("The recovery key could not be removed") { try await self.active().removeRecoveryKey() }
        hasRecoveryKey = await vault?.hasRecoveryKey ?? false
    }

    public func verify() async -> Vault.IntegrityReport? {
        await saveNow()
        return await perform("The vault could not be checked") { try await self.active().verify() }
    }

    /// Lists the parts Verify found unreferenced as items of their own.
    public func recoverUnreferenced() async -> Int {
        let added = await perform("The parts could not be recovered") { try await self.active().recoverUnreferenced() } ?? []
        items += added
        return added.count
    }

    public func removeUnreferenced() async {
        _ = await perform("The parts could not be removed") { try await self.active().removeUnreferenced() }
    }

    /// Deletes the current vault and everything in it. The lock screen then
    /// shows another vault, or the setup screen if none is left.
    public func destroyVault() async -> Bool {
        guard let vault else { return false }
        await lockAndWait()
        clipboard.clearIfOurs()
        do {
            try await vault.destroy()
        } catch {
            show(error, title: "The vault could not be deleted")
            return false
        }
        self.vault = nil
        current = nil
        vaults = library.list()
        if let next = vaults.first {
            await choose(next)
        } else {
            hasRecoveryKey = false
            phase = .setup
        }
        return true
    }

    /// Deletes every vault, for uninstalling.
    public func destroyAllVaults() async {
        await lockAndWait()
        clipboard.clearIfOurs()
        for entry in library.list() {
            try? await Vault(root: entry.directory).destroy()
        }
        vault = nil
        current = nil
        vaults = []
        phase = .setup
    }

    // MARK: Vault files (.hashlock)

    /// A vault file whose vault is already here: replace it, or keep both?
    public struct ImportConflict: Identifiable {
        public let id = UUID()
        public let url: URL
        public let name: String
        public let existing: VaultEntry
    }
    public var importConflict: ImportConflict?

    /// Writes the open vault, encrypted as it is, to one file.
    public func exportVault(to url: URL) async {
        await saveNow()
        working = true
        defer { working = false }
        _ = await perform("The vault could not be exported") { try await self.active().exportArchive(to: url) }
    }

    /// Adds the vault in a .hashlock file; asks first if it is already here.
    public func importVault(from url: URL) async {
        working = true
        defer { working = false }
        let lib = library
        let result = await Task.detached { () -> Result<(VaultArchive.Info, VaultEntry?), Error> in
            Result { let info = try VaultArchive.inspect(url); return (info, lib.existing(info)) }
        }.value
        switch result {
        case .failure(let error):
            show(error, title: "The vault could not be imported")
        case .success(let (info, existing)):
            if let existing {
                importConflict = ImportConflict(url: url, name: info.name, existing: existing)
            } else {
                await finishImport(url, replacing: nil)
            }
        }
    }

    /// Imports, as a new vault or in place of the one already here.
    public func finishImport(_ url: URL, replacing: VaultEntry?) async {
        working = true
        defer { working = false }
        if let replacing, replacing.id == current?.id { await lockAndWait() }
        let lib = library
        let result = await Task.detached { Result { try lib.importArchive(url, replacing: replacing) } }.value
        switch result {
        case .failure(let error):
            show(error, title: "The vault could not be imported")
        case .success(let entry):
            vaults = library.list()
            if replacing?.id == current?.id { current = nil }
            await choose(entry)
        }
    }

    // MARK: Helpers

    /// A new note or wallet: listed, opened, and its title ready to type.
    /// A filter or search that would hide it is cleared first.
    private func insert(_ item: Item) {
        items.append(item)
        if !filter.matches(item) { filter = .all }
        if !search.isEmpty, !item.title.localizedStandardContains(search.trimmingCharacters(in: .whitespaces)) { search = "" }
        selection = item.id
        focusTitle = true
    }

    private func replace(_ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item }
    }

    private func uniqueTitle(_ base: String) -> String {
        let taken = Set(items.map(\.title))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Runs a vault call; on failure shows `title` with the reason.
    private func perform<T: Sendable>(_ title: String, _ body: @Sendable () async throws -> T) async -> T? {
        do {
            return try await body()
        } catch VaultError.locked {
            return nil  // locked meanwhile: nothing to report
        } catch {
            show(error, title: title)
            return nil
        }
    }

    func show(_ error: Error, title: String) {
        notice = Notice(title: title, message: Self.describe(error))
    }

    static func describe(_ error: Error) -> String {
        switch error as? VaultError {
        case .wrongPassword: "The password is incorrect."
        case .locked: "Hash Lock is locked."
        case .notFound: "There is no vault."
        case .alreadyExists: "A vault already exists."
        case .newerFormat: "The vault was made by a newer version of Hash Lock. Install the latest version to open it."
        case .unsupportedParameters: "The vault’s header asks for settings Hash Lock does not accept. It may have been tampered with."
        case .damaged(let what): "Part of the vault is damaged or was changed outside Hash Lock (\(what))."
        case .notEnoughMemory: "There is not enough free memory to derive the key. Quit other apps and try again."
        case .sourceChanged: "The file changed while it was being added. Try again once it is finished."
        case .tooLarge: "The file is too large to open here. Export it instead."
        case .inUse: "The vault is open in another copy of Hash Lock. Lock it or quit that copy first."
        case .tooManyFiles(let n): "The folder holds more than \(n.formatted()) files and folders. Add its parts separately."
        case .io(let text): text
        case nil: error.localizedDescription
        }
    }
}

/// Where the vaults live: inside the app's sandbox container, so no other
/// app can reach them without the user's say.
public enum VaultLocation {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hash Lock", isDirectory: true)
    }

    public static var library: URL {
        support.appendingPathComponent("Vaults", isDirectory: true)
    }
}
