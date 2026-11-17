import Clibsodium
import Foundation

/// libsodium needs one call to `sodium_init` before anything else; it is
/// thread-safe and idempotent, and a static `let` runs it exactly once.
enum Sodium {
    static let ready: Void = {
        precondition(sodium_init() >= 0, "libsodium failed to initialize")
    }()
}

/// Key material in guarded memory: allocated with `sodium_malloc` (locked
/// so it is never swapped out, fenced by guard pages, with a canary that
/// traps on underflow) and wiped when freed.
///
/// Only keys and passwords live here. Swift strings and `Data` can be copied
/// by the runtime and cannot be wiped reliably, so key material never takes
/// that form.
public final class SecureBytes: @unchecked Sendable {
    // @unchecked: the buffer is written only while being filled, before the
    // value is shared, and freed only in deinit.
    private let pointer: UnsafeMutableRawPointer
    /// The allocation's size.
    let count: Int
    /// The number of meaningful bytes: `count`, or 0 for an empty password
    /// (which still needs a non-empty allocation).
    public let length: Int

    /// A zeroed buffer of `count` bytes.
    public convenience init(count: Int) {
        self.init(allocating: count, length: count)
    }

    private init(allocating count: Int, length: Int) {
        _ = Sodium.ready
        precondition(count > 0 && length <= count)
        guard let p = sodium_malloc(count) else {
            fatalError("out of memory for key material")
        }
        sodium_memzero(p, count)
        pointer = p
        self.count = count
        self.length = length
    }

    /// A copy of `bytes`; the caller wipes its own copy.
    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        self.init(allocating: max(bytes.count, 1), length: bytes.count)
        if let base = bytes.baseAddress, bytes.count > 0 {
            pointer.copyMemory(from: base, byteCount: bytes.count)
        }
    }

    /// The UTF-8 bytes of a password, in Unicode canonical composition, so
    /// "é" typed one way or another derives the same key.
    public convenience init(password: String) {
        var utf8 = Array(password.precomposedStringWithCanonicalMapping.utf8)
        defer { utf8.withUnsafeMutableBytes { sodium_memzero($0.baseAddress, $0.count) } }
        self.init(allocating: max(utf8.count, 1), length: utf8.count)
        if !utf8.isEmpty { pointer.copyMemory(from: utf8, byteCount: utf8.count) }
    }

    public static func random(count: Int) -> SecureBytes {
        let b = SecureBytes(count: count)
        randombytes_buf(b.pointer, count)
        return b
    }

    deinit {
        // sodium_free wipes the buffer before releasing it.
        sodium_free(pointer)
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: pointer, count: length))
    }

    func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeMutableRawBufferPointer(start: pointer, count: count))
    }

    /// Typed access for the C API, which takes `unsigned char *`.
    func withBytes<R>(_ body: (UnsafePointer<UInt8>) throws -> R) rethrows -> R {
        try body(pointer.assumingMemoryBound(to: UInt8.self))
    }

    func withMutableBytes<R>(_ body: (UnsafeMutablePointer<UInt8>) throws -> R) rethrows -> R {
        try body(pointer.assumingMemoryBound(to: UInt8.self))
    }

    /// Constant-time comparison.
    public func isEqual(to other: SecureBytes) -> Bool {
        length == other.length && sodium_memcmp(pointer, other.pointer, length) == 0
    }
}

/// Random bytes from the system's CSPRNG.
public func randomBytes(_ count: Int) -> [UInt8] {
    _ = Sodium.ready
    var b = [UInt8](repeating: 0, count: count)
    randombytes_buf(&b, count)
    return b
}

/// A uniformly distributed integer in 0..<bound.
public func randomUniform(_ bound: UInt32) -> UInt32 {
    _ = Sodium.ready
    return randombytes_uniform(bound)
}

/// Wipes a buffer in a way the compiler cannot optimize away.
public func wipe(_ data: inout Data) {
    data.withUnsafeMutableBytes { sodium_memzero($0.baseAddress, $0.count) }
}

public func wipe(_ bytes: inout [UInt8]) {
    bytes.withUnsafeMutableBytes { sodium_memzero($0.baseAddress, $0.count) }
}

/// The libsodium release built in, for About.
public var sodiumVersion: String {
    String(cString: sodium_version_string())
}
