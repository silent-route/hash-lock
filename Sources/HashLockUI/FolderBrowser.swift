import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// An attached folder, listed as Finder lists one: disclosure triangles,
/// sortable columns (Name, Date Modified, Size, Kind), rows in alternating
/// colors and a status line. The listing comes from the decrypted catalog;
/// a file's content is decrypted only to preview or export it.
struct FolderBrowser: View {
    let model: AppModel
    let folder: Attachment
    @State private var sortOrder = [KeyPathComparator(\FolderEntry.name, comparator: .localizedStandard)]
    @State private var selection: FolderEntry.ID?
    @State private var preview: Attachment?
    @AppStorage("folderViewMode") private var mode = FolderViewMode.list

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $mode) {
                    ForEach(FolderViewMode.allCases) { m in
                        Image(systemName: m.symbol).help("View \(m.title)").tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()
            switch mode {
            case .icons:
                FolderIcons(model: model, name: folder.name, root: folder.folder ?? [])
            case .columns:
                FolderColumns(model: model, root: folder.folder ?? [])
            case .list:
                list
            }
            Divider()
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(.bar)
        }
        .sheet(item: $preview) { a in
            PreviewSheet(model: model, attachment: a)
        }
    }

    private var list: some View {
            Table(sorted(folder.folder ?? []), children: \.children, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { e in
                    Label {
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                            .help(e.linkTarget.map { "Points to \($0)" } ?? "")
                    } icon: {
                        Image(nsImage: e.icon).resizable().frame(width: 16, height: 16)
                    }
                }
                .width(min: 180, ideal: 300)
                TableColumn("Date Modified", value: \.sortDate) { e in
                    Text(e.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--")
                        .foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 170)
                TableColumn("Size", value: \.size) { e in
                    Text(e.isFolder || e.isLink ? "--" : ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Kind", value: \.kindText) { e in
                    Text(e.kindText).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 140)
            }
            // Full-width rectangular rows in alternating colors, as in
            // Finder's list view and Activity Monitor.
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: FolderEntry.ID.self) { ids in
                if let id = ids.first, let e = entry(id) {
                    if let target = e.linkTarget {
                        Text("Points to \(target)")
                        Divider()
                    }
                    if !e.isFolder, !e.isLink, PreviewContent.canPreview(e.asAttachment) {
                        Button("Preview") { preview = e.asAttachment }
                    }
                    Button("Export…") { Task { await ExportPanel.run(e.asAttachment, model: model) } }
                }
            } primaryAction: { ids in
                if let id = ids.first, let e = entry(id), !e.isFolder, !e.isLink { preview = e.asAttachment }
            }
    }

    /// "12 items, 4.2 MB" — counted at the top level, as Finder does.
    private var status: String {
        let n = folder.folder?.count ?? 0
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(folder.size), countStyle: .file)
        return "\(n) \(n == 1 ? "item" : "items"), \(folder.fileCount) \(folder.fileCount == 1 ? "file" : "files") in all, \(bytes)"
    }

    private func sorted(_ entries: [FolderEntry]) -> [FolderEntry] {
        entries.sorted(using: sortOrder).map { e in
            var e = e
            e.children = e.children.map(sorted)
            return e
        }
    }

    private func entry(_ id: FolderEntry.ID, in entries: [FolderEntry]? = nil) -> FolderEntry? {
        for e in entries ?? folder.folder ?? [] {
            if e.id == id { return e }
            if let found = entry(id, in: e.children ?? []) { return found }
        }
        return nil
    }
}

extension FolderEntry {
    var sortDate: Date { modified ?? .distantPast }

    var kindText: String {
        if isLink { return "Alias" }
        return isFolder ? "Folder" : typeIdentifier.flatMap(UTType.init)?.localizedDescription ?? "Document"
    }

    /// Finder's icon for the kind of file, from its type alone.
    var icon: NSImage {
        if isLink { return NSWorkspace.shared.icon(for: .aliasFile) }
        return NSWorkspace.shared.icon(for: isFolder ? .folder : typeIdentifier.flatMap(UTType.init) ?? .data)
    }
}

/// An attached folder in a window-sized sheet, with Export.
struct FolderSheet: View {
    let model: AppModel
    let folder: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(nsImage: folder.icon).resizable().frame(width: 20, height: 20)
                Text(folder.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(folder.sizeText).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await ExportPanel.run(folder, model: model) }
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            FolderBrowser(model: model, folder: folder)
        }
        .frame(minWidth: 680, idealWidth: 820, minHeight: 440, idealHeight: 560)
    }
}
