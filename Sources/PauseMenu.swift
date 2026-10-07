import AppKit
import SceneKit

private func swatchColor(_ c: SIMD3<Float>) -> NSColor {
    NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
}

/// A bird seen from above, wings spread, in its own colors (draw in a flipped view; head toward minY).
enum BirdIcon {
    static func draw(_ l: BirdLook, in r: NSRect, alpha: CGFloat = 1, mono: NSColor? = nil) {
        let s = min(r.width, r.height) / 32
        let c = NSPoint(x: r.midX, y: r.midY + 1 * s)
        func col(_ v: SIMD3<Float>) -> NSColor { (mono ?? swatchColor(v)).withAlphaComponent(alpha) }
        // A soft shadow keeps white birds (the owl) visible on the white cards.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if mono == nil {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.28 * alpha)
            sh.shadowBlurRadius = max(1, s * 0.9)
            sh.shadowOffset = NSSize(width: 0, height: -s * 0.3)
            sh.set()
        }
        let spanK = CGFloat(min(max(l.span, 0.85), 1.15)) * 0.9
        // Wings: a swept, curved blade on each side, darker toward the tip.
        for side: CGFloat in [-1, 1] {
            let w = NSBezierPath()
            let root = NSPoint(x: c.x + side * 2.5 * s, y: c.y - 3.5 * s)
            let tip = NSPoint(x: c.x + side * 15.5 * s * spanK, y: c.y + 1 * s)
            w.move(to: root)
            w.curve(to: tip, controlPoint1: NSPoint(x: c.x + side * 7 * s, y: c.y - 7.5 * s),
                    controlPoint2: NSPoint(x: c.x + side * 12 * s * spanK, y: c.y - 5 * s))
            w.curve(to: NSPoint(x: c.x + side * 2.5 * s, y: c.y + 3 * s), controlPoint1: NSPoint(x: c.x + side * 11 * s * spanK, y: c.y + 2 * s),
                    controlPoint2: NSPoint(x: c.x + side * 6 * s, y: c.y + 2.5 * s))
            w.close()
            if let g = NSGradient(starting: col(l.wingRoot), ending: col(l.wingTip)) {
                g.draw(in: w, angle: side > 0 ? 0 : 180)
            }
        }
        // Tail
        let t = NSBezierPath()
        t.move(to: NSPoint(x: c.x - 1.5 * s, y: c.y + 5 * s))
        t.line(to: NSPoint(x: c.x - 3.5 * s, y: c.y + 11 * s))
        t.line(to: NSPoint(x: c.x + 3.5 * s, y: c.y + 11 * s))
        t.line(to: NSPoint(x: c.x + 1.5 * s, y: c.y + 5 * s))
        t.close()
        col(l.tail).setFill(); t.fill()
        // Body, head, beak
        col(l.body).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 3.2 * s, y: c.y - 7 * s, width: 6.4 * s, height: 14 * s)).fill()
        col(l.back).withAlphaComponent(alpha * 0.8).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 1.6 * s, y: c.y - 4 * s, width: 3.2 * s, height: 8 * s)).fill()
        let hs = CGFloat(l.headScale), hr = 2.8 * s * hs
        let hc = NSPoint(x: c.x, y: c.y - 8.2 * s - (hs - 1) * 1.5 * s)
        if let t = l.throat {
            col(t).setFill()
            NSBezierPath(ovalIn: NSRect(x: hc.x - hr * 0.75, y: hc.y - hr * 0.2, width: hr * 1.5, height: hr * 1.2)).fill()
        }
        col(l.head).setFill()
        NSBezierPath(ovalIn: NSRect(x: hc.x - hr, y: hc.y - hr, width: hr * 2, height: hr * 2)).fill()
        let bw = 1 * s * CGFloat(max(l.beakWidth, 0.45)), blen = 3.5 * s * CGFloat(l.beakLength)
        let b = NSBezierPath()
        b.move(to: NSPoint(x: hc.x - bw, y: hc.y - hr * 0.8))
        b.line(to: NSPoint(x: hc.x, y: hc.y - hr * 0.8 - blen))
        b.line(to: NSPoint(x: hc.x + bw, y: hc.y - hr * 0.8))
        b.close()
        col(l.beak).setFill(); b.fill()
    }
}

/// Stat bar: base points in blue, upgrades in use in light blue, bought-but-switched-off upgrades hatched,
/// and a tick where this bird's upgrade cap is.
final class StatBarView: FlippedView {
    var base = 5 { didSet { needsDisplay = true } }
    var upgrades = 0 { didSet { needsDisplay = true } }
    var bought = 0 { didSet { needsDisplay = true } }
    var cap = StatRules.maxLevel { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(StatRules.maxPoints)
        let track = NSRect(x: 0, y: (bounds.height - 10) / 2, width: bounds.width, height: 10)
        Wii.tileLow.setFill(); NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        let unit = track.width / n
        let total = CGFloat(base + max(bought, upgrades))
        if total > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: unit * total, height: track.height),
                         xRadius: 5, yRadius: 5).addClip()
            Wii.blue.setFill()
            NSRect(x: track.minX, y: track.minY, width: unit * CGFloat(base), height: track.height).fill()
            NSColor(srgbRed: 0.55, green: 0.84, blue: 0.97, alpha: 1).setFill()
            NSRect(x: track.minX + unit * CGFloat(base), y: track.minY, width: unit * CGFloat(upgrades), height: track.height).fill()
            // Switched off: pale with diagonal hatching.
            let off = NSRect(x: track.minX + unit * CGFloat(base + upgrades), y: track.minY, width: unit * CGFloat(bought - upgrades), height: track.height)
            if off.width > 0 {
                NSColor(srgbRed: 0.85, green: 0.93, blue: 0.98, alpha: 1).setFill(); off.fill()
                let hatch = NSBezierPath()
                var x = off.minX - track.height
                while x < off.maxX { hatch.move(to: NSPoint(x: x, y: off.maxY)); hatch.line(to: NSPoint(x: x + track.height, y: off.minY)); x += 4 }
                hatch.lineWidth = 1.2
                NSColor(srgbRed: 0.45, green: 0.72, blue: 0.88, alpha: 1).setStroke()
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: off).addClip(); hatch.stroke(); NSGraphicsContext.restoreGraphicsState()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        // Cap marker
        let capX = track.minX + unit * CGFloat(min(base + cap, StatRules.maxPoints))
        let tick = NSBezierPath()
        tick.move(to: NSPoint(x: capX, y: track.minY - 3)); tick.line(to: NSPoint(x: capX, y: track.maxY + 3))
        tick.lineWidth = 2
        Wii.text.withAlphaComponent(0.55).setStroke(); tick.stroke()
    }
}

/// One tile in the shop grid (a bird or a world).
final class ShopCardView: FlippedView {
    enum Item { case bird(Species), world(WorldInfo) }
    let item: Item
    var onSelect: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }
    var isEquipped = false { didSet { needsDisplay = true } }
    var owned = false { didSet { needsDisplay = true } }
    var affordable = false { didSet { needsDisplay = true } }
    private var hover = false

    init(_ item: Item) {
        self.item = item
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    var id: String { switch item { case .bird(let b): return b.id; case .world(let w): return w.id } }
    private var name: String { switch item { case .bird(let b): return b.name; case .world(let w): return w.name } }
    private var cost: Int { switch item { case .bird(let b): return b.cost; case .world(let w): return w.cost } }
    var comingSoon: Bool { switch item { case .bird(let b): return b.comingSoon; case .world(let w): return w.comingSoon } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 5, dy: 5)
        let border = isHighlighted ? Wii.blue : (hover ? Wii.blueLight : Wii.border)
        Wii.tile(r, radius: 10, fill: .white, bottom: Wii.tileLow, border: border, borderWidth: isHighlighted ? 3 : 2)
        let sw = NSRect(x: r.minX + 12, y: r.midY - 15, width: 30, height: 30)
        switch item {
        case .bird(let b):
            let well = NSBezierPath(roundedRect: sw.insetBy(dx: -4, dy: -4), xRadius: 9, yRadius: 9)
            NSColor(srgbRed: 0.86, green: 0.93, blue: 0.98, alpha: 1).setFill(); well.fill()
            BirdIcon.draw(b.look, in: sw.insetBy(dx: -3, dy: -3), alpha: owned && !b.comingSoon ? 1 : 0.45)
        case .world(let w) where w.isFinale && !owned:
            // Locked: a night sky, a dark castle against it, a question mark in gold.
            let path = NSBezierPath(roundedRect: sw, xRadius: 7, yRadius: 7)
            NSGradient(starting: NSColor(srgbRed: 0.05, green: 0.04, blue: 0.12, alpha: 1), ending: NSColor(srgbRed: 0.22, green: 0.12, blue: 0.3, alpha: 1))?
                .draw(in: path, angle: 90)
            Wii.drawText("?", in: sw, size: 20, bold: true, color: NSColor(srgbRed: 1, green: 0.8, blue: 0.35, alpha: 1), align: .center, centerV: true)
        case .world(let w) where !w.comingSoon && WorldArtView.screenshot(w.id) != nil:
            let img = WorldArtView.screenshot(w.id)!
            let path = NSBezierPath(roundedRect: sw, xRadius: 7, yRadius: 7)
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            let side = min(img.size.width, img.size.height)
            img.draw(in: sw, from: NSRect(x: (img.size.width - side) / 2, y: (img.size.height - side) / 2, width: side, height: side),
                     operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        case .world(let w):
            let path = NSBezierPath(roundedRect: sw, xRadius: 7, yRadius: 7)
            NSGradient(starting: swatchColor(w.art[0]), ending: swatchColor(w.art[1]))?.draw(in: path, angle: 90)
            NSGraphicsContext.saveGraphicsState(); path.addClip()
            swatchColor(w.art[2]).setFill()
            NSBezierPath(ovalIn: NSRect(x: sw.minX - 8, y: sw.midY + 3, width: sw.width + 16, height: sw.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        let lockedFinale: Bool = { if case .world(let w) = item { return w.isFinale && !owned }; return false }()
        if case .world = item, (!owned || comingSoon) && !lockedFinale {
            NSColor.white.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: sw, xRadius: 7, yRadius: 7).fill()
        }
        let tx = sw.maxX + 10, tw = r.maxX - tx - 8
        Wii.drawText(name, in: NSRect(x: tx, y: r.minY + 12, width: tw, height: 20), size: 13, bold: true,
                     color: comingSoon ? Wii.textSoft : Wii.text, truncate: true)
        let status: String
        var color = Wii.textSoft
        if comingSoon { status = "Coming soon" }
        else if lockedFinale { status = "Locked"; color = NSColor(srgbRed: 0.55, green: 0.42, blue: 0.75, alpha: 1) }
        else if isEquipped { status = "Selected"; color = Wii.blue }
        else if owned { status = "Owned" }
        else { status = "● \(cost)"; if !affordable { color = NSColor(srgbRed: 0.8, green: 0.35, blue: 0.3, alpha: 1) } }
        Wii.drawText(status, in: NSRect(x: tx, y: r.minY + 33, width: tw, height: 18), size: 12, color: color, truncate: true)
    }
}

/// Simple painting of a world for the shop.
/// A world's secrets on its page in the menu: what secrets are, how many are found, and a line for each — what it was
/// once found, a clue while it's still hidden.
final class SecretsListView: FlippedView {
    var world = "" { didSet { needsDisplay = true } }
    var found: Set<String> = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ids = WorldCatalog.secrets[world], !ids.isEmpty else { return }
        let r = bounds
        Wii.tile(r, radius: 10, fill: NSColor(white: 1, alpha: 0.7), bottom: Wii.tileLow, border: Wii.border, borderWidth: 1, shadow: false)
        let n = ids.filter(found.contains).count
        let x = r.minX + 12, w = r.width - 24
        Wii.drawText("SECRETS", in: NSRect(x: x, y: r.minY + 9, width: 100, height: 16), size: 12, bold: true, color: Wii.textSoft)
        Wii.drawText(n == ids.count ? "All \(n) found!" : "\(n) of \(ids.count) found  ·  \(ids.count - n) left",
                     in: NSRect(x: x, y: r.minY + 8, width: w, height: 18), size: 13, bold: true,
                     color: n == ids.count ? NSColor(srgbRed: 0.25, green: 0.6, blue: 0.35, alpha: 1) : Wii.text, align: .right)
        Wii.drawText("Hidden places and moments in this world. Each pays coins the first time you find it.",
                     in: NSRect(x: x, y: r.minY + 28, width: w, height: 16), size: 11.5, color: Wii.textSoft, truncate: true)
        let top = r.minY + 48
        let line = min(22, (r.maxY - 6 - top) / CGFloat(ids.count))
        for (i, id) in ids.enumerated() {
            let y = top + CGFloat(i) * line
            let info = WorldCatalog.secretInfo[id] ?? (name: id, clue: "?")
            let got = found.contains(id)
            let mark = NSRect(x: x, y: y + (line - 16) / 2, width: 16, height: 16)
            if got {
                NSColor(srgbRed: 0.28, green: 0.72, blue: 0.4, alpha: 1).setFill(); NSBezierPath(ovalIn: mark).fill()
                let tick = NSBezierPath()
                tick.move(to: NSPoint(x: mark.minX + 4.2, y: mark.midY)); tick.line(to: NSPoint(x: mark.minX + 7, y: mark.midY + 3.2))
                tick.line(to: NSPoint(x: mark.maxX - 3.6, y: mark.minY + 4.6))
                tick.lineWidth = 2; tick.lineCapStyle = .round; NSColor.white.setStroke(); tick.stroke()
            } else {
                NSColor(srgbRed: 0.55, green: 0.42, blue: 0.75, alpha: 1).setFill(); NSBezierPath(ovalIn: mark).fill()
                Wii.drawText("?", in: mark.offsetBy(dx: 0, dy: 0.5), size: 11, bold: true, color: .white, align: .center, centerV: true)
            }
            Wii.drawText(got ? info.name : info.clue, in: NSRect(x: x + 24, y: y, width: w - 24, height: line), size: 12.5, bold: got,
                         color: got ? Wii.text : Wii.textSoft, centerV: true, truncate: true)
        }
    }
}

final class WorldArtView: FlippedView {
    var world: WorldInfo? { didSet { needsDisplay = true } }
    /// The Finale before it's open: a castle in the dark and a question.
    var mystery = false { didSet { needsDisplay = true } }

    private static var shots: [String: NSImage] = [:]
    /// Real screenshot bundled with the app (playable worlds only).
    static func screenshot(_ id: String) -> NSImage? {
        if let img = shots[id] { return img }
        guard let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "worlds"),
              let img = NSImage(contentsOf: url) else { return nil }
        shots[id] = img
        return img
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let w = world else { return }
        let r = bounds
        let clip = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if mystery {
            drawMystery(r)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if !w.comingSoon, let img = Self.screenshot(w.id) {
            // Aspect-fill the screenshot.
            let s = max(r.width / img.size.width, r.height / img.size.height)
            let size = NSSize(width: img.size.width * s, height: img.size.height * s)
            img.draw(in: NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGradient(starting: swatchColor(w.art[0]), ending: swatchColor(w.art[1]))?.draw(in: r, angle: 90)
        let ground = swatchColor(w.art[2]), accent = swatchColor(w.art[3])
        func hills(_ baseY: CGFloat, _ amp: CGFloat, _ color: NSColor, _ seed: CGFloat) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX, y: r.maxY))
            for i in 0...24 {
                let x = r.minX + r.width * CGFloat(i) / 24
                p.line(to: NSPoint(x: x, y: baseY - amp * (0.5 + 0.5 * sin(CGFloat(i) * 0.7 + seed)) * (0.6 + 0.4 * sin(CGFloat(i) * 0.23 + seed * 2))))
            }
            p.line(to: NSPoint(x: r.maxX, y: r.maxY)); p.close()
            color.setFill(); p.fill()
        }
        switch w.kind {
        case .volcano:
            let cone = NSBezierPath()
            cone.move(to: NSPoint(x: r.midX - r.width * 0.42, y: r.maxY))
            cone.line(to: NSPoint(x: r.midX - r.width * 0.09, y: r.minY + r.height * 0.36))
            cone.line(to: NSPoint(x: r.midX + r.width * 0.09, y: r.minY + r.height * 0.36))
            cone.line(to: NSPoint(x: r.midX + r.width * 0.42, y: r.maxY)); cone.close()
            (ground.blended(withFraction: 0.2, of: .black) ?? ground).setFill(); cone.fill()
            accent.setFill()
            for i in 0..<6 {
                let x = r.midX + CGFloat(i - 3) * 5, h = CGFloat(20 + (i * 13) % 30)
                NSBezierPath(ovalIn: NSRect(x: x, y: r.minY + r.height * 0.36 - h, width: 7, height: 9)).fill()
            }
            hills(r.maxY - r.height * 0.18, 18, ground, 1.3)
            accent.withAlphaComponent(0.9).setFill()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - r.height * 0.1, width: r.width, height: r.height * 0.1)).fill()
        case .caves:
            (ground.blended(withFraction: 0.5, of: .black) ?? ground).setFill()
            NSBezierPath(rect: r).fill()
            let arch = NSBezierPath(ovalIn: NSRect(x: r.minX + r.width * 0.12, y: r.minY + r.height * 0.2, width: r.width * 0.76, height: r.height * 0.9))
            swatchColor(w.art[1]).setFill(); arch.fill()
            hills(r.maxY - r.height * 0.14, 16, ground, 0.4)
            for i in 0..<14 {
                let x = r.minX + r.width * (0.15 + 0.7 * CGFloat((i * 37) % 100) / 100)
                let y = r.minY + r.height * (0.35 + 0.5 * CGFloat((i * 53) % 100) / 100)
                accent.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 5, height: 5)).fill()
            }
        case .dogfight:
            hills(r.maxY - r.height * 0.3, 20, ground, 2.1)
            for i in 0..<5 {
                let y = r.maxY - r.height * 0.22 + CGFloat(i) * 9
                (i % 2 == 0 ? NSColor(srgbRed: 0.85, green: 0.74, blue: 0.40, alpha: 1) : ground.blended(withFraction: 0.15, of: .black)!).setFill()
                NSBezierPath(rect: NSRect(x: r.minX, y: y, width: r.width, height: 9)).fill()
            }
            // Biplane silhouette
            let c = NSPoint(x: r.midX + r.width * 0.12, y: r.minY + r.height * 0.3)
            accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: c.x - 30, y: c.y - 3, width: 60, height: 5), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: c.x - 26, y: c.y + 9, width: 52, height: 5), xRadius: 2, yRadius: 2).fill()
            NSBezierPath(roundedRect: NSRect(x: c.x - 5, y: c.y - 6, width: 10, height: 20), xRadius: 4, yRadius: 4).fill()
        default:
            accent.setFill()
            NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - r.height * 0.3, width: r.width, height: r.height * 0.3)).fill()
            hills(r.maxY - r.height * 0.28, 30, ground, 0.2)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.maxX - 70, y: r.minY + 24, width: 40, height: 40)).fill()
        }
        if w.comingSoon {
            NSColor.white.withAlphaComponent(0.55).setFill(); NSBezierPath(rect: r).fill()
            Wii.drawText("Coming soon", in: r, size: 18, bold: true, color: Wii.textSoft, align: .center, centerV: true)
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension WorldArtView {
    /// Night over a castle on a hill, every window dark, stars, and a question in gold.
    fileprivate func drawMystery(_ r: NSRect) {
        NSGradient(starting: NSColor(srgbRed: 0.03, green: 0.03, blue: 0.09, alpha: 1), ending: NSColor(srgbRed: 0.2, green: 0.1, blue: 0.28, alpha: 1))?
            .draw(in: r, angle: 90)
        NSColor.white.withAlphaComponent(0.8).setFill()
        for i in 0..<40 {
            let x = r.minX + r.width * CGFloat((i * 37 + 11) % 100) / 100, y = r.minY + r.height * 0.6 * CGFloat((i * 53 + 7) % 100) / 100
            let s: CGFloat = i % 5 == 0 ? 2.2 : 1.3
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: s, height: s)).fill()
        }
        // The hill and the castle, black against the sky.
        let hill = NSBezierPath()
        hill.move(to: NSPoint(x: r.minX, y: r.maxY))
        hill.curve(to: NSPoint(x: r.maxX, y: r.maxY), controlPoint1: NSPoint(x: r.minX + r.width * 0.3, y: r.maxY - r.height * 0.45),
                   controlPoint2: NSPoint(x: r.maxX - r.width * 0.3, y: r.maxY - r.height * 0.45))
        hill.close()
        let ink = NSColor(srgbRed: 0.04, green: 0.03, blue: 0.07, alpha: 1)
        ink.setFill(); hill.fill()
        let base = r.maxY - r.height * 0.3, cx = r.midX
        NSBezierPath(rect: NSRect(x: cx - r.width * 0.26, y: base - r.height * 0.1, width: r.width * 0.52, height: r.height * 0.12)).fill()
        for (dx, h, w) in [(-0.26, 0.2, 0.07), (0.19, 0.2, 0.07), (-0.08, 0.3, 0.09), (0.04, 0.42, 0.06)] as [(CGFloat, CGFloat, CGFloat)] {
            let x = cx + r.width * dx
            NSBezierPath(rect: NSRect(x: x, y: base - r.height * h, width: r.width * w, height: r.height * h)).fill()
            let roof = NSBezierPath()
            roof.move(to: NSPoint(x: x - r.width * 0.012, y: base - r.height * h))
            roof.line(to: NSPoint(x: x + r.width * w / 2, y: base - r.height * (h + 0.11)))
            roof.line(to: NSPoint(x: x + r.width * (w + 0.012), y: base - r.height * h))
            roof.close(); roof.fill()
        }
        let gold = NSColor(srgbRed: 1, green: 0.8, blue: 0.35, alpha: 1)
        Wii.drawText("?", in: NSRect(x: r.minX, y: r.minY + r.height * 0.08, width: r.width, height: r.height * 0.4), size: 64, bold: true,
                     color: gold, align: .center, centerV: true)
    }
}

/// Two glossy tabs ("Birds" / "Worlds").
final class WiiTabs: FlippedView {
    var titles: [String]
    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?

    init(_ titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = min(Int(p.x / (bounds.width / CGFloat(titles.count))), titles.count - 1)
        if i != selected { selected = i; onChange?(i) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let segW = bounds.width / CGFloat(titles.count)
        Wii.tile(bounds.insetBy(dx: 2, dy: 2), radius: 10, fill: Wii.tileLow, border: Wii.border, borderWidth: 1.5, shadow: false, bevel: false)
        for (i, t) in titles.enumerated() {
            let r = NSRect(x: CGFloat(i) * segW, y: 0, width: segW, height: bounds.height).insetBy(dx: 4, dy: 4)
            if i == selected { Wii.glossy(r, radius: 8, rim: Wii.blue, rimWidth: 2) }
            Wii.drawText(t, in: r.offsetBy(dx: 0, dy: 1), size: 14, bold: i == selected,
                         color: i == selected ? Wii.text : Wii.textSoft, align: .center, centerV: true)
        }
    }
}

/// Turntable 3D preview of a species (and its outfit) on a plain light backdrop.
final class BirdPreviewView: SCNView, SCNSceneRendererDelegate {
    enum Framing { case full, portrait }
    private let pivot = SCNNode()
    private let cam = SCNNode()
    /// Swapped on the main thread, animated on the render thread: guarded by `lock`.
    private var bird: BirdNode?
    private var framing = Framing.full
    private let lock = NSLock()
    private var lastTime: TimeInterval = 0
    private var angle: Float = 0
    private var shown: (String, Outfit, Framing)?

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        let scene = SCNScene()
        scene.lightingEnvironment.contents = Sky.cachedFaces
        scene.lightingEnvironment.intensity = 1.1
        scene.background.contents = NSImage(size: NSSize(width: 64, height: 256), flipped: false) { r in
            NSGradient(starting: NSColor(white: 0.84, alpha: 1), ending: NSColor(srgbRed: 0.93, green: 0.96, blue: 0.98, alpha: 1))?
                .draw(in: r, angle: 90)
            return true
        }
        self.scene = scene
        backgroundColor = NSColor(white: 0.9, alpha: 1)
        antialiasingMode = .multisampling4X
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1400
        sun.simdLook(at: SIMD3(0.4, -1, -0.6), up: kUp, localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(sun)

        scene.rootNode.addChildNode(pivot)
        cam.camera = SCNCamera()
        cam.camera?.projectionDirection = .horizontal
        cam.camera?.zNear = 0.05
        cam.camera?.wantsHDR = true
        cam.camera?.bloomIntensity = 0.4
        cam.camera?.bloomThreshold = 1.2
        scene.rootNode.addChildNode(cam)
        pointOfView = cam
        delegate = self
        rendersContinuously = true
        placeCamera(.full)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Stopped previews stop drawing too (they sit in hidden tabs).
    override var isPlaying: Bool { didSet { rendersContinuously = isPlaying } }

    private func placeCamera(_ framing: Framing) {
        switch framing {
        case .full:
            cam.camera?.fieldOfView = 50
            cam.simdPosition = SIMD3(0, 1.45, 3.7)
            cam.simdLook(at: SIMD3(0, 0, 0), up: kUp, localFront: SIMD3(0, 0, -1))
        case .portrait:
            cam.camera?.fieldOfView = 34
            cam.simdPosition = SIMD3(0, 0.55, 2.1)
            cam.simdLook(at: SIMD3(0, 0.12, 0), up: kUp, localFront: SIMD3(0, 0, -1))
        }
    }

    /// `portrait` frames the head (hats, glasses, neckwear) and sways instead of spinning all the way round.
    func show(_ sp: Species, outfit: Outfit = Outfit(), framing f: Framing = .full) {
        if let s = shown, s.0 == sp.id, s.1 == outfit, s.2 == f { return }
        shown = (sp.id, outfit, f)
        placeCamera(f)
        let b = BirdNode(look: sp.look, outfit: outfit, preview: true)
        b.pose(left: WingPose(elevation: 0.18, bend: -0.1), right: WingPose(elevation: 0.18, bend: -0.1),
               fold: 0, pitchIn: 0, rollIn: 0, dt: 1)
        switch f {
        case .full:
            let fit = 1 / max(sp.look.span * 0.9, sp.look.size)
            b.node.simdScale = SIMD3(repeating: fit)
            b.node.simdPosition = SIMD3(0, -0.1, 0)
        case .portrait:
            // Head (and its hat) at the centre of the turn, whatever the bird's size.
            let k = 1.25 * sp.look.size
            let fit = 1.1 / (k * sp.look.headScale)
            b.node.simdScale = SIMD3(repeating: fit)
            b.node.simdPosition = -sp.look.headCenter * k * fit
        }
        lock.lock()
        let old = bird
        bird = b
        framing = f
        lock.unlock()
        old?.node.removeFromParentNode()
        pivot.addChildNode(b.node)
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let bird = self.bird, framing = self.framing
        lock.unlock()
        let dt = lastTime > 0 ? Float(min(time - lastTime, 0.1)) : 0
        lastTime = time
        angle += dt
        switch framing {
        case .full: pivot.simdOrientation = simd_quatf(angle: angle * .pi * 2 / 16, axis: kUp)
        // Facing you (the bird looks down -Z, so turn it round), swaying between three-quarter views.
        case .portrait: pivot.simdOrientation = simd_quatf(angle: .pi + 0.62 * sin(angle * 0.5), axis: kUp)
        }
        bird?.tick(dt: dt, speed: 14, camera: cam.simdWorldPosition, emitting: true)
    }
}

/// The pause panel's glossy face (a separate flipped view so the glass sits at the top).
private final class GlossBackground: FlippedView {
    static let margin: CGFloat = 20
    override func draw(_ dirtyRect: NSRect) {
        Wii.glossy(bounds.insetBy(dx: Self.margin, dy: Self.margin), radius: 16, rim: Wii.border, rimWidth: 2.4,
                   maxGlass: 72, depth: 0.55)
    }
}

/// Shared geometry for the Play, Birds and Worlds tabs, so switching tabs never moves anything:
/// two rows of cards, then a picture (with the main button under it) beside a column of details.
enum TabLayout {
    static let cardH: CGFloat = 70
    static let columns = 4
    /// Space between the card grid and the details.
    static let gap: CGFloat = 18
    static let actionH: CGFloat = 60
    static func pictureWidth(_ areaW: CGFloat) -> CGFloat { min(260, areaW * 0.34) }
    /// Rows a grid of `count` cards needs (at least two, so the details don't jump around between tabs).
    static func rows(_ count: Int) -> Int { max(2, (count + columns - 1) / columns) }
    /// Cards get a little shorter when there are three rows of them.
    static func rowHeight(_ rows: Int) -> CGFloat { rows > 2 ? 64 : cardH }
    static func cardFrame(_ i: Int, areaW: CGFloat, top: CGFloat, rows: Int = 2) -> NSRect {
        let w = (areaW + 10) / CGFloat(columns), h = rowHeight(rows)
        return NSRect(x: -5 + CGFloat(i % columns) * w, y: top + CGFloat(i / columns) * h, width: w, height: h)
    }
    static func detailTop(rows: Int) -> CGFloat { rowHeight(rows) * CGFloat(max(rows, 2)) + gap }
    static var detailTop: CGFloat { detailTop(rows: 2) }
}

/// The tabs on the right of the pause menu.
enum MenuTab: Int, CaseIterable {
    case play, birds, style, worlds, goals, lan
    var title: String {
        switch self {
        case .play: return "Play"
        case .birds: return "Birds"
        case .style: return "Style"
        case .worlds: return "Worlds"
        case .goals: return "Goals"
        case .lan: return "LAN"
        }
    }
}

/// Parts of the pause menu the tutorial points at.
enum MenuPart { case tabs, tabArea, leftColumn, recalibrate, tutorial, settings, resume, coins }

/// Esc screen: pause, settings and the bird shop.
final class PauseMenuView: NSView {
    let progress: Progress
    let lan: LANSession

    var onResume: (() -> Void)?
    var onRestart: (() -> Void)?
    var onRecalibrate: (() -> Void)?
    /// Sound, camera, HUD, chat, graphics and update settings live on this card (the Settings button opens it).
    let settings = SettingsCard()
    /// The flown species or its stats changed.
    var onBirdChanged: ((Species) -> Void)?
    /// The chosen world changed (bought or picked) — travel there.
    var onWorldChanged: (() -> Void)?
    /// Every key typed while the menu is open (used for the test-coins shortcut).
    var onKey: ((String) -> Void)?
    var onPlay: ((GameMode, WorldID) -> Void)? { didSet { playPanel.onPlay = onPlay } }
    var onStartRound: (() -> Void)? { didSet { playPanel.onStartRound = onStartRound; lanPanel.onStartRound = onStartRound } }
    var onHost: (() -> Void)? { didSet { lanPanel.onHost = onHost } }
    var onRulesChanged: ((MatchRules) -> Void)? { didSet { lanPanel.onRulesChanged = onRulesChanged } }
    var onProfileChanged: ((String, Int) -> Void)? { didSet { lanPanel.onProfileChanged = onProfileChanged } }
    var onGoOnline: (() -> Void)? { didSet { lanPanel.onGoOnline = onGoOnline } }
    /// Bought, wore or took off a cosmetic.
    var onOutfitChanged: ((Outfit) -> Void)? { didSet { stylePanel.onOutfitChanged = onOutfitChanged } }
    var onTutorial: (() -> Void)?
    /// Back to the title screen.
    var onMainMenu: (() -> Void)?
    /// The update row's button.
    var onUpdateAction: (() -> Void)? { didSet { updateRow.onAction = onUpdateAction } }

    private let panel = FlippedView()
    private let panelGloss = GlossBackground()
    private let title = WiiLabel(28, bold: true)
    private let coinLabel = WiiLabel(20, bold: true)

    // The left column's buttons are all the same size.
    private let resume = WiiButton("Resume", textSize: 16)
    private let restart = WiiButton("Restart", textSize: 16)
    private let recal = WiiButton("Recalibrate", textSize: 16)
    private let tutorialButton = WiiButton("Tutorial", textSize: 16)
    private let settingsButton = WiiButton("Settings", textSize: 16)
    private let mainMenuButton = WiiButton("Main Menu", textSize: 16)
    private let lifetime = WiiLabel(12, color: Wii.textSoft)
    private let version = WiiLabel(11, color: Wii.textSoft)
    let updateRow = UpdateRowView()

    private let shopHeader = WiiLabel(20, bold: true)
    private let shopSub = WiiLabel(13, color: Wii.textSoft)
    private let tabs = WiiTabs(MenuTab.allCases.map(\.title))
    private let playPanel: PlayPanel
    private let lanPanel: LANPanel
    let stylePanel: StylePanel
    private let goalsPanel: GoalsPanel
    private var birdCards: [ShopCardView] = []
    private var worldCards: [ShopCardView] = []
    private(set) var tab = MenuTab.birds
    private var showingWorlds: Bool { tab == .worlds }
    private var showingShop: Bool { tab == .birds || tab == .worlds }
    private let worldArt = WorldArtView()
    private var worldInfo: [WiiLabel] = []
    private let secretsList = SecretsListView()
    private var viewingWorld: WorldInfo
    private let preview = BirdPreviewView(frame: .zero)
    private let previewFrame = WiiFrame()
    private let detailTitle = WiiLabel(22, bold: true)
    private let detailBlurb = WiiLabel(13, color: Wii.textSoft)
    private let action = WiiButton("", textSize: 17)

    // Birds tab: the stat list and the panel for the picked stat.
    /// Stat row picked with a click or ↑ ↓ (← → turn its upgrades off and on).
    private var selectedStat = 0
    private let attackLine = WiiLabel(12, color: Wii.textSoft)
    private var statNames: [WiiLabel] = []
    private var statBars: [StatBarView] = []
    private var statValues: [WiiLabel] = []
    private let statSelect = StatSelection()
    private let statClick = StatClickArea()
    private let statPanel = StatPanelBackground()
    private let statTitle = WiiLabel(15, bold: true)
    private let statBlurb = WiiLabel(13, color: Wii.textSoft)
    private let statHint = WiiLabel(11, color: Wii.textSoft)
    private let statLevel = WiiLabel(14, bold: true)
    private let lowerButton = WiiButton("")
    private let raiseButton = WiiButton("")
    private let buyButton = WiiButton("", textSize: 14)

    private var viewing: Species

    init(progress: Progress, lan: LANSession) {
        self.progress = progress
        self.lan = lan
        playPanel = PlayPanel(progress: progress, lan: lan)
        lanPanel = LANPanel(lan: lan)
        stylePanel = StylePanel(progress: progress)
        goalsPanel = GoalsPanel(progress: progress)
        viewing = progress.selected
        viewingWorld = progress.world
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 0.72).cgColor
        panel.wantsLayer = true
        addSubview(panelGloss)
        addSubview(panel)

        title.text = "Paused"
        coinLabel.align = .right
        version.text = "Bird Game · \(AppVersion.display)"
        statLevel.align = .center
        statLevel.centerV = true
        statHint.centerV = true
        lowerButton.arrow = -1
        raiseButton.arrow = 1
        lowerButton.toolTip = "Turn one upgrade off (no refund — turn it back on any time)  ←"
        raiseButton.toolTip = "Turn a switched-off upgrade back on for free  →"
        for v in [title, coinLabel, resume, restart, recal, tutorialButton, settingsButton, mainMenuButton,
                  lifetime, version, shopHeader, shopSub, tabs, preview, previewFrame, worldArt, detailTitle, detailBlurb,
                  attackLine, statSelect, statPanel, statTitle, statBlurb, statHint, statLevel, lowerButton, raiseButton, buyButton,
                  action, playPanel, lanPanel, stylePanel, goalsPanel, updateRow, secretsList] as [NSView] {
            panel.addSubview(v)
        }

        resume.onClick = { [weak self] in self?.onResume?() }
        restart.onClick = { [weak self] in self?.onRestart?() }
        recal.onClick = { [weak self] in self?.onRecalibrate?() }
        tutorialButton.onClick = { [weak self] in self?.onTutorial?() }
        tutorialButton.toolTip = "A quick walk-through: how to fly, the modes, the shop and the hidden tricks. Jump to any step."
        settingsButton.onClick = { [weak self] in self?.showSettings() }
        settingsButton.toolTip = "Sound, the camera, the HUD, chat, graphics and updates"
        mainMenuButton.onClick = { [weak self] in self?.onMainMenu?() }
        mainMenuButton.toolTip = "Back to the title screen"
        settings.onClose = { [weak self] in self?.hideSettings() }
        lowerButton.onClick = { [weak self] in self.map { $0.lower(BirdStat(rawValue: $0.selectedStat)!) } }
        raiseButton.onClick = { [weak self] in self.map { $0.raise(BirdStat(rawValue: $0.selectedStat)!) } }
        buyButton.onClick = { [weak self] in self.map { $0.upgrade(BirdStat(rawValue: $0.selectedStat)!) } }

        tabs.onChange = { [weak self] i in self?.select(tab: MenuTab(rawValue: i) ?? .play) }
        for sp in Catalog.all {
            let c = ShopCardView(.bird(sp))
            c.onSelect = { [weak self] in self?.view(sp) }
            panel.addSubview(c)
            birdCards.append(c)
        }
        for w in WorldCatalog.all {
            let c = ShopCardView(.world(w))
            c.onSelect = { [weak self] in self?.viewingWorld = w; self?.refresh() }
            panel.addSubview(c)
            worldCards.append(c)
        }
        for _ in 0..<5 {
            let l = WiiLabel(13)
            l.centerV = true
            panel.addSubview(l)
            worldInfo.append(l)
        }
        for stat in BirdStat.allCases {
            let n = WiiLabel(13, bold: true)
            n.text = stat.name
            n.centerV = true
            let bar = StatBarView()
            let v = WiiLabel(12, color: Wii.textSoft)
            v.centerV = true
            v.align = .right
            for x in [n, bar, v] as [NSView] { panel.addSubview(x) }
            statNames.append(n); statBars.append(bar); statValues.append(v)
        }
        // On top of the rows so a click anywhere on a row picks it.
        statClick.onPick = { [weak self] i in self?.selectedStat = i; self?.refresh() }
        panel.addSubview(statClick)
        action.onClick = { [weak self] in self?.primaryAction() }
        coach.isHidden = true
        coach.wantsLayer = true
        coach.layer?.zPosition = 100
        coach.onNext = { [weak self] in self?.advanceTour() }
        coach.onSkip = { [weak self] in
            self?.endTour()
            self?.tourFinished?()
        }
        settings.isHidden = true
        settings.wantsLayer = true
        settings.layer?.zPosition = 50
        addSubview(settings)
        addSubview(coach)
        updateRow.show(.idle, current: AppVersion.short)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        onKey?(e.charactersIgnoringModifiers ?? "")
        if e.keyCode == 53 { onResume?(); return }
        // Birds tab: ↑↓ pick a stat, ← turns an upgrade off, → turns it back on.
        if tab == .birds {
            let n = BirdStat.allCases.count
            switch e.keyCode {
            case 126: selectedStat = (selectedStat + n - 1) % n; refresh(); return
            case 125: selectedStat = (selectedStat + 1) % n; refresh(); return
            case 123: lower(BirdStat(rawValue: selectedStat)!); return
            case 124: raise(BirdStat(rawValue: selectedStat)!); return
            default: break
            }
        }
        // The test codes' keys aren't used for anything else: no error beep for them.
        if let c = e.charactersIgnoringModifiers, c.count == 1, "[];',.".contains(c) { return }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) { onResume?() }
    override func mouseDown(with event: NSEvent) {}  // swallow clicks on the backdrop

    // MARK: State

    /// Fill in the settings card (called each time the menu opens).
    func setSettings(_ v: SettingsCard.Values) { settings.show(v) }

    func showSettings() {
        settings.isHidden = false
        needsLayout = true
        window?.makeFirstResponder(settings)
    }

    func hideSettings() {
        guard !settings.isHidden else { return }
        settings.isHidden = true
        window?.makeFirstResponder(self)
    }

    func willShow() {
        viewing = progress.selected
        viewingWorld = progress.world
        preview.isPlaying = tab == .birds
        if tab == .style { stylePanel.willShow() }
        if tab == .goals { goalsPanel.refresh() }
        refresh()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.15
        layer?.add(fade, forKey: "fade")
    }
    func didHide() { settings.isHidden = true; preview.isPlaying = false; stylePanel.didHide(); window?.makeFirstResponder(nil) }

    /// Which mode and map are being played (for the Play tab).
    func setPlaying(mode: GameMode, world: WorldID) {
        playPanel.setPlaying(mode: mode, world: world)
        lanPanel.playing = (mode, world)
        lanPanel.refresh()
    }

    /// The LAN session changed (players, games, invites…).
    func lanChanged() {
        lanPanel.refresh()
        playPanel.refresh()
    }

    func chatChanged() { lanPanel.chatChanged() }

    func select(tab t: MenuTab) {
        tab = t
        if t == .lan { lanPanel.refresh() }
        if t == .play { playPanel.refresh() }
        preview.isPlaying = t == .birds
        if t == .style { stylePanel.willShow() } else { stylePanel.didHide() }
        if t == .goals { goalsPanel.refresh() }
        window?.makeFirstResponder(self)
        refresh()
    }

    // MARK: Menu tour (tutorial)

    private let coach = CoachMarkView()
    private var tourIndex = -1
    private var tourFinished: (() -> Void)?
    var touring: Bool { tourIndex >= 0 }

    /// Walk through the tabs with highlights; `done` runs at the end (or when skipped).
    func startTour(done: @escaping () -> Void) {
        tourFinished = done
        tourIndex = 0
        coach.isHidden = false
        showTourStop()
    }

    func endTour() {
        coach.isHidden = true
        tourIndex = -1
    }

    private func showTourStop() {
        let stops = MenuTour.stops
        guard stops.indices.contains(tourIndex) else { return }
        let stop = stops[tourIndex]
        if let t = stop.tab { select(tab: t) }
        layoutSubtreeIfNeeded()
        coach.frame = bounds
        coach.hole = frameOf(stop.part)
        coach.show(stop, index: tourIndex, count: stops.count)
        Sounds.shared?.click()
    }

    /// Test hook: jump the tour forward.
    func debugAdvanceTour(_ n: Int) { for _ in 0..<n { advanceTour() } }

    private func advanceTour() {
        tourIndex += 1
        if tourIndex >= MenuTour.stops.count {
            endTour()
            tourFinished?()
        } else {
            showTourStop()
        }
    }

    /// Test hook: open the Worlds tab on a given world.
    func debugShowWorld(_ id: String) {
        tab = .worlds
        viewingWorld = WorldCatalog.info(id)
        refresh()
    }

    /// Test hook: open a tab.
    func debugShowTab(_ t: MenuTab) { select(tab: t) }
    func debugShowPlayMap(_ w: WorldID) { select(tab: .play); playPanel.debugSelect(w) }
    func debugScrollGoalsToEnd() { goalsPanel.debugScrollToEnd() }
    /// Test hook: the Birds tab showing one bird.
    func debugShowBird(_ sp: Species) { select(tab: .birds); view(sp) }

    /// Where a part of the menu is, in this view's coordinates (for the tutorial's highlights).
    func frameOf(_ part: MenuPart) -> NSRect {
        let v: NSView
        switch part {
        case .tabs: v = tabs
        case .tabArea: v = shopSub
        case .leftColumn: v = resume
        case .recalibrate: v = recal
        case .tutorial: v = tutorialButton
        case .settings: v = settingsButton
        case .resume: v = resume
        case .coins: v = coinLabel
        }
        var r = convert(v.bounds, from: v)
        switch part {
        case .tabArea:
            // The whole tab: header, tab bar and everything under them.
            let tabsRect = convert(tabs.bounds, from: tabs)
            let body = convert(playPanel.bounds, from: playPanel)
            let head = convert(shopHeader.bounds, from: shopHeader)
            r = r.union(tabsRect).union(body).union(head).insetBy(dx: -10, dy: -8)
        case .leftColumn:
            let last = convert(settingsButton.bounds, from: settingsButton)
            r = r.union(last).insetBy(dx: -8, dy: -8)
        case .recalibrate:
            r = r.union(convert(tutorialButton.bounds, from: tutorialButton)).insetBy(dx: -6, dy: -6)
        default:
            r = r.insetBy(dx: -6, dy: -6)
        }
        return r
    }

    func refresh() {
        coinLabel.text = "● \(progress.coins)"
        lifetime.text = "Rings flown: \(progress.totalRings)   Races: \(progress.racesFinished)\nWins: \(progress.wins)   Knock-outs: \(progress.knockouts)"
        let flying = progress.selected
        tabs.selected = tab.rawValue
        playPanel.isHidden = tab != .play
        lanPanel.isHidden = tab != .lan
        stylePanel.isHidden = tab != .style
        goalsPanel.isHidden = tab != .goals
        switch tab {
        case .play: shopHeader.text = "Play"; shopSub.text = "Pick a mode, then a map. Every mode pays out coins."
        case .lan: shopHeader.text = "LAN"; shopSub.text = "Play with friends on the same network. Host a game, or join or get invited to one."
        case .birds: shopHeader.text = "Birds"; shopSub.text = "Better birds cost more. Upgrade the birds you own with coins from flying, racing and fighting."
        case .style:
            shopHeader.text = "Style"
            shopSub.text = "Hats, glasses, neckwear, trails and paint jobs. Click one to try it on. Everyone in a LAN game sees it."
            stylePanel.refresh()
        case .worlds: shopHeader.text = "Worlds"; shopSub.text = "Unlock new worlds to fly, race and fight in."
        case .goals:
            shopHeader.text = "Goals"
            shopSub.text = "\(progress.goalsDoneCount) of \(GoalCatalog.all.count) done. Goals pay coins and unlock things you can't buy. "
                + (progress.finaleUnlocked ? "The Finale is open." : "Finish them all and something opens…")
            goalsPanel.refresh()
        }
        for c in birdCards {
            guard case .bird(let b) = c.item else { continue }
            c.isHidden = tab != .birds
            c.isHighlighted = b.id == viewing.id
            c.isEquipped = b.id == flying.id
            c.owned = progress.owns(b)
            c.affordable = progress.coins >= b.cost
        }
        let here = progress.world
        for c in worldCards {
            guard case .world(let w) = c.item else { continue }
            c.isHidden = tab != .worlds
            c.isHighlighted = w.id == viewingWorld.id
            c.isEquipped = w.id == here.id
            c.owned = progress.ownsWorld(w)
            c.affordable = progress.coins >= w.cost
        }
        let birds = tab == .birds
        for v in [preview, previewFrame, attackLine, statSelect, statClick, statPanel, statTitle, statBlurb, statHint, statLevel,
                  lowerButton, raiseButton, buyButton] as [NSView] { v.isHidden = !birds }
        for i in 0..<statBars.count { for v in [statNames[i], statBars[i], statValues[i]] as [NSView] { v.isHidden = !birds } }
        worldArt.isHidden = !showingWorlds
        for l in worldInfo { l.isHidden = !showingWorlds }
        secretsList.isHidden = true
        for v in [detailTitle, detailBlurb, action] as [NSView] { v.isHidden = !showingShop }
        if showingWorlds { refreshWorld(); needsLayout = true; needsDisplay = true; return }
        if !showingShop { needsLayout = true; needsDisplay = true; return }

        let sp = viewing
        let owned = progress.owns(sp)
        preview.show(sp)
        detailTitle.text = sp.name
        detailBlurb.text = sp.blurb
        attackLine.text = "Attack: \(sp.weapon.name) — \(sp.weapon.blurb)"
        for stat in BirdStat.allCases {
            let i = stat.rawValue
            let bought = progress.level(sp, stat)
            let on = progress.activeLevel(sp, stat)
            statBars[i].base = sp.base[i]
            statBars[i].upgrades = on
            statBars[i].bought = bought
            statBars[i].cap = sp.maxLevel
            statValues[i].text = "\(min(sp.base[i] + on, StatRules.maxPoints))  ·  Lv \(on)/\(sp.maxLevel)"
            statNames[i].color = i == selectedStat ? Wii.text : Wii.text.withAlphaComponent(0.85)
        }
        selectedStat = clamp(selectedStat, 0, BirdStat.allCases.count - 1)

        // The picked stat
        let stat = BirdStat(rawValue: selectedStat)!
        let bought = progress.level(sp, stat), on = progress.activeLevel(sp, stat)
        statTitle.text = stat.name
        var blurb = stat.blurb
        if stat == .luck { blurb += "  (● \(progress.coinsPerRing(sp)) per ring)" }
        statBlurb.text = blurb
        statLevel.text = "Lv \(on) / \(sp.maxLevel)"
        lowerButton.isEnabled = owned && on > 0
        raiseButton.isEnabled = owned && on < bought
        if sp.comingSoon {
            buyButton.title = "Coming soon"; buyButton.isEnabled = false
            statHint.text = ""
        } else if !owned {
            buyButton.title = "Upgrade"; buyButton.isEnabled = false
            statHint.text = "Buy \(sp.name) to upgrade it (up to \(sp.maxLevel) per stat)"
        } else if let cost = progress.upgradeCost(sp, stat) {
            buyButton.title = "Upgrade  ● \(cost)"; buyButton.isEnabled = progress.coins >= cost
            statHint.text = on < bought ? "\(bought - on) switched off — → turns it back on for free"
                : "← → switch upgrades off / on"
        } else {
            buyButton.title = sp.maxLevel < StatRules.maxLevel ? "Capped" : "Maxed"; buyButton.isEnabled = false
            statHint.text = sp.maxLevel < StatRules.maxLevel ? "\(sp.name) tops out at \(sp.maxLevel) — pricier birds go further"
                : "Fully upgraded. ← → turn upgrades off / on"
        }

        if sp.comingSoon {
            action.title = "Coming soon"; action.isEnabled = false
        } else if !owned {
            action.title = "Buy  ● \(sp.cost)"
            action.isEnabled = progress.coins >= sp.cost
        } else if sp.id == flying.id {
            action.title = "Flying this bird"; action.isEnabled = false
        } else {
            action.title = "Fly this bird"; action.isEnabled = true
        }
        needsLayout = true
        needsDisplay = true
    }

    private func refreshWorld() {
        let w = viewingWorld
        worldArt.world = w
        let locked = w.isFinale && !progress.finaleUnlocked
        worldArt.mystery = locked
        detailTitle.text = w.name
        detailBlurb.text = locked ? WorldCatalog.finaleTeaser : w.blurb
        if locked {
            let rows = ["Goals done:  \(progress.requiredGoalsDone) of \(GoalCatalog.required.count)", "", "", "", ""]
            for (l, t) in zip(worldInfo, rows) { l.text = t }
            secretsList.isHidden = true
            action.title = "Locked"; action.isEnabled = false
            return
        }
        let st = progress.stats(w)
        let secrets = WorldCatalog.secrets[w.id]
        let rows: [String] = secrets != nil ? [
            // Short, so the secrets fit underneath.
            "Ring value:  \(w.multiplierText) (double with a streak)   ·   Boost: +\(Int(w.ringBoost * 3.6)) km/h",
            "Hazards:  \(w.hazards)",
            "Best streak:  \(st.bestStreak)   ·   Rings here: \(st.rings)   ·   Coins earned: \(st.coins)",
            "", "",
        ] : w.isChallenge || w.comingSoon ? [
            "Ring value:  \(w.multiplierText), up to double with a streak",
            "Ring boost:  +\(Int(w.ringBoost * 3.6)) km/h",
            "Hazards:  \(w.hazards)",
            "Best streak:  \(st.bestStreak)",
            "Rings flown here:  \(st.rings)   ·   Coins earned: \(st.coins)",
        ] : [
            "Ring value:  ×1",
            "Ring boost:  +\(Int(w.ringBoost * 3.6)) km/h",
            "Hazards:  none — just fly",
            "Rings flown here:  \(st.rings)",
            "Coins earned here:  \(st.coins)",
        ]
        for (l, t) in zip(worldInfo, rows) { l.text = t }
        secretsList.isHidden = secrets == nil || !showingWorlds
        secretsList.world = w.id
        secretsList.found = Set((secrets ?? []).filter(progress.discovered))
        needsLayout = true
        if w.comingSoon {
            action.title = "Coming soon"; action.isEnabled = false
        } else if !progress.ownsWorld(w) {
            action.title = "Unlock  ● \(w.cost)"; action.isEnabled = progress.coins >= w.cost
        } else if lan.role == .joined {
            action.title = "Host picks the map"; action.isEnabled = false
        } else if w.id == progress.world.id {
            action.title = "You're here"; action.isEnabled = false
        } else if w.isFinale && !progress.finaleSeen && lan.role != .hosting {
            action.title = "Enter The Finale"; action.isEnabled = true
        } else {
            action.title = lan.role == .hosting ? "Take everyone here" : "Travel here"; action.isEnabled = true
        }
    }

    private func view(_ sp: Species) { viewing = sp; refresh() }

    private func upgrade(_ stat: BirdStat) {
        guard progress.upgrade(viewing, stat) else { NSSound.beep(); return }
        if viewing.id == progress.selected.id { onBirdChanged?(viewing) }
        refresh()
    }

    /// Switch one bought upgrade off (kept, free to turn back on).
    private func lower(_ stat: BirdStat) {
        selectedStat = stat.rawValue
        guard progress.lowerLevel(viewing, stat) else { NSSound.beep(); refresh(); return }
        if viewing.id == progress.selected.id { onBirdChanged?(viewing) }
        refresh()
    }

    private func raise(_ stat: BirdStat) {
        selectedStat = stat.rawValue
        guard progress.raiseLevel(viewing, stat) else { NSSound.beep(); refresh(); return }
        if viewing.id == progress.selected.id { onBirdChanged?(viewing) }
        refresh()
    }

    private func primaryAction() {
        if showingWorlds {
            let w = viewingWorld
            if progress.ownsWorld(w) { progress.selectWorld(w) } else if !progress.buyWorld(w) { NSSound.beep(); return }
            onWorldChanged?()
            refresh()
            return
        }
        if progress.owns(viewing) {
            progress.select(viewing)
        } else if !progress.buy(viewing) {
            NSSound.beep(); return
        }
        onBirdChanged?(progress.selected)
        refresh()
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        settings.frame = bounds
        coach.frame = bounds
        if touring, MenuTour.stops.indices.contains(tourIndex) { coach.hole = frameOf(MenuTour.stops[tourIndex].part) }
        let W = min(1120, bounds.width - 40), H = min(740, bounds.height - 40)
        panel.frame = NSRect(x: (bounds.width - W) / 2, y: (bounds.height - H) / 2, width: W, height: H)
        panelGloss.frame = panel.frame.insetBy(dx: -GlossBackground.margin, dy: -GlossBackground.margin)
        let pad: CGFloat = 32

        title.frame = NSRect(x: pad, y: 26, width: 300, height: 36)
        coinLabel.frame = NSRect(x: W - pad - 240, y: 30, width: 240, height: 30)
        let sep = pad + 50  // content starts below the header

        // Left column
        let sx = pad, sw: CGFloat = 230
        var y = sep + 20
        for b in [resume, restart, recal, tutorialButton, settingsButton, mainMenuButton] {
            b.frame = NSRect(x: sx - 5, y: y, width: sw + 10, height: 52); y += 58
        }
        y += 10
        lifetime.frame = NSRect(x: sx, y: y, width: sw, height: 44)
        version.frame = NSRect(x: sx, y: H - 30, width: sw, height: 16)
        // The update row replaces the version line (it names the version itself).
        version.isHidden = true
        updateRow.frame = NSRect(x: sx, y: H - 80, width: sw, height: 66)
        lifetime.isHidden = updateRow.frame.minY < lifetime.frame.maxY + 4

        // Tab area
        let x0 = sx + sw + 40, areaW = W - pad - x0
        shopHeader.frame = NSRect(x: x0, y: sep + 14, width: 200, height: 26)
        let tabsW = min(areaW - 110, 600)
        tabs.frame = NSRect(x: x0 + areaW - tabsW, y: sep + 6, width: tabsW, height: 42)
        shopSub.frame = NSRect(x: x0, y: sep + 50, width: areaW, height: 20)
        let gridTop = sep + 80
        playPanel.frame = NSRect(x: x0, y: gridTop, width: areaW, height: H - 30 - gridTop)
        lanPanel.frame = NSRect(x: x0, y: sep + 80, width: areaW, height: H - 30 - (sep + 80))
        stylePanel.frame = NSRect(x: x0, y: gridTop, width: areaW, height: H - 30 - gridTop)
        goalsPanel.frame = NSRect(x: x0, y: gridTop, width: areaW, height: H - 30 - gridTop)
        let birdRows = TabLayout.rows(birdCards.count), worldRows = TabLayout.rows(worldCards.count)
        for (cards, rows) in [(birdCards, birdRows), (worldCards, worldRows)] {
            for (i, card) in cards.enumerated() {
                card.frame = TabLayout.cardFrame(i, areaW: areaW, top: 0, rows: rows).offsetBy(dx: x0, dy: gridTop)
            }
        }
        let dy = gridTop + TabLayout.detailTop(rows: tab == .worlds ? worldRows : birdRows)
        let dh = H - 30 - dy
        let pw = TabLayout.pictureWidth(areaW)
        let pictureH = dh - TabLayout.actionH - 12
        preview.frame = NSRect(x: x0, y: dy, width: pw, height: pictureH)
        previewFrame.frame = preview.frame
        worldArt.frame = preview.frame
        action.frame = NSRect(x: x0 - 5, y: dy + dh - TabLayout.actionH, width: pw + 10, height: TabLayout.actionH)

        let cx = x0 + pw + 28, cw = areaW - pw - 28
        detailTitle.frame = NSRect(x: cx, y: dy - 4, width: cw, height: 30)
        detailBlurb.frame = NSRect(x: cx, y: dy + 30, width: cw, height: detailBlurb.fittingHeight(width: cw))
        let compact = !secretsList.isHidden
        for (i, l) in worldInfo.enumerated() {
            l.frame = NSRect(x: cx, y: dy + 30 + max(detailBlurb.frame.height, 36) + (compact ? 6 : 14) + CGFloat(i) * (compact ? 24 : 32),
                             width: cw, height: compact ? 22 : 28)
        }
        // The secrets box: under the facts, down to the bottom of the button.
        let secretsTop = worldInfo[2].frame.maxY + 8
        secretsList.frame = NSRect(x: cx, y: secretsTop, width: cw, height: max(120, dy + dh - secretsTop))

        // Birds: stat list, then the panel for the picked stat (bottom-aligned with the main button).
        attackLine.frame = NSRect(x: cx, y: dy + 30 + max(detailBlurb.frame.height, 18) + 2, width: cw, height: 16)
        let panelH: CGFloat = 94
        let panelTop = dy + dh - panelH
        let listTop = attackLine.frame.maxY + 8
        let rowH = min(26, (panelTop - 10 - listTop) / CGFloat(statBars.count))
        let nameW: CGFloat = 96, valueW: CGFloat = 104
        for i in 0..<statBars.count {
            let ry = listTop + CGFloat(i) * rowH
            statNames[i].frame = NSRect(x: cx, y: ry, width: nameW, height: rowH)
            statBars[i].frame = NSRect(x: cx + nameW, y: ry, width: cw - nameW - valueW - 12, height: rowH)
            statValues[i].frame = NSRect(x: cx + cw - valueW, y: ry, width: valueW, height: rowH)
        }
        statSelect.frame = NSRect(x: cx - 10, y: listTop + CGFloat(selectedStat) * rowH, width: cw + 20, height: rowH)
        statClick.frame = NSRect(x: cx - 10, y: listTop, width: cw + 20, height: rowH * CGFloat(statBars.count))
        statClick.rowHeight = rowH
        statPanel.frame = NSRect(x: cx - 10, y: panelTop, width: cw + 20, height: panelH)
        // Line 1: the stat's name and what it does.
        let titleW = Wii.attributed(statTitle.text, font: Wii.font(15, bold: true), color: Wii.text, align: .left).size().width + 12
        statTitle.frame = NSRect(x: cx + 4, y: panelTop + 12, width: titleW, height: 20)
        statBlurb.frame = NSRect(x: cx + 4 + titleW, y: panelTop + 14, width: cw - titleW - 8, height: 18)
        // Line 2: ◀ level ▶, a hint, and the upgrade button.
        let arrowW: CGFloat = 40, levelW: CGFloat = 78, buyW: CGFloat = 150, row = panelTop + 40
        lowerButton.frame = NSRect(x: cx - 1, y: row, width: arrowW, height: 44)
        statLevel.frame = NSRect(x: lowerButton.frame.maxX, y: row, width: levelW, height: 44)
        raiseButton.frame = NSRect(x: statLevel.frame.maxX, y: row, width: arrowW, height: 44)
        buyButton.frame = NSRect(x: cx + cw - buyW + 4, y: row - 2, width: buyW, height: 48)
        statHint.frame = NSRect(x: raiseButton.frame.maxX + 12, y: row + 6, width: buyButton.frame.minX - raiseButton.frame.maxX - 20, height: 32)
    }
}

/// Soft highlight behind the stat row picked with the arrow keys.
final class StatSelection: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Wii.blueLight.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// Invisible layer over the stat rows: a click picks the row under it.
final class StatClickArea: FlippedView {
    var rowHeight: CGFloat = 26
    var onPick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onPick?(clamp(Int(p.y / max(rowHeight, 1)), 0, BirdStat.allCases.count - 1))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Tile behind the picked stat's controls.
final class StatPanelBackground: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        Wii.tile(bounds.insetBy(dx: 1, dy: 1), radius: 12, fill: .white, bottom: Wii.tileLow, border: Wii.border, borderWidth: 1.5,
                 shadow: false)
    }
}
