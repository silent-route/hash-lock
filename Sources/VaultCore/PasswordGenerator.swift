import Foundation

/// Random passwords and passphrases, from the system's CSPRNG with no
/// modulo bias.
public enum PasswordGenerator {
    public struct Options: Codable, Sendable, Equatable {
        public enum Style: String, Codable, Sendable, CaseIterable, Identifiable {
            /// Letters, digits and symbols.
            case characters
            /// Words from the BIP-39 list, joined by hyphens.
            case words
            public var id: String { rawValue }
        }

        public var style: Style = .characters
        public var length = 20
        public var symbols = true
        public var digits = true
        /// Leaves out characters easily confused: 0 O o, 1 l I.
        public var avoidAmbiguous = true
        public var wordCount = 6

        public init() {}
    }

    static let lower = Array("abcdefghijklmnopqrstuvwxyz")
    static let upper = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    static let digitChars = Array("0123456789")
    static let symbolChars = Array("!#$%&*+-=?@^_~.,:;")
    static let ambiguous = Set("0Oo1lI")

    public static func generate(_ o: Options) -> String {
        switch o.style {
        case .words:
            return (0..<max(o.wordCount, 3)).map { _ in
                BIP39.english[Int(randomUniform(UInt32(BIP39.english.count)))]
            }.joined(separator: "-")
        case .characters:
            var classes = [lower, upper]
            if o.digits { classes.append(digitChars) }
            if o.symbols { classes.append(symbolChars) }
            if o.avoidAmbiguous { classes = classes.map { $0.filter { !ambiguous.contains($0) } } }
            let all = classes.flatMap { $0 }
            let length = max(o.length, classes.count)
            // One from each class, so every kind asked for is present, then
            // the rest from all of them, then shuffled.
            var chars = classes.map { pick($0) }
            while chars.count < length { chars.append(pick(all)) }
            for i in stride(from: chars.count - 1, to: 0, by: -1) {
                chars.swapAt(i, Int(randomUniform(UInt32(i + 1))))
            }
            return String(chars)
        }
    }

    private static func pick(_ set: [Character]) -> Character {
        set[Int(randomUniform(UInt32(set.count)))]
    }

    /// The entropy in bits the options give, as shown next to the generator.
    public static func entropyBits(_ o: Options) -> Double {
        switch o.style {
        case .words:
            return Double(max(o.wordCount, 3)) * log2(Double(BIP39.english.count))
        case .characters:
            var n = 52.0
            if o.digits { n += 10 }
            if o.symbols { n += Double(symbolChars.count) }
            if o.avoidAmbiguous { n -= Double(o.digits ? 6 : 4) }
            return Double(o.length) * log2(n)
        }
    }
}

/// Random user names, for a new account.
public enum LoginGenerator {
    public enum Style: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Two words and two digits: "orbit.lemon42". Easy to read out.
        case words
        /// Twelve letters and digits, starting with a letter: "k7rmq2x9fh3t".
        case random
        public var id: String { rawValue }
    }

    public static func generate(_ style: Style) -> String {
        switch style {
        case .words:
            let w = (0..<2).map { _ in BIP39.english[Int(randomUniform(UInt32(BIP39.english.count)))] }
            return w.joined(separator: ".") + String(format: "%02u", randomUniform(100))
        case .random:
            let letters = Array("abcdefghjkmnpqrstuvwxyz")
            let all = letters + Array("23456789")
            var out = [letters[Int(randomUniform(UInt32(letters.count)))]]
            while out.count < 12 { out.append(all[Int(randomUniform(UInt32(all.count)))]) }
            return String(out)
        }
    }
}

/// A rough strength estimate for the vault password: it counts the kinds of
/// characters and penalizes repetition and short length. It is a guide for
/// the person typing, not a guarantee; a passphrase of several random words
/// is the advice.
public enum PasswordStrength: Int, Sendable, Comparable {
    case veryWeak, weak, fair, strong, veryStrong

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    public static func estimate(_ password: String) -> PasswordStrength {
        let chars = Array(password)
        guard !chars.isEmpty else { return .veryWeak }
        var pool = 0.0
        if chars.contains(where: \.isLowercase) { pool += 26 }
        if chars.contains(where: \.isUppercase) { pool += 26 }
        if chars.contains(where: \.isNumber) { pool += 10 }
        if chars.contains(where: { !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) { pool += 32 }
        if chars.contains(where: \.isWhitespace) { pool += 1 }
        if chars.contains(where: { !$0.isASCII }) { pool += 64 }
        // Repeated characters add little: count distinct ones more.
        let distinct = Double(Set(chars).count)
        let effective = min(Double(chars.count), distinct * 1.5)
        let bits = effective * log2(max(pool, 2))
        switch bits {
        case ..<36: return .veryWeak
        case ..<52: return .weak
        case ..<68: return .fair
        case ..<90: return .strong
        default: return .veryStrong
        }
    }
}
