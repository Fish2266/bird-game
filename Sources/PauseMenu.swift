import AppKit
import SceneKit

private func swatchColor(_ c: SIMD3<Float>) -> NSColor {
    NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
}

/// Stat bar: base points in blue, upgrades in light blue.
final class StatBarView: FlippedView {
    var base = 5 { didSet { needsDisplay = true } }
    var upgrades = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let n = CGFloat(StatRules.maxPoints)
        let track = NSRect(x: 0, y: (bounds.height - 10) / 2, width: bounds.width, height: 10)
        Wii.tileLow.setFill(); NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        let total = CGFloat(base + upgrades)
        guard total > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * total / n, height: track.height),
                     xRadius: 5, yRadius: 5).addClip()
        Wii.blue.setFill()
        NSRect(x: track.minX, y: track.minY, width: track.width * CGFloat(base) / n, height: track.height).fill()
        NSColor(srgbRed: 0.55, green: 0.84, blue: 0.97, alpha: 1).setFill()
        NSRect(x: track.minX + track.width * CGFloat(base) / n, y: track.minY,
               width: track.width * CGFloat(upgrades) / n, height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()
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
            swatchColor(b.look.wingMid).setFill(); NSBezierPath(ovalIn: sw).fill()
            swatchColor(b.look.body).setFill(); NSBezierPath(ovalIn: sw.insetBy(dx: 7, dy: 7)).fill()
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
        if !owned || comingSoon { NSColor.white.withAlphaComponent(0.55).setFill(); NSBezierPath(ovalIn: sw).fill() }
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

/// Esc screen: pause, settings and the bird shop.
final class PauseMenuView: NSView {
    let progress: Progress

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
    private let tabs = WiiTabs(["Birds", "Worlds"])
    private var birdCards: [ShopCardView] = []
    private var worldCards: [ShopCardView] = []
    private var showingWorlds = false
    private let worldArt = WorldArtView()
    private var worldInfo: [WiiLabel] = []
    private var viewingWorld: WorldInfo
    private let preview = BirdPreviewView(frame: .zero)
    private let previewFrame = WiiFrame()
    private let birdName = WiiLabel(22, bold: true)
    private let birdBlurb = WiiLabel(13, color: Wii.textSoft)
    private var statNames: [WiiLabel] = []
    private var statBars: [StatBarView] = []
    private var statLevels: [WiiLabel] = []
    private var statButtons: [WiiButton] = []
    private let perRing = WiiLabel(12, color: Wii.textSoft)
    private let action = WiiButton("", textSize: 17)

    private var viewing: Species

    init(progress: Progress) {
        self.progress = progress
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
        shopHeader.text = "Shop"
        shopSub.text = "Earn coins by flying through rings. Buy new birds and worlds, and upgrade the birds you own."
        for v in [title, coinLabel, resume, restart, recal, settingsHeader, soundBox, previewBox, helpBox, opacitySlider,
                  cameraSelector, lifetime, version, shopHeader, shopSub, tabs, preview, previewFrame, worldArt, birdName, birdBlurb,
                  perRing, action] as [NSView] {
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

        tabs.onChange = { [weak self] i in self?.showingWorlds = i == 1; self?.refresh() }
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
            n.toolTip = stat.blurb
            let bar = StatBarView()
            bar.toolTip = stat.blurb
            let lv = WiiLabel(12, color: Wii.textSoft)
            lv.centerV = true
            let b = WiiButton("", textSize: 12)
            b.toolTip = "Upgrade \(stat.name): \(stat.blurb.lowercased())"
            b.onClick = { [weak self] in self?.upgrade(stat) }
            for v in [n, bar, lv, b] as [NSView] { panel.addSubview(v) }
            statNames.append(n); statBars.append(bar); statLevels.append(lv); statButtons.append(b)
        }
        action.onClick = { [weak self] in self?.primaryAction() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Input

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        onKey?(e.charactersIgnoringModifiers ?? "")
        if e.keyCode == 53 { onResume?() } else { super.keyDown(with: e) }
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
    func didHide() { preview.isPlaying = false }

    /// Test hook: open the Worlds tab on a given world.
    func debugShowWorld(_ id: String) {
        showingWorlds = true
        viewingWorld = WorldCatalog.info(id)
        refresh()
    }

    func refresh() {
        coinLabel.text = "● \(progress.coins)"
        lifetime.text = "Rings flown: \(progress.totalRings)\nCoins earned: \(progress.coinsEarned)"
        let flying = progress.selected
        for c in birdCards {
            guard case .bird(let b) = c.item else { continue }
            c.isHidden = showingWorlds
            c.isHighlighted = b.id == viewing.id
            c.isEquipped = b.id == flying.id
            c.owned = progress.owns(b)
            c.affordable = progress.coins >= b.cost
        }
        let here = progress.world
        for c in worldCards {
            guard case .world(let w) = c.item else { continue }
            c.isHidden = !showingWorlds
            c.isHighlighted = w.id == viewingWorld.id
            c.isEquipped = w.id == here.id
            c.owned = progress.ownsWorld(w)
            c.affordable = progress.coins >= w.cost
        }
        tabs.selected = showingWorlds ? 1 : 0
        for v in [preview, previewFrame, perRing] as [NSView] { v.isHidden = showingWorlds }
        for i in 0..<statBars.count { for v in [statNames[i], statBars[i], statLevels[i], statButtons[i]] as [NSView] { v.isHidden = showingWorlds } }
        worldArt.isHidden = !showingWorlds
        for l in worldInfo { l.isHidden = !showingWorlds }
        if showingWorlds { refreshWorld(); needsLayout = true; needsDisplay = true; return }

        let sp = viewing
        let owned = progress.owns(sp)
        preview.show(sp)
        birdName.text = sp.name
        birdBlurb.text = sp.blurb
        for stat in BirdStat.allCases {
            let i = stat.rawValue
            let lv = progress.level(sp, stat)
            statBars[i].base = sp.base[i]
            statBars[i].upgrades = lv
            statLevels[i].text = "\(min(sp.base[i] + lv, StatRules.maxPoints))   Lv \(lv)/\(StatRules.maxLevel)"
            let b = statButtons[i]
            if let cost = progress.upgradeCost(sp, stat) {
                b.title = "Upgrade ● \(cost)"
                b.isEnabled = owned && progress.coins >= cost
                b.toolTip = owned ? "Upgrade \(stat.name): \(stat.blurb.lowercased())" : "Buy this bird to upgrade it"
            } else {
                b.title = "Max"
                b.isEnabled = false
            }
        }
        perRing.text = "● \(progress.coinsPerRing(sp)) per ring with this bird"
        if sp.comingSoon {
            action.title = "Coming soon"; action.isEnabled = false
            for b in statButtons { b.isEnabled = false }
        } else if !owned {
            action.title = "Buy  ● \(sp.cost)"
            action.isEnabled = progress.coins >= sp.cost
        } else if sp.id == flying.id {
            action.title = "Selected"; action.isEnabled = false
        } else {
            action.title = "Select"; action.isEnabled = true
        }
        needsLayout = true
        needsDisplay = true
    }

    private func refreshWorld() {
        let w = viewingWorld
        worldArt.world = w
        birdName.text = w.name
        birdBlurb.text = w.blurb
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
        } else if w.id == progress.world.id {
            action.title = "You're here"; action.isEnabled = false
        } else {
            action.title = "Travel here"; action.isEnabled = true
        }
    }

    private func view(_ sp: Species) { viewing = sp; refresh() }

    private func upgrade(_ stat: BirdStat) {
        guard progress.upgrade(viewing, stat) else { NSSound.beep(); return }
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

        // Shop
        let x0 = sx + sw + 40, areaW = W - pad - x0
        shopHeader.frame = NSRect(x: x0, y: sep + 14, width: 120, height: 26)
        tabs.frame = NSRect(x: x0 + areaW - 240, y: sep + 6, width: 240, height: 42)
        shopSub.frame = NSRect(x: x0, y: sep + 50, width: areaW, height: 20)
        let cols = 4, cardH: CGFloat = 70
        let cardW = (areaW + 10) / CGFloat(cols)
        let gy = sep + 74
        for cards in [birdCards, worldCards] {
            for (i, card) in cards.enumerated() {
                let r = i / cols, col = i % cols
                card.frame = NSRect(x: x0 - 5 + CGFloat(col) * cardW, y: gy + CGFloat(r) * cardH, width: cardW, height: cardH)
            }
        }
        let rows = 2
        let dy = gy + CGFloat(rows) * cardH + 16
        let dh = H - 30 - dy
        let pw = min(280, areaW * 0.36)
        preview.frame = NSRect(x: x0, y: dy, width: pw, height: dh)
        previewFrame.frame = preview.frame
        worldArt.frame = preview.frame

        let cx = x0 + pw + 24, cw = areaW - pw - 24
        birdName.frame = NSRect(x: cx, y: dy, width: cw, height: 30)
        birdBlurb.frame = NSRect(x: cx, y: dy + 34, width: cw, height: birdBlurb.fittingHeight(width: cw))
        let top = dy + 34 + max(birdBlurb.frame.height, 36) + 10
        let rowH: CGFloat = min(42, (dh - (top - dy) - 90) / 5)
        let btnW: CGFloat = 132, lvW: CGFloat = 84, nameW: CGFloat = 96
        for i in 0..<statBars.count {
            let ry = top + CGFloat(i) * rowH
            statNames[i].frame = NSRect(x: cx, y: ry, width: nameW, height: rowH)
            statBars[i].frame = NSRect(x: cx + nameW, y: ry, width: cw - nameW - lvW - btnW - 10, height: rowH)
            statLevels[i].frame = NSRect(x: cx + cw - btnW - lvW + 4, y: ry, width: lvW, height: rowH)
            statButtons[i].frame = NSRect(x: cx + cw - btnW, y: ry + (rowH - 40) / 2, width: btnW, height: 40)
        }
        for (i, l) in worldInfo.enumerated() {
            l.frame = NSRect(x: cx, y: top + CGFloat(i) * 34, width: cw, height: 30)
        }
        perRing.frame = NSRect(x: cx, y: dy + dh - 82, width: cw, height: 18)
        action.frame = NSRect(x: cx - 5, y: dy + dh - 60, width: min(280, cw), height: 60)
    }
}
