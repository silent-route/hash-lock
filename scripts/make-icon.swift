// Draws the app icon: a white wireframe glyph on a gradient squircle, in the
// style of Apple's own icons (light drop shadow, glass highlight, thin rim).
//
//   swift scripts/make-icon.swift Resources/AppIcon.icns [--variant NAME]
//   swift scripts/make-icon.swift --sheet icons.png     every variant side by side
//
// Drawn in code rather than kept as a PNG so the icon can be changed with a
// diff, and rebuilt without design tools.

import AppKit

let size: CGFloat = 1024

struct Palette {
    var colors: [(CGFloat, CGFloat, CGFloat)]
    var glow: (CGFloat, CGFloat, CGFloat)
}

enum Glyph { case padlockHash, shieldHash, hashKeyhole, vaultDial, padlockKeyhole }

struct Variant {
    let name: String
    let title: String
    let palette: Palette
    let glyph: Glyph
}

let variants: [Variant] = [
    Variant(name: "indigo", title: "A · Indigo padlock", palette: Palette(
        colors: [(0.09, 0.09, 0.16), (0.20, 0.20, 0.52), (0.52, 0.34, 0.86)], glow: (0.78, 0.70, 1)), glyph: .padlockHash),
    Variant(name: "graphite", title: "B · Graphite padlock", palette: Palette(
        colors: [(0.06, 0.06, 0.07), (0.17, 0.18, 0.21), (0.36, 0.38, 0.43)], glow: (0.75, 0.82, 0.95)), glyph: .padlockHash),
    Variant(name: "emerald", title: "C · Emerald shield", palette: Palette(
        colors: [(0.03, 0.12, 0.11), (0.05, 0.36, 0.30), (0.20, 0.72, 0.52)], glow: (0.60, 1, 0.80)), glyph: .shieldHash),
    Variant(name: "midnight", title: "D · Hash keyhole", palette: Palette(
        colors: [(0.05, 0.07, 0.18), (0.10, 0.22, 0.50), (0.22, 0.52, 0.92)], glow: (0.60, 0.80, 1)), glyph: .hashKeyhole),
    Variant(name: "amber", title: "E · Vault dial", palette: Palette(
        colors: [(0.16, 0.07, 0.03), (0.52, 0.22, 0.06), (0.95, 0.58, 0.18)], glow: (1, 0.85, 0.55)), glyph: .vaultDial),
    Variant(name: "crimson", title: "F · Keyhole padlock", palette: Palette(
        colors: [(0.14, 0.03, 0.07), (0.45, 0.08, 0.20), (0.86, 0.26, 0.40)], glow: (1, 0.70, 0.78)), glyph: .padlockKeyhole),
]

func cg(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor { CGColor(red: c.0, green: c.1, blue: c.2, alpha: a) }

func draw(_ v: Variant, in ctx: CGContext) {
    // macOS icon grid: an 824 pt squircle centered in the 1024 canvas.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: CGColor(gray: 0, alpha: 0.22))
    ctx.addPath(tilePath)
    ctx.setFillColor(cg(v.palette.colors[1]))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: v.palette.colors.map { cg($0) } as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.minY), end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    let c = CGPoint(x: size / 2, y: size / 2 - 10)
    let glow = CGGradient(colorsSpace: space, colors: [cg(v.palette.glow, 0.32), cg(v.palette.glow, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 380, options: [])

    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    switch v.glyph {
    case .padlockHash: padlock(ctx, c, inner: .hash)
    case .padlockKeyhole: padlock(ctx, c, inner: .keyhole)
    case .shieldHash: shield(ctx, c)
    case .hashKeyhole: hashKeyhole(ctx, c)
    case .vaultDial: vaultDial(ctx, c)
    }

    let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.26), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: c.x, y: tile.maxY), end: CGPoint(x: c.x, y: tile.midY), options: [])
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.22))
    ctx.setLineWidth(6)
    ctx.strokePath()
}

let line: CGFloat = 28

enum Inner { case hash, keyhole }

func padlock(_ ctx: CGContext, _ c: CGPoint, inner: Inner) {
    let body = CGRect(x: c.x - 220, y: c.y - 250, width: 440, height: 320)
    ctx.setLineWidth(line * 1.15)
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.strokePath()
    let half: CGFloat = 138, top = body.maxY + 190
    ctx.move(to: CGPoint(x: c.x - half, y: body.maxY))
    ctx.addLine(to: CGPoint(x: c.x - half, y: top - half))
    ctx.addArc(center: CGPoint(x: c.x, y: top - half), radius: half, startAngle: .pi, endAngle: 0, clockwise: true)
    ctx.addLine(to: CGPoint(x: c.x + half, y: body.maxY))
    ctx.strokePath()
    let h = CGPoint(x: body.midX, y: body.midY)
    switch inner {
    case .hash: hash(ctx, h, span: 92, gap: 40)
    case .keyhole: keyhole(ctx, h, scale: 1)
    }
}

func hash(_ ctx: CGContext, _ h: CGPoint, span: CGFloat, gap: CGFloat, width: CGFloat = line) {
    let slant = span * 0.15
    ctx.setLineWidth(width)
    for dx in [-gap, gap] {
        ctx.move(to: CGPoint(x: h.x + dx - slant, y: h.y - span))
        ctx.addLine(to: CGPoint(x: h.x + dx + slant, y: h.y + span))
    }
    for dy in [-gap, gap] {
        ctx.move(to: CGPoint(x: h.x - span, y: h.y + dy))
        ctx.addLine(to: CGPoint(x: h.x + span, y: h.y + dy))
    }
    ctx.strokePath()
}

func keyhole(_ ctx: CGContext, _ h: CGPoint, scale s: CGFloat) {
    ctx.addEllipse(in: CGRect(x: h.x - 42 * s, y: h.y - 4 * s, width: 84 * s, height: 84 * s))
    ctx.move(to: CGPoint(x: h.x - 24 * s, y: h.y + 10 * s))
    ctx.addLine(to: CGPoint(x: h.x - 38 * s, y: h.y - 92 * s))
    ctx.addLine(to: CGPoint(x: h.x + 38 * s, y: h.y - 92 * s))
    ctx.addLine(to: CGPoint(x: h.x + 24 * s, y: h.y + 10 * s))
    ctx.closePath()
    ctx.fillPath()
}

func shield(_ ctx: CGContext, _ c: CGPoint) {
    let w: CGFloat = 250, top = c.y + 290, bottom = c.y - 320
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: top))
    p.addQuadCurve(to: CGPoint(x: c.x + w, y: top - 70), control: CGPoint(x: c.x + w * 0.55, y: top - 10))
    p.addLine(to: CGPoint(x: c.x + w, y: c.y - 20))
    p.addQuadCurve(to: CGPoint(x: c.x, y: bottom), control: CGPoint(x: c.x + w, y: bottom + 120))
    p.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y - 20), control: CGPoint(x: c.x - w, y: bottom + 120))
    p.addLine(to: CGPoint(x: c.x - w, y: top - 70))
    p.addQuadCurve(to: CGPoint(x: c.x, y: top), control: CGPoint(x: c.x - w * 0.55, y: top - 10))
    ctx.setLineWidth(line * 1.15)
    ctx.addPath(p)
    ctx.strokePath()
    hash(ctx, CGPoint(x: c.x, y: c.y + 10), span: 110, gap: 46)
}

func hashKeyhole(_ ctx: CGContext, _ c: CGPoint) {
    hash(ctx, CGPoint(x: c.x, y: c.y + 10), span: 250, gap: 105, width: line * 1.5)
    keyhole(ctx, CGPoint(x: c.x, y: c.y + 20), scale: 0.95)
}

func vaultDial(_ ctx: CGContext, _ c: CGPoint) {
    let r: CGFloat = 270
    ctx.setLineWidth(line * 1.15)
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.strokePath()
    ctx.setLineWidth(line * 0.7)
    for i in 0..<12 {
        let a = CGFloat(i) * .pi / 6
        ctx.move(to: CGPoint(x: c.x + cos(a) * (r - 34), y: c.y + sin(a) * (r - 34)))
        ctx.addLine(to: CGPoint(x: c.x + cos(a) * (r - 64), y: c.y + sin(a) * (r - 64)))
    }
    ctx.strokePath()
    hash(ctx, c, span: 100, gap: 42)
}

func png(_ v: Variant, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / size, y: CGFloat(pixels) / size)
    draw(v, in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

/// Every variant at three sizes (as in Finder, the Dock and a list), on a
/// light and a dark strip, labeled.
func sheet(to url: URL) throws {
    let cell: CGFloat = 300, labelH: CGFloat = 40
    let width = cell * CGFloat(variants.count), height = (cell + labelH) * 2
    let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
        for (row, dark) in [true, false].enumerated() {
            let y0 = CGFloat(row) * (cell + labelH)
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
            NSRect(x: 0, y: y0, width: width, height: cell + labelH).fill()
            for (i, v) in variants.enumerated() {
                let x0 = CGFloat(i) * cell
                let big = NSImage(data: png(v, pixels: 512))!
                big.draw(in: NSRect(x: x0 + 20, y: y0 + labelH + 60, width: 220, height: 220))
                let mid = NSImage(data: png(v, pixels: 128))!
                mid.draw(in: NSRect(x: x0 + 236, y: y0 + labelH + 150, width: 64, height: 64))
                let small = NSImage(data: png(v, pixels: 64))!
                small.draw(in: NSRect(x: x0 + 252, y: y0 + labelH + 100, width: 32, height: 32))
                let tiny = NSImage(data: png(v, pixels: 32))!
                tiny.draw(in: NSRect(x: x0 + 260, y: y0 + labelH + 70, width: 16, height: 16))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                    .foregroundColor: dark ? NSColor.white : NSColor.black,
                ]
                (v.title as NSString).draw(at: NSPoint(x: x0 + 24, y: y0 + 22), withAttributes: attrs)
            }
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--sheet", args.count == 2 {
    try sheet(to: URL(fileURLWithPath: args[1]))
    exit(0)
}
var variantName = "indigo"
if let i = args.firstIndex(of: "--variant"), i + 1 < args.count {
    variantName = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard args.count == 1, let variant = variants.first(where: { $0.name == variantName }) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift OUT.icns [--variant \(variants.map(\.name).joined(separator: "|"))]\n       make-icon.swift --sheet OUT.png\n".utf8))
    exit(2)
}
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("AppIcon-\(ProcessInfo.processInfo.processIdentifier).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    try png(variant, pixels: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(variant, pixels: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", args[0]]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
