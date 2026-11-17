import Clibsodium
import Foundation

/// Argon2id settings for turning a password into a key. They are stored in
/// the vault header next to the salt; the password itself, and anything
/// derived from it, is never stored.
public struct KDFParameters: Codable, Sendable, Hashable {
    public static let algorithm = "argon2id13"

    public var algorithm: String
    /// Passes over memory.
    public var opsLimit: UInt64
    /// Memory in bytes.
    public var memLimit: UInt64

    public init(opsLimit: UInt64, memLimit: UInt64) {
        algorithm = Self.algorithm
        self.opsLimit = opsLimit
        self.memLimit = memLimit
    }

    /// The strength levels offered in Settings.
    public enum Level: String, CaseIterable, Codable, Sendable, Identifiable {
        case standard, strong, maximum
        public var id: String { rawValue }

        public var parameters: KDFParameters {
            switch self {
            case .standard: KDFParameters(opsLimit: 3, memLimit: 256 << 20)
            case .strong: KDFParameters(opsLimit: 3, memLimit: 1 << 30)
            case .maximum: KDFParameters(opsLimit: 4, memLimit: 2 << 30)
            }
        }
    }

    public var level: Level? { Level.allCases.first { $0.parameters == self } }

    /// The weakest settings a vault may carry: a header edited to cheaper
    /// ones is refused rather than used.
    public static let minimum = KDFParameters(opsLimit: 2, memLimit: 64 << 20)
    /// The most a header may ask for, so a damaged or hostile one cannot
    /// make unlocking exhaust the Mac's memory.
    public static let maximum = KDFParameters(opsLimit: 32, memLimit: 4 << 30)

    public var isAcceptable: Bool {
        algorithm == Self.algorithm
            && (Self.minimum.opsLimit...Self.maximum.opsLimit).contains(opsLimit)
            && (Self.minimum.memLimit...Self.maximum.memLimit).contains(memLimit)
            && memLimit <= UInt64(Int.max)
    }
}

enum KeyDerivation {
    static let saltBytes = Int(crypto_pwhash_SALTBYTES)
    static let keyBytes = 32

    /// Argon2id(password, salt). Runs for about a second at the chosen
    /// level and takes its memory for that time; called on the vault's own
    /// queue, never on the main thread.
    static func derive(password: SecureBytes, salt: [UInt8], parameters: KDFParameters) throws -> SecureBytes {
        guard parameters.isAcceptable else { throw VaultError.unsupportedParameters }
        guard salt.count == saltBytes else { throw VaultError.damaged("salt") }
        let key = SecureBytes(count: keyBytes)
        let rc = key.withMutableBytes { out in
            password.withBytes { pw in
                pw.withMemoryRebound(to: CChar.self, capacity: max(password.length, 1)) { p in
                    crypto_pwhash(out, UInt64(keyBytes), p, UInt64(password.length),
                                  salt, parameters.opsLimit, Int(parameters.memLimit),
                                  crypto_pwhash_ALG_ARGON2ID13)
                }
            }
        }
        // The only failure for valid parameters is running out of memory.
        guard rc == 0 else { throw VaultError.notEnoughMemory }
        return key
    }
}

/// Subkeys of the master key, one per purpose, so no key is ever used for
/// two things.
enum Subkey: UInt64 {
    case catalog = 1
    case blobs = 2

    static let context = Array("HashLock".utf8)  // exactly crypto_kdf_CONTEXTBYTES

    func derive(from master: SecureBytes) -> SecureBytes {
        let key = SecureBytes(count: 32)
        key.withMutableBytes { out in
            master.withBytes { mk in
                Self.context.withUnsafeBufferPointer { ctx in
                    ctx.baseAddress!.withMemoryRebound(to: CChar.self, capacity: ctx.count) { c in
                        _ = crypto_kdf_derive_from_key(out, 32, rawValue, c, mk)
                    }
                }
            }
        }
        return key
    }
}
