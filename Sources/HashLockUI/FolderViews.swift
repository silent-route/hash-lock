import AppKit
import SwiftUI
import VaultCore

/// How an attached folder is shown, as Finder's View menu offers.
enum FolderViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns
    var id: String { rawValue }
    var title: String {
        switch self {
        case .icons: "as Icons"
        case .list: "as List"
        case .columns: "as Columns"
        }
    }
    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        }
    }
}

extension FolderEntry {
    static func byName(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// Finder's column view: each folder chosen opens its contents in a new
/// column to the right; a file chosen shows its preview and details in the
/// last column.
struct FolderColumns: View {
    let model: AppModel
    let root: [FolderEntry]
    /// The entry chosen in each column, left to right.
    @State private var path: [FolderEntry] = []
    @State private var preview: Attachment?

    private var columns: [[FolderEntry]] {
        var out = [root.sorted(by: FolderEntry.byName)]
        for e in path {
            guard let children = e.children else { break }
            out.append(children.sorted(by: FolderEntry.byName))
        }
        return out
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { i, entries in
                        column(i, entries)
                            .frame(width: 230)
                        Divider()
                    }
                    if let file = path.last, !file.isFolder {
                        FileInfoPane(model: model, entry: file, preview: $preview)
                            .frame(width: 260)
                            .id("info")
                    }
                    Color.clear.frame(width: 1).id("end")
                }
            }
            .onChange(of: path) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .trailing) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $preview) { a in PreviewSheet(model: model, attachment: a) }
    }

    private func column(_ i: Int, _ entries: [FolderEntry]) -> some View {
        List(selection: Binding<FolderEntry.ID?>(
            get: { i < path.count ? path[i].id : nil },
            set: { id in
                guard let id, let e = entries.first(where: { $0.id == id }) else { return }
                path = Array(path.prefix(i)) + [e]
            })) {
            ForEach(entries) { e in
                HStack(spacing: 6) {
                    Image(nsImage: e.icon).resizable().frame(width: 16, height: 16)
                    Text(e.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if e.isFolder {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(e.id)
                .listRowSeparator(.hidden)
                .contextMenu { FolderEntryMenu(model: model, entry: e, preview: $preview) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// The last column for a file: a preview where Hash Lock can show one, then
/// what Finder shows under it.
struct FileInfoPane: View {
    let model: AppModel
    let entry: FolderEntry
    @Binding var preview: Attachment?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                let a = entry.asAttachment
                if PreviewContent.canPreview(a) {
                    PreviewContent(model: model, attachment: a, limit: PreviewContent.inlineLimit)
                        .frame(height: 180)
                        .onTapGesture(count: 2) { preview = a }
                } else {
                    Image(nsImage: entry.icon).resizable().frame(width: 96, height: 96)
                }
                Text(entry.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(entry.kindText + (entry.isLink ? "" : " – " + ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Information").font(.callout.weight(.semibold))
                    if let target = entry.linkTarget {
                        InfoRow(label: "Points to", value: target)
                    }
                    InfoRow(label: "Modified",
                            value: entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    if PreviewContent.canPreview(a) {
                        Button("Preview") { preview = a }
                    }
                    Button("Export…") { Task { await ExportPanel.run(a, model: model) } }
                }
                .controlSize(.small)
            }
            .padding(14)
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}

/// The context menu of an entry inside a folder, in every view.
struct FolderEntryMenu: View {
    let model: AppModel
    let entry: FolderEntry
    @Binding var preview: Attachment?

    var body: some View {
        if let target = entry.linkTarget {
            Text("Points to \(target)")
            Divider()
        }
        if !entry.isFolder, !entry.isLink, PreviewContent.canPreview(entry.asAttachment) {
            Button("Preview") { preview = entry.asAttachment }
        }
        Button("Export…") { Task { await ExportPanel.run(entry.asAttachment, model: model) } }
    }
}

/// Finder's icon view, one folder at a time: double-click opens a folder,
/// the path bar above goes back up.
struct FolderIcons: View {
    let model: AppModel
    let name: String
    let root: [FolderEntry]
    @State private var trail: [FolderEntry] = []
    @State private var selected: FolderEntry.ID?
    @State private var preview: Attachment?

    private var current: [FolderEntry] {
        (trail.last?.children ?? root).sorted(by: FolderEntry.byName)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The path, as Finder's path bar: each part goes back to it.
            HStack(spacing: 4) {
                Button(name) { trail = []; selected = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(trail.isEmpty ? .primary : .secondary)
                ForEach(Array(trail.enumerated()), id: \.element.id) { i, e in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(e.name) { trail = Array(trail.prefix(i + 1)); selected = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == trail.count - 1 ? .primary : .secondary)
                }
                Spacer()
            }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 8)], spacing: 8) {
                    ForEach(current) { e in
                        VStack(spacing: 4) {
                            Image(nsImage: e.icon).resizable().frame(width: 56, height: 56)
                                .padding(4)
                                .background(selected == e.id ? Color.primary.opacity(0.1) : .clear,
                                            in: .rect(cornerRadius: 6))
                            Text(e.name)
                                .font(.callout)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .truncationMode(.middle)
                                .padding(.horizontal, 4)
                                .foregroundStyle(selected == e.id ? Color.white : .primary)
                                .background(selected == e.id ? Color.accentColor : .clear, in: .rect(cornerRadius: 4))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { open(e) }
                        .onTapGesture { selected = e.id }
                        .contextMenu { FolderEntryMenu(model: model, entry: e, preview: $preview) }
                    }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(item: $preview) { a in PreviewSheet(model: model, attachment: a) }
    }

    private func open(_ e: FolderEntry) {
        if e.isFolder {
            trail.append(e)
            selected = nil
        } else if !e.isLink, PreviewContent.canPreview(e.asAttachment) {
            preview = e.asAttachment
        }
    }
}
