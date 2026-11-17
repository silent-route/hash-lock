import Clibsodium
import Foundation

public enum VaultError: Error, Equatable, Sendable {
    /// The password (or recovery phrase) does not open this vault.
    case wrongPassword
    /// The vault is locked; unlock it first.
    case locked
    /// No vault at this location.
    case notFound
    /// A vault already exists there.
    case alreadyExists
    /// The vault was made by a newer version of Hash Lock.
    case newerFormat(Int)
    /// A header asks for key derivation settings outside the accepted range.
    case unsupportedParameters
    /// Data failed authentication or is malformed: tampered with, cut short
    /// or damaged on disk. The associated text says which part.
    case damaged(String)
    /// Not enough memory for the key derivation.
    case notEnoughMemory
    /// A file changed while it was being added.
    case sourceChanged
    /// Too large to open in memory; export it instead.
    case tooLarge
    /// The vault is open in another copy of Hash Lock.
    case inUse
    /// A folder with more entries than one attachment may hold.
    case tooManyFiles(Int)
    /// An input/output error, with the system's description.
    case io(String)
}

/// The master key, wrapped (encrypted) by a key derived from a password or a
/// recovery phrase. Opening a slot is the password check: a wrong password
/// derives a different key, and the authentication tag does not verify.
struct KeySlot: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case password
        case recovery
    }

    var kind: Kind
    /// Present for password slots.
    var kdf: KDFParameters?
    var salt: Data
    var nonce: Data
    var wrappedKey: Data

    static let nonceBytes = Int(crypto_aead_xchacha20poly1305_ietf_NPUBBYTES)
    static let tagBytes = Int(crypto_aead_xchacha20poly1305_ietf_ABYTES)

    /// Everything the slot's encryption depends on besides the key: the
    /// vault, the slot's kind and its derivation settings. Changing any of
    /// them in the header makes the slot fail to open.
    static func associatedData(vaultID: UUID, kind: Kind, kdf: KDFParameters?, salt: Data) -> [UInt8] {
        var ad = Array("HashLock/slot/v1".utf8)
        ad.append(0)
        withUnsafeBytes(of: vaultID.uuid) { ad.append(contentsOf: $0) }
        ad.append(contentsOf: kind.rawValue.utf8)
        ad.append(0)
        ad.append(contentsOf: (kdf?.algorithm ?? "").utf8)
        ad.append(0)
        withUnsafeBytes(of: (kdf?.opsLimit ?? 0).littleEndian) { ad.append(contentsOf: $0) }
        withUnsafeBytes(of: (kdf?.memLimit ?? 0).littleEndian) { ad.append(contentsOf: $0) }
        ad.append(contentsOf: salt)
        return ad
    }

    /// Wraps `master` under `wrappingKey`.
    static func seal(master: SecureBytes, wrappingKey: SecureBytes, vaultID: UUID, kind: Kind,
                     kdf: KDFParameters?, salt: Data) -> KeySlot {
        let nonce = randomBytes(nonceBytes)
        let ad = associatedData(vaultID: vaultID, kind: kind, kdf: kdf, salt: salt)
        var out = [UInt8](repeating: 0, count: master.length + tagBytes)
        var outLen: UInt64 = 0
        master.withBytes { m in
            wrappingKey.withBytes { k in
                _ = crypto_aead_xchacha20poly1305_ietf_encrypt(
                    &out, &outLen, m, UInt64(master.length), ad, UInt64(ad.count), nil, nonce, k)
            }
        }
        return KeySlot(kind: kind, kdf: kdf, salt: salt, nonce: Data(nonce), wrappedKey: Data(out))
    }

    /// The master key, or `nil` when `wrappingKey` is not the right one (or
    /// the slot was altered: the two cannot be told apart, by design).
    func open(with wrappingKey: SecureBytes, vaultID: UUID) -> SecureBytes? {
        guard nonce.count == Self.nonceBytes, wrappedKey.count == 32 + Self.tagBytes else { return nil }
        let ad = Self.associatedData(vaultID: vaultID, kind: kind, kdf: kdf, salt: salt)
        let master = SecureBytes(count: 32)
        var len: UInt64 = 0
        let rc = master.withMutableBytes { m in
            wrappingKey.withBytes { k in
                wrappedKey.withUnsafeBytes { c in
                    nonce.withUnsafeBytes { n in
                        crypto_aead_xchacha20poly1305_ietf_decrypt(
                            m, &len, nil,
                            c.bindMemory(to: UInt8.self).baseAddress!, UInt64(c.count),
                            ad, UInt64(ad.count),
                            n.bindMemory(to: UInt8.self).baseAddress!, k)
                    }
                }
            }
        }
        return rc == 0 && len == 32 ? master : nil
    }
}

/// The vault's only unencrypted file: which format it is in, and the key
/// slots. It says nothing about what the vault holds.
struct VaultHeader: Codable, Sendable, Equatable {
    static let formatName = "Hash Lock Vault"
    /// Version 1: the layout described in docs/format.md.
    static let currentVersion = 1

    var format: String
    var version: Int
    var vaultID: UUID
    var slots: [KeySlot]

    init(vaultID: UUID, slots: [KeySlot]) {
        format = Self.formatName
        version = Self.currentVersion
        self.vaultID = vaultID
        self.slots = slots
    }

    var passwordSlot: KeySlot? { slots.first { $0.kind == .password } }
    var recoverySlot: KeySlot? { slots.first { $0.kind == .recovery } }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    static func decode(_ data: Data) throws -> VaultHeader {
        guard let h = try? JSONDecoder().decode(VaultHeader.self, from: data), h.format == formatName else {
            throw VaultError.damaged("header")
        }
        guard h.version <= currentVersion else { throw VaultError.newerFormat(h.version) }
        return h
    }
}
