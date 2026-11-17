import Darwin
import Foundation

/// Writes a file so that it is either entirely the old version or entirely
/// the new one, even across a crash or power loss: the data goes to a
/// temporary file beside it (owner-only), is flushed to the disk itself
/// (`F_FULLFSYNC`, not just the drive's cache), and is renamed over the
/// target; the directory is then flushed too.
final class AtomicWriter {
    let target: URL
    private let temp: URL
    private var fd: Int32
    private var committed = false

    init(target: URL) throws {
        self.target = target
        temp = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).tmp")
        fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VaultError.io(Self.errnoText("create \(target.lastPathComponent)")) }
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw VaultError.io(Self.errnoText("write \(target.lastPathComponent)"))
            }
            offset += n
        }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    func commit() throws {
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else {
            throw VaultError.io(Self.errnoText("flush \(target.lastPathComponent)"))
        }
        close(fd)
        fd = -1
        guard rename(temp.path, target.path) == 0 else {
            throw VaultError.io(Self.errnoText("save \(target.lastPathComponent)"))
        }
        committed = true
        Self.syncDirectory(target.deletingLastPathComponent())
    }

    deinit {
        if fd >= 0 { close(fd) }
        if !committed { unlink(temp.path) }
    }

    static func write(_ data: Data, to url: URL) throws {
        let w = try AtomicWriter(target: url)
        try w.write(data)
        try w.commit()
    }

    static func syncDirectory(_ dir: URL) {
        let d = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard d >= 0 else { return }
        if fcntl(d, F_FULLFSYNC) != 0 { fsync(d) }
        close(d)
    }

    static func errnoText(_ what: String) -> String {
        "Could not \(what): \(String(cString: strerror(errno)))"
    }
}

/// Reads a file in pieces. The vault's own files are opened without
/// following a symbolic link in their place; a file the user adds may be one.
final class FileReader {
    private let fd: Int32
    let size: UInt64

    init(url: URL, followLinks: Bool = false) throws {
        fd = open(url.path, O_RDONLY | O_CLOEXEC | (followLinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            throw errno == ENOENT ? VaultError.damaged("missing file") : VaultError.io(AtomicWriter.errnoText("open \(url.lastPathComponent)"))
        }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw VaultError.io("Not a regular file: \(url.lastPathComponent)")
        }
        size = UInt64(st.st_size)
    }

    /// Fills `buffer` as far as the file allows; returns the bytes read
    /// (fewer only at the end of the file).
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        var total = 0
        while total < buffer.count {
            let n = Darwin.read(fd, buffer.baseAddress! + total, buffer.count - total)
            if n < 0 {
                if errno == EINTR { continue }
                throw VaultError.io(AtomicWriter.errnoText("read"))
            }
            if n == 0 { break }
            total += n
        }
        return total
    }

    deinit { close(fd) }
}
