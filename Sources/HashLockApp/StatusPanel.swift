import AppKit
import SwiftUI

/// The menu bar panel, placed as macOS places its own (Wi-Fi, Control
/// Center): a rounded panel just under the menu bar, without an arrow. It
/// opens to the right of its icon, or to the left when there is no room.
/// Over a full-screen app the menu bar stays while it is open, as it does
/// for the system's menus. A click elsewhere, switching apps or desktops,
/// or Esc closes it.
@MainActor
final class StatusPanel: NSPanel, NSWindowDelegate {
    private static let margin: CGFloat = 6
    /// How far the menu bar's highlight reaches past the item's button on
    /// each side (measured on macOS 15: the same for the system's items and
    /// for others, whatever their width). The system's own menus line up
    /// with the highlight's edge, and so does the panel. Not measured on
    /// macOS 26: there it lines up with the button, as before.
    private static var highlightOutset: CGFloat {
        if #available(macOS 26, *) { 0 } else { 10 }
    }
    /// On macOS 14–15, the corners of the system's menu bar menus (Wi-Fi,
    /// Now Playing): measured against them, pixel by pixel.
    private static var cornerRadius: CGFloat {
        if #available(macOS 26, *) { 18 } else { 6 }
    }

    private let host: NSView
    private weak var button: NSStatusBarButton?
    /// The highlight's sides, and the height the panel's top edge is at.
    private var anchor: NSRect = .zero
    private var screenFrame: NSRect = .zero
    private var menuBarMoves: NSObjectProtocol?
    private var monitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(content: some View) {
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        host = hosting
        super.init(contentRect: NSRect(x: 0, y: 0, width: 270, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = Self.background(around: hosting)
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    func toggle(below button: NSStatusBarButton) {
        isVisible ? dismiss() : show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        guard let bw = button.window else { return }
        self.button = button
        screenFrame = (bw.screen ?? NSScreen.main)?.frame ?? .zero
        updateAnchor()
        place()
        makeKeyAndOrderFront(nil)
        keepHighlighted()
        menuTracking(true)
        watchForClose()
        followMenuBar(bw)
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    /// Where the panel hangs. On macOS 14–15 the system's menus touch the
    /// menu bar's bottom edge, which is the bottom of the item's window; on
    /// macOS 26 they float a little below the item.
    private func updateAnchor() {
        guard let button, let bw = button.window else { return }
        let inButton = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let top: CGFloat
        if #available(macOS 26, *) { top = inButton.minY - 5 } else { top = bw.frame.minY }
        anchor = NSRect(x: inButton.minX - Self.highlightOutset, y: min(top, screenFrame.maxY),
                        width: inButton.width + 2 * Self.highlightOutset, height: 0)
    }

    /// Should the menu bar still slide away over a full-screen app (or come
    /// back), the item's window moves with it, and the panel follows.
    private func followMenuBar(_ bw: NSWindow) {
        if let o = menuBarMoves { NotificationCenter.default.removeObserver(o) }
        menuBarMoves = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: bw, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.updateAnchor()
                self.place()
            }
        }
    }

    /// The button is pressed while the panel is open, as a menu's is. Mouse
    /// clicks never reach the button (the app delegate takes them), so
    /// nothing turns it off. An accessibility press goes through the button,
    /// which clears its highlight once its action has run: it is set again
    /// after that.
    private func keepHighlighted() {
        button?.highlight(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.button?.highlight(true)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        workspaceObservers = []
        if let o = menuBarMoves { NotificationCenter.default.removeObserver(o) }
        menuBarMoves = nil
        orderOut(nil)
        button?.highlight(false)
        menuTracking(false)
    }

    /// The system's menus announce that they are open and closed; while one
    /// is open, the menu bar over a full-screen app stays instead of sliding
    /// away when the pointer leaves it. The panel announces the same.
    private func menuTracking(_ open: Bool) {
        let name = open ? "com.apple.HIToolbox.beginMenuTrackingNotification"
                        : "com.apple.HIToolbox.endMenuTrackingNotification"
        DistributedNotificationCenter.default().post(name: .init(name), object: nil)
    }

    /// Sized to the content, its top under the icon.
    private func place() {
        let size = host.fittingSize
        let screen = screenFrame
        var x = anchor.minX
        if x + size.width > screen.maxX - Self.margin { x = anchor.maxX - size.width }
        x = min(max(x, screen.minX + Self.margin), screen.maxX - Self.margin - size.width)
        let y = anchor.minY - size.height
        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    func windowDidResize(_ notification: Notification) {
        if isVisible { DispatchQueue.main.async { [weak self] in self?.invalidateShadow() } }
    }

    func refit() {
        if isVisible { place() }
    }

    private func watchForClose() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                 object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.dismiss() }
        })
        workspaceObservers.append(ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                    handler: { [weak self] event in
            let w = event.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if w != ObjectIdentifier(self), w != self.button?.window.map(ObjectIdentifier.init) { self.dismiss() }
            }
            return event
        }) { monitors.append(l) }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    /// Liquid Glass on macOS 26; the menu material with rounded corners on
    /// macOS 14 and 15.
    private static func background(around content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.cornerRadius = cornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(glass)
            pin(glass, to: clip)
            return clip
        }
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = roundedMask(cornerRadius)
        fx.addSubview(content)
        pin(content, to: fx)
        return fx
    }

    private static func pin(_ v: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    private static func roundedMask(_ r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
