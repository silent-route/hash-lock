import Foundation

/// The name of an encrypted blob on disk: 128 random bits, in hex. It says
/// nothing about the content.
public struct BlobID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let hex: String

    public init() {
        hex = randomBytes(16).map { String(format: "%02x", $0) }.joined()
    }

    init?(hex: String) {
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.hex = hex
    }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let id = BlobID(hex: s) else { throw VaultError.damaged("catalog") }
        self = id
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public var description: String { hex }
}

/// What the sidebar lists. Encrypted as one blob; it holds titles and file
/// names (so they can be searched) but no note text and no file content.
public struct Catalog: Codable, Sendable, Equatable {
    public var version = 1
    public var items: [Item] = []
    /// Blobs this version of the catalog let go of, removed right after it
    /// is saved. A crash before they are gone leaves the list here, and the
    /// next unlock finishes the job. Nothing else is ever removed on its
    /// own: a blob the catalog does not know (an older catalog put back,
    /// say) may be the only copy of something, so it is kept.
    public var retired: [BlobID]?

    public init(items: [Item] = []) { self.items = items }

    /// Every blob the catalog refers to.
    public var blobIDs: Set<BlobID> {
        var ids = Set<BlobID>()
        for item in items {
            if let b = item.body { ids.insert(b) }
            for a in item.attachments { ids.formUnion(a.blobs) }
        }
        return ids
    }
}

public struct Item: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Text, fields and attached files.
        case note
        /// A file on its own, with a description.
        case file
        /// A crypto wallet backup: seed words, passphrase and the rest.
        case wallet
    }

    public let id: UUID
    public var kind: Kind
    public var title: String
    public var created: Date
    public var modified: Date
    public var pinned: Bool
    /// The encrypted `NoteBody`; `nil` while it is empty.
    public var body: BlobID?
    /// For a `.file` item, the first attachment is the file itself.
    public var attachments: [Attachment]

    public init(kind: Kind, title: String, date: Date = Date()) {
        id = UUID()
        self.kind = kind
        self.title = title
        created = date
        modified = date
        pinned = false
        body = nil
        attachments = []
    }
}

/// A file attached to an item, or a whole folder.
public struct Attachment: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    /// A file's size, or the total of a folder's files.
    public var size: UInt64
    /// The uniform type identifier, for the icon and the viewer.
    public var typeIdentifier: String?
    public var added: Date
    /// A file's encrypted content; `nil` for a folder.
    public var blob: BlobID?
    /// A folder's contents; `nil` for a file. Each file inside is a blob of
    /// its own, so one can be shown or exported without the others.
    public var folder: [FolderEntry]?
    /// A symbolic link from inside a folder, shown or exported on its own.
    public var linkTarget: String?

    public init(name: String, size: UInt64, typeIdentifier: String?, blob: BlobID, added: Date = Date()) {
        id = UUID()
        self.name = name
        self.size = size
        self.typeIdentifier = typeIdentifier
        self.added = added
        self.blob = blob
        folder = nil
    }

    public init(folderNamed name: String, contents: [FolderEntry], added: Date = Date()) {
        id = UUID()
        self.name = name
        size = contents.reduce(0) { $0 + $1.size }
        typeIdentifier = "public.folder"
        self.added = added
        blob = nil
        folder = contents
    }

    public var isFolder: Bool { folder != nil }
    public var isLink: Bool { linkTarget != nil }

    /// Any of the three kinds, for entries taken out of a folder.
    init(name: String, size: UInt64, typeIdentifier: String?, added: Date,
         blob: BlobID?, folder: [FolderEntry]?, linkTarget: String?) {
        id = UUID()
        self.name = name
        self.size = size
        self.typeIdentifier = typeIdentifier
        self.added = added
        self.blob = blob
        self.folder = folder
        self.linkTarget = linkTarget
    }

    /// Every blob it is made of.
    public var blobs: [BlobID] {
        if let blob { return [blob] }
        return (folder ?? []).flatMap(\.blobs)
    }

    /// Files inside a folder, at any depth.
    public var fileCount: Int { (folder ?? []).reduce(0) { $0 + $1.fileCount } }
}

/// A file or folder inside an attached folder, as Finder lists it.
public struct FolderEntry: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String
    public var modified: Date?
    /// A file's size, or the total of a folder's files.
    public var size: UInt64
    public var typeIdentifier: String?
    /// A file's encrypted content.
    public var blob: BlobID?
    /// A folder's contents; `nil` for a file.
    public var children: [FolderEntry]?
    /// A symbolic link: the path it points to, kept as it was (not followed).
    public var linkTarget: String?

    public init(file name: String, size: UInt64, modified: Date?, typeIdentifier: String?, blob: BlobID) {
        id = UUID()
        self.name = name
        self.size = size
        self.modified = modified
        self.typeIdentifier = typeIdentifier
        self.blob = blob
        children = nil
    }

    public init(folder name: String, modified: Date?, children: [FolderEntry]) {
        id = UUID()
        self.name = name
        self.modified = modified
        size = children.reduce(0) { $0 + $1.size }
        typeIdentifier = "public.folder"
        blob = nil
        self.children = children
    }

    public init(link name: String, target: String, modified: Date?) {
        id = UUID()
        self.name = name
        self.modified = modified
        size = 0
        typeIdentifier = "public.symlink"
        blob = nil
        children = nil
        linkTarget = target
    }

    public var isFolder: Bool { children != nil }
    public var isLink: Bool { linkTarget != nil }

    public var blobs: [BlobID] {
        if let blob { return [blob] }
        return (children ?? []).flatMap(\.blobs)
    }

    public var fileCount: Int {
        if let children { return children.reduce(0) { $0 + $1.fileCount } }
        return blob != nil ? 1 : 0
    }

    /// The entry as an attachment of its own, to show or export it.
    public var asAttachment: Attachment {
        Attachment(name: name, size: size, typeIdentifier: typeIdentifier, added: modified ?? Date(),
                   blob: blob, folder: children, linkTarget: linkTarget)
    }
}

/// An item's content, decrypted only while the item is open.
public struct NoteBody: Codable, Sendable, Equatable {
    public var text: String
    public var fields: [Field]
    public var wallet: WalletBackup?

    public init(text: String = "", fields: [Field] = [], wallet: WalletBackup? = nil) {
        self.text = text
        self.fields = fields
        self.wallet = wallet
    }

    public var isEmpty: Bool { text.isEmpty && fields.isEmpty && wallet == nil }
}

/// A labeled value above the note's text: a login, a password, a server's
/// address. Secret kinds are shown as dots until revealed.
public struct Field: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case login, password, address, url, text, secret
        public var id: String { rawValue }

        public var isSecret: Bool { self == .password || self == .secret }

        public var defaultLabel: String {
            switch self {
            case .login: "Login"
            case .password: "Password"
            case .address: "IP Address"
            case .url: "Website"
            case .text: "Text"
            case .secret: "Secret"
            }
        }
    }

    public let id: UUID
    public var kind: Kind
    public var label: String
    public var value: String
    /// Shown as dots until revealed. `nil` follows the kind: passwords and
    /// secrets are hidden, everything else shown.
    public var concealed: Bool?

    public var isConcealed: Bool { concealed ?? kind.isSecret }

    public init(kind: Kind, label: String? = nil, value: String = "") {
        id = UUID()
        self.kind = kind
        self.label = label ?? kind.defaultLabel
        self.value = value
    }
}

/// A crypto wallet's backup, in whichever form its software uses. The coin
/// chooses which seed formats and details are offered; everything typed is
/// kept when it changes.
public struct WalletBackup: Codable, Sendable, Equatable {
    public enum Coin: String, Codable, Sendable, CaseIterable, Identifiable {
        case bitcoin, monero, other
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .bitcoin: "Bitcoin"
            case .monero: "Monero"
            case .other: "Other"
            }
        }

        public var formats: [SeedFormat] {
            switch self {
            case .bitcoin: [.bip39, .electrum, .slip39, .aezeed, .other]
            case .monero: [.monero, .polyseed, .other]
            case .other: [.bip39, .slip39, .other]
            }
        }
    }

    public enum SeedFormat: String, Codable, Sendable, CaseIterable, Identifiable {
        /// BIP-39: 12, 15, 18, 21 or 24 words with a checksum.
        case bip39
        /// Electrum's own seeds (12 words, version in the hash).
        case electrum
        /// SLIP-39 (Shamir) shares: 20 or 33 words each, as Trezor makes.
        case slip39
        /// LND's aezeed: 24 words.
        case aezeed
        /// Monero's own seed: 25 words (the last a checksum) from Monero's
        /// list, or 13 from the old MyMonero.
        case monero
        /// Polyseed: 16 words from the BIP-39 list, as Feather and Cake make.
        case polyseed
        case other
        public var id: String { rawValue }

        public var name: String {
            switch self {
            case .bip39: "BIP-39"
            case .electrum: "Electrum"
            case .slip39: "SLIP-39 Share"
            case .aezeed: "aezeed (LND)"
            case .monero: "Monero"
            case .polyseed: "Polyseed"
            case .other: "Other"
            }
        }

        public var wordCounts: [Int] {
            switch self {
            case .bip39: [12, 15, 18, 21, 24]
            case .electrum: [12, 13]
            case .slip39: [20, 33]
            case .aezeed: [24]
            case .monero: [25, 13]
            case .polyseed: [16]
            case .other: [12, 13, 15, 16, 18, 20, 21, 24, 25, 33]
            }
        }

        /// Formats whose words come from the BIP-39 English list.
        public var usesBIP39Words: Bool { [.bip39, .electrum, .aezeed, .polyseed].contains(self) }
    }

    public var coin: Coin
    public var format: SeedFormat
    public var words: [String]
    /// The optional passphrase (BIP-39's, or Monero's seed offset).
    public var passphrase: String
    public var software: String
    public var derivationPath: String
    /// xpub/ypub/zpub, to watch a Bitcoin wallet without the seed.
    public var extendedPublicKey: String
    /// A receiving address: Monero's primary address, or another coin's.
    public var address: String
    /// Monero's private view key: shows incoming payments, spends nothing.
    public var viewKey: String
    /// Monero's private spend key: as powerful as the seed.
    public var spendKey: String
    /// When the wallet was made, or its first block (Monero's restore
    /// height), to speed up a rescan.
    public var birthday: String

    public init(coin: Coin = .bitcoin, format: SeedFormat = .bip39, wordCount: Int = 12) {
        self.coin = coin
        self.format = format
        words = Array(repeating: "", count: wordCount)
        passphrase = ""
        software = ""
        derivationPath = ""
        extendedPublicKey = ""
        address = ""
        viewKey = ""
        spendKey = ""
        birthday = ""
    }

    /// Wallets saved before there was a choice of coin are Bitcoin ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coin = try c.decodeIfPresent(Coin.self, forKey: .coin) ?? .bitcoin
        format = try c.decode(SeedFormat.self, forKey: .format)
        words = try c.decode([String].self, forKey: .words)
        passphrase = try c.decodeIfPresent(String.self, forKey: .passphrase) ?? ""
        software = try c.decodeIfPresent(String.self, forKey: .software) ?? ""
        derivationPath = try c.decodeIfPresent(String.self, forKey: .derivationPath) ?? ""
        extendedPublicKey = try c.decodeIfPresent(String.self, forKey: .extendedPublicKey) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        viewKey = try c.decodeIfPresent(String.self, forKey: .viewKey) ?? ""
        spendKey = try c.decodeIfPresent(String.self, forKey: .spendKey) ?? ""
        birthday = try c.decodeIfPresent(String.self, forKey: .birthday) ?? ""
    }
}
