import Foundation
import Testing
@testable import VaultCore

@Suite struct LibraryTests {
    @Test func severalVaultsEachWithItsOwnPassword() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HashLockLib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lib = VaultLibrary(root: dir)
        #expect(lib.list().isEmpty)

        let (work, workVault) = try await lib.create(name: "  Work  ", password: "work pass", parameters: .minimum)
        let (home, homeVault) = try await lib.create(name: "Home", password: "home pass", parameters: .minimum)
        _ = try await workVault.addItem(kind: .note, title: "VPN")
        await workVault.lock()
        await homeVault.lock()

        #expect(lib.list().map(\.name) == ["Home", "Work"])
        #expect(work.name == "Work")

        await #expect(throws: VaultError.wrongPassword) { try await Vault(root: work.directory).unlock(password: "home pass") }
        #expect(try await Vault(root: work.directory).unlock(password: "work pass").items.map(\.title) == ["VPN"])
        #expect(try await Vault(root: home.directory).unlock(password: "home pass").items.isEmpty)

        let renamed = try lib.rename(home, to: "Family")
        #expect(lib.list().first { $0.id == home.id }?.name == "Family")
        #expect(renamed.name == "Family")

        try await Vault(root: work.directory).destroy()
        #expect(lib.list().map(\.id) == [home.id])
    }

    @Test func emptyNameBecomesVault() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("HashLockLib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (e, _) = try await VaultLibrary(root: dir).create(name: "   ", password: "x", parameters: .minimum)
        #expect(e.name == "Vault")
    }
}
