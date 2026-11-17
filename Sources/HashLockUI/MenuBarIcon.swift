import AppKit

/// The menu bar item's image, locked and unlocked: template images, so the
/// menu bar tints them for its appearance like every other item.
public enum MenuBarIcon: String, CaseIterable, Sendable {
    /// The app icon's padlock with a hash sign, drawn to the menu bar grid.
    case hashPadlock
    case hashPadlockFilled
    case lockFilled
    case lockOutline
    case shield
    case key

    public var title: String {
        switch self {
        case .hashPadlock: "Hash padlock"
        case .hashPadlockFilled: "Hash padlock, filled"
        case .lockFilled: "Padlock, filled"
        case .lockOutline: "Padlock, outline"
        case .shield: "Shield"
        case .key: "Key"
        }
    }

    @MainActor
    public func image(unlocked: Bool) -> NSImage? {
        let description = unlocked ? "Hash Lock, unlocked" : "Hash Lock, locked"
        let image: NSImage?
        switch self {
        case .hashPadlock: image = Self.drawn(unlocked: unlocked, filled: false)
        case .hashPadlockFilled: image = Self.drawn(unlocked: unlocked, filled: true)
        case .lockFilled: image = NSImage(systemSymbolName: unlocked ? "lock.open.fill" : "lock.fill", accessibilityDescription: description)
        case .lockOutline: image = NSImage(systemSymbolName: unlocked ? "lock.open" : "lock", accessibilityDescription: description)
        case .shield: image = NSImage(systemSymbolName: unlocked ? "shield" : "lock.shield.fill", accessibilityDescription: description)
        case .key: image = NSImage(systemSymbolName: unlocked ? "key" : "key.fill", accessibilityDescription: description)
        }
        image?.isTemplate = true
        image?.accessibilityDescription = description
        return image
    }

    /// 18 × 18 pt: a body with a hash sign and a shackle, which swings open
    /// to the left when unlocked. Filled, the hash is cut out of the body.
    private static func drawn(unlocked: Bool, filled: Bool) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            let body = CGRect(x: 3, y: 1.5, width: 12, height: 9)
            let shackleHalf: CGFloat = 3.6
            let shackleX = unlocked ? body.midX - 5.2 : body.midX
            let shackleTop: CGFloat = unlocked ? 17 : 16
            ctx.setLineWidth(1.6)
            ctx.move(to: CGPoint(x: shackleX - shackleHalf, y: unlocked ? body.maxY + 3 : body.maxY))
            ctx.addLine(to: CGPoint(x: shackleX - shackleHalf, y: shackleTop - shackleHalf))
            ctx.addArc(center: CGPoint(x: shackleX, y: shackleTop - shackleHalf), radius: shackleHalf,
                       startAngle: .pi, endAngle: 0, clockwise: true)
            ctx.addLine(to: CGPoint(x: shackleX + shackleHalf, y: body.maxY))
            ctx.strokePath()

            let rounded = CGPath(roundedRect: body, cornerWidth: 2.4, cornerHeight: 2.4, transform: nil)
            if filled {
                ctx.addPath(rounded)
                ctx.fillPath()
                ctx.setBlendMode(.clear)
            } else {
                ctx.setLineWidth(1.5)
                ctx.addPath(rounded)
                ctx.strokePath()
            }
            // The hash sign.
            let c = CGPoint(x: body.midX, y: body.midY)
            let span: CGFloat = 2.6, gap: CGFloat = 1.2, slant: CGFloat = 0.45
            ctx.setLineWidth(1.1)
            for dx in [-gap, gap] {
                ctx.move(to: CGPoint(x: c.x + dx - slant, y: c.y - span))
                ctx.addLine(to: CGPoint(x: c.x + dx + slant, y: c.y + span))
            }
            for dy in [-gap, gap] {
                ctx.move(to: CGPoint(x: c.x - span, y: c.y + dy))
                ctx.addLine(to: CGPoint(x: c.x + span, y: c.y + dy))
            }
            ctx.strokePath()
            return true
        }
    }
}
