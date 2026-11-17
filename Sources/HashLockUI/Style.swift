import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

extension View {
    /// A group in the content layer, drawn as System Settings draws its
    /// grouped sections: a light fill and a hairline.
    func contentCard(cornerRadius: CGFloat = 10) -> some View {
        background(Color.primary.opacity(0.035), in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

extension Text {
    /// A form section's footer, as System Settings sets it: secondary, and
    /// aligned with the rows above.
    func formFooter() -> some View {
        foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The side-to-side shake of the macOS login window for a wrong password.
struct Shake: GeometryEffect {
    var travel: CGFloat = 8
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(animatableData * .pi * 4), y: 0))
    }
}

struct AppIcon: View {
    var size: CGFloat = 96
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension Item {
    /// A wallet's symbol: the folded wallet where the system has it.
    static var walletSymbol: String {
        if #available(macOS 15, *) { "wallet.bifold" } else { "wallet.pass" }
    }

    /// The sidebar's symbol.
    var symbol: String {
        switch kind {
        case .note: "note.text"
        case .wallet: Item.walletSymbol
        case .file: attachments.first.map { $0.symbol } ?? "doc"
        }
    }
}

extension Attachment {
    var type: UTType? { typeIdentifier.flatMap(UTType.init) }

    var symbol: String {
        if isFolder { return "folder" }
        guard let t = type else { return "doc" }
        if t.conforms(to: .image) { return "photo" }
        if t.conforms(to: .pdf) { return "doc.richtext" }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return "film" }
        if t.conforms(to: .audio) { return "waveform" }
        if t.conforms(to: .archive) { return "doc.zipper" }
        if t.conforms(to: .sourceCode) || t.conforms(to: .script) { return "chevron.left.forwardslash.chevron.right" }
        if t.conforms(to: .text) { return "doc.text" }
        if t.conforms(to: .x509Certificate) || t.identifier.contains("key") { return "key" }
        return "doc"
    }

    /// The file's icon as Finder shows it, from its type alone (nothing is
    /// written to disk to get it).
    var icon: NSImage {
        NSWorkspace.shared.icon(for: isFolder ? .folder : type ?? .data)
    }

    /// The size alone, for a list's Size column.
    var bytesText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    var sizeText: String {
        let bytes = bytesText
        guard isFolder else { return bytes }
        let n = fileCount
        return "\(n) \(n == 1 ? "file" : "files") · \(bytes)"
    }

    var kindText: String {
        isFolder ? "Folder" : type?.localizedDescription ?? "Document"
    }
}

extension Field.Kind {
    var symbol: String {
        switch self {
        case .login: "person"
        case .password: "key"
        case .address: "network"
        case .url: "link"
        case .text: "text.alignleft"
        case .secret: "lock"
        }
    }
}

/// A file dropped, pasted or picked, ready for the vault.
enum Imports {
    /// A file, or a folder with everything in it.
    static func file(_ url: URL) -> FileImport {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true {
            return FileImport(name: url.lastPathComponent, typeIdentifier: UTType.folder.identifier, source: .folder(url))
        }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        return FileImport(name: url.lastPathComponent, typeIdentifier: type?.identifier, source: .file(url))
    }

    /// Whatever the pasteboard holds that can become a file: file URLs
    /// first, then an image (a screenshot copied with ⌃⇧⌘4), then a PDF.
    @MainActor
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [FileImport] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map(file)
        }
        let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        if let png = pb.data(forType: .png) {
            return [FileImport(name: "Pasted Image \(stamp).png", typeIdentifier: UTType.png.identifier, source: .data(png))]
        }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [FileImport(name: "Pasted Image \(stamp).png", typeIdentifier: UTType.png.identifier, source: .data(png))]
        }
        if let pdf = pb.data(forType: .pdf) {
            return [FileImport(name: "Pasted Document \(stamp).pdf", typeIdentifier: UTType.pdf.identifier, source: .data(pdf))]
        }
        return []
    }

    @MainActor
    static func pasteboardHasFiles(_ pb: NSPasteboard = .general) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.availableType(from: [.png, .tiff, .pdf]) != nil
    }

    /// File URLs from a drop.
    static func load(_ providers: [NSItemProvider]) async -> [FileImport] {
        var out: [FileImport] = []
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { cont in
                _ = p.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
            }
            if let url { out.append(file(url)) }
        }
        return out
    }
}
