import Clibsodium
import Foundation

/// A vault as one file (`.hashlock`), to move it to another Mac or keep a
/// copy on a drive. Everything in it is the vault's own files, already
/// encrypted; nothing is decrypted to make it, and it opens with the
/// vault's password (or recovery phrase), as the vault does.
///
///     "HLARCH01"
///     entries: path length (u16 LE), path (UTF-8), size (u64 LE), bytes
///     end: path length 0
///     BLAKE2b-256 of everything before it
///
/// The checksum catches a copy damaged on the way (a drive pulled out too
/// early); it is not what keeps the vault safe — its own encryption and
/// authentication do that. Only the vault's known files are accepted
/// (header.json, info.json, catalog, blobs/xx/<hex>), so an archive cannot
/// write anywhere else.
/// Streaming BLAKE2b-256. libsodium's state is 64-byte aligned, which Swift
/// sees as an opaque type, so it is allocated here with that alignment.
final class StreamHash {
    private let state: UnsafeMutableRawPointer

    init() {
        _ = Sodium.ready
        state = .allocate(byteCount: crypto_generichash_statebytes(), alignment: 64)
        crypto_generichash_init(OpaquePointer(state), nil, 0, 32)
    }

    func update(_ bytes: UnsafeRawBufferPointer) {
        crypto_generichash_update(OpaquePointer(state), bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(bytes.count))
    }

    func update(_ bytes: [UInt8], count: Int? = nil) {
        bytes.withUnsafeBytes { update(UnsafeRawBufferPointer(rebasing: $0[0..<(count ?? bytes.count)])) }
    }

    func final() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        crypto_generichash_final(OpaquePointer(state), &out, 32)
        return out
    }

    deinit {
        sodium_memzero(state, crypto_generichash_statebytes())
        state.deallocate()
    }
}

public enum VaultArchive {
    public static let fileExtension = "hashlock"
    static let magic = Array("HLARCH01".utf8)
    static let chunk = 1 << 20
    /// The most entries an archive may hold (a vault folder with every
    /// file it can have, and some).
    static let maxEntries = 2_000_000

    public struct Info: Sendable, Equatable {
        public let vaultID: UUID
        public let name: String
    }

    /// The paths of a vault's files, relative to its folder.
    static func isVaultPath(_ path: String) -> Bool {
        if ["header.json", "info.json", "catalog"].contains(path) { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "blobs", let id = BlobID(hex: String(parts[2])) else { return false }
        return parts[1] == id.hex.prefix(2)
    }

    // MARK: Writing

    /// Writes the vault in `root` to `url`. Called on the vault's actor, so
    /// no change is made to it meanwhile.
    static func write(vaultAt root: URL, to url: URL) throws {
        let fm = FileManager.default
        var paths = ["header.json", "info.json", "catalog"].filter { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
        let blobs = root.appendingPathComponent("blobs")
        for dir in ((try? fm.contentsOfDirectory(atPath: blobs.path)) ?? []).sorted() {
            for name in ((try? fm.contentsOfDirectory(atPath: blobs.appendingPathComponent(dir).path)) ?? []).sorted() {
                let p = "blobs/\(dir)/\(name)"
                if isVaultPath(p) { paths.append(p) }
            }
        }

        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError.io(AtomicWriter.errnoText("create \(url.lastPathComponent)")) }
        let hash = StreamHash()
        func put(_ bytes: UnsafeRawBufferPointer) throws {
            hash.update(bytes)
            var off = 0
            while off < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + off, bytes.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw VaultError.io(AtomicWriter.errnoText("write \(url.lastPathComponent)"))
                }
                off += n
            }
        }
        func put<T: FixedWidthInteger>(_ v: T) throws { try withUnsafeBytes(of: v.littleEndian) { try put($0) } }

        do {
            try magic.withUnsafeBytes { try put($0) }
            var buffer = [UInt8](repeating: 0, count: chunk)
            for p in paths {
                let reader = try FileReader(url: root.appendingPathComponent(p))
                let name = Array(p.utf8)
                try put(UInt16(name.count))
                try name.withUnsafeBytes { try put($0) }
                try put(reader.size)
                var left = reader.size
                while left > 0 {
                    let n = try buffer.withUnsafeMutableBytes { b in
                        try reader.read(into: UnsafeMutableRawBufferPointer(rebasing: b[0..<Int(min(UInt64(chunk), left))]))
                    }
                    guard n > 0 else { throw VaultError.io("A vault file changed while it was exported.") }
                    try buffer.withUnsafeBytes { try put(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                    left -= UInt64(n)
                }
            }
            try put(UInt16(0))
            let digest = hash.final()
            // The checksum itself is not hashed.
            var off = 0
            while off < digest.count {
                let n = digest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + off, $0.count - off) }
                if n < 0 { if errno == EINTR { continue }; throw VaultError.io(AtomicWriter.errnoText("write \(url.lastPathComponent)")) }
                off += n
            }
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
            close(fd)
        } catch {
            close(fd)
            unlink(url.path)
            throw error
        }
    }

    // MARK: Reading

    /// Reads the archive, checking its checksum and every path, and hands
    /// each file to `file` (nil: only check). Returns what the header says.
    @discardableResult
    static func read(_ url: URL, into dir: URL?) throws -> Info {
        let reader = try FileReader(url: url, followLinks: true)
        let hash = StreamHash()
        var consumed: UInt64 = 0
        func take(_ count: Int) throws -> [UInt8] {
            var b = [UInt8](repeating: 0, count: count)
            guard try b.withUnsafeMutableBytes({ try reader.read(into: $0) }) == count else { throw VaultError.damaged("archive cut short") }
            hash.update(b)
            consumed += UInt64(count)
            return b
        }
        func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
        }

        guard try take(magic.count) == magic else { throw VaultError.damaged("not a Hash Lock vault file") }
        var seen = Set<String>()
        var headerData: Data?
        var infoData: Data?
        var buffer = [UInt8](repeating: 0, count: chunk)
        while true {
            let nameLength = Int(try int(UInt16.self))
            if nameLength == 0 { break }
            guard seen.count < maxEntries else { throw VaultError.damaged("archive") }
            guard let path = String(bytes: try take(nameLength), encoding: .utf8), isVaultPath(path), seen.insert(path).inserted else {
                throw VaultError.damaged("archive path")
            }
            let size = try int(UInt64.self)
            guard size <= reader.size - consumed else { throw VaultError.damaged("archive cut short") }
            let small = path == "header.json" || path == "info.json"
            guard !small || size < 1 << 20 else { throw VaultError.damaged("archive") }

            var writer: AtomicWriter?
            if let dir {
                let target = dir.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                writer = try AtomicWriter(target: target)
            }
            var collected = Data()
            var left = size
            while left > 0 {
                let n = Int(min(UInt64(chunk), left))
                let got = try buffer.withUnsafeMutableBytes { try reader.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<n])) }
                guard got == n else { throw VaultError.damaged("archive cut short") }
                hash.update(buffer, count: n)
                consumed += UInt64(n)
                try buffer.withUnsafeBytes { try writer?.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                if small { collected.append(contentsOf: buffer[0..<n]) }
                left -= UInt64(n)
            }
            try writer?.commit()
            if path == "header.json" { headerData = collected }
            if path == "info.json" { infoData = collected }
        }
        let expected = hash.final()
        var stored = [UInt8](repeating: 0, count: 32)
        guard try stored.withUnsafeMutableBytes({ try reader.read(into: $0) }) == 32, stored == expected else {
            throw VaultError.damaged("archive checksum")
        }
        var extra: UInt8 = 0
        guard try withUnsafeMutableBytes(of: &extra, { try reader.read(into: $0) }) == 0 else { throw VaultError.damaged("archive") }

        guard let headerData, seen.contains("catalog") else { throw VaultError.damaged("archive without a vault") }
        let header = try VaultHeader.decode(headerData)
        let name = infoData.flatMap { try? JSONDecoder.iso.decode(VaultLibrary.Info.self, from: $0) }?.name ?? "Vault"
        return Info(vaultID: header.vaultID, name: name)
    }

    /// What a vault file holds, after checking all of it.
    public static func inspect(_ url: URL) throws -> Info {
        try read(url, into: nil)
    }
}

extension Vault {
    /// Writes this vault to one file, encrypted as it is.
    public func exportArchive(to url: URL) throws {
        guard Self.exists(at: root) else { throw VaultError.notFound }
        try VaultArchive.write(vaultAt: root, to: url)
    }

    /// The vault's own identity, from its header (without unlocking).
    public nonisolated static func vaultID(at root: URL) -> UUID? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("header.json")) else { return nil }
        return (try? VaultHeader.decode(data))?.vaultID
    }
}

extension VaultLibrary {
    /// The vault already here with the same identity as the archive's, if any.
    public func existing(_ info: VaultArchive.Info) -> VaultEntry? {
        list().first { Vault.vaultID(at: $0.directory) == info.vaultID }
    }

    /// Adds the vault in `url` as a new vault, or in place of `replacing`.
    /// It is unpacked beside the others first and moved into place only
    /// once all of it checks out.
    public func importArchive(_ url: URL, replacing: VaultEntry? = nil) throws -> VaultEntry {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw VaultError.io(error.localizedDescription)
        }
        let staging = root.appendingPathComponent("\(Self.importPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw VaultError.io(error.localizedDescription)
        }
        try VaultArchive.read(url, into: staging)
        try? fm.createDirectory(at: staging.appendingPathComponent("blobs"), withIntermediateDirectories: true)

        let id = replacing?.id ?? UUID()
        let target = root.appendingPathComponent(id.uuidString, isDirectory: true)
        if let replacing {
            // The vault being replaced must not be open, here or in another
            // copy of the app: a save still under way would land in the
            // imported folder.
            let lock = open(replacing.directory.appendingPathComponent(".lock").path,
                            O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard lock >= 0 else { throw VaultError.io(AtomicWriter.errnoText("open the vault")) }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw VaultError.inUse }
            // One step: a crash leaves the old vault or the new one.
            guard renamex_np(staging.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
                throw VaultError.io(AtomicWriter.errnoText("replace the vault"))
            }
            AtomicWriter.syncDirectory(root)
            // `staging` now holds the replaced vault, which goes.
            try? Vault.shred(staging)
        } else {
            do {
                try fm.moveItem(at: staging, to: target)
            } catch {
                throw VaultError.io(error.localizedDescription)
            }
        }
        guard let entry = list().first(where: { $0.id == id }) else { throw VaultError.damaged("imported vault") }
        return entry
    }
}
