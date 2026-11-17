import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VaultCore

/// The main window's content: setup, the lock screen or the vault.
public struct RootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .starting:
                Color.clear
            case .setup:
                SetupView(model: model)
            case .locked:
                LockView(model: model)
            case .unlocked:
                MainView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .toolbar {
            // Settings are reachable from the window too, not only from the
            // menu bar and ⌘,. The open vault puts the button after its own.
            if model.phase != .unlocked {
                ToolbarItem(placement: .primaryAction) { SettingsButton() }
            }
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(
            get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }
        ), presenting: model.notice) { _ in
            Button("OK") { model.notice = nil }
        } message: { n in
            Text(n.message)
        }
        .sheet(isPresented: $model.offerRecoveryKey) {
            OfferRecoverySheet(model: model)
        }
        .sheet(isPresented: $model.showNewVault) {
            SetupView(model: model, asSheet: true)
        }
        .confirmationDialog("“\(model.importConflict?.name ?? "")” is already on this Mac",
                            isPresented: Binding(get: { model.importConflict != nil },
                                                 set: { if !$0 { model.importConflict = nil } }),
                            presenting: model.importConflict) { c in
            Button("Replace", role: .destructive) {
                Task { await model.finishImport(c.url, replacing: c.existing) }
            }
            Button("Keep Both") {
                Task { await model.finishImport(c.url, replacing: nil) }
            }
        } message: { c in
            Text("Replace it with the copy in the file, or keep both? The file may be older: what was added to the vault here since it was made would be lost.")
        }
    }
}

struct SettingsButton: View {
    var body: some View {
        SettingsLink {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Settings (⌘,)")
    }
}

/// Open and Save panels for .hashlock files.
@MainActor
enum VaultFilePanels {
    static var type: UTType { UTType(filenameExtension: VaultArchive.fileExtension) ?? .data }

    static func importVault(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a Hash Lock vault file (.hashlock). It opens with that vault's password."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importVault(from: url) }
    }

    static func exportVault(model: AppModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(model.current?.name ?? "Vault").\(VaultArchive.fileExtension)"
        panel.canCreateDirectories = true
        panel.message = "The file stays encrypted and opens with this vault's password, on this Mac or another."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportVault(to: url) }
    }
}
