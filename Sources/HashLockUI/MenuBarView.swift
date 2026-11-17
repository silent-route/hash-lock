import SwiftUI
import VaultCore

/// The menu bar panel: the vault's state, and the ways to the window, to
/// locking, to Settings and out.
public struct MenuBarView: View {
    let model: AppModel
    let autoLock: AutoLock
    let update: UpdateWatcher
    let openMain: () -> Void
    let close: () -> Void
    @Environment(\.openSettings) private var openSettings

    public init(model: AppModel, autoLock: AutoLock, update: UpdateWatcher,
                openMain: @escaping () -> Void, close: @escaping () -> Void) {
        self.model = model
        self.autoLock = autoLock
        self.update = update
        self.openMain = openMain
        self.close = close
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 11)
            Divider().padding(.horizontal, 10)
            VStack(spacing: 1) {
                MenuRow("Open Hash Lock", symbol: "macwindow", shortcut: "⌘0") {
                    close()
                    openMain()
                }
                switch model.phase {
                case .unlocked:
                    MenuRow("Lock Now", symbol: "lock", shortcut: "⌘L") {
                        model.lock()
                        close()
                    }
                case .locked:
                    MenuRow("Unlock…", symbol: "lock.open") {
                        close()
                        openMain()
                    }
                default:
                    EmptyView()
                }
            }
            .padding(5)
            if let v = update.newVersion {
                Divider().padding(.horizontal, 10)
                MenuRow("Relaunch to Update to \(v)", symbol: "arrow.triangle.2.circlepath") {
                    close()
                    update.relaunch(model: model)
                }
                .padding(5)
            }
            Divider().padding(.horizontal, 10)
            VStack(spacing: 1) {
                MenuRow("Settings…", symbol: "gearshape", shortcut: "⌘,") {
                    close()
                    NSApp.activate()
                    openSettings()
                }
                MenuRow(model.phase == .unlocked ? "Lock and Quit" : "Quit Hash Lock", symbol: "power", shortcut: "⌘Q") {
                    close()
                    NSApp.terminate(nil)
                }
            }
            .padding(5)
        }
        .frame(width: 270)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.phase == .unlocked ? "lock.open.fill" : "lock.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(model.phase == .unlocked ? Color.orange : Color.indigo, in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.current?.name ?? "Hash Lock").font(.headline).lineLimit(1)
                // The minutes left before the idle lock change by themselves.
                TimelineView(.periodic(from: .now, by: 20)) { _ in
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var status: String {
        switch model.phase {
        case .starting: return "…"
        case .setup: return "No vault yet"
        case .locked: return "Locked"
        case .unlocked:
            if let m = autoLock.minutesUntilIdleLock {
                return "Unlocked · locks in \(m) min"
            }
            return "Unlocked"
        }
    }
}

/// A row that looks and highlights like a menu item.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @State private var hover = false

    init(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(hover ? Color.white : .secondary)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(hover ? Color.white.opacity(0.8) : Color.secondary.opacity(0.7))
                }
            }
            .foregroundStyle(hover ? Color.white : .primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(hover ? Color.accentColor : .clear, in: .rect(cornerRadius: 5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
