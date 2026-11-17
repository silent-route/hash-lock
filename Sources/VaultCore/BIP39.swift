import Clibsodium
import Foundation

/// BIP-39 mnemonics: entropy as words from a list of 2048, with a checksum
/// in the last word. Used for the vault's recovery key and to check the seed
/// words of a wallet backup for typos.
public enum BIP39 {
    public static let validWordCounts = [12, 15, 18, 21, 24]

    private static let index: [String: Int] = {
        var d = [String: Int]()
        for (i, w) in english.enumerated() { d[w] = i }
        return d
    }()

    public static func isWord(_ word: String) -> Bool { index[word] != nil }

    /// Words starting with `prefix`, for completion. Four letters always pick
    /// one word.
    public static func completions(for prefix: String, limit: Int = 8) -> [String] {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        return Array(english.lazy.filter { $0.hasPrefix(p) }.prefix(limit))
    }

    /// The mnemonic for 16–32 bytes of entropy (a multiple of 4).
    public static func mnemonic(entropy: [UInt8]) -> [String] {
        precondition(entropy.count % 4 == 0 && (16...32).contains(entropy.count))
        let checksumBits = entropy.count / 4
        var bits = [Bool]()
        for byte in entropy + [sha256(entropy)[0]] {
            for i in (0..<8).reversed() { bits.append(byte >> i & 1 == 1) }
        }
        let used = entropy.count * 8 + checksumBits
        return stride(from: 0, to: used, by: 11).map { start in
            english[bits[start..<start + 11].reduce(0) { $0 << 1 | ($1 ? 1 : 0) }]
        }
    }

    public enum Problem: Equatable, Sendable {
        case wrongCount(Int)
        /// Words not in the list, by position (0-based).
        case unknownWords([Int])
        case badChecksum
    }

    /// The entropy of a valid mnemonic, or what is wrong with it.
    public static func entropy(of words: [String]) -> Result<[UInt8], ProblemError> {
        let normalized = words.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        guard validWordCounts.contains(normalized.count) else { return .failure(.init(.wrongCount(normalized.count))) }
        let unknown = normalized.indices.filter { index[normalized[$0]] == nil }
        guard unknown.isEmpty else { return .failure(.init(.unknownWords(unknown))) }

        var bits = [Bool]()
        for w in normalized {
            let v = index[w]!
            for i in (0..<11).reversed() { bits.append(v >> i & 1 == 1) }
        }
        let checksumBits = bits.count / 33
        let entropyBits = bits.count - checksumBits
        var entropy = [UInt8](repeating: 0, count: entropyBits / 8)
        for i in 0..<entropyBits where bits[i] { entropy[i / 8] |= 1 << (7 - i % 8) }
        let expected = sha256(entropy)[0] >> (8 - checksumBits)
        let actual = bits[entropyBits...].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        guard expected == actual else {
            wipe(&entropy)
            return .failure(.init(.badChecksum))
        }
        return .success(entropy)
    }

    public struct ProblemError: Error, Equatable, Sendable {
        public let problem: Problem
        init(_ p: Problem) { problem = p }
    }

    /// Checks seed words without keeping the entropy.
    public static func validate(_ words: [String]) -> Problem? {
        switch entropy(of: words) {
        case .success(var e):
            wipe(&e)
            return nil
        case .failure(let f):
            return f.problem
        }
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        _ = Sodium.ready
        var out = [UInt8](repeating: 0, count: Int(crypto_hash_sha256_BYTES))
        crypto_hash_sha256(&out, bytes, UInt64(bytes.count))
        return out
    }
}
