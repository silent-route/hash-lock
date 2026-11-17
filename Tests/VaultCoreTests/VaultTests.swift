import Foundation
import Testing
@testable import VaultCore

/// A vault in a fresh temporary directory, removed afterwards. The cheapest
/// accepted derivation settings keep the tests fast.
final class TempVault {
    let dir: URL
    let vault: Vault
    static let fast = KDFParameters.minimum

    init() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HashLockTests-\(UUID().uuidString)")
        vault = Vault(root: dir.appendingPathComponent("Vault"))
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func created(password: String = "correct horse") async throws -> Vault {
        try await vault.create(password: password, parameters: Self.fast)
        return vault
    }

    /// The only blob file of the vault (tests that add exactly one).
    func onlyBlob() throws -> URL {
        let blobs = vault.root.appendingPathComponent("blobs")
        let files = try FileManager.default.subpathsOfDirectory(atPath: blobs.path)
            .map { blobs.appendingPathComponent($0) }
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent.count == 32 }
        #expect(files.count == 1)
        return files[0]
    }
}

func flipByte(at offset: Int, in url: URL) throws {
    var d = try Data(contentsOf: url)
    d[offset] ^= 0x01
    try d.write(to: url)
}

@Suite struct VaultTests {
    @Test func createLockUnlock() async throws {
        let t = TempVault()
        let v = try await t.created()
        let item = try await v.addItem(kind: .note, title: "GitHub")
        await v.lock()
        #expect(await v.isUnlocked == false)
        let catalog = try await v.unlock(password: "correct horse")
        #expect(catalog.items == [item])
    }

    @Test func wrongPasswordIsRefused() async throws {
        let t = TempVault()
        let v = try await t.created()
        await v.lock()
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(password: "Correct horse") }
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(password: "") }
        try await v.checkPassword("correct horse")
        await #expect(throws: VaultError.wrongPassword) { try await v.checkPassword("nope") }
    }

    @Test func passwordUnicodeFormsAreTheSame() async throws {
        let t = TempVault()
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        let v = try await t.created(password: composed)
        await v.lock()
        _ = try await v.unlock(password: decomposed)
    }

    @Test func noPasswordOrKeyIsStored() async throws {
        let t = TempVault()
        let v = try await t.created(password: "unique-marker-password")
        _ = try await v.addItem(kind: .note, title: "Visible-Title-Marker",
                                body: NoteBody(text: "secret-body-marker"))
        let files = try FileManager.default.subpathsOfDirectory(atPath: v.root.path)
        for f in files {
            let url = v.root.appendingPathComponent(f)
            guard !url.hasDirectoryPath, let data = try? Data(contentsOf: url) else { continue }
            for marker in ["unique-marker-password", "Visible-Title-Marker", "secret-body-marker"] {
                #expect(data.range(of: Data(marker.utf8)) == nil, "\(marker) found in \(f)")
            }
        }
    }

    @Test func headerTamperingFails() async throws {
        let t = TempVault()
        let v = try await t.created()
        await v.lock()
        let url = v.root.appendingPathComponent("header.json")
        let original = try Data(contentsOf: url)

        // Stronger but different settings: the slot no longer opens.
        var h = try VaultHeader.decode(original)
        h.slots[0].kdf!.opsLimit += 1
        try h.encoded().write(to: url)
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(password: "correct horse") }

        // Weaker than the minimum: refused outright.
        h = try VaultHeader.decode(original)
        h.slots[0].kdf!.memLimit = 8 << 20
        try h.encoded().write(to: url)
        await #expect(throws: VaultError.unsupportedParameters) { try await v.unlock(password: "correct horse") }

        // Another vault ID.
        h = try VaultHeader.decode(original)
        h.vaultID = UUID()
        try h.encoded().write(to: url)
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(password: "correct horse") }

        // A newer format.
        h = try VaultHeader.decode(original)
        h.version = 99
        try h.encoded().write(to: url)
        await #expect(throws: VaultError.newerFormat(99)) { try await v.unlock(password: "correct horse") }

        try original.write(to: url)
        _ = try await v.unlock(password: "correct horse")
    }

    @Test func notesRoundTrip() async throws {
        let t = TempVault()
        let v = try await t.created()
        var wallet = WalletBackup(format: .bip39, wordCount: 12)
        wallet.words = Array(repeating: "abandon", count: 11) + ["about"]
        wallet.passphrase = "wasabi password"
        let body = NoteBody(text: "Server notes\nline 2",
                            fields: [Field(kind: .login, value: "admin"),
                                     Field(kind: .password, value: "p@ss"),
                                     Field(kind: .address, value: "10.0.0.1:22")],
                            wallet: wallet)
        let item = try await v.addItem(kind: .note, title: "Server", body: body)
        await v.lock()
        _ = try await v.unlock(password: "correct horse")
        #expect(try await v.body(of: item.id) == body)

        var changed = body
        changed.text = "new text"
        let updated = try await v.setBody(changed, of: item.id)
        #expect(updated.body != item.body)
        #expect(try await v.body(of: item.id) == changed)
        // The old body's blob is gone.
        #expect(try t.onlyBlob().lastPathComponent == updated.body?.hex)

        let cleared = try await v.setBody(NoteBody(), of: item.id)
        #expect(cleared.body == nil)
        #expect(try await v.body(of: item.id) == NoteBody())
    }

    @Test(arguments: [0, 1, 511, 512, 65_535, 65_536, 65_537, 200_000, 3 * 65_536])
    func filesRoundTrip(size: Int) async throws {
        let t = TempVault()
        let v = try await t.created()
        let content = Data(randomBytes(size))
        let src = t.dir.appendingPathComponent("source.bin")
        try content.write(to: src)
        let item = try await v.addItem(kind: .file, title: "file",
                                       files: [FileImport(name: "source.bin", typeIdentifier: nil, source: .file(src))])
        let a = item.attachments[0]
        #expect(a.size == UInt64(size))
        let blob = try t.onlyBlob()
        let onDisk = try FileManager.default.attributesOfItem(atPath: blob.path)[.size] as! UInt64
        #expect(onDisk == BlobCipher.encryptedSize(forContentLength: UInt64(size)))

        #expect(try await v.data(of: a, limit: .max) == content)
        let out = t.dir.appendingPathComponent("exported.bin")
        try await v.export(a, to: out)
        #expect(try Data(contentsOf: out) == content)
        let perms = try FileManager.default.attributesOfItem(atPath: out.path)[.posixPermissions] as! Int
        #expect(perms == 0o600)
    }

    @Test func viewerLimitIsChecked() async throws {
        let t = TempVault()
        let v = try await t.created()
        let item = try await v.addItem(kind: .file, title: "f",
                                       files: [FileImport(name: "f", typeIdentifier: nil, source: .data(Data(count: 2000)))])
        await #expect(throws: VaultError.tooLarge) { try await v.data(of: item.attachments[0], limit: 1000) }
    }

    @Test func blobTamperingFails() async throws {
        let t = TempVault()
        let v = try await t.created()
        let item = try await v.addItem(kind: .file, title: "f",
                                       files: [FileImport(name: "f", typeIdentifier: nil, source: .data(Data(randomBytes(100_000))))])
        let a = item.attachments[0]
        let blob = try t.onlyBlob()
        let original = try Data(contentsOf: blob)

        for offset in [0, 30, 60, 70_000, original.count - 1] {
            try original.write(to: blob)
            try flipByte(at: offset, in: blob)
            await #expect(throws: VaultError.self) { try await v.data(of: a, limit: .max) }
        }
        // Cut short, or extended.
        try original.prefix(original.count - 17).write(to: blob)
        await #expect(throws: VaultError.self) { try await v.data(of: a, limit: .max) }
        try (original + Data(count: 17)).write(to: blob)
        await #expect(throws: VaultError.self) { try await v.data(of: a, limit: .max) }

        try original.write(to: blob)
        #expect(try await v.verify().damaged.isEmpty)
        try flipByte(at: 100, in: blob)
        #expect(try await v.verify().damaged == [item.id])
    }

    @Test func blobsCannotBeSwapped() async throws {
        let t = TempVault()
        let v = try await t.created()
        let a = try await v.addItem(kind: .file, title: "a",
                                    files: [FileImport(name: "a", typeIdentifier: nil, source: .data(Data("first".utf8)))])
        let b = try await v.addItem(kind: .file, title: "b",
                                    files: [FileImport(name: "b", typeIdentifier: nil, source: .data(Data("second".utf8)))])
        let blobs = v.root.appendingPathComponent("blobs")
        func url(_ id: BlobID) -> URL { blobs.appendingPathComponent(String(id.hex.prefix(2))).appendingPathComponent(id.hex) }
        let dataB = try Data(contentsOf: url(b.attachments[0].blob!))
        try dataB.write(to: url(a.attachments[0].blob!))
        await #expect(throws: VaultError.self) { try await v.data(of: a.attachments[0], limit: .max) }
    }

    @Test func catalogTamperingFails() async throws {
        let t = TempVault()
        let v = try await t.created()
        _ = try await v.addItem(kind: .note, title: "x")
        await v.lock()
        try flipByte(at: 40, in: v.root.appendingPathComponent("catalog"))
        await #expect(throws: VaultError.self) { try await v.unlock(password: "correct horse") }
    }

    @Test func changePassword() async throws {
        let t = TempVault()
        let v = try await t.created()
        let item = try await v.addItem(kind: .note, title: "keep", body: NoteBody(text: "data"))
        await #expect(throws: VaultError.wrongPassword) {
            try await v.changePassword(current: "wrong", new: "new one", parameters: TempVault.fast)
        }
        try await v.changePassword(current: "correct horse", new: "new one", parameters: TempVault.fast)
        await v.lock()
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(password: "correct horse") }
        _ = try await v.unlock(password: "new one")
        #expect(try await v.body(of: item.id).text == "data")
    }

    @Test func reencryptingShutsOutAnOldHeader() async throws {
        // Someone kept a copy of the header and knows the password of that
        // day. After a password change with re-encryption, that header no
        // longer opens what the vault holds now.
        let t = TempVault()
        let v = try await t.created(password: "leaked")
        let words = try await v.createRecoveryKey()
        let item = try await v.addItem(kind: .note, title: "secret", body: NoteBody(text: "old text"),
                                       files: [FileImport(name: "f", typeIdentifier: nil, source: .data(Data(repeating: 7, count: 200_000)))])
        let headerURL = v.root.appendingPathComponent("header.json")
        let oldHeader = try Data(contentsOf: headerURL)

        let newWords = try #require(try await v.changePassword(current: "leaked", new: "fresh", parameters: TempVault.fast,
                                                                 reencrypt: true))
        #expect(newWords != words)
        // Still unlocked, still working.
        let after = try await v.setBody(NoteBody(text: "new text"), of: item.id)
        #expect(try await v.body(of: after.id).text == "new text")
        let fileItem = try #require(await v.catalog.items.first)
        #expect(try await v.data(of: fileItem.attachments[0], limit: .max) == Data(repeating: 7, count: 200_000))
        await v.lock()

        // Nothing is left beside the vault.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: v.root.deletingLastPathComponent().path)
        #expect(siblings == ["Vault"])

        _ = try await v.unlock(password: "fresh")
        await v.lock()
        _ = try await v.unlock(recoveryPhrase: newWords)
        await v.lock()
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(recoveryPhrase: words) }

        // The old header opens with the old password, but the catalog and
        // blobs are no longer under its key.
        let current = try Data(contentsOf: headerURL)
        try oldHeader.write(to: headerURL)
        await #expect(throws: VaultError.damaged("blob authentication")) { try await v.unlock(password: "leaked") }
        try current.write(to: headerURL)
        _ = try await v.unlock(password: "fresh")
    }

    @Test func swappedHeaderDoesNotPassForTheCurrentPassword() async throws {
        // Someone at an unlocked Mac swaps in the header of a vault whose
        // password they know, then "changes" the password with it.
        let mine = TempVault()
        let v = try await mine.created(password: "owner's password")
        let theirs = TempVault()
        _ = try await theirs.created(password: "known")
        let theirHeader = try Data(contentsOf: theirs.vault.root.appendingPathComponent("header.json"))
        try theirHeader.write(to: v.root.appendingPathComponent("header.json"))
        await #expect(throws: VaultError.wrongPassword) {
            try await v.changePassword(current: "known", new: "attacker's", parameters: TempVault.fast)
        }
    }

    @Test func aVaultOpensInOneCopyAtATime() async throws {
        let t = TempVault()
        let v = try await t.created()
        let other = Vault(root: v.root)   // as a second copy of the app would
        await #expect(throws: VaultError.inUse) { try await other.unlock(password: "correct horse") }
        await v.lock()
        _ = try await other.unlock(password: "correct horse")
    }

    @Test func recoveryKey() async throws {
        let t = TempVault()
        let v = try await t.created()
        #expect(await v.hasRecoveryKey == false)
        let words = try await v.createRecoveryKey()
        #expect(words.count == 24)
        #expect(BIP39.validate(words) == nil)
        await v.lock()
        _ = try await v.unlock(recoveryPhrase: words)

        // A new phrase replaces the old one.
        let newer = try await v.createRecoveryKey()
        await v.lock()
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(recoveryPhrase: words) }
        _ = try await v.unlock(recoveryPhrase: newer)

        // The password still works after recovery, and can be changed.
        try await v.changePassword(current: "correct horse", new: "after", parameters: TempVault.fast)
        try await v.removeRecoveryKey()
        await v.lock()
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(recoveryPhrase: newer) }
        _ = try await v.unlock(password: "after")
    }

    @Test func passwordResetOnlyAfterRecovery() async throws {
        let t = TempVault()
        let v = try await t.created()
        let words = try await v.createRecoveryKey()
        // Unlocked with the password: no reset without the old one.
        await #expect(throws: VaultError.wrongPassword) { try await v.resetPassword(new: "x", parameters: TempVault.fast) }
        await v.lock()
        _ = try await v.unlock(recoveryPhrase: words)
        try await v.resetPassword(new: "brand new", parameters: TempVault.fast)
        await v.lock()
        await #expect(throws: VaultError.wrongPassword) { try await v.unlock(password: "correct horse") }
        _ = try await v.unlock(password: "brand new")
        // The recovery phrase still works.
        await v.lock()
        _ = try await v.unlock(recoveryPhrase: words)
    }

    @Test func attachmentsAndDeletion() async throws {
        let t = TempVault()
        let v = try await t.created()
        var item = try await v.addItem(kind: .note, title: "n", body: NoteBody(text: "t"))
        item = try await v.addAttachments([FileImport(name: "a.txt", typeIdentifier: "public.plain-text",
                                                      source: .data(Data("A".utf8)))], to: item.id)
        item = try await v.renameAttachment(item.attachments[0].id, of: item.id, to: "b.txt")
        #expect(item.attachments[0].name == "b.txt")
        item = try await v.removeAttachment(item.attachments[0].id, of: item.id)
        #expect(item.attachments.isEmpty)
        try await v.deleteItems([item.id])
        #expect(await v.catalog.items.isEmpty)
        let blobs = v.root.appendingPathComponent("blobs")
        let left = try FileManager.default.subpathsOfDirectory(atPath: blobs.path).filter { $0.count > 3 }
        #expect(left.isEmpty)
    }

    @Test func foldersRoundTrip() async throws {
        let t = TempVault()
        let v = try await t.created()
        let fm = FileManager.default
        let src = t.dir.appendingPathComponent("Project")
        try fm.createDirectory(at: src.appendingPathComponent("docs/old"), withIntermediateDirectories: true)
        try Data("readme".utf8).write(to: src.appendingPathComponent("README.md"))
        try Data(randomBytes(70_000)).write(to: src.appendingPathComponent("docs/spec.bin"))
        try Data("x".utf8).write(to: src.appendingPathComponent("docs/old/notes.txt"))
        try Data().write(to: src.appendingPathComponent(".DS_Store"))
        try fm.createSymbolicLink(at: src.appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))

        var item = try await v.addItem(kind: .note, title: "n")
        item = try await v.addAttachments([FileImport(name: "Project", typeIdentifier: "public.folder", source: .folder(src))],
                                          to: item.id)
        let a = item.attachments[0]
        #expect(a.isFolder)
        #expect(a.fileCount == 3)
        #expect(a.size == 6 + 70_000 + 1)
        #expect(a.folder!.map(\.name) == ["docs", "link", "README.md"])
        #expect(a.folder![1].linkTarget == "/etc/hosts")
        #expect(a.blobs.count == 3)

        // Survives a lock: the folder's blobs are not taken for orphans.
        await v.lock()
        let catalog = try await v.unlock(password: "correct horse")
        let reread = catalog.items[0].attachments[0]
        #expect(reread == a)

        let out = t.dir.appendingPathComponent("Exported")
        try await v.export(reread, to: out)
        #expect(try Data(contentsOf: out.appendingPathComponent("README.md")) == Data("readme".utf8))
        #expect(try Data(contentsOf: out.appendingPathComponent("docs/spec.bin"))
                == Data(contentsOf: src.appendingPathComponent("docs/spec.bin")))
        #expect(try Data(contentsOf: out.appendingPathComponent("docs/old/notes.txt")) == Data("x".utf8))
        // The link comes back as a link, pointing where it did.
        #expect(try fm.destinationOfSymbolicLink(atPath: out.appendingPathComponent("link").path) == "/etc/hosts")

        // The link on its own, and a folder holding only a link of the
        // same name (exported as a folder, not as the link).
        let link = reread.folder!.first { $0.isLink }!
        try await v.export(link.asAttachment, to: t.dir.appendingPathComponent("just-link"))
        #expect(try fm.destinationOfSymbolicLink(atPath: t.dir.appendingPathComponent("just-link").path) == "/etc/hosts")
        let lonely = Attachment(folderNamed: "link", contents: [link])
        try await v.export(lonely, to: t.dir.appendingPathComponent("lonely"))
        #expect(try fm.destinationOfSymbolicLink(atPath: t.dir.appendingPathComponent("lonely/link").path) == "/etc/hosts")

        // A failed export into a folder that was already there leaves it.
        let existing = t.dir.appendingPathComponent("existing")
        try fm.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: existing.appendingPathComponent("mine.txt"))
        let broken = Attachment(folderNamed: "x", contents: [
            FolderEntry(file: "y", size: 1, modified: nil, typeIdentifier: nil, blob: BlobID()),
        ])
        await #expect(throws: VaultError.self) { try await v.export(broken, to: existing) }
        #expect(try Data(contentsOf: existing.appendingPathComponent("mine.txt")) == Data("keep".utf8))

        // One file inside, on its own.
        let spec = reread.folder![0].children!.first { $0.name == "spec.bin" }!
        #expect(try await v.data(of: spec.asAttachment, limit: .max).count == 70_000)

        _ = try await v.removeAttachment(reread.id, of: item.id)
        let blobs = v.root.appendingPathComponent("blobs")
        #expect(try fm.subpathsOfDirectory(atPath: blobs.path).filter { $0.count > 3 }.isEmpty)
    }

    @Test func folderExportCannotWriteThroughALink() async throws {
        // A folder whose link "docs" points outside, and a real "docs"
        // folder with a file: exporting must not write into the target.
        let t = TempVault()
        let v = try await t.created()
        let outside = t.dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // A real encrypted file to point the entry at.
        let real = try await v.addItem(kind: .file, title: "x",
                                       files: [FileImport(name: "x", typeIdentifier: nil, source: .data(Data("x".utf8)))])
        let entries = [
            FolderEntry(link: "docs", target: outside.path, modified: nil),
            FolderEntry(folder: "docs", modified: nil, children: [
                FolderEntry(file: "x", size: 1, modified: nil, typeIdentifier: nil, blob: real.attachments[0].blob!),
            ]),
        ]
        let a = Attachment(folderNamed: "Evil", contents: entries)
        await #expect(throws: VaultError.self) { try await v.export(a, to: t.dir.appendingPathComponent("Out")) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func unknownBlobsAreKeptAndTempFilesRemoved() async throws {
        let t = TempVault()
        let v = try await t.created()
        let dir = v.root.appendingPathComponent("blobs/ab")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unknown = dir.appendingPathComponent(String(repeating: "ab", count: 16))
        let temp = dir.appendingPathComponent(".x.tmp")
        try Data("x".utf8).write(to: unknown)
        try Data("x".utf8).write(to: temp)
        await v.lock()
        _ = try await v.unlock(password: "correct horse")
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        #expect(try await v.verify().unreferenced == 1)
        // It does not decrypt, so it is not listed as an item.
        #expect(try await v.recoverUnreferenced().isEmpty)
        #expect(try await v.removeUnreferenced() == 1)
        #expect(!FileManager.default.fileExists(atPath: unknown.path))
    }

    @Test func retiredBlobsAreRemovedAfterACrash() async throws {
        // A crash after the catalog is saved but before the old blob is
        // removed: the next unlock finishes the removal.
        let t = TempVault()
        let v = try await t.created()
        let item = try await v.addItem(kind: .note, title: "n", body: NoteBody(text: "one"))
        let old = try t.onlyBlob()
        let oldBytes = try Data(contentsOf: old)
        _ = try await v.setBody(NoteBody(text: "two"), of: item.id)
        try oldBytes.write(to: old)
        await v.lock()
        _ = try await v.unlock(password: "correct horse")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try await v.body(of: item.id).text == "two")
        #expect(try await v.verify().unreferenced == 0)
    }

    @Test func anOlderCatalogPutBackLosesNothing() async throws {
        // Restoring the catalog file alone (from a backup) must not delete
        // what was added since: it is kept and can be recovered.
        let t = TempVault()
        let v = try await t.created()
        let catalogURL = v.root.appendingPathComponent("catalog")
        let olderCatalog = try Data(contentsOf: catalogURL)
        _ = try await v.addItem(kind: .note, title: "later", body: NoteBody(text: "added since"))
        _ = try await v.addItem(kind: .file, title: "f.bin",
                                files: [FileImport(name: "f.bin", typeIdentifier: nil, source: .data(Data([1, 2, 3])))])
        await v.lock()
        try olderCatalog.write(to: catalogURL)
        #expect(try await v.unlock(password: "correct horse").items.isEmpty)
        #expect(try await v.verify().unreferenced == 2)
        let recovered = try await v.recoverUnreferenced()
        #expect(recovered.count == 2)
        let note = try #require(recovered.first { $0.kind == .note })
        #expect(try await v.body(of: note.id).text == "added since")
        let file = try #require(recovered.first { $0.kind == .file })
        #expect(try await v.data(of: file.attachments[0], limit: .max) == Data([1, 2, 3]))
        #expect(try await v.verify().unreferenced == 0)
    }

    @Test func destroy() async throws {
        let t = TempVault()
        let v = try await t.created()
        try await v.destroy()
        #expect(!FileManager.default.fileExists(atPath: v.root.path))
        #expect(!Vault.exists(at: v.root))
    }

    @Test func lockedVaultRefusesWork() async throws {
        let t = TempVault()
        let v = try await t.created()
        await v.lock()
        await #expect(throws: VaultError.locked) { try await v.addItem(kind: .note, title: "x") }
        await #expect(throws: VaultError.locked) { try await v.createRecoveryKey() }
    }
}

@Suite struct PrimitiveTests {
    @Test func padme() {
        #expect(BlobCipher.paddedLength(0) == 512)
        #expect(BlobCipher.paddedLength(512) == 512)
        for l: UInt64 in [513, 1000, 65_537, 1_000_000, 123_456_789] {
            let p = BlobCipher.paddedLength(l)
            #expect(p >= l)
            #expect(Double(p - l) / Double(l) <= 0.12)
        }
    }

    @Test func bip39Vectors() {
        // From the BIP-39 test vectors (trezor/python-mnemonic vectors.json).
        #expect(BIP39.mnemonic(entropy: [UInt8](repeating: 0, count: 16)).joined(separator: " ")
                == Array(repeating: "abandon", count: 11).joined(separator: " ") + " about")
        #expect(BIP39.mnemonic(entropy: [UInt8](repeating: 0x7f, count: 16)).joined(separator: " ")
                == "legal winner thank year wave sausage worth useful legal winner thank yellow")
        #expect(BIP39.mnemonic(entropy: [UInt8](repeating: 0xff, count: 32)).joined(separator: " ")
                == Array(repeating: "zoo", count: 23).joined(separator: " ") + " vote")
        let words = "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter always"
            .split(separator: " ").map(String.init)
        #expect(BIP39.validate(words) == nil)
        #expect((try? BIP39.entropy(of: words).get()) == [UInt8](repeating: 0x80, count: 24))
    }

    @Test func bip39Problems() {
        #expect(BIP39.validate(Array(repeating: "abandon", count: 12)) == .badChecksum)
        #expect(BIP39.validate(Array(repeating: "abandon", count: 11)) == .wrongCount(11))
        #expect(BIP39.validate(Array(repeating: "abandon", count: 11) + ["bitcoinz"]) == .unknownWords([11]))
        #expect(BIP39.completions(for: "aban") == ["abandon"])
    }

    @Test func generator() {
        var o = PasswordGenerator.Options()
        o.length = 32
        let p = PasswordGenerator.generate(o)
        #expect(p.count == 32)
        #expect(p.contains(where: \.isLowercase) && p.contains(where: \.isUppercase) && p.contains(where: \.isNumber))
        #expect(!p.contains(where: { "0Oo1lI".contains($0) }))
        o.style = .words
        o.wordCount = 5
        #expect(PasswordGenerator.generate(o).split(separator: "-").count == 5)
        #expect(PasswordGenerator.generate(o) != PasswordGenerator.generate(o))
    }

    @Test func loginGenerator() {
        let w = LoginGenerator.generate(.words)
        #expect(w.split(separator: ".").count == 2)
        #expect(w.last!.isNumber)
        let r = LoginGenerator.generate(.random)
        #expect(r.count == 12 && r.first!.isLetter && r.allSatisfy { $0.isLowercase || $0.isNumber })
    }

    @Test func walletsFromBeforeCoinsAreBitcoin() throws {
        let json = #"{"format":"bip39","words":["a","b"],"passphrase":"p","software":"s","derivationPath":"m","extendedPublicKey":"x","birthday":"2020"}"#
        let w = try JSONDecoder().decode(WalletBackup.self, from: Data(json.utf8))
        #expect(w.coin == .bitcoin)
        #expect(w.words == ["a", "b"] && w.extendedPublicKey == "x" && w.birthday == "2020")
        #expect(w.address.isEmpty && w.viewKey.isEmpty && w.spendKey.isEmpty)
        var m = WalletBackup(coin: .monero, format: .monero, wordCount: 25)
        m.viewKey = "v"
        #expect(try JSONDecoder().decode(WalletBackup.self, from: JSONEncoder().encode(m)) == m)
    }

    @Test func fieldConcealmentDecodesFromOlderNotes() throws {
        // Notes saved before the setting existed have no "concealed" key.
        let json = #"{"id":"6A1B6F3E-0000-4000-8000-000000000001","kind":"login","label":"Login","value":"a"}"#
        let f = try JSONDecoder().decode(Field.self, from: Data(json.utf8))
        #expect(f.concealed == nil && !f.isConcealed)
    }

    @Test func strength() {
        #expect(PasswordStrength.estimate("123456") == .veryWeak)
        #expect(PasswordStrength.estimate("aaaaaaaaaaaaaaaaaaaa") <= .weak)
        #expect(PasswordStrength.estimate("orbit-lemon-velvet-candle-ninety") >= .strong)
    }

    @Test func kdfBounds() {
        #expect(KDFParameters.minimum.isAcceptable)
        for level in KDFParameters.Level.allCases { #expect(level.parameters.isAcceptable) }
        #expect(!KDFParameters(opsLimit: 1, memLimit: 1 << 30).isAcceptable)
        #expect(!KDFParameters(opsLimit: 3, memLimit: 8 << 30).isAcceptable)
    }
}
