import SwiftUI
import VaultCore

/// The sheets, for ui-snapshots to render; the app opens them itself.
public enum SheetGallery {
    @MainActor
    public static func folder(model: AppModel, folder: Attachment) -> AnyView {
        AnyView(FolderSheet(model: model, folder: folder))
    }

    @MainActor
    public static func all(model: AppModel) -> [(String, AnyView)] {
        [
            ("new-vault", AnyView(SetupView(model: model, asSheet: true))),
            ("change-password", AnyView(ChangePasswordSheet(model: model))),
            ("reset-password", AnyView(ChangePasswordSheet(model: model, reset: true))),
            ("recovery-key", AnyView(RecoveryKeySheet(words: BIP39.mnemonic(entropy: [UInt8](repeating: 0x7f, count: 32))))),
            ("offer-recovery", AnyView(OfferRecoverySheet(model: model))),
            ("recovery-unlock", AnyView(RecoveryUnlockSheet(model: model))),
            ("delete-vault", AnyView(DeleteSheet(model: model, actions: AppActions { _ in }, mode: .deleteVault))),
            ("uninstall", AnyView(DeleteSheet(model: model, actions: AppActions { _ in }, mode: .uninstall))),
            ("add-files", AnyView(AddFilesSheet(model: model, target: .newItems))),
            ("export-warning", AnyView(ExportWarningSheet {})),
        ] + model.items.flatMap(\.attachments).filter(\.isFolder).prefix(1).map {
            ("folder", AnyView(FolderSheet(model: model, folder: $0).frame(width: 820, height: 520)))
        }
    }
}
