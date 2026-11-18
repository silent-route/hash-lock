import AppKit
import Darwin
import HashLockUI
import ServiceManagement
import SwiftUI
import VaultCore

// The app: a normal window plus a menu bar control. The window and the
// status item are AppKit-owned (SwiftUI inside), so the window can be
// brought back from the menu bar whatever state SwiftUI's scenes are in.
// Quitting always locks the vault first.

@main
struct HashLockMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model, actions: delegate.actions)
        }
        .commands {
            VaultCommands(model: delegate.model, showMain: { delegate.showMainWindow() })
        }
    }
}

struct VaultCommands: Commands {
    let model: AppModel
    let showMain: () -> Void

    var body: some Commands {
        let open = model.phase == .unlocked
        CommandGroup(replacing: .newItem) {
            Button("New Note") { run { await model.newNote() } }
                .keyboardShortcut("n")
                .disabled(!open)
            Button("New Crypto Wallet") { run { await model.newWallet() } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!open)
            Button("Add Files…") {
                showMain()
                model.addFilesTarget = .newItems
            }
            .keyboardShortcut("o")
            .disabled(!open)
            Divider()
            // No ⌘⌫: in a text field it deletes to the start of the line.
            // The sidebar takes the Delete key itself.
            Button("Delete…") {
                if let id = model.selection { model.deleteRequest = [id] }
            }
            .disabled(!open || model.selection == nil)
            Divider()
            Button("Lock") { model.lock() }
                .keyboardShortcut("l")
                .disabled(!open)
        }
        CommandGroup(before: .sidebar) {
            Picker("Show", selection: Binding(get: { model.filter }, set: { model.filter = $0 })) {
                Text("All Items").keyboardShortcut("1").tag(AppModel.Filter.all)
                Text("Notes").keyboardShortcut("2").tag(AppModel.Filter.notes)
                Text("Files").keyboardShortcut("3").tag(AppModel.Filter.files)
                Text("Wallets").keyboardShortcut("4").tag(AppModel.Filter.wallets)
            }
            .pickerStyle(.inline)
            .disabled(!open)
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button("Hash Lock") { showMain() }
                .keyboardShortcut("0")
            Divider()
        }
        // No help pages: Hash Lock has no network access to show them with.
        CommandGroup(replacing: .help) {}
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        showMain()
        Task { await body() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel.standard()
    private(set) lazy var autoLock = AutoLock(model: model)
    private let update = UpdateWatcher()
    private var statusItem: NSStatusItem?
    private var panel: StatusPanel?
    private var statusClicks: Any?
    private var mainWindow: NSWindow?
    private var quitting = false
    private var observers: [NSObjectProtocol] = []

    lazy var actions = AppActions { [weak self] withData in
        await self?.uninstall(withData: withData)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One copy at a time. A copy that is quitting (Relaunch to Update)
        // gets a few seconds; one that stays is brought forward instead.
        if let id = Bundle.main.bundleIdentifier {
            let me = ProcessInfo.processInfo.processIdentifier
            let deadline = Date().addingTimeInterval(4)
            while let other = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0.processIdentifier != me && !$0.isTerminated }) {
                if Date() > deadline {
                    other.activate()
                    exit(0)
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
        }
        Preferences.register()
        // No core dumps: one would hold whatever was in memory.
        var none = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &none)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        autoLock.start()
        update.start()
        watchPreferences()
        Task {
            await model.start()
            if Preferences.defaults.bool(forKey: Preferences.openWindowAtLaunchKey) || model.phase == .setup {
                showMainWindow()
            }
            applyDockPolicy()
        }
        // Unlocking starts the idle clock afresh.
        observePhase()
    }

    /// A .hashlock file opened from Finder: imported once the app is ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { $0.pathExtension.lowercased() == VaultArchive.fileExtension }
        guard !files.isEmpty else { return }
        Task {
            while model.phase == .starting { try? await Task.sleep(for: .milliseconds(50)) }
            showMainWindow()
            for url in files { await model.importVault(from: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    /// The open edit is saved and the vault locked before the app goes;
    /// never longer than a few seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting { return .terminateNow }
        quitting = true
        panel?.dismiss()
        let reply = OneShot { sender.reply(toApplicationShouldTerminate: true) }
        Task {
            await model.lockForQuit()
            reply.fire()
        }
        Task {
            try? await Task.sleep(for: .seconds(5))
            reply.fire()
        }
        return .terminateLater
    }

    /// The panel may have been opened again while the vault was locking;
    /// closing it ends its menu tracking, so the menu bar over a full-screen
    /// app is not left held in place.
    func applicationWillTerminate(_ notification: Notification) {
        panel?.dismiss()
    }

    // MARK: Main window

    func showMainWindow() {
        panel?.dismiss()
        if mainWindow == nil {
            let host = NSHostingController(rootView: RootView(model: model))
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: host)
            w.title = "Hash Lock"
            // Named in the Window menu and Mission Control, not over the
            // content, as in Notes.
            w.titleVisibility = .hidden
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: 980, height: 640))
            w.isReleasedWhenClosed = false
            // Nothing about the window's content is saved for state restoration.
            w.isRestorable = false
            w.delegate = self
            w.setFrameAutosaveName("HashLockMain")
            if !w.setFrameUsingName("HashLockMain") { w.center() }
            mainWindow = w
        }
        applyCapturePolicy()
        mainWindow?.makeKeyAndOrderFront(nil)
        applyDockPolicy()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        if Preferences.defaults.bool(forKey: Preferences.lockOnWindowCloseKey) { model.lock() }
        DispatchQueue.main.async { self.applyDockPolicy() }
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // The action is for VoiceOver and other accessibility presses;
        // clicks are taken before the button sees them (below).
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        statusItem = item
        watchStatusClicks()
        let content = MenuBarView(model: model, autoLock: autoLock, update: update,
                                  openMain: { [weak self] in self?.showMainWindow() },
                                  close: { [weak self] in self?.panel?.dismiss() })
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] _ in self?.panel?.refit() }
        panel = StatusPanel(content: content)
        updateIcon()
    }

    /// Opens and closes the panel on the press of either mouse button, as
    /// the system's menu bar items do. The button never tracks the click:
    /// if it did, it would switch its highlight off when the click ends,
    /// and the highlight the open panel keeps on it would blink. ⌘-drag,
    /// which moves the icon, is left to the button.
    private func watchStatusClicks() {
        statusClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let window = event.window.map(ObjectIdentifier.init)
            let command = event.modifierFlags.contains(.command)
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self, !command, let button = self.statusItem?.button,
                      let bw = button.window, window == ObjectIdentifier(bw) else { return false }
                self.panel?.toggle(below: button)
                return true
            }
            return taken ? nil : event
        }
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        panel?.toggle(below: button)
    }

    /// The icon follows the vault's state: a closed or an open lock.
    private func updateIcon() {
        let unlocked = withObservationTracking {
            model.phase == .unlocked
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
        applyIcon(unlocked: unlocked)
    }

    /// Draws the icon for the state and the style chosen in Settings.
    private func applyIcon(unlocked: Bool? = nil) {
        let style = MenuBarIcon(rawValue: Preferences.defaults.string(forKey: Preferences.menuBarIconKey) ?? "")
            ?? Preferences.menuBarIconDefault
        statusItem?.button?.image = style.image(unlocked: unlocked ?? (model.phase == .unlocked))
    }

    private func observePhase() {
        let unlocked = withObservationTracking {
            model.phase == .unlocked
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePhase() }
        }
        if unlocked { autoLock.noteActivity() }
    }

    // MARK: Settings that act on windows

    private func watchPreferences() {
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyDockPolicy()
                self?.applyCapturePolicy()
                self?.applyIcon()
            }
        })
        // Windows SwiftUI makes (Settings) get the same treatment once shown.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyCapturePolicy() }
        })
    }

    private func applyDockPolicy() {
        let mode = Preferences.DockIcon(rawValue: Preferences.defaults.string(forKey: Preferences.dockIconKey) ?? "")
            ?? Preferences.dockIconDefault
        let regular: Bool
        switch mode {
        case .always: regular = true
        case .never: regular = false
        case .whileWindowOpen: regular = mainWindow?.isVisible == true
        }
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        // Only the policy: bringing the app forward is for the user's own
        // actions (showMainWindow), never a side effect.
        NSApp.setActivationPolicy(policy)
    }

    private func applyCapturePolicy() {
        let hide = Preferences.defaults.bool(forKey: Preferences.hideFromCaptureKey)
        for w in NSApp.windows + [panel].compactMap({ $0 }) {
            w.sharingType = hide ? .none : .readOnly
        }
    }

    // MARK: Uninstalling

    /// Moves the app to the Trash, after deleting the vault and settings if
    /// asked to, and quits.
    private func uninstall(withData: Bool) async {
        if withData {
            await model.destroyAllVaults()
            try? FileManager.default.removeItem(at: VaultLocation.support)
            if let id = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: id)
            }
        } else {
            await model.lockForQuit()
        }
        try? await SMAppService.mainApp.unregister()

        let app = Bundle.main.bundleURL
        do {
            _ = try await NSWorkspace.shared.recycle([app])
        } catch {
            // The sandbox lets Hash Lock touch its own bundle only once the
            // user picks it: ask for that, with the app already selected.
            let panel = NSOpenPanel()
            panel.directoryURL = app.deletingLastPathComponent()
            panel.message = "Select Hash Lock and click Move to Trash to finish uninstalling."
            panel.prompt = "Move to Trash"
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.allowedContentTypes = [.application]
            NSApp.activate()
            if panel.runModal() == .OK, let picked = panel.url {
                try? FileManager.default.trashItem(at: picked, resultingItemURL: nil)
            }
        }
        quitting = true
        NSApp.terminate(nil)
    }
}

/// Runs its action once, however many times it is fired.
@MainActor
final class OneShot {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func fire() {
        action?()
        action = nil
    }
}
