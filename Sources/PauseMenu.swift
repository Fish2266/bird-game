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
        col(l.head).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - 2.8 * s, y: c.y - 11 * s, width: 5.6 * s, height: 5.6 * s)).fill()
        let b = NSBezierPath()
        b.move(to: NSPoint(x: c.x - 1 * s, y: c.y - 10.5 * s))
        b.line(to: NSPoint(x: c.x, y: c.y - 14 * s))
        b.line(to: NSPoint(x: c.x + 1 * s, y: c.y - 10.5 * s))
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
        if case .world = item, !owned || comingSoon {
            NSColor.white.withAlphaComponent(0.55).setFill(); NSBezierPath(roundedRect: sw, xRadius: 7, yRadius: 7).fill()
        }
        let tx = sw.maxX + 10, tw = r.maxX - tx - 8
        Wii.drawText(name, in: NSRect(x: tx, y: r.minY + 12, width: tw, height: 20), size: 13, bold: true,
                     color: comingSoon ? Wii.textSoft : Wii.text, truncate: true)
        let status: String
        var color = Wii.textSoft
        if comingSoon { status = "Coming soon" }
        else if isEquipped { status = "Selected"; color = Wii.blue }
        else if owned { status = "Owned" }
        else { status = "● \(cost)"; if !affordable { color = NSColor(srgbRed: 0.8, green: 0.35, blue: 0.3, alpha: 1) } }
        Wii.drawText(status, in: NSRect(x: tx, y: r.minY + 33, width: tw, height: 18), size: 12, color: color, truncate: true)
    }
}

/// Simple painting of a world for the shop.
final class WorldArtView: FlippedView {
    var world: WorldInfo? { didSet { needsDisplay = true } }

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

/// Turntable 3D preview of a species on a plain light backdrop.
final class BirdPreviewView: SCNView {
    private let pivot = SCNNode()
    private var bird: BirdNode?

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
        pivot.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16)))

        let cam = SCNNode()
        cam.camera = SCNCamera()
        cam.camera?.projectionDirection = .horizontal
        cam.camera?.fieldOfView = 50
        cam.simdPosition = SIMD3(0, 1.45, 3.7)
        cam.simdLook(at: SIMD3(0, 0, 0), up: kUp, localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(cam)
        pointOfView = cam
        rendersContinuously = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ sp: Species) {
        bird?.node.removeFromParentNode()
        let b = BirdNode(look: sp.look)
        b.pose(left: WingPose(elevation: 0.18, bend: -0.1), right: WingPose(elevation: 0.18, bend: -0.1),
               fold: 0, pitchIn: 0, rollIn: 0, dt: 1)
        b.node.simdPosition = SIMD3(0, -0.1, 0)
        let fit = 1 / max(sp.look.span * 0.9, sp.look.size)
        b.node.simdScale = SIMD3(repeating: fit)
        pivot.addChildNode(b.node)
        bird = b
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
    static func cardFrame(_ i: Int, areaW: CGFloat, top: CGFloat) -> NSRect {
        let w = (areaW + 10) / CGFloat(columns)
        return NSRect(x: -5 + CGFloat(i % columns) * w, y: top + CGFloat(i / columns) * cardH, width: w, height: cardH)
    }
    static var detailTop: CGFloat { cardH * 2 + gap }
}

/// Esc screen: pause, settings and the bird shop.
final class PauseMenuView: NSView {
    let progress: Progress
    let lan: LANSession

    var onResume: (() -> Void)?
    var onRestart: (() -> Void)?
    var onRecalibrate: (() -> Void)?
    var onSound: ((Bool) -> Void)?
    var onPreview: ((Bool) -> Void)?
    var onHelp: ((Bool) -> Void)?
    var onHUDOpacity: ((CGFloat) -> Void)?
    var onCamera: ((String) -> Void)?
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

    private let panel = FlippedView()
    private let panelGloss = GlossBackground()
    private let title = WiiLabel(28, bold: true)
    private let coinLabel = WiiLabel(20, bold: true)

    private let resume = WiiButton("Resume", textSize: 17)
    private let restart = WiiButton("Restart")
    private let recal = WiiButton("Recalibrate")
    private let settingsHeader = WiiLabel(13, color: Wii.textSoft)
    private let soundBox = WiiToggle("Sound")
    private let previewBox = WiiToggle("Camera preview")
    private let helpBox = WiiToggle("Help")
    private let opacitySlider = WiiSlider("HUD opacity")
    private let cameraSelector = WiiSelector("Camera")
    private var cameras: [(id: String, name: String)] = []
    private var cameraIndex = 0
    private let lifetime = WiiLabel(12, color: Wii.textSoft)
    private let version = WiiLabel(11, color: Wii.textSoft)

    private let shopHeader = WiiLabel(20, bold: true)
    private let shopSub = WiiLabel(13, color: Wii.textSoft)
    private let tabs = WiiTabs(["Play", "LAN", "Birds", "Worlds"])
    private let playPanel: PlayPanel
    private let lanPanel: LANPanel
    private var birdCards: [ShopCardView] = []
    private var worldCards: [ShopCardView] = []
    /// 0 Play, 1 LAN, 2 Birds, 3 Worlds.
    private var tab = 2
    private var showingWorlds: Bool { tab == 3 }
    private var showingShop: Bool { tab >= 2 }
    private let worldArt = WorldArtView()
    private var worldInfo: [WiiLabel] = []
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
        settingsHeader.text = "Settings"
        version.text = "Bird Game · \(AppVersion.display)"
        statLevel.align = .center
        statLevel.centerV = true
        statHint.centerV = true
        lowerButton.arrow = -1
        raiseButton.arrow = 1
        lowerButton.toolTip = "Turn one upgrade off (no refund — turn it back on any time)  ←"
        raiseButton.toolTip = "Turn a switched-off upgrade back on for free  →"
        for v in [title, coinLabel, resume, restart, recal, settingsHeader, soundBox, previewBox, helpBox, opacitySlider,
                  cameraSelector, lifetime, version, shopHeader, shopSub, tabs, preview, previewFrame, worldArt, detailTitle, detailBlurb,
                  attackLine, statSelect, statPanel, statTitle, statBlurb, statHint, statLevel, lowerButton, raiseButton, buyButton,
                  action, playPanel, lanPanel] as [NSView] {
            panel.addSubview(v)
        }

        resume.onClick = { [weak self] in self?.onResume?() }
        restart.onClick = { [weak self] in self?.onRestart?() }
        recal.onClick = { [weak self] in self?.onRecalibrate?() }
        soundBox.onChange = { [weak self] on in self?.onSound?(on) }
        previewBox.onChange = { [weak self] on in self?.onPreview?(on) }
        helpBox.onChange = { [weak self] on in self?.onHelp?(on) }
        opacitySlider.onChange = { [weak self] v in self?.onHUDOpacity?(v) }
        cameraSelector.onClick = { [weak self] in self?.nextCamera() }
        lowerButton.onClick = { [weak self] in self.map { $0.lower(BirdStat(rawValue: $0.selectedStat)!) } }
        raiseButton.onClick = { [weak self] in self.map { $0.raise(BirdStat(rawValue: $0.selectedStat)!) } }
        buyButton.onClick = { [weak self] in self.map { $0.upgrade(BirdStat(rawValue: $0.selectedStat)!) } }

        tabs.onChange = { [weak self] i in self?.select(tab: i) }
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
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        onKey?(e.charactersIgnoringModifiers ?? "")
        if e.keyCode == 53 { onResume?(); return }
        // Birds tab: ↑↓ pick a stat, ← turns an upgrade off, → turns it back on.
        if tab == 2 {
            let n = BirdStat.allCases.count
            switch e.keyCode {
            case 126: selectedStat = (selectedStat + n - 1) % n; refresh(); return
            case 125: selectedStat = (selectedStat + 1) % n; refresh(); return
            case 123: lower(BirdStat(rawValue: selectedStat)!); return
            case 124: raise(BirdStat(rawValue: selectedStat)!); return
            default: break
            }
        }
        super.keyDown(with: e)
    }
    override func cancelOperation(_ sender: Any?) { onResume?() }
    override func mouseDown(with event: NSEvent) {}  // swallow clicks on the backdrop

    // MARK: State

    func setSettings(sound: Bool, preview: Bool, help: Bool, hudOpacity: CGFloat,
                     cameras: [(id: String, name: String)], current: String?) {
        opacitySlider.value = hudOpacity
        soundBox.setOn(sound)
        previewBox.setOn(preview)
        helpBox.setOn(help)
        self.cameras = cameras
        cameraIndex = cameras.firstIndex { $0.id == current } ?? 0
        cameraSelector.value = cameras.isEmpty ? "No camera" : cameras[cameraIndex].name
    }

    private func nextCamera() {
        guard cameras.count > 1 else { NSSound.beep(); return }
        cameraIndex = (cameraIndex + 1) % cameras.count
        cameraSelector.value = cameras[cameraIndex].name
        onCamera?(cameras[cameraIndex].id)
    }

    func willShow() {
        viewing = progress.selected
        viewingWorld = progress.world
        preview.isPlaying = true
        refresh()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.15
        layer?.add(fade, forKey: "fade")
    }
    func didHide() { preview.isPlaying = false; window?.makeFirstResponder(nil) }

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

    private func select(tab i: Int) {
        tab = i
        if i == 1 { lanPanel.refresh() }
        if i == 0 { playPanel.refresh() }
        window?.makeFirstResponder(self)
        refresh()
    }

    /// Test hook: open the Worlds tab on a given world.
    func debugShowWorld(_ id: String) {
        tab = 3
        viewingWorld = WorldCatalog.info(id)
        refresh()
    }

    /// Test hook: open a tab by index (0 Play, 1 LAN, 2 Birds, 3 Worlds).
    func debugShowTab(_ i: Int) { select(tab: i) }

    func refresh() {
        coinLabel.text = "● \(progress.coins)"
        lifetime.text = "Rings flown: \(progress.totalRings)   Races: \(progress.racesFinished)\nWins: \(progress.wins)   Knock-outs: \(progress.knockouts)"
        let flying = progress.selected
        tabs.selected = tab
        playPanel.isHidden = tab != 0
        lanPanel.isHidden = tab != 1
        switch tab {
        case 0: shopHeader.text = "Play"; shopSub.text = "Pick a mode, then a map. Every mode pays out coins."
        case 1: shopHeader.text = "LAN"; shopSub.text = "Play with friends on the same network. Host a game, or join or get invited to one."
        case 2: shopHeader.text = "Birds"; shopSub.text = "Better birds cost more. Upgrade the birds you own with coins from flying, racing and fighting."
        default: shopHeader.text = "Worlds"; shopSub.text = "Unlock new worlds to fly, race and fight in."
        }
        for c in birdCards {
            guard case .bird(let b) = c.item else { continue }
            c.isHidden = tab != 2
            c.isHighlighted = b.id == viewing.id
            c.isEquipped = b.id == flying.id
            c.owned = progress.owns(b)
            c.affordable = progress.coins >= b.cost
        }
        let here = progress.world
        for c in worldCards {
            guard case .world(let w) = c.item else { continue }
            c.isHidden = tab != 3
            c.isHighlighted = w.id == viewingWorld.id
            c.isEquipped = w.id == here.id
            c.owned = progress.ownsWorld(w)
            c.affordable = progress.coins >= w.cost
        }
        let birds = tab == 2
        for v in [preview, previewFrame, attackLine, statSelect, statClick, statPanel, statTitle, statBlurb, statHint, statLevel,
                  lowerButton, raiseButton, buyButton] as [NSView] { v.isHidden = !birds }
        for i in 0..<statBars.count { for v in [statNames[i], statBars[i], statValues[i]] as [NSView] { v.isHidden = !birds } }
        worldArt.isHidden = !showingWorlds
        for l in worldInfo { l.isHidden = !showingWorlds }
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
        detailTitle.text = w.name
        detailBlurb.text = w.blurb
        let st = progress.stats(w)
        let rows: [String] = w.isChallenge || w.comingSoon ? [
            "Ring value:  ×\(Int(w.ringMultiplier)), plus a streak bonus",
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
        if w.comingSoon {
            action.title = "Coming soon"; action.isEnabled = false
        } else if !progress.ownsWorld(w) {
            action.title = "Unlock  ● \(w.cost)"; action.isEnabled = progress.coins >= w.cost
        } else if lan.role == .joined {
            action.title = "Host picks the map"; action.isEnabled = false
        } else if w.id == progress.world.id {
            action.title = "You're here"; action.isEnabled = false
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
        resume.frame = NSRect(x: sx - 5, y: y, width: sw + 10, height: 56); y += 60
        restart.frame = NSRect(x: sx - 5, y: y, width: sw + 10, height: 48); y += 50
        recal.frame = NSRect(x: sx - 5, y: y, width: sw + 10, height: 48); y += 66
        settingsHeader.frame = NSRect(x: sx, y: y, width: sw, height: 18); y += 26
        for b in [soundBox, previewBox, helpBox] { b.frame = NSRect(x: sx, y: y, width: sw, height: 32); y += 38 }
        opacitySlider.frame = NSRect(x: sx - 12, y: y + 2, width: sw + 24, height: 48); y += 56
        cameraSelector.frame = NSRect(x: sx, y: y, width: sw, height: 58); y += 70
        lifetime.frame = NSRect(x: sx, y: y, width: sw, height: 44)
        version.frame = NSRect(x: sx, y: H - 30, width: sw, height: 16)

        // Tab area
        let x0 = sx + sw + 40, areaW = W - pad - x0
        shopHeader.frame = NSRect(x: x0, y: sep + 14, width: 200, height: 26)
        tabs.frame = NSRect(x: x0 + areaW - 420, y: sep + 6, width: 420, height: 42)
        shopSub.frame = NSRect(x: x0, y: sep + 50, width: areaW, height: 20)
        let gridTop = sep + 80
        playPanel.frame = NSRect(x: x0, y: gridTop, width: areaW, height: H - 30 - gridTop)
        lanPanel.frame = NSRect(x: x0, y: sep + 80, width: areaW, height: H - 30 - (sep + 80))
        for cards in [birdCards, worldCards] {
            for (i, card) in cards.enumerated() {
                card.frame = TabLayout.cardFrame(i, areaW: areaW, top: 0).offsetBy(dx: x0, dy: gridTop)
            }
        }
        let dy = gridTop + TabLayout.detailTop
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
        for (i, l) in worldInfo.enumerated() {
            l.frame = NSRect(x: cx, y: dy + 30 + max(detailBlurb.frame.height, 36) + 14 + CGFloat(i) * 32, width: cw, height: 28)
        }

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
