// Renders Hash Lock's windows to PNGs for layout review, in light and dark,
// with a throwaway vault in a temporary folder:
//
//   swift run ui-snapshots [out-dir]      (default build/snapshots)
//
// The windows are shown on screen for a moment, as they must be for AppKit
// to draw toolbars and materials, and captured with screencapture.

import AppKit
import HashLockUI
import SwiftUI
import VaultCore

/// Lets the main actor run what was scheduled (loading the open item,
/// drawing) for a while.
func spin(_ seconds: Double) async {
    try? await Task.sleep(for: .seconds(seconds))
}

@MainActor
func capture<V: View>(_ view: V, size: NSSize, name: String, dark: Bool, toolbar: Bool = false,
                      sizesToFit: Bool = false, out: URL) async {
    let host = NSHostingController(rootView: view)
    host.sceneBridgingOptions = toolbar ? [.toolbars, .title] : []
    let w = NSWindow(contentViewController: host)
    w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    w.title = "Hash Lock"
    w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // A sheet: measured once, then given that size (a window that follows
    // its content's size as it lays out can loop).
    w.setContentSize(sizesToFit ? NSHostingView(rootView: view).fittingSize : size)
    w.titleVisibility = .hidden
    w.center()
    w.makeKeyAndOrderFront(nil)
    await spin(1.2)
    let file = out.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(w.windowNumber)", file.path]
    try? p.run()
    p.waitUntilExit()
    w.orderOut(nil)
    print("wrote \(file.lastPathComponent)")
}

/// The menu bar icon's styles, locked and unlocked, on a light and a dark
/// menu bar, at 4× and at actual size.
@MainActor
func menuBarIconSheet(to url: URL) {
    let styles = MenuBarIcon.allCases
    let cellW: CGFloat = 230, rowH: CGFloat = 120
    let size = NSSize(width: cellW * CGFloat(styles.count), height: rowH * 2)
    let image = NSImage(size: size, flipped: false) { _ in
        for (row, dark) in [false, true].enumerated() {
            let y0 = CGFloat(1 - row) * rowH
            (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: y0, width: size.width, height: rowH).fill()
            let ink = dark ? NSColor.white : NSColor.black
            for (i, style) in styles.enumerated() {
                let x0 = CGFloat(i) * cellW + 16
                for (k, unlocked) in [false, true].enumerated() {
                    guard let icon = style.image(unlocked: unlocked) else { continue }
                    let tinted = NSImage(size: icon.size, flipped: false) { r in
                        icon.draw(in: r)
                        ink.set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(x: x0 + CGFloat(k) * 80, y: y0 + 36, width: 64, height: 64))
                    tinted.draw(in: NSRect(x: x0 + CGFloat(k) * 80 + 70, y: y0 + 82, width: 18, height: 18))
                }
                (style.title as NSString).draw(at: NSPoint(x: x0, y: y0 + 10), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink])
            }
        }
        return true
    }
    if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: url)
        print("wrote \(url.lastPathComponent)")
    }
}

@MainActor
func run() async {
    let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/snapshots")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    menuBarIconSheet(to: out.appendingPathComponent("7-menubar-icons.png"))
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("hashlock-snapshots-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    Preferences.register()

    let model = AppModel(library: VaultLibrary(root: tmp.appendingPathComponent("Vaults")))
    await model.start()
    for dark in [false, true] {
        await capture(RootView(model: model), size: NSSize(width: 980, height: 640), name: "00-setup", dark: dark, out: out)
    }
    _ = await model.createVault(name: "Work", password: "other password", level: .standard)
    _ = await model.createVault(name: "Personal", password: "snapshot password", level: .standard)
    model.offerRecoveryKey = false

    // A note with fields and files.
    let server = await model.newNote()!
    await model.rename(server.id, to: "Production Server")
    var body = NoteBody(text: "Root login is disabled. Use the deploy user, key below.\nFirewall allows SSH only from the office.")
    body.fields = [Field(kind: .login, value: "deploy"),
                   Field(kind: .password, value: PasswordGenerator.generate(.init())),
                   Field(kind: .address, value: "203.0.113.24:22"),
                   Field(kind: .url, value: "https://panel.example.com"),
                   {
                       var f = Field(kind: .secret, label: "API Token",
                                     value: "sk-live-7Qm2xV9pLr4TzW8nKc3HbJ6yFd1GsA5eNu0RoMt-XiPvZkYqEwBhCjDlUaSgOfIn")
                       f.concealed = false
                       return f
                   }()]
    model.selection = server.id
    await spin(0.5)
    model.draft = body
    await spin(1.0)
    await model.attach([FileImport(name: "id_ed25519", typeIdentifier: "public.data", source: .data(Data(repeating: 65, count: 411))),
                        FileImport(name: "recovery-codes.txt", typeIdentifier: "public.plain-text", source: .data(Data("1234-5678\n".utf8)))],
                       to: server.id)

    // A folder with a little tree in it.
    let tree = tmp.appendingPathComponent("Server Backup")
    let fm = FileManager.default
    try? fm.createDirectory(at: tree.appendingPathComponent("etc/nginx/sites"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: tree.appendingPathComponent("keys"), withIntermediateDirectories: true)
    try? Data(repeating: 35, count: 1_200).write(to: tree.appendingPathComponent("etc/nginx/nginx.conf"))
    try? Data(repeating: 35, count: 640).write(to: tree.appendingPathComponent("etc/nginx/sites/panel.conf"))
    try? Data(repeating: 65, count: 411).write(to: tree.appendingPathComponent("keys/id_ed25519"))
    try? Data(repeating: 65, count: 99).write(to: tree.appendingPathComponent("keys/id_ed25519.pub"))
    try? Data(repeating: 80, count: 48_000).write(to: tree.appendingPathComponent("Firewall rules.pdf"))
    try? Data("notes".utf8).write(to: tree.appendingPathComponent("README.txt"))
    await model.attach([FileImport(name: "Server Backup", typeIdentifier: "public.folder", source: .folder(tree))], to: server.id)

    let wallet = await model.newWallet()!
    await model.rename(wallet.id, to: "Wasabi — Savings")
    let mail = await model.newNote()!
    await model.rename(mail.id, to: "Mail Account")
    if let tiff = NSApp.applicationIconImage?.tiffRepresentation ?? NSWorkspace.shared.icon(for: .png).tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        await model.addFiles([FileImport(name: "Passport scan.png", typeIdentifier: "public.png", source: .data(png))])
    }
    await model.togglePin(server.id)

    for dark in [false, true] {
        model.selection = server.id
        await spin(0.6)
        await capture(RootView(model: model), size: NSSize(width: 1000, height: 700), name: "1-note", dark: dark, toolbar: true, out: out)

        Preferences.defaults.set(true, forKey: Preferences.attachmentsAsListKey)
        await spin(0.3)
        await capture(RootView(model: model), size: NSSize(width: 1000, height: 700), name: "1b-note-list", dark: dark, toolbar: true, out: out)
        Preferences.defaults.set(false, forKey: Preferences.attachmentsAsListKey)

        model.selection = wallet.id
        await spin(0.6)
        if var w = model.draft?.wallet {
            w.words = "legal winner thank year wave sausage worth useful legal winner thank yellow".split(separator: " ").map(String.init)
            w.passphrase = "extra words"
            w.software = "Wasabi Wallet"
            w.derivationPath = "m/84'/0'/0'"
            model.draft?.wallet = w
        }
        await spin(0.4)
        await capture(RootView(model: model), size: NSSize(width: 1000, height: 760), name: "2-wallet", dark: dark, toolbar: true, out: out)

        if var w = model.draft?.wallet {
            w.coin = .monero
            w.format = .monero
            w.words = Array(repeating: "", count: 25)
            w.software = "Feather"
            w.address = "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5UzqtReoS44qo9mtmXCqY45DJ852K5Jv2684Rge"
            w.birthday = "3200000"
            w.extendedPublicKey = ""
            model.draft?.wallet = w
        }
        await spin(0.4)
        await capture(RootView(model: model), size: NSSize(width: 1000, height: 760), name: "2b-wallet-monero", dark: dark, toolbar: true, out: out)

        model.selection = nil
        await spin(0.4)
        await capture(RootView(model: model), size: NSSize(width: 1000, height: 640), name: "1c-no-selection", dark: dark, toolbar: true, out: out)

        if let file = model.items.first(where: { $0.kind == .file }) {
            model.selection = file.id
            await spin(0.8)
            await capture(RootView(model: model), size: NSSize(width: 1000, height: 700), name: "3-file", dark: dark, toolbar: true, out: out)
        }

        let autoLock = AutoLock(model: model)
        let update = UpdateWatcher()
        await capture(MenuBarView(model: model, autoLock: autoLock, update: update, openMain: {}, close: {})
                        .fixedSize().background(.regularMaterial),
                      size: NSSize(width: 270, height: 240), name: "4-menubar-unlocked", dark: dark, out: out)

        let actions = AppActions { _ in }
        await capture(SettingsView.page(.vault, model: model, actions: actions), size: NSSize(width: 600, height: 1300),
                      name: "5-settings-vault-full", dark: dark, out: out)
        for tab in SettingsView.Tab.allCases {
            await capture(SettingsView.page(tab, model: model, actions: actions), size: NSSize(width: 600, height: 400),
                    name: "5-settings-\(tab.rawValue)", dark: dark, out: out)
        }
    }

    // An attached folder in each of Finder's views.
    if let folder = model.items.flatMap(\.attachments).first(where: \.isFolder) {
        for mode in ["icons", "list", "columns"] {
            Preferences.defaults.set(mode, forKey: "folderViewMode")
            await capture(SheetGallery.folder(model: model, folder: folder), size: NSSize(width: 860, height: 540),
                          name: "8-folder-\(mode)", dark: true, out: out)
        }
        Preferences.defaults.set("list", forKey: "folderViewMode")
    }

    for dark in [false, true] {
        for (name, view) in SheetGallery.all(model: model) {
            await capture(view, size: NSSize(width: 300, height: 200), name: "6-sheet-\(name)", dark: dark,
                          sizesToFit: true, out: out)
        }
    }

    model.lock()
    await spin(1.0)
    for dark in [false, true] {
        await capture(RootView(model: model), size: NSSize(width: 1000, height: 640), name: "0-locked", dark: dark, out: out)
        await capture(SettingsView.page(.lock, model: model, actions: AppActions { _ in }),
                      size: NSSize(width: 600, height: 400), name: "5-settings-lock-while-locked", dark: dark, out: out)
        await capture(MenuBarView(model: model, autoLock: AutoLock(model: model), update: UpdateWatcher(), openMain: {}, close: {})
                        .fixedSize().background(.regularMaterial),
                      size: NSSize(width: 270, height: 240), name: "4-menubar-locked", dark: dark, out: out)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    await run()
    exit(0)
}
app.run()
