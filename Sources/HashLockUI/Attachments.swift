import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// The files attached to a note: tiles to preview, export, rename, remove or
/// drag out to Finder.
struct AttachmentsSection: View {
    let model: AppModel
    let item: Item
    @State private var preview: Attachment?
    @State private var browsing: Attachment?
    @State private var renaming: Attachment?
    @State private var newName = ""
    @State private var removing: Attachment?
    @State private var selected: UUID?
    @AppStorage(Preferences.attachmentsAsListKey) private var asList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Files")
                Spacer()
                if !item.attachments.isEmpty {
                    Picker("View", selection: $asList) {
                        Image(systemName: "square.grid.2x2").help("As Icons").tag(false)
                        Image(systemName: "list.bullet").help("As List").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("View files as")
                }
                Button {
                    model.addFilesTarget = .attach(item.id)
                } label: {
                    Label("Add Files…", systemImage: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach files: choose, drop or paste them")
            }
            if item.attachments.isEmpty {
                Text("Drop files on this note to attach them.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .contentCard()
            } else if asList {
                AttachmentList(attachments: item.attachments, selected: selected) { a in interaction(a) }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 10)], spacing: 10) {
                    ForEach(item.attachments) { a in
                        AttachmentTile(attachment: a)
                            .background(selected == a.id ? Color.accentColor.opacity(0.18) : .clear,
                                        in: .rect(cornerRadius: 8))
                            .overlay { interaction(a) }
                    }
                }
                .padding(10)
                .contentCard()
            }
        }
        .sheet(item: $preview) { a in
            PreviewSheet(model: model, attachment: a)
        }
        .sheet(item: $browsing) { a in
            FolderSheet(model: model, folder: a)
        }
        .onChange(of: item.id) { selected = nil }
        .alert("Rename File", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let a = renaming { Task { await model.renameAttachment(a, of: item.id, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let a = removing { Task { await model.removeAttachment(a, of: item.id) } }
                removing = nil
            }
        } message: {
            Text("The file is deleted from the vault. This cannot be undone.")
        }
    }
}

/// Files as a list, the way Finder shows one: columns, and rows in
/// alternating colors.
struct AttachmentList<Interaction: View>: View {
    let attachments: [Attachment]
    let selected: UUID?
    @ViewBuilder let interaction: (Attachment) -> Interaction

    private static var rowColors: [Color] {
        NSColor.alternatingContentBackgroundColors.map { Color(nsColor: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Kind").frame(width: 150, alignment: .leading)
                Text("Size").frame(width: 70, alignment: .trailing)
                Text("Date Added").frame(width: 150, alignment: .leading).padding(.leading, 16)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ForEach(Array(attachments.enumerated()), id: \.element.id) { i, a in
                let isSelected = selected == a.id
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(nsImage: a.icon).resizable().frame(width: 16, height: 16)
                        Text(a.name).lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(a.kindText)
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                    Text(a.bytesText)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 70, alignment: .trailing)
                    Text(a.added.formatted(date: .abbreviated, time: .shortened))
                        .lineLimit(1)
                        .frame(width: 150, alignment: .leading)
                        .padding(.leading, 16)
                }
                .font(.callout)
                .foregroundStyle(isSelected ? Color.white : .primary)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(isSelected ? Color.accentColor : Self.rowColors[i % Self.rowColors.count])
                .overlay { interaction(a) }
                .accessibilityElement(children: .combine)
            }
        }
        // Square corners with a hairline, as a bordered table is drawn:
        // stripes running edge to edge don't sit well in a rounded box.
        .overlay(Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

extension AttachmentsSection {
    func open(_ a: Attachment) {
        if a.isFolder { browsing = a } else { preview = a }
    }

    /// Clicks, the menu and dragging out, the same in both views.
    func interaction(_ a: Attachment) -> TileInteraction {
        TileInteraction(
            model: model, attachment: a,
            onSelect: { selected = a.id },
            onOpen: { open(a) },
            menu: [
                .init(a.isFolder ? "Open" : "Preview") { open(a) },
                .init("Export…") { Task { await ExportPanel.run(a, model: model) } },
                .init("Rename…") { newName = a.name; renaming = a },
                .separator,
                .init("Remove…") { removing = a },
            ])
    }
}

struct AttachmentTile: View {
    let attachment: Attachment

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: attachment.icon)
                .resizable()
                .frame(width: 44, height: 44)
            Text(attachment.name)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(attachment.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 108)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Mouse handling for a tile, in AppKit: a double click opens it, a right
/// click shows its menu, and a drag hands Finder a file promise. With a
/// promise, the decrypted file is written straight to where it is dropped;
/// nothing goes through a temporary file.
struct TileInteraction: NSViewRepresentable {
    struct MenuEntry {
        var title: String?
        var action: (() -> Void)?
        init(_ title: String, action: @escaping () -> Void) {
            self.title = title
            self.action = action
        }
        private init() {}
        static var separator: MenuEntry { MenuEntry() }
    }

    let model: AppModel
    let attachment: Attachment
    var onSelect: () -> Void = {}
    let onOpen: () -> Void
    let menu: [MenuEntry]

    func makeNSView(context: Context) -> TileView {
        let v = TileView()
        v.setAccessibilityElement(false)
        return v
    }

    func updateNSView(_ v: TileView, context: Context) {
        v.model = model
        v.attachment = attachment
        v.onSelect = onSelect
        v.onOpen = onOpen
        v.entries = menu
    }

    @MainActor
    final class TileView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
        var model: AppModel?
        var attachment: Attachment?
        var onSelect: (() -> Void)?
        var onOpen: (() -> Void)?
        var entries: [MenuEntry] = []
        private var downEvent: NSEvent?

        override func mouseDown(with event: NSEvent) {
            downEvent = event
            onSelect?()
            if event.clickCount == 2 { onOpen?() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = downEvent, let a = attachment,
                  Preferences.defaults.bool(forKey: Preferences.allowDragOutKey) else { return }
            let d = hypot(event.locationInWindow.x - down.locationInWindow.x,
                          event.locationInWindow.y - down.locationInWindow.y)
            guard d > 4 else { return }
            downEvent = nil
            let type = a.isFolder ? UTType.folder.identifier : a.typeIdentifier ?? UTType.data.identifier
            let provider = NSFilePromiseProvider(fileType: type, delegate: self)
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = a.icon
            item.setDraggingFrame(NSRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44), contents: icon)
            beginDraggingSession(with: [item], event: down, source: self)
        }

        override func mouseUp(with event: NSEvent) { downEvent = nil }

        override func menu(for event: NSEvent) -> NSMenu? {
            onSelect?()
            let m = NSMenu()
            for e in entries {
                if let title = e.title, let action = e.action {
                    m.addItem(ClosureMenuItem(title: title, action: action))
                } else {
                    m.addItem(.separator())
                }
            }
            return m
        }

        nonisolated func draggingSession(_ session: NSDraggingSession,
                                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }

        nonisolated func filePromiseProvider(_ p: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            MainActor.assumeIsolated { attachment?.name ?? "File" }
        }

        nonisolated func filePromiseProvider(_ p: NSFilePromiseProvider, writePromiseTo url: URL,
                                             completionHandler: @escaping @Sendable (Error?) -> Void) {
            Task { @MainActor in
                guard let model, let a = attachment else {
                    completionHandler(VaultError.locked)
                    return
                }
                do {
                    try await model.write(a, to: url)
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

/// Exporting to a file the user names.
enum ExportPanel {
    @MainActor
    static func run(_ a: Attachment, model: AppModel) async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = a.name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "The file is saved decrypted. Anyone with access to where you save it can read it."
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        await model.export(a, to: url)
    }
}

/// Adding files: drop them, paste them with ⌘V, or choose them.
struct AddFilesSheet: View {
    let model: AppModel
    let target: AppModel.AddTarget
    @Environment(\.dismiss) private var dismiss
    @State private var targeted = false
    @State private var nothingToPaste = false

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                Text("Drop Files or Folders Here")
                    .font(.title3.weight(.medium))
                Text("or press ⌘V to paste files or an image")
                    .foregroundStyle(.secondary)
                if nothingToPaste {
                    Text("The clipboard holds no files or images.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 400, height: 200)
            .background(targeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03),
                        in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.18),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task {
                    let files = await Imports.load(providers)
                    finish(files)
                }
                return true
            }
            Text("Files are encrypted as they are added. The originals stay where they are; delete them yourself if they should exist only in Hash Lock.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(width: 400)
            HStack {
                Button("Choose Files…", action: choose)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // ⌘V while the sheet is open.
                Button("Paste", action: paste)
                    .keyboardShortcut("v", modifiers: .command)
            }
        }
        .padding(20)
    }

    private var title: String {
        switch target {
        case .newItems: "Add Files"
        case .attach(let id): "Attach Files to “\(model.items.first { $0.id == id }?.title ?? "Note")”"
        }
    }

    private func paste() {
        let files = Imports.fromPasteboard()
        if files.isEmpty {
            nothingToPaste = true
        } else {
            finish(files)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        finish(panel.urls.map(Imports.file))
    }

    private func finish(_ files: [FileImport]) {
        guard !files.isEmpty else { return }
        dismiss()
        Task {
            switch target {
            case .newItems: await model.addFiles(files)
            case .attach(let id): await model.attach(files, to: id)
            }
        }
    }
}
