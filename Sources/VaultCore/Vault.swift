import Clibsodium
import Foundation
import UniformTypeIdentifiers

/// A file or folder to add to the vault.
public struct FileImport: Sendable {
    public enum Source: Sendable {
        case data(Data)
        case file(URL)
        /// A folder and everything in it.
        case folder(URL)
    }

    public var name: String
    public var typeIdentifier: String?
    public var source: Source

    public init(name: String, typeIdentifier: String?, source: Source) {
        self.name = name
        self.typeIdentifier = typeIdentifier
        self.source = source
    }
}

/// An encrypted vault in a directory:
///
///     header.json          key slots (the only unencrypted file)
///     catalog              the encrypted item list
///     blobs/xx/<id>        one encrypted blob per note body or file
///
/// The actor owns the keys and the decrypted catalog while unlocked; `lock()`
/// wipes the keys. It runs on its own serial queue, because key derivation
/// and encrypting large files block for a while, which must happen neither on
/// the main thread nor on Swift's shared thread pool.
public actor Vault {
    public nonisolated let root: URL
    private let queue = DispatchSerialQueue(label: "Hash Lock vault")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private struct Keys {
        let master: SecureBytes
        let catalog: SecureBytes
        let blobs: SecureBytes

        init(master: SecureBytes) {
            self.master = master
            catalog = Subkey.catalog.derive(from: master)
            blobs = Subkey.blobs.derive(from: master)
        }
    }

    private var keys: Keys?
    private var header: VaultHeader?
    /// An exclusive lock on the vault's folder while it is unlocked, so a
    /// second copy of the app cannot open it at the same time (it would
    /// take the other's new files for leftovers).
    private var lockFD: Int32 = -1
    /// Opened with the recovery phrase in this session: the password may be
    /// replaced without giving the old one (which is what was forgotten).
    public private(set) var openedWithRecovery = false
    public private(set) var catalog = Catalog()

    public init(root: URL) {
        self.root = root
    }

    var headerURL: URL { root.appendingPathComponent("header.json") }
    var catalogURL: URL { root.appendingPathComponent("catalog") }
    var blobsURL: URL { root.appendingPathComponent("blobs") }

    func blobURL(_ id: BlobID) -> URL { Self.blobURL(id, in: root) }

    static func blobURL(_ id: BlobID, in root: URL) -> URL {
        root.appendingPathComponent("blobs").appendingPathComponent(String(id.hex.prefix(2))).appendingPathComponent(id.hex)
    }

    public nonisolated static func exists(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("header.json").path)
    }

    public var isUnlocked: Bool { keys != nil }

    /// Whether the vault has a recovery phrase, read from the header without
    /// unlocking (the lock screen offers it only then).
    public func headerHasRecoveryKey() -> Bool {
        (try? readHeader())?.recoverySlot != nil
    }
    public var hasRecoveryKey: Bool { header?.recoverySlot != nil }
    public var kdfParameters: KDFParameters? { header?.passwordSlot?.kdf }

    // MARK: Creating, unlocking, locking

    /// Makes a new, empty vault and leaves it unlocked.
    public func create(password: String, parameters: KDFParameters) throws {
        guard !Self.exists(at: root) else { throw VaultError.alreadyExists }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: blobsURL, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch {
            throw VaultError.io(error.localizedDescription)
        }
        let vaultID = UUID()
        let master = SecureBytes.random(count: 32)
        let slot = try passwordSlot(master: master, password: SecureBytes(password: password),
                                    parameters: parameters, vaultID: vaultID)
        let newHeader = VaultHeader(vaultID: vaultID, slots: [slot])
        let newKeys = Keys(master: master)
        // The catalog first: a header without one would be a vault that
        // cannot be opened.
        try write(catalog: Catalog(), keys: newKeys)
        try AtomicWriter.write(newHeader.encoded(), to: headerURL)
        try takeFolderLock()
        header = newHeader
        keys = newKeys
        catalog = Catalog()
    }

    /// Opens the vault with its password. A wrong one throws `.wrongPassword`.
    public func unlock(password: String) throws -> Catalog {
        let h = try readHeader()
        guard let slot = h.passwordSlot, let kdf = slot.kdf else { throw VaultError.damaged("header") }
        let kek = try KeyDerivation.derive(password: SecureBytes(password: password),
                                           salt: Array(slot.salt), parameters: kdf)
        guard let master = slot.open(with: kek, vaultID: h.vaultID) else { throw VaultError.wrongPassword }
        let catalog = try finishUnlock(header: h, master: master)
        openedWithRecovery = false
        return catalog
    }

    /// Opens the vault with its recovery phrase.
    public func unlock(recoveryPhrase words: [String]) throws -> Catalog {
        let h = try readHeader()
        guard let slot = h.recoverySlot else { throw VaultError.wrongPassword }
        guard case .success(var entropy) = BIP39.entropy(of: words), entropy.count == 32 else {
            throw VaultError.wrongPassword
        }
        defer { wipe(&entropy) }
        let kek = Self.recoveryWrappingKey(entropy: entropy, vaultID: h.vaultID)
        guard let master = slot.open(with: kek, vaultID: h.vaultID) else { throw VaultError.wrongPassword }
        let catalog = try finishUnlock(header: h, master: master)
        openedWithRecovery = true
        return catalog
    }

    private func takeFolderLock() throws {
        guard lockFD < 0 else { return }
        let fd = open(root.appendingPathComponent(".lock").path, O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError.io(AtomicWriter.errnoText("open the vault")) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw VaultError.inUse
        }
        lockFD = fd
    }

    private func releaseFolderLock() {
        guard lockFD >= 0 else { return }
        flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }

    private func finishUnlock(header h: VaultHeader, master: SecureBytes) throws -> Catalog {
        try takeFolderLock()
        let k = Keys(master: master)
        var data: Data
        do {
            data = try BlobCipher.decryptData(from: catalogURL, key: k.catalog)
        } catch {
            releaseFolderLock()
            throw error
        }
        defer { wipe(&data) }
        guard let c = try? JSONDecoder().decode(Catalog.self, from: data) else {
            releaseFolderLock()
            throw VaultError.damaged("catalog")
        }
        header = h
        keys = k
        catalog = c
        finishRemovals()
        return c
    }

    /// Wipes the keys and forgets the catalog.
    public func lock() {
        keys = nil
        header = nil
        catalog = Catalog()
        openedWithRecovery = false
        releaseFolderLock()
    }

    /// Checks `password` without changing the vault's state; asked before
    /// deleting it. A wrong one throws `.wrongPassword`, and only that error
    /// means the password is wrong: anything else (memory, a damaged
    /// header) is no answer either way. While unlocked, the header in
    /// memory is the one checked.
    public func checkPassword(_ password: String) throws {
        let h = try header ?? readHeader()
        guard let slot = h.passwordSlot, let kdf = slot.kdf else { throw VaultError.damaged("header") }
        let kek = try KeyDerivation.derive(password: SecureBytes(password: password),
                                           salt: Array(slot.salt), parameters: kdf)
        guard slot.open(with: kek, vaultID: h.vaultID) != nil else { throw VaultError.wrongPassword }
    }

    // MARK: Password and recovery key

    /// Replaces the password (and the derivation settings).
    ///
    /// Without `reencrypt` only the master key is re-wrapped, which takes as
    /// long as one unlock; but the master key stays the same, so an older
    /// copy of `header.json` (a backup, a snapshot) still opens today's
    /// vault with the old password. With `reencrypt` the whole vault is
    /// encrypted again under a new master key, which no older header holds.
    /// A recovery key is then replaced too (the old phrase wraps the old
    /// key), and the new phrase is returned.
    @discardableResult
    public func changePassword(current: String, new: String, parameters: KDFParameters,
                               reencrypt: Bool = false) throws -> [String]? {
        let k = try unlockedKeys()
        guard var h = header else { throw VaultError.locked }
        // Checked against the header and master key in memory, not the file
        // on disk: a header swapped in from another vault (whose password
        // someone knows) must not pass for this vault's password.
        guard let currentSlot = h.passwordSlot, let kdf = currentSlot.kdf,
              let opened = currentSlot.open(with: try KeyDerivation.derive(password: SecureBytes(password: current),
                                                                            salt: Array(currentSlot.salt), parameters: kdf),
                                            vaultID: h.vaultID),
              opened.isEqual(to: k.master) else {
            throw VaultError.wrongPassword
        }
        if reencrypt {
            return try reencryptAll(password: SecureBytes(password: new), parameters: parameters)
        }
        let slot = try passwordSlot(master: k.master, password: SecureBytes(password: new),
                                    parameters: parameters, vaultID: h.vaultID)
        h.slots = h.slots.filter { $0.kind != .password } + [slot]
        try AtomicWriter.write(h.encoded(), to: headerURL)
        header = h
        return nil
    }

    /// Sets a new password without the old one, only in a session opened
    /// with the recovery phrase. Otherwise the current password is asked
    /// (`changePassword`), so that someone at an unlocked Mac cannot lock
    /// its owner out.
    public func resetPassword(new: String, parameters: KDFParameters) throws {
        let k = try unlockedKeys()
        guard openedWithRecovery, var h = header else { throw VaultError.wrongPassword }
        let slot = try passwordSlot(master: k.master, password: SecureBytes(password: new),
                                    parameters: parameters, vaultID: h.vaultID)
        h.slots = h.slots.filter { $0.kind != .password } + [slot]
        try AtomicWriter.write(h.encoded(), to: headerURL)
        header = h
        openedWithRecovery = false
    }

    /// Makes a new recovery phrase (24 words, 256 bits), replacing any
    /// earlier one, which stops opening this header. Like a password
    /// change, it does not reach older copies of the header: the old phrase
    /// opens those until the vault is re-encrypted.
    public func createRecoveryKey() throws -> [String] {
        let k = try unlockedKeys()
        guard var h = header else { throw VaultError.locked }
        var entropy = randomBytes(32)
        defer { wipe(&entropy) }
        let kek = Self.recoveryWrappingKey(entropy: entropy, vaultID: h.vaultID)
        let slot = KeySlot.seal(master: k.master, wrappingKey: kek, vaultID: h.vaultID,
                                kind: .recovery, kdf: nil, salt: Data())
        h.slots = h.slots.filter { $0.kind != .recovery } + [slot]
        try AtomicWriter.write(h.encoded(), to: headerURL)
        header = h
        return BIP39.mnemonic(entropy: entropy)
    }

    public func removeRecoveryKey() throws {
        _ = try unlockedKeys()
        guard var h = header else { throw VaultError.locked }
        h.slots.removeAll { $0.kind == .recovery }
        try AtomicWriter.write(h.encoded(), to: headerURL)
        header = h
    }

    private func passwordSlot(master: SecureBytes, password: SecureBytes, parameters: KDFParameters,
                              vaultID: UUID) throws -> KeySlot {
        let salt = randomBytes(KeyDerivation.saltBytes)
        let kek = try KeyDerivation.derive(password: password, salt: salt, parameters: parameters)
        return KeySlot.seal(master: master, wrappingKey: kek, vaultID: vaultID, kind: .password,
                            kdf: parameters, salt: Data(salt))
    }

    /// The recovery phrase carries 256 random bits, so a keyed hash is enough
    /// to turn it into a key; there is nothing for a slow derivation to
    /// protect.
    static func recoveryWrappingKey(entropy: [UInt8], vaultID: UUID) -> SecureBytes {
        var message = Array("HashLock/recovery/v1".utf8)
        withUnsafeBytes(of: vaultID.uuid) { message.append(contentsOf: $0) }
        let key = SecureBytes(count: 32)
        key.withMutableBytes { out in
            _ = crypto_generichash(out, 32, message, UInt64(message.count), entropy, entropy.count)
        }
        return key
    }

    // MARK: Items

    /// Adds an item with its body and files. Returns it as saved.
    public func addItem(kind: Item.Kind, title: String, body: NoteBody = NoteBody(),
                        files: [FileImport] = []) throws -> Item {
        let k = try unlockedKeys()
        var item = Item(kind: kind, title: title)
        var written: [BlobID] = []
        do {
            if !body.isEmpty {
                let id = try writeBody(body, keys: k)
                written.append(id)
                item.body = id
            }
            for f in files {
                let a = try writeAttachment(f, keys: k, written: &written)
                item.attachments.append(a)
            }
            var c = catalog
            c.items.append(item)
            try commit(c, keys: k)
        } catch {
            removeBlobs(written)
            throw error
        }
        return item
    }

    /// Changes an item's title or pin.
    public func updateItem(_ id: UUID, title: String? = nil, pinned: Bool? = nil) throws -> Item {
        let k = try unlockedKeys()
        var c = catalog
        guard let i = c.items.firstIndex(where: { $0.id == id }) else { throw VaultError.damaged("no such item") }
        if let title { c.items[i].title = title; c.items[i].modified = Date() }
        if let pinned { c.items[i].pinned = pinned }
        try commit(c, keys: k)
        return c.items[i]
    }

    /// The item's text, fields and wallet; empty if it has none.
    public func body(of id: UUID) throws -> NoteBody {
        let k = try unlockedKeys()
        guard let item = catalog.items.first(where: { $0.id == id }) else { throw VaultError.damaged("no such item") }
        guard let blob = item.body else { return NoteBody() }
        var data = try BlobCipher.decryptData(from: blobURL(blob), key: blobKey(blob, keys: k))
        defer { wipe(&data) }
        guard let body = try? JSONDecoder().decode(NoteBody.self, from: data) else { throw VaultError.damaged("note") }
        return body
    }

    /// Saves the item's body: a new blob, then the catalog, then the old blob
    /// is removed — a crash at any point leaves one complete version.
    public func setBody(_ body: NoteBody, of id: UUID) throws -> Item {
        let k = try unlockedKeys()
        var c = catalog
        guard let i = c.items.firstIndex(where: { $0.id == id }) else { throw VaultError.damaged("no such item") }
        let old = c.items[i].body
        let new = body.isEmpty ? nil : try writeBody(body, keys: k)
        c.items[i].body = new
        c.items[i].modified = Date()
        do {
            try commit(c, keys: k, retiring: old.map { [$0] } ?? [])
        } catch {
            if let new { removeBlobs([new]) }
            throw error
        }
        if let old { removeBlobs([old]) }
        return c.items[i]
    }

    public func addAttachments(_ files: [FileImport], to id: UUID) throws -> Item {
        let k = try unlockedKeys()
        var c = catalog
        guard let i = c.items.firstIndex(where: { $0.id == id }) else { throw VaultError.damaged("no such item") }
        var written: [BlobID] = []
        do {
            for f in files {
                let a = try writeAttachment(f, keys: k, written: &written)
                c.items[i].attachments.append(a)
            }
            c.items[i].modified = Date()
            try commit(c, keys: k)
        } catch {
            removeBlobs(written)
            throw error
        }
        return c.items[i]
    }

    public func renameAttachment(_ attachment: UUID, of id: UUID, to name: String) throws -> Item {
        let k = try unlockedKeys()
        var c = catalog
        guard let i = c.items.firstIndex(where: { $0.id == id }),
              let j = c.items[i].attachments.firstIndex(where: { $0.id == attachment }) else {
            throw VaultError.damaged("no such attachment")
        }
        c.items[i].attachments[j].name = name
        c.items[i].modified = Date()
        try commit(c, keys: k)
        return c.items[i]
    }

    public func removeAttachment(_ attachment: UUID, of id: UUID) throws -> Item {
        let k = try unlockedKeys()
        var c = catalog
        guard let i = c.items.firstIndex(where: { $0.id == id }),
              let j = c.items[i].attachments.firstIndex(where: { $0.id == attachment }) else {
            throw VaultError.damaged("no such attachment")
        }
        let removed = c.items[i].attachments.remove(at: j)
        c.items[i].modified = Date()
        try commit(c, keys: k, retiring: removed.blobs)
        removeBlobs(removed.blobs)
        return c.items[i]
    }

    public func deleteItems(_ ids: Set<UUID>) throws {
        let k = try unlockedKeys()
        var c = catalog
        let removed = c.items.filter { ids.contains($0.id) }
            .flatMap { item in (item.body.map { [$0] } ?? []) + item.attachments.flatMap(\.blobs) }
        c.items.removeAll { ids.contains($0.id) }
        try commit(c, keys: k, retiring: removed)
        removeBlobs(removed)
    }

    /// A file's content in memory, for the viewer. Larger than `limit`
    /// throws `.tooLarge`.
    public func data(of attachment: Attachment, limit: UInt64) throws -> Data {
        let k = try unlockedKeys()
        guard let blob = attachment.blob else { throw VaultError.tooLarge }
        return try BlobCipher.decryptData(from: blobURL(blob), key: blobKey(blob, keys: k), limit: limit)
    }

    /// Writes an attachment, decrypted, where the user chose: a file, or a
    /// folder with everything in it (and the files' modification dates).
    /// What is written is owner-only; on any error it is removed rather than
    /// left half-written.
    public func export(_ attachment: Attachment, to url: URL) throws {
        let k = try unlockedKeys()
        if let target = attachment.linkTarget {
            try makeLink(target, at: url)
        } else if let contents = attachment.folder {
            // Only a folder made here is removed on failure: one the user
            // chose to export into is left as it was found.
            let created = try makeDirectory(url)
            do {
                var links: [(URL, String)] = []
                for entry in contents { try export(entry, into: url, keys: k, links: &links) }
                // Links last, as tar does: none exists while files are
                // written, so no write can be sent through one.
                for (at, target) in links { try makeLink(target, at: at) }
            } catch {
                if created { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        } else if let blob = attachment.blob {
            try exportFile(blob, to: url, keys: k)
        }
    }

    private func export(_ entry: FolderEntry, into dir: URL, keys k: Keys, links: inout [(URL, String)]) throws {
        let url = dir.appendingPathComponent(Self.safeName(entry.name), isDirectory: entry.isFolder)
        if let target = entry.linkTarget {
            links.append((url, target))
            return
        }
        if let children = entry.children {
            _ = try makeDirectory(url)
            for child in children { try export(child, into: url, keys: k, links: &links) }
        } else if let blob = entry.blob {
            try exportFile(blob, to: url, keys: k)
        }
        if let date = entry.modified {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    /// A new folder, or one already there that is a real folder (never a
    /// link to somewhere else). Returns whether it was made here.
    @discardableResult
    private func makeDirectory(_ url: URL) throws -> Bool {
        if mkdir(url.path, 0o700) == 0 { return true }
        guard errno == EEXIST else { throw VaultError.io(AtomicWriter.errnoText("create \(url.lastPathComponent)")) }
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw VaultError.io("Could not create \(url.lastPathComponent): something that is not a folder is in its place.")
        }
        return false
    }

    private func makeLink(_ target: String, at url: URL) throws {
        guard symlink(target, url.path) == 0 else {
            throw VaultError.io(AtomicWriter.errnoText("create the link \(url.lastPathComponent)"))
        }
    }

    /// A name read from the catalog, made safe to use as one path component.
    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: ":").replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "Untitled" : cleaned
    }

    private func exportFile(_ blob: BlobID, to url: URL, keys k: Keys) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError.io(AtomicWriter.errnoText("create \(url.lastPathComponent)")) }
        do {
            try BlobCipher.decrypt(from: blobURL(blob), key: blobKey(blob, keys: k)) { piece in
                var off = 0
                while off < piece.count {
                    let n = Darwin.write(fd, piece.baseAddress! + off, piece.count - off)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw VaultError.io(AtomicWriter.errnoText("write \(url.lastPathComponent)"))
                    }
                    off += n
                }
            }
            close(fd)
        } catch {
            close(fd)
            unlink(url.path)
            throw error
        }
    }

    // MARK: Maintenance

    public struct IntegrityReport: Sendable, Equatable {
        public var checked = 0
        /// Items with a part that failed to decrypt.
        public var damaged: [UUID] = []
        /// Blobs in the folder that no item refers to: left by a crash
        /// while something was being saved, or there because an older
        /// catalog was put back. They are kept until the user decides.
        public var unreferenced = 0
    }

    /// Decrypts every blob (and discards the result) to find damage.
    public func verify() throws -> IntegrityReport {
        let k = try unlockedKeys()
        var report = IntegrityReport()
        for item in catalog.items {
            let blobs = (item.body.map { [$0] } ?? []) + item.attachments.flatMap(\.blobs)
            for b in blobs {
                report.checked += 1
                do {
                    try BlobCipher.decrypt(from: blobURL(b), key: blobKey(b, keys: k)) { _ in }
                } catch {
                    if !report.damaged.contains(item.id) { report.damaged.append(item.id) }
                }
            }
        }
        report.unreferenced = unreferencedBlobs().count
        return report
    }

    /// Blob files that no item refers to.
    private func unreferencedBlobs() -> [BlobID] {
        let fm = FileManager.default
        let live = catalog.blobIDs
        var found: [BlobID] = []
        for dir in (try? fm.contentsOfDirectory(at: blobsURL, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                if let id = BlobID(hex: file.lastPathComponent), dir.lastPathComponent == id.hex.prefix(2), !live.contains(id) {
                    found.append(id)
                }
            }
        }
        return found.sorted { $0.hex < $1.hex }
    }

    /// Lists every unreferenced blob that decrypts as an item of its own:
    /// a note's text and fields come back as a note, anything else as a
    /// file. Names are not in blobs, so they come back numbered. Returns
    /// the items added; blobs that do not decrypt are left as they are.
    public func recoverUnreferenced() throws -> [Item] {
        let k = try unlockedKeys()
        var c = catalog
        var added: [Item] = []
        for id in unreferencedBlobs() {
            let key = blobKey(id, keys: k)
            guard let length = try? BlobReader(url: blobURL(id), key: key).length else { continue }
            var item: Item
            if length <= 1 << 22, var data = try? BlobCipher.decryptData(from: blobURL(id), key: key) {
                defer { wipe(&data) }
                if let body = try? JSONDecoder().decode(NoteBody.self, from: data) {
                    item = Item(kind: body.wallet == nil ? .note : .wallet, title: "Recovered Item \(added.count + 1)")
                    item.body = id
                    c.items.append(item)
                    added.append(item)
                    continue
                }
            } else if length <= 1 << 22 {
                continue  // does not decrypt: damaged, or not this vault's
            } else {
                // A large file: checked whole before it is listed.
                guard (try? BlobCipher.decrypt(from: blobURL(id), key: key) { _ in }) != nil else { continue }
            }
            let name = "Recovered File \(added.count + 1)"
            item = Item(kind: .file, title: name)
            item.attachments = [Attachment(name: name, size: length, typeIdentifier: nil, blob: id)]
            c.items.append(item)
            added.append(item)
        }
        if !added.isEmpty { try commit(c, keys: k) }
        return added
    }

    /// Removes every unreferenced blob, for good.
    @discardableResult
    public func removeUnreferenced() throws -> Int {
        _ = try unlockedKeys()
        let ids = unreferencedBlobs()
        removeBlobs(ids)
        return ids.count
    }

    /// Deletes the vault for good. The header, which holds the only wrapped
    /// copies of the master key, is overwritten with random bytes first;
    /// without it no other file can be decrypted.
    ///
    /// Copies made before (Time Machine, APFS snapshots, an exported file)
    /// are beyond its reach: they still open with the password of their day.
    public func destroy() throws {
        lock()
        try Self.shred(root)
    }

    /// Overwrites a vault folder's header with random bytes, then removes
    /// the folder.
    static func shred(_ dir: URL) throws {
        let header = dir.appendingPathComponent("header.json")
        if let size = (try? FileManager.default.attributesOfItem(atPath: header.path))?[.size] as? Int {
            let fd = open(header.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                var noise = randomBytes(max(size, 1))
                _ = noise.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                wipe(&noise)
                if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
                close(fd)
            }
        }
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            throw VaultError.io(error.localizedDescription)
        }
    }

    // MARK: Re-encrypting

    /// Encrypts the whole vault again under a new master key, with a new
    /// password slot (and a new recovery slot if it had one). Everything is
    /// written to a folder beside the vault first; the two folders are then
    /// swapped in one step, so a crash leaves either the old vault or the
    /// new one, never a mix. The old folder is shredded after.
    private func reencryptAll(password: SecureBytes, parameters: KDFParameters) throws -> [String]? {
        let old = try unlockedKeys()
        guard let h = header else { throw VaultError.locked }
        let fm = FileManager.default
        let newKeys = Keys(master: SecureBytes.random(count: 32))
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("\(VaultLibrary.reencryptPrefix)\(UUID().uuidString)", isDirectory: true)
        var c = catalog
        c.retired = nil
        var words: [String]?
        var newHeader = VaultHeader(vaultID: h.vaultID, slots: [])
        var newLock: Int32 = -1
        do {
            do {
                try fm.createDirectory(at: staging.appendingPathComponent("blobs"), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            } catch {
                throw VaultError.io(error.localizedDescription)
            }
            for id in c.blobIDs {
                let reader = try BlobReader(url: blobURL(id), key: blobKey(id, keys: old))
                let target = Self.blobURL(id, in: staging)
                if !fm.fileExists(atPath: target.deletingLastPathComponent().path) {
                    do {
                        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
                    } catch {
                        throw VaultError.io(error.localizedDescription)
                    }
                }
                try BlobCipher.encrypt(length: reader.length, key: blobKey(id, keys: newKeys), to: target) {
                    try reader.read(into: $0)
                }
            }
            try write(catalog: c, keys: newKeys, to: staging.appendingPathComponent("catalog"))
            newHeader.slots = [try passwordSlot(master: newKeys.master, password: password,
                                                parameters: parameters, vaultID: h.vaultID)]
            if h.recoverySlot != nil {
                var entropy = randomBytes(32)
                defer { wipe(&entropy) }
                let kek = Self.recoveryWrappingKey(entropy: entropy, vaultID: h.vaultID)
                newHeader.slots.append(KeySlot.seal(master: newKeys.master, wrappingKey: kek, vaultID: h.vaultID,
                                                    kind: .recovery, kdf: nil, salt: Data()))
                words = BIP39.mnemonic(entropy: entropy)
            }
            try AtomicWriter.write(newHeader.encoded(), to: staging.appendingPathComponent("header.json"))
            let info = root.appendingPathComponent(VaultLibrary.infoFile)
            if let data = try? Data(contentsOf: info) {
                try AtomicWriter.write(data, to: staging.appendingPathComponent(VaultLibrary.infoFile))
            }
            // The new folder is locked before it takes the vault's place.
            newLock = open(staging.appendingPathComponent(".lock").path, O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard newLock >= 0, flock(newLock, LOCK_EX | LOCK_NB) == 0 else {
                throw VaultError.io(AtomicWriter.errnoText("lock the re-encrypted vault"))
            }
            guard renamex_np(staging.path, root.path, UInt32(RENAME_SWAP)) == 0 else {
                throw VaultError.io(AtomicWriter.errnoText("replace the vault"))
            }
        } catch {
            if newLock >= 0 { close(newLock) }
            try? fm.removeItem(at: staging)
            throw error
        }
        AtomicWriter.syncDirectory(root.deletingLastPathComponent())
        // `staging` now holds the old vault.
        releaseFolderLock()
        lockFD = newLock
        header = newHeader
        keys = newKeys
        catalog = c
        try? Self.shred(staging)
        return words
    }

    // MARK: Internals

    private func unlockedKeys() throws -> Keys {
        guard let keys else { throw VaultError.locked }
        return keys
    }

    private func readHeader() throws -> VaultHeader {
        guard Self.exists(at: root) else { throw VaultError.notFound }
        let reader = try FileReader(url: headerURL)
        guard reader.size < 1 << 20 else { throw VaultError.damaged("header") }
        var data = Data(count: Int(reader.size))
        let n = try data.withUnsafeMutableBytes { try reader.read(into: $0) }
        guard n == data.count else { throw VaultError.damaged("header") }
        return try VaultHeader.decode(data)
    }

    private func blobKey(_ id: BlobID, keys: Keys) -> SecureBytes {
        let key = SecureBytes(count: 32)
        let name = Array(id.hex.utf8)
        key.withMutableBytes { out in
            keys.blobs.withBytes { bk in
                _ = crypto_generichash(out, 32, name, UInt64(name.count), bk, 32)
            }
        }
        return key
    }

    @discardableResult
    private func writeBlob(_ source: BlobSource, keys: Keys) throws -> (BlobID, UInt64) {
        let id = BlobID()
        let url = blobURL(id)
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                throw VaultError.io(error.localizedDescription)
            }
        }
        let length = try BlobCipher.encrypt(source, key: blobKey(id, keys: keys), to: url)
        return (id, length)
    }

    private func writeBody(_ body: NoteBody, keys: Keys) throws -> BlobID {
        var data = try JSONEncoder().encode(body)
        defer { wipe(&data) }
        return try writeBlob(.data(data), keys: keys).0
    }

    /// Encrypts a file or a folder; every blob written is added to
    /// `written`, so a failure can remove them all.
    private func writeAttachment(_ f: FileImport, keys: Keys, written: inout [BlobID]) throws -> Attachment {
        switch f.source {
        case .data(let d):
            let (id, size) = try writeBlob(.data(d), keys: keys)
            written.append(id)
            return Attachment(name: f.name, size: size, typeIdentifier: f.typeIdentifier, blob: id)
        case .file(let url):
            let (id, size) = try writeBlob(.file(url), keys: keys)
            written.append(id)
            return Attachment(name: f.name, size: size, typeIdentifier: f.typeIdentifier, blob: id)
        case .folder(let url):
            var count = 0
            let contents = try readFolder(url, keys: keys, written: &written, count: &count)
            return Attachment(folderNamed: f.name, contents: contents)
        }
    }

    /// The most entries one folder may bring, so a mistaken drop of a whole
    /// disk does not swamp the catalog.
    static let maxFolderEntries = 100_000

    /// Everything in `dir`, files encrypted one by one. A symbolic link is
    /// kept as a link — the path it points to — and not followed, as tar
    /// and Finder copy them. Finder's .DS_Store files are left out.
    private func readFolder(_ dir: URL, keys: Keys, written: inout [BlobID], count: inout Int) throws -> [FolderEntry] {
        let fm = FileManager.default
        let props: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey,
                                       .contentModificationDateKey, .contentTypeKey]
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: props, options: [])
        } catch {
            throw VaultError.io(error.localizedDescription)
        }
        var out: [FolderEntry] = []
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let v = try? url.resourceValues(forKeys: Set(props))
            if url.lastPathComponent == ".DS_Store" { continue }
            count += 1
            guard count <= Self.maxFolderEntries else { throw VaultError.tooManyFiles(Self.maxFolderEntries) }
            if v?.isSymbolicLink == true {
                guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { continue }
                out.append(FolderEntry(link: url.lastPathComponent, target: target, modified: v?.contentModificationDate))
            } else if v?.isDirectory == true {
                let children = try readFolder(url, keys: keys, written: &written, count: &count)
                out.append(FolderEntry(folder: url.lastPathComponent, modified: v?.contentModificationDate, children: children))
            } else if v?.isRegularFile == true {
                let (id, size) = try writeBlob(.file(url), keys: keys)
                written.append(id)
                out.append(FolderEntry(file: url.lastPathComponent, size: size, modified: v?.contentModificationDate,
                                       typeIdentifier: v?.contentType?.identifier, blob: id))
            }
        }
        return out
    }

    private func write(catalog c: Catalog, keys: Keys, to url: URL? = nil) throws {
        var data = try JSONEncoder().encode(c)
        defer { wipe(&data) }
        try BlobCipher.encrypt(.data(data), key: keys.catalog, to: url ?? catalogURL)
    }

    /// Saves `c` and makes it the current catalog. `retiring` names the
    /// blobs the caller removes once this returns; the catalog keeps the
    /// list until the next save, so a crash in between is finished at the
    /// next unlock.
    private func commit(_ c: Catalog, keys: Keys, retiring: [BlobID] = []) throws {
        var c = c
        c.retired = retiring.isEmpty ? nil : retiring
        try write(catalog: c, keys: keys)
        catalog = c
    }

    private func removeBlobs(_ ids: [BlobID]) {
        for id in ids { unlink(blobURL(id).path) }
    }

    /// Finishes removals a crash interrupted: the blobs the catalog itself
    /// lists as retired (never one it still refers to), and unfinished
    /// temporary files. Other unreferenced blobs are kept; Verify reports
    /// them.
    private func finishRemovals() {
        let fm = FileManager.default
        let live = catalog.blobIDs
        removeBlobs((catalog.retired ?? []).filter { !live.contains($0) })
        for dir in (try? fm.contentsOfDirectory(at: blobsURL, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasSuffix(".tmp") {
                unlink(file.path)
            }
        }
        for file in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasSuffix(".tmp") {
            unlink(file.path)
        }
    }
}
