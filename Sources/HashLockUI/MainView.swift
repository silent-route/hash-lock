import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// The unlocked vault: the item list on the left, the open item on the right.
struct MainView: View {
    @Bindable var model: AppModel
    @AppStorage(Preferences.sortOrderKey) private var sort = Preferences.sortOrderDefault
    @State private var confirmDelete: Set<UUID>?
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            detail
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.lock() } label: {
                    Label("Lock", systemImage: "lock")
                }
                .help("Lock Hash Lock (⌘L)")
            }
            ToolbarItem(placement: .primaryAction) { SettingsButton() }
        }
        .sheet(item: $model.addFilesTarget) { target in
            AddFilesSheet(model: model, target: target)
        }
        .sheet(isPresented: $model.mustSetPassword) {
            ChangePasswordSheet(model: model, reset: true)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let ids = confirmDelete { Task { await model.delete(ids) } }
                confirmDelete = nil
            }
        } message: {
            Text("Its text and files are removed from the vault. This cannot be undone.")
        }
        .onChange(of: sort) { model.sortChanged() }
        .onChange(of: model.deleteRequest) { _, ids in
            if let ids { confirmDelete = ids; model.deleteRequest = nil }
        }
    }

    private var deleteTitle: String {
        guard let ids = confirmDelete else { return "" }
        if ids.count == 1, let item = model.items.first(where: { ids.contains($0.id) }) {
            return "Delete “\(item.title)”?"
        }
        return "Delete \(ids.count) items?"
    }

    // MARK: Sidebar

    /// Pinned items first, under a header of their own, as in Notes. A
    /// click on a header closes the open item; a right-click or a
    /// double-click on an empty part of the list makes a new one.
    private var sidebar: some View {
        List(selection: $model.selection) {
            let visible = model.visibleItems
            let pinned = visible.filter(\.pinned)
            let rest = visible.filter { !$0.pinned }
            if !pinned.isEmpty {
                Section {
                    rows(pinned)
                } header: {
                    ListHeader(title: "Pinned", model: model) { newItemsMenu }
                }
            }
            if !rest.isEmpty {
                Section {
                    rows(rest)
                } header: {
                    ListHeader(title: model.filter.title, model: model) { newItemsMenu }
                }
            }
        }
        .listStyle(.sidebar)
        // Room between the search field and the first row's highlight.
        .safeAreaPadding(.top, 6)
        .searchable(text: $model.search, placement: .sidebar, prompt: "Search Names")
        .overlay {
            if model.items.isEmpty {
                EmptyVault(model: model)
            } else if model.visibleItems.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.isEmpty { newItemsMenu } else { itemMenu(ids) }
        } primaryAction: { ids in
            if ids.isEmpty { Task { await model.newNote() } }
        }
        .onDeleteCommand {
            if let id = model.selection { confirmDelete = [id] }
        }
        .onExitCommand { model.selection = nil }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .pdf]) { _ in
            let files = Imports.fromPasteboard()
            Task { await model.addFiles(files) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { await model.addFiles(await Imports.load(providers)) }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.adding > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.adding == 1 ? "Encrypting…" : "Encrypting \(model.adding) items…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VaultPicker(model: model)
            }
            ToolbarItem {
                Menu {
                    Picker("Show", selection: $model.filter) {
                        ForEach(AppModel.Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Sort By", selection: $sort) {
                        ForEach(Preferences.SortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("View Options", systemImage: model.filter == .all
                          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Show and sort")
            }
            // Next to the list it adds to, as Notes has it.
            ToolbarItem { addMenu }
        }
    }

    private func rows(_ items: [Item]) -> some View {
        ForEach(items) { item in
            ItemRow(item: item)
                .tag(item.id)
        }
    }

    /// What can be added: the empty part of the list, its headers and the
    /// + button offer the same.
    @ViewBuilder
    private var newItemsMenu: some View {
        Button { Task { await model.newNote() } } label: {
            Label("New Note", systemImage: "note.text.badge.plus")
        }
        Button { Task { await model.newWallet() } } label: {
            Label("New Crypto Wallet", systemImage: Item.walletSymbol)
        }
        Divider()
        Button { model.addFilesTarget = .newItems } label: {
            Label("Add Files…", systemImage: "doc.badge.plus")
        }
    }

    @ViewBuilder
    private func itemMenu(_ ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
            Button(item.pinned ? "Unpin" : "Pin to Top") { Task { await model.togglePin(id) } }
            Button("Rename") {
                model.selection = id
                model.focusTitle = true
            }
            if item.kind == .file, let a = item.attachments.first {
                Button("Export…") { Task { await ExportPanel.run(a, model: model) } }
            }
            Divider()
        }
        if !ids.isEmpty {
            Button("Delete…", role: .destructive) { confirmDelete = ids }
        }
    }

    private var addMenu: some View {
        Menu {
            newItemsMenu
        } label: {
            Label("Add", systemImage: "plus")
        }
        .help("Add a note, a wallet or files")
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let item = model.selectedItem {
            if model.openFailed == item.id {
                ContentUnavailableView("Can’t Open “\(item.title)”", systemImage: "exclamationmark.triangle",
                                       description: Text("Part of it is damaged or was changed outside Hash Lock. Settings › Vault › Verify checks the whole vault."))
            } else if model.draft != nil {
                switch item.kind {
                case .note, .wallet: NoteEditor(model: model, item: item)
                case .file: FileDetail(model: model, item: item)
                }
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !model.items.isEmpty {
            ContentUnavailableView {
                Label("No Item Selected", systemImage: "lock.doc")
            } description: {
                Text("Choose an item in the list, or double-click an empty part of it for a new note.")
            } actions: {
                Button("New Note") { Task { await model.newNote() } }
            }
        }
    }
}

struct ItemRow: View {
    let item: Item

    var body: some View {
        Label {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if item.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }
        } icon: {
            Image(systemName: item.symbol)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let date = item.modified.formatted(.relative(presentation: .named))
        switch item.kind {
        case .file:
            return [item.attachments.first?.sizeText, date].compactMap { $0 }.joined(separator: " · ")
        case .note:
            let n = item.attachments.count
            return n == 0 ? date : "\(date) · \(n) \(n == 1 ? "file" : "files")"
        case .wallet:
            return "Wallet · \(date)"
        }
    }
}

/// A section header of the item list. Clicking it closes the open item, so
/// the list stays and the right side is left empty; a right-click offers
/// what can be added.
struct ListHeader<MenuItems: View>: View {
    let title: String
    let model: AppModel
    @ViewBuilder let menu: () -> MenuItems

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { model.selection = nil }
            .contextMenu { menu() }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Closes the open item")
    }
}

/// An empty vault: what can be put in it, and how.
struct EmptyVault: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("The Vault Is Empty")
                .font(.headline)
            Text("Drop files here, paste them with ⌘V, or create a note with ⌘N or a double-click.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 200)
            Button("New Note") { Task { await model.newNote() } }
                .controlSize(.small)
        }
        .padding()
    }
}
