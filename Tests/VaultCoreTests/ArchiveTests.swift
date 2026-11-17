import Foundation
import Testing
@testable import VaultCore

@Suite struct ArchiveTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HashLockArchive-\(UUID().uuidString)")
    }

    @Test func exportAndImportOnAnotherMac() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let here = VaultLibrary(root: dir.appendingPathComponent("here"))
        let (entry, vault) = try await here.create(name: "Work", password: "pw", parameters: .minimum)
        let item = try await vault.addItem(kind: .note, title: "VPN", body: NoteBody(text: "secret"),
                                           files: [FileImport(name: "k", typeIdentifier: nil, source: .data(Data(randomBytes(90_000))))])
        let file = dir.appendingPathComponent("Work.hashlock")
        try await vault.exportArchive(to: file)

        // Nothing readable in the file.
        let bytes = try Data(contentsOf: file)
        #expect(bytes.range(of: Data("secret".utf8)) == nil && bytes.range(of: Data("VPN".utf8)) == nil)

        let info = try VaultArchive.inspect(file)
        #expect(info.name == "Work")
        #expect(here.existing(info)?.id == entry.id)

        let there = VaultLibrary(root: dir.appendingPathComponent("there"))
        #expect(there.existing(info) == nil)
        let imported = try there.importArchive(file)
        #expect(imported.name == "Work")
        let copy = Vault(root: imported.directory)
        await #expect(throws: VaultError.wrongPassword) { try await copy.unlock(password: "nope") }
        let catalog = try await copy.unlock(password: "pw")
        #expect(catalog.items.map(\.id) == [item.id])
        #expect(try await copy.body(of: item.id).text == "secret")
        #expect(try await copy.data(of: catalog.items[0].attachments[0], limit: .max).count == 90_000)
    }

    @Test func replacingAnExistingVault() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = VaultLibrary(root: dir.appendingPathComponent("lib"))
        let (entry, vault) = try await lib.create(name: "V", password: "pw", parameters: .minimum)
        let file = dir.appendingPathComponent("V.hashlock")
        try await vault.exportArchive(to: file)
        _ = try await vault.addItem(kind: .note, title: "added later")
        await vault.lock()

        let back = try lib.importArchive(file, replacing: entry)
        #expect(back.id == entry.id)
        #expect(lib.list().count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lib.root.path) == [entry.id.uuidString])
        let reopened = Vault(root: back.directory)
        #expect(try await reopened.unlock(password: "pw").items.isEmpty)

        // An open vault is not replaced under it.
        await #expect(throws: VaultError.inUse) { try lib.importArchive(file, replacing: entry) }
        await reopened.lock()
    }

    @Test func leftoversAreShredded() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = VaultLibrary(root: dir.appendingPathComponent("lib"))
        let (entry, vault) = try await lib.create(name: "V", password: "pw", parameters: .minimum)
        await vault.lock()
        let leftover = lib.root.appendingPathComponent(".reencrypt-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: entry.directory, to: leftover)
        lib.removeLeftovers()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(lib.list().count == 1)
    }

    @Test func damagedFileIsRefused() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = VaultLibrary(root: dir.appendingPathComponent("lib"))
        let (_, vault) = try await lib.create(name: "V", password: "pw", parameters: .minimum)
        let file = dir.appendingPathComponent("V.hashlock")
        try await vault.exportArchive(to: file)
        var d = try Data(contentsOf: file)
        d[d.count / 2] ^= 1
        try d.write(to: file)
        #expect(throws: VaultError.self) { try VaultArchive.inspect(file) }
        let other = VaultLibrary(root: dir.appendingPathComponent("other"))
        #expect(throws: VaultError.self) { try other.importArchive(file) }
        #expect(other.list().isEmpty)

        try d.prefix(d.count - 40).write(to: file)
        #expect(throws: VaultError.self) { try VaultArchive.inspect(file) }
    }

    @Test func pathsOutsideTheVaultAreRefused() throws {
        // A hand-made archive naming "../escape": refused before any write.
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = Data("HLARCH01".utf8)
        let path = Array("../escape".utf8)
        withUnsafeBytes(of: UInt16(path.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: path)
        withUnsafeBytes(of: UInt64(1).littleEndian) { d.append(contentsOf: $0) }
        d.append(0x41)
        let file = dir.appendingPathComponent("evil.hashlock")
        try d.write(to: file)
        let lib = VaultLibrary(root: dir.appendingPathComponent("lib"))
        #expect(throws: VaultError.self) { try lib.importArchive(file) }
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("lib/escape").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape").path))
        for bad in ["../escape", "/etc/passwd", "blobs/zz/abc", "blobs/ab/../../x", "attempts", "blobs/ab"] {
            #expect(!VaultArchive.isVaultPath(bad), "\(bad)")
        }
        #expect(VaultArchive.isVaultPath("blobs/ab/ab" + String(repeating: "0", count: 30)))
    }
}
