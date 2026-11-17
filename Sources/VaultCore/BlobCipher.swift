import Clibsodium
import Foundation

/// What a blob is made from.
public enum BlobSource: Sendable {
    case data(Data)
    /// A file the user added; read in pieces, never whole into memory.
    case file(URL)
}

/// Encrypts one item's content into one file, in a stream of authenticated
/// pieces (libsodium's secretstream, XChaCha20-Poly1305), so a file of any
/// size passes through a 64 KiB buffer.
///
/// Layout (docs/format.md):
///
///     secretstream header                      24 bytes
///     message 0: "HLB1", 4 zero bytes, length   16 bytes + 17
///     content, then zeros up to the padded length, in 64 KiB messages;
///     the last one shorter (possibly empty) and tagged FINAL
///
/// Cutting the file short, reordering, dropping or altering any piece, or
/// moving it to another blob's name fails authentication (each blob has its
/// own key). The padding (Padmé) hides the exact size: what remains visible
/// is a size class with at most 12% overhead.
enum BlobCipher {
    static let chunk = 64 * 1024
    static let headerBytes = Int(crypto_secretstream_xchacha20poly1305_HEADERBYTES)
    static let aBytes = Int(crypto_secretstream_xchacha20poly1305_ABYTES)
    static let tagMessage = UInt8(crypto_secretstream_xchacha20poly1305_TAG_MESSAGE)
    static let tagFinal = UInt8(crypto_secretstream_xchacha20poly1305_TAG_FINAL)
    static let magic = Array("HLB1".utf8)
    static let minimumPadded: UInt64 = 512

    /// Padmé: rounds up to a size class that leaks O(log log n) bits.
    static func paddedLength(_ length: UInt64) -> UInt64 {
        let l = max(length, minimumPadded)
        let e = UInt64(63 - l.leadingZeroBitCount)            // floor(log2 l)
        let s = UInt64(64 - e.leadingZeroBitCount)            // floor(log2 e) + 1
        let mask: UInt64 = (1 << (e - s)) - 1
        return (l + mask) & ~mask
    }

    /// The size of the encrypted file for `length` bytes of content.
    static func encryptedSize(forContentLength length: UInt64) -> UInt64 {
        let padded = paddedLength(length)
        let c = UInt64(chunk)
        let full = padded / c
        return UInt64(headerBytes) + UInt64(16 + aBytes) + full * (c + UInt64(aBytes)) + (padded % c) + UInt64(aBytes)
    }

    // MARK: Encryption

    /// Returns the content length encrypted.
    @discardableResult
    static func encrypt(_ source: BlobSource, key: SecureBytes, to url: URL) throws -> UInt64 {
        switch source {
        case .data(let data):
            var offset = 0
            try encrypt(length: UInt64(data.count), key: key, to: url) { buf in
                let n = min(buf.count, data.count - offset)
                data.withUnsafeBytes { src in
                    buf.baseAddress!.copyMemory(from: src.baseAddress! + offset, byteCount: n)
                }
                offset += n
                return n
            }
            return UInt64(data.count)
        case .file(let file):
            let reader = try FileReader(url: file, followLinks: true)
            try encrypt(length: reader.size, key: key, to: url) { try reader.read(into: $0) }
            return reader.size
        }
    }

    /// `read` fills the buffer it is given and returns how much it wrote;
    /// fewer bytes than asked mean the end of the source.
    static func encrypt(length: UInt64, key: SecureBytes, to url: URL,
                        read: (UnsafeMutableRawBufferPointer) throws -> Int) throws {
        let writer = try AtomicWriter(target: url)
        var state = crypto_secretstream_xchacha20poly1305_state()
        defer { sodium_memzero(&state, MemoryLayout.size(ofValue: state)) }
        var header = [UInt8](repeating: 0, count: headerBytes)
        key.withBytes { k in _ = crypto_secretstream_xchacha20poly1305_init_push(&state, &header, k) }
        try header.withUnsafeBytes { try writer.write($0) }

        var plain = [UInt8](repeating: 0, count: chunk)
        var cipher = [UInt8](repeating: 0, count: chunk + aBytes)
        defer { wipe(&plain) }

        func push(_ count: Int, tag: UInt8) throws {
            var outLen: UInt64 = 0
            _ = crypto_secretstream_xchacha20poly1305_push(&state, &cipher, &outLen, plain, UInt64(count), nil, 0, tag)
            try cipher.withUnsafeBytes { try writer.write(UnsafeRawBufferPointer(rebasing: $0[0..<Int(outLen)])) }
        }

        // Message 0: what follows.
        plain.replaceSubrange(0..<4, with: magic)
        plain.replaceSubrange(4..<8, with: [0, 0, 0, 0])
        withUnsafeBytes(of: length.littleEndian) { plain.replaceSubrange(8..<16, with: $0) }
        try push(16, tag: tagMessage)

        var contentLeft = length
        var totalLeft = paddedLength(length)
        while true {
            let n = Int(min(UInt64(chunk), totalLeft))
            let fromContent = Int(min(UInt64(n), contentLeft))
            if fromContent > 0 {
                let got = try plain.withUnsafeMutableBytes {
                    try read(UnsafeMutableRawBufferPointer(rebasing: $0[0..<fromContent]))
                }
                guard got == fromContent else { throw VaultError.sourceChanged }
            }
            for i in fromContent..<n { plain[i] = 0 }
            contentLeft -= UInt64(fromContent)
            totalLeft -= UInt64(n)
            if n < chunk {
                try push(n, tag: tagFinal)
                break
            }
            try push(n, tag: tagMessage)
        }
        // A source that grew while it was read is refused, not cut short.
        var probe: UInt8 = 0
        guard try withUnsafeMutableBytes(of: &probe, { try read($0) }) == 0 else {
            throw VaultError.sourceChanged
        }
        try writer.commit()
    }

    // MARK: Decryption

    /// Decrypts the blob at `url`, handing its content to `sink` piece by
    /// piece. Nothing is passed on before its piece is authenticated, but a
    /// sink sees the first pieces before a later one fails; callers that
    /// write to a file delete it on error. Returns the content length.
    @discardableResult
    static func decrypt(from url: URL, key: SecureBytes,
                        start: (UInt64) throws -> Void = { _ in },
                        into sink: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        let reader = try BlobReader(url: url, key: key)
        try start(reader.length)
        var buffer = [UInt8](repeating: 0, count: chunk)
        defer { wipe(&buffer) }
        while true {
            let n = try buffer.withUnsafeMutableBytes { try reader.read(into: $0) }
            if n == 0 { break }
            try buffer.withUnsafeBytes { try sink(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
        return reader.length
    }

    /// The whole content in memory, for notes and for files small enough to
    /// show; the caller wipes it when done. Content over `limit` bytes is
    /// refused before anything is read.
    static func decryptData(from url: URL, key: SecureBytes, limit: UInt64 = .max) throws -> Data {
        var data = Data()
        do {
            try decrypt(from: url, key: key, start: { length in
                guard length <= limit else { throw VaultError.tooLarge }
                // Allocated once at full size, so growing it never leaves an
                // unwiped copy behind.
                data.reserveCapacity(Int(length))
            }, into: { data.append(contentsOf: $0) })
        } catch {
            wipe(&data)
            throw error
        }
        return data
    }
}

/// A blob's content, read in order: each 64 KiB message is authenticated
/// before any of it is handed out, and the end is reported only after the
/// FINAL message (padding included) has been checked. Reading from one
/// blob while encrypting into another re-encrypts it without the content
/// ever being on disk.
final class BlobReader {
    /// The content length, from the blob's first message.
    private(set) var length: UInt64 = 0
    private let file: FileReader
    private var state = crypto_secretstream_xchacha20poly1305_state()
    private var plain = [UInt8](repeating: 0, count: BlobCipher.chunk)
    private var cipher = [UInt8](repeating: 0, count: BlobCipher.chunk + BlobCipher.aBytes)
    private var contentLeft: UInt64 = 0
    private var totalLeft: UInt64 = 0
    private var finished = false
    /// The part of `plain` not handed out yet.
    private var pending = 0..<0

    init(url: URL, key: SecureBytes) throws {
        file = try FileReader(url: url)
        var header = [UInt8](repeating: 0, count: BlobCipher.headerBytes)
        guard try header.withUnsafeMutableBytes({ try file.read(into: $0) }) == BlobCipher.headerBytes else {
            throw VaultError.damaged("blob header")
        }
        let initOK = key.withBytes { k in crypto_secretstream_xchacha20poly1305_init_pull(&state, header, k) == 0 }
        guard initOK else { throw VaultError.damaged("blob header") }

        guard try pull(16) == BlobCipher.tagMessage, Array(plain[0..<4]) == BlobCipher.magic else {
            throw VaultError.damaged("blob format")
        }
        length = plain[8..<16].withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        // The file's size follows from the length; checking it first also
        // catches a length that is not what the writer wrote.
        guard file.size == BlobCipher.encryptedSize(forContentLength: length) else { throw VaultError.damaged("blob size") }
        contentLeft = length
        totalLeft = BlobCipher.paddedLength(length)
    }

    deinit {
        wipe(&plain)
        sodium_memzero(&state, MemoryLayout.size(ofValue: state))
    }

    /// Fills `out` with content and returns how much; fewer bytes than
    /// asked only at the end, once the whole blob has been authenticated.
    func read(into out: UnsafeMutableRawBufferPointer) throws -> Int {
        var written = 0
        while written < out.count {
            if pending.isEmpty {
                guard try nextMessage() else { break }
                continue
            }
            let n = min(pending.count, out.count - written)
            plain.withUnsafeBytes { p in
                out.baseAddress!.advanced(by: written).copyMemory(from: p.baseAddress! + pending.lowerBound, byteCount: n)
            }
            pending = (pending.lowerBound + n)..<pending.upperBound
            written += n
        }
        return written
    }

    /// Reads the next message; `false` once the FINAL one is behind.
    private func nextMessage() throws -> Bool {
        guard !finished else { return false }
        let n = Int(min(UInt64(BlobCipher.chunk), totalLeft))
        let tag = try pull(n)
        let isLast = n < BlobCipher.chunk
        guard tag == (isLast ? BlobCipher.tagFinal : BlobCipher.tagMessage) else { throw VaultError.damaged("blob order") }
        let content = Int(min(UInt64(n), contentLeft))
        pending = 0..<content
        contentLeft -= UInt64(content)
        totalLeft -= UInt64(n)
        finished = isLast
        return true
    }

    /// Reads and authenticates one message of `count` plaintext bytes.
    private func pull(_ count: Int) throws -> UInt8 {
        let want = count + BlobCipher.aBytes
        let got = try cipher.withUnsafeMutableBytes { try file.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<want])) }
        guard got == want else { throw VaultError.damaged("blob cut short") }
        var outLen: UInt64 = 0
        var tag: UInt8 = 0
        guard crypto_secretstream_xchacha20poly1305_pull(&state, &plain, &outLen, &tag, cipher, UInt64(want), nil, 0) == 0,
              outLen == UInt64(count) else {
            throw VaultError.damaged("blob authentication")
        }
        return tag
    }
}
