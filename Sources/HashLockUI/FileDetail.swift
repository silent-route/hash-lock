import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// A file item: what it is, a preview where Hash Lock can show one, and a
/// description.
struct FileDetail: View {
    @Bindable var model: AppModel
    let item: Item
    @State private var title = ""
    @State private var showPreview = false
    @FocusState private var titleFocused: Bool

    private var file: Attachment? { item.attachments.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let file {
                    header(file)
                    if file.isFolder {
                        FolderBrowser(model: model, folder: file)
                            .frame(height: 380)
                    } else if PreviewContent.canPreview(file) {
                        PreviewContent(model: model, attachment: file, limit: PreviewContent.inlineLimit)
                            .frame(height: 360)
                            .frame(maxWidth: .infinity)
                            .contentCard()
                            .onTapGesture(count: 2) { showPreview = true }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle("Description")
                    PlainTextView(text: textBinding, placeholder: "What this file is, where it came from, how to use it…")
                        .padding(10)
                        .contentCard()
                }
                FieldsSection(model: model, fields: fieldsBinding)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottom) { CopiedToast(clipboard: model.clipboard) }
        .sheet(isPresented: $showPreview) {
            if let file { PreviewSheet(model: model, attachment: file) }
        }
        .onAppear {
            title = item.title
            if model.focusTitle { titleFocused = true; model.focusTitle = false }
        }
        .onChange(of: item.id) { title = item.title }
        .onChange(of: model.focusTitle) { _, now in
            if now { titleFocused = true; model.focusTitle = false }
        }
    }

    private func header(_ file: Attachment) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: file.icon)
                .resizable()
                .frame(width: 64, height: 64)
                .overlay {
                    TileInteraction(model: model, attachment: file, onOpen: { showPreview = true }, menu: [
                        .init("Preview") { showPreview = true },
                        .init("Export…") { Task { await ExportPanel.run(file, model: model) } },
                    ])
                }
                .help("Drag to Finder to export")
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold))
                    .focused($titleFocused)
                    .onChange(of: title) { _, t in if t != item.title { model.titleEdited(item.id, t) } }
                Text("\(file.kindText) · \(file.sizeText)")
                    .foregroundStyle(.secondary)
                Text("Added \(file.added.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    Task { await ExportPanel.run(file, model: model) }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                if PreviewContent.canPreview(file) {
                    Button { showPreview = true } label: { Label("Preview", systemImage: "eye") }
                }
            }
        }
    }


    private var textBinding: Binding<String> {
        Binding(get: { model.draft?.text ?? "" }, set: { model.draft?.text = $0 })
    }

    private var fieldsBinding: Binding<[Field]> {
        Binding(get: { model.draft?.fields ?? [] }, set: { model.draft?.fields = $0 })
    }
}

/// A file shown from memory: images, PDFs and text. Nothing is written to
/// disk for it (Quick Look would need a file, so it is not used).
struct PreviewContent: View {
    let model: AppModel
    let attachment: Attachment
    let limit: UInt64

    static let inlineLimit: UInt64 = 64 << 20
    static let sheetLimit: UInt64 = 512 << 20
    static let textLimit: UInt64 = 8 << 20

    enum Loaded {
        case image(NSImage)
        case pdf(PDFDocument)
        case text(String)
    }

    @State private var loaded: Loaded?
    @State private var failure: String?

    static func kind(of a: Attachment) -> UTType? {
        guard let t = a.type else { return nil }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .text) || t.conforms(to: .sourceCode) || t.conforms(to: .json)
            || t.conforms(to: .xml) || t.conforms(to: .propertyList) { return .text }
        return nil
    }

    static func canPreview(_ a: Attachment) -> Bool {
        guard !a.isFolder, let k = kind(of: a) else { return false }
        return k == .text ? a.size <= textLimit : true
    }

    var body: some View {
        Group {
            switch loaded {
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            case .pdf(let doc):
                PDFViewer(document: doc)
            case .text(let s):
                ScrollView {
                    Text(s)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case nil:
                if let failure {
                    ContentUnavailableView("No Preview", systemImage: "eye.slash", description: Text(failure))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: attachment.blob) { await load() }
        .onDisappear { loaded = nil }
    }

    private func load() async {
        loaded = nil
        failure = nil
        do {
            var data = try await model.content(of: attachment, limit: limit)
            defer { wipe(&data) }
            switch Self.kind(of: attachment) {
            case .image?:
                if let img = NSImage(data: data) { loaded = .image(img) } else { failure = "The image could not be read." }
            case .pdf?:
                if let doc = PDFDocument(data: data) { loaded = .pdf(doc) } else { failure = "The PDF could not be read." }
            case .text?:
                loaded = .text(String(decoding: data, as: UTF8.self))
            default:
                failure = "Hash Lock cannot show this kind of file. Export it to open it."
            }
        } catch {
            failure = AppModel.describe(error)
        }
    }
}

struct PDFViewer: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.backgroundColor = .clear
        v.document = document
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document !== document { v.document = document }
    }

    static func dismantleNSView(_ v: PDFView, coordinator: ()) {
        v.document = nil
    }
}

/// A larger preview in a sheet, with Export.
struct PreviewSheet: View {
    let model: AppModel
    let attachment: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: attachment.icon).resizable().frame(width: 20, height: 20)
                Text(attachment.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(attachment.sizeText).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await ExportPanel.run(attachment, model: model) }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if PreviewContent.canPreview(attachment) {
                PreviewContent(model: model, attachment: attachment, limit: PreviewContent.sheetLimit)
            } else if attachment.isFolder {
                FolderBrowser(model: model, folder: attachment)
            } else {
                ContentUnavailableView("No Preview", systemImage: "eye.slash",
                                       description: Text("Hash Lock cannot show this kind of file. Export it to open it in another app."))
            }
        }
        .frame(minWidth: 640, idealWidth: 820, minHeight: 480, idealHeight: 640)
    }
}
