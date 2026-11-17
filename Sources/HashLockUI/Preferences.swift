import Foundation
import VaultCore

/// Settings keys and their defaults. The defaults lean toward convenience;
/// the stricter choices are one click away in Settings. Preferences are not
/// secret and live in the app's (sandboxed) user defaults.
public enum Preferences {
    public enum DockIcon: String, CaseIterable, Identifiable, Sendable {
        /// Always in the Dock, like most apps.
        case always
        /// Only while the main window is open; otherwise menu bar only.
        case whileWindowOpen
        case never
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .always: "Always"
            case .whileWindowOpen: "While the Window Is Open"
            case .never: "Never"
            }
        }
    }

    public enum SortOrder: String, CaseIterable, Identifiable, Sendable {
        case title, modified, created
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .title: "Name"
            case .modified: "Date Modified"
            case .created: "Date Created"
            }
        }
    }

    // General
    public static let dockIconKey = "dockIcon"
    public static let dockIconDefault = DockIcon.always
    public static let openWindowAtLaunchKey = "openWindowAtLaunch"
    public static let sortOrderKey = "sortOrder"
    public static let sortOrderDefault = SortOrder.modified

    public static let menuBarIconKey = "menuBarIcon"
    public static let menuBarIconDefault = MenuBarIcon.lockFilled

    // Lock
    /// Minutes without using Hash Lock before it locks; 0 is never.
    public static let idleLockKey = "idleLockMinutes"
    public static let idleLockDefault = 15
    public static let idleLockChoices = [1, 2, 5, 10, 15, 30, 60, 0]
    public static let lockOnSleepKey = "lockOnSleep"
    public static let lockOnScreenLockKey = "lockOnScreenLock"
    public static let lockOnUserSwitchKey = "lockOnUserSwitch"
    public static let lockOnWindowCloseKey = "lockOnWindowClose"
    /// Minutes in the background (another app in front) before locking; 0 is never.
    public static let backgroundLockKey = "backgroundLockMinutes"
    public static let backgroundLockChoices = [0, 1, 5, 15, 30, 60]

    /// Erase a vault after this many incorrect passwords in a row; off by default.
    public static let eraseAfterFailuresKey = "eraseAfterFailures"
    public static let eraseAfterLimitKey = "eraseAfterLimit"
    public static let eraseAfterLimitChoices = [3, 5, 10, 20, 50]
    public static let eraseAfterLimitDefault = 10

    // Clipboard
    /// Seconds before a copied value is cleared from the clipboard; 0 is never.
    public static let clipboardClearKey = "clipboardClearSeconds"
    public static let clipboardClearDefault = 90
    public static let clipboardClearChoices = [10, 30, 60, 90, 120, 300, 0]
    public static let clipboardLocalOnlyKey = "clipboardLocalOnly"
    public static let clearClipboardOnLockKey = "clearClipboardOnLock"

    // Privacy
    public static let hideFromCaptureKey = "hideFromScreenCapture"
    public static let concealSecretsKey = "concealSecrets"
    public static let allowDragOutKey = "allowDragOut"
    /// A note's files as a list rather than icons.
    public static let attachmentsAsListKey = "attachmentsAsList"

    // Vault
    public static let kdfLevelKey = "kdfLevel"
    public static let kdfLevelDefault = KDFParameters.Level.standard

    /// Defaults for every Bool setting, registered at launch.
    public static func register() {
        UserDefaults.standard.register(defaults: [
            dockIconKey: dockIconDefault.rawValue,
            menuBarIconKey: menuBarIconDefault.rawValue,
            openWindowAtLaunchKey: true,
            sortOrderKey: sortOrderDefault.rawValue,
            idleLockKey: idleLockDefault,
            lockOnSleepKey: true,
            lockOnScreenLockKey: true,
            lockOnUserSwitchKey: true,
            lockOnWindowCloseKey: false,
            eraseAfterFailuresKey: false,
            eraseAfterLimitKey: eraseAfterLimitDefault,
            backgroundLockKey: 0,
            clipboardClearKey: clipboardClearDefault,
            clipboardLocalOnlyKey: true,
            clearClipboardOnLockKey: true,
            hideFromCaptureKey: false,
            concealSecretsKey: true,
            allowDragOutKey: true,
            kdfLevelKey: kdfLevelDefault.rawValue,
            // No window state is kept across launches: it could show what
            // was open.
            "NSQuitAlwaysKeepsWindows": false,
        ])
    }

    public static var defaults: UserDefaults { .standard }

    static func minutes(_ n: Int) -> String {
        n == 0 ? "Never" : n == 60 ? "1 hour" : n == 1 ? "1 minute" : "\(n) minutes"
    }

    static func seconds(_ n: Int) -> String {
        switch n {
        case 0: "Never"
        case let s where s >= 60 && s % 60 == 0: s == 60 ? "1 minute" : "\(s / 60) minutes"
        default: "\(n) seconds"
        }
    }
}
