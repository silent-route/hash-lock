import AppKit
import Observation

/// Notices when a newer Hash Lock has been copied over this one while it
/// runs (Finder replaces the bundle, the running copy goes on as it was),
/// and offers to relaunch: the vault is locked, the old copy quits and the
/// new one starts. The vault is kept apart from the app, so nothing else is
/// needed.
@MainActor @Observable
public final class UpdateWatcher {
    /// The version on disk, when it differs from the running one.
    public private(set) var newVersion: String?
    private let running: String
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?

    public init() {
        running = Self.build(of: Bundle.main.bundleURL) ?? ""
    }

    public func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func check() {
        let url = Bundle.main.bundleURL
        guard let build = Self.build(of: url), build != running else { return }
        newVersion = Self.info(of: url)?["HLVersion"] as? String ?? build
    }

    public func relaunch(model: AppModel) {
        let url = Bundle.main.bundleURL
        Task {
            await model.lockForQuit()
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            config.activates = true
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                NSApp.terminate(nil)
            } catch {
                model.show(error, title: "Hash Lock could not relaunch")
            }
        }
    }

    /// Read from disk, not from `Bundle`, which keeps what it loaded at launch.
    private static func info(of bundle: URL) -> [String: Any]? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private static func build(of bundle: URL) -> String? {
        guard let i = info(of: bundle) else { return nil }
        return "\(i["HLVersion"] as? String ?? "")+\(i["CFBundleVersion"] as? String ?? "")"
    }
}
