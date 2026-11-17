import AppKit
import Observation

/// Copies values to the clipboard the way password managers should:
///
/// - marked with the nspasteboard.org types for concealed and transient
///   content, which clipboard history apps (Raycast, Paste, Maccy, Alfred…)
///   honor by not recording it;
/// - optionally kept off Universal Clipboard, so it does not reach the
///   iPhone or other Macs;
/// - cleared after the time set in Settings, but only if it is still what
///   Hash Lock put there.
@MainActor @Observable
public final class Clipboard {
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let source = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// The pasteboard's change count after our last copy.
    private var ours: Int?
    private var clearTask: Task<Void, Never>?
    /// What was copied last, for the "Copied" label.
    public private(set) var lastCopiedLabel: String?
    /// Counts copies, so the label shows again for the same value.
    public private(set) var copyCount = 0

    public init() {}

    public func copy(_ value: String, label: String, secret: Bool) {
        let pb = NSPasteboard.general
        if Preferences.defaults.bool(forKey: Preferences.clipboardLocalOnlyKey) {
            pb.prepareForNewContents(with: .currentHostOnly)
        } else {
            pb.clearContents()
        }
        pb.setString(value, forType: .string)
        if secret {
            pb.setString("", forType: Self.concealed)
            pb.setString("", forType: Self.transient)
        }
        pb.setString(Bundle.main.bundleIdentifier ?? "org.hashlock.app", forType: Self.source)
        ours = pb.changeCount
        lastCopiedLabel = label
        copyCount += 1
        scheduleClear()
    }

    /// Clears the clipboard if it still holds what Hash Lock copied.
    public func clearIfOurs() {
        clearTask?.cancel()
        clearTask = nil
        lastCopiedLabel = nil
        guard let ours, NSPasteboard.general.changeCount == ours else {
            self.ours = nil
            return
        }
        NSPasteboard.general.clearContents()
        self.ours = nil
    }

    private func scheduleClear() {
        clearTask?.cancel()
        let seconds = Preferences.defaults.integer(forKey: Preferences.clipboardClearKey)
        guard seconds > 0 else { return }
        clearTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            clearIfOurs()
        }
    }
}
