import AppKit

/// Locks the vault when Settings say so: after a time without using Hash
/// Lock, after a time in the background, when the Mac sleeps, when the
/// screen locks or the screen saver starts, and on a switch to another user.
@MainActor
public final class AutoLock {
    private let model: AppModel
    private var lastActivity = Date()
    private var backgroundSince: Date?
    private var timer: Timer?
    private var eventMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(model: AppModel) {
        self.model = model
    }

    public func start() {
        // Any input to Hash Lock counts as using it.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .otherMouseDown]
        ) { [weak self] event in
            self?.lastActivity = Date()
            return event
        }

        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.willSleepNotification) { $0.lockIf(Preferences.lockOnSleepKey) }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.lockIf(Preferences.lockOnUserSwitchKey) }

        let dist = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            observe(dist, Notification.Name(name)) { $0.lockIf(Preferences.lockOnScreenLockKey) }
        }

        let app = NotificationCenter.default
        observe(app, NSApplication.didResignActiveNotification) { $0.backgroundSince = Date() }
        observe(app, NSApplication.didBecomeActiveNotification) { me in
            me.checkBackground()
            me.backgroundSince = nil
            me.lastActivity = Date()
        }

        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Unlocking starts the idle clock afresh.
    public func noteActivity() {
        lastActivity = Date()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ action: @escaping @MainActor (AutoLock) -> Void) {
        let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        observers.append((center, o))
    }

    private func lockIf(_ key: String) {
        if Preferences.defaults.bool(forKey: key) { model.lock() }
    }

    private func tick() {
        guard model.phase == .unlocked else { return }
        let idle = Preferences.defaults.integer(forKey: Preferences.idleLockKey)
        if idle > 0, Date().timeIntervalSince(lastActivity) >= Double(idle * 60) {
            model.lock()
            return
        }
        checkBackground()
    }

    private func checkBackground() {
        guard model.phase == .unlocked, let since = backgroundSince else { return }
        let limit = Preferences.defaults.integer(forKey: Preferences.backgroundLockKey)
        if limit > 0, Date().timeIntervalSince(since) >= Double(limit * 60) { model.lock() }
    }

    /// Minutes until the idle lock, for the menu bar panel; nil if off.
    public var minutesUntilIdleLock: Int? {
        let idle = Preferences.defaults.integer(forKey: Preferences.idleLockKey)
        guard idle > 0, model.phase == .unlocked else { return nil }
        let left = Double(idle * 60) - Date().timeIntervalSince(lastActivity)
        return max(1, Int((left / 60).rounded(.up)))
    }
}
