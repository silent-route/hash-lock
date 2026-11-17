import Foundation

/// A vault as listed before it is unlocked.
public struct VaultEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var created: Date
    public let directory: URL
}

/// The vaults on this Mac, one folder each, every one with its own password
/// and keys:
///
///     Vaults/<id>/info.json      the name, in the clear (shown before unlocking)
///     Vaults/<id>/header.json    key slots
///     Vaults/<id>/…              as in `Vault`
///
/// The name is the only thing about a vault that is not encrypted: it must be
/// shown to choose which vault to unlock.
public struct VaultLibrary: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    struct Info: Codable {
        var name: String
        var created: Date
    }

    static let infoFile = "info.json"
    public static let maxNameLength = 60
    /// Folders beside the vaults while work is under way; whatever is left
    /// of them after a crash is removed by `removeLeftovers()`.
    static let reencryptPrefix = ".reencrypt-"
    static let importPrefix = ".import-"
    static let replacedPrefix = ".replaced-"

    /// Shreds what an interrupted import or re-encryption left beside the
    /// vaults. Such a folder may hold an old header, which would still open
    /// with the old password: it must not stay. Called at launch, before
    /// any vault is open.
    public func removeLeftovers() {
        let prefixes = [Self.reencryptPrefix, Self.importPrefix, Self.replacedPrefix]
        for dir in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where prefixes.contains(where: { dir.lastPathComponent.hasPrefix($0) }) {
            try? Vault.shred(dir)
        }
    }

    /// Every vault with a header, by name.
    public func list() -> [VaultEntry] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.compactMap { dir -> VaultEntry? in
            guard let id = UUID(uuidString: dir.lastPathComponent), Vault.exists(at: dir) else { return nil }
            let info = (try? Data(contentsOf: dir.appendingPathComponent(Self.infoFile)))
                .flatMap { try? JSONDecoder.iso.decode(Info.self, from: $0) }
            // Cleaned on reading too: an imported file's name is someone
            // else's text.
            return VaultEntry(id: id, name: Self.clean(info?.name ?? ""), created: info?.created ?? .distantPast, directory: dir)
        }
        .sorted { a, b in
            let c = a.name.localizedStandardCompare(b.name)
            return c == .orderedSame ? a.created < b.created : c == .orderedAscending
        }
    }

    /// Makes a vault and returns it unlocked.
    public func create(name: String, password: String, parameters: KDFParameters) async throws -> (VaultEntry, Vault) {
        let clean = Self.clean(name)
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw VaultError.io(error.localizedDescription)
        }
        let vault = Vault(root: dir)
        do {
            try await vault.create(password: password, parameters: parameters)
            let info = Info(name: clean, created: Date())
            try AtomicWriter.write(JSONEncoder.iso.encode(info), to: dir.appendingPathComponent(Self.infoFile))
            return (VaultEntry(id: id, name: clean, created: info.created, directory: dir), vault)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    public func rename(_ entry: VaultEntry, to name: String) throws -> VaultEntry {
        var e = entry
        e.name = Self.clean(name)
        let info = Info(name: e.name, created: entry.created)
        try AtomicWriter.write(JSONEncoder.iso.encode(info), to: entry.directory.appendingPathComponent(Self.infoFile))
        return e
    }

    static func clean(_ name: String) -> String {
        let t = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Vault" : String(t.prefix(maxNameLength))
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
