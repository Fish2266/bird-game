import AppKit
import SceneKit

// The "Style" (cosmetics shop) and "Goals" tabs of the pause menu.

// MARK: - Thumbnails

/// Little pictures of each cosmetic for the shop cards: hats, glasses and neckwear rendered on a head in 3D, trails and
/// paints drawn in 2D. The 3D ones are made in the background soon after launch (and kept on disk between launches), so
/// the Style tab opens with every picture ready.
enum CosmeticThumbs {
    private static var cache: [String: NSImage] = [:]
    private static var pending = Set<String>()
    /// Cards waiting for a picture (called on the main queue when it's ready).
    private static var waiters: [String: [() -> Void]] = [:]
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "bird.thumbs", qos: .utility)

    private static func is3D(_ c: Cosmetic) -> Bool { c.slot != .trail && c.slot != .paint }

    /// The picture if it's ready; otherwise it's on its way and `ready` is called on the main queue when it is.
    static func image(_ c: Cosmetic, ready: @escaping () -> Void) -> NSImage? {
        lock.lock()
        if let img = cache[c.id] { lock.unlock(); return img }
        guard is3D(c) else {
            let img = draw2D(c)
            cache[c.id] = img
            lock.unlock()
            return img
        }
        waiters[c.id, default: []].append(ready)
        let start = pending.insert(c.id).inserted
        lock.unlock()
        if start { queue.async { make([c]) } }
        return nil
    }

    /// Make every 3D picture now, in the background (called shortly after launch). Hats first: the tab opens on them.
    /// `done` runs on the main queue once they're all ready.
    static func warmUp(done: (() -> Void)? = nil) {
        let items = CosmeticCatalog.all.filter(is3D)
        lock.lock()
        let todo = items.filter { cache[$0.id] == nil && pending.insert($0.id).inserted }
        lock.unlock()
        queue.async {
            make(todo)
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }

    private static func make(_ items: [Cosmetic]) {
        guard !items.isEmpty else { return }
        let start = CACurrentMediaTime()
        var studio: Studio?
        var rendered = 0
        for c in items {
            let img: NSImage
            if let saved = loadSaved(c) {
                img = saved
            } else {
                if studio == nil { studio = Studio() }
                img = studio!.render(c)
                save(img, c)
                rendered += 1
            }
            lock.lock()
            cache[c.id] = img
            pending.remove(c.id)
            let w = waiters.removeValue(forKey: c.id) ?? []
            lock.unlock()
            if !w.isEmpty { DispatchQueue.main.async { w.forEach { $0() } } }
        }
        if items.count > 1 {
            Log.write(String(format: "cosmetic pictures: %d ready (%d rendered) in %.2f s", items.count, rendered, CACurrentMediaTime() - start))
        }
    }

    // MARK: Disk cache

    /// One folder per build, so pictures are redone whenever the models might have changed.
    private static let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let root = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "BirdGame", isDirectory: true)
            .appendingPathComponent("CosmeticPictures", isDirectory: true)
        let dir = root.appendingPathComponent("\(AppVersion.short)-\(AppVersion.build ?? "0")", isDirectory: true)
        // Throw away the pictures of older builds.
        for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where old != dir {
            try? FileManager.default.removeItem(at: old)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func loadSaved(_ c: Cosmetic) -> NSImage? {
        guard let url = folder?.appendingPathComponent("\(c.id).png"), let img = NSImage(contentsOf: url), img.isValid else { return nil }
        return img
    }

    private static func save(_ img: NSImage, _ c: Cosmetic) {
        guard let url = folder?.appendingPathComponent("\(c.id).png"), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    // MARK: Rendering

    /// One lit scene, camera and renderer reused for every picture (making a renderer per picture was slow).
    private final class Studio {
        let scene = SCNScene()
        let cam = SCNNode()
        let renderer: SCNRenderer

        init() {
            scene.lightingEnvironment.contents = Sky.cachedFaces
            scene.lightingEnvironment.intensity = 1.2
            scene.background.contents = NSColor(srgbRed: 0.86, green: 0.93, blue: 0.98, alpha: 1)
            let sun = SCNNode()
            sun.light = SCNLight()
            sun.light?.type = .directional
            sun.light?.intensity = 1500
            sun.simdLook(at: SIMD3(0.3, -1, -0.8), up: kUp, localFront: SIMD3(0, 0, -1))
            scene.rootNode.addChildNode(sun)
            cam.camera = SCNCamera()
            cam.camera?.zNear = 0.02
            cam.camera?.fieldOfView = 30
            scene.rootNode.addChildNode(cam)
            renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = scene
            renderer.pointOfView = cam
        }

        func render(_ c: Cosmetic) -> NSImage {
            var o = Outfit()
            o[c.slot] = c.id
            let bird = BirdNode(look: Catalog.species("gull").look, outfit: o)
            bird.pose(left: WingPose(elevation: 0.15, bend: 0), right: WingPose(elevation: 0.15, bend: 0), fold: 0, pitchIn: 0, rollIn: 0, dt: 1)
            bird.tick(dt: 0.2, speed: 10, camera: .zero, emitting: false)
            scene.rootNode.addChildNode(bird.node)
            defer { bird.node.removeFromParentNode() }
            let k: Float = 1.25
            let head = BirdLook().headCenter * k
            let focus: SIMD3<Float>, offset: SIMD3<Float>
            switch c.slot {
            case .hat:
                // Centre on the hat itself; big ones need a step back.
                let tall: Set<String> = ["wizard", "tophat", "party", "unicorn", "viking", "halo"]
                let wide: Set<String> = ["sombrero", "cowboy", "pirate"]
                focus = head + SIMD3(0, (tall.contains(c.id) ? 0.14 : 0.1) * k, 0)
                offset = SIMD3(0.36, 0.2, -0.56) * (wide.contains(c.id) ? 1.3 : (tall.contains(c.id) ? 1.15 : 0.95))
            case .eyes:
                focus = head + SIMD3(0, 0.035, -0.07) * k
                offset = SIMD3(0.2, 0.06, -0.46) * (c.id == "monocle" ? 1.15 : 1)
            default:
                focus = SIMD3<Float>(0, 0.0, -0.37) * k
                offset = c.id == "scarf" || c.id == "rainbowscarf" ? SIMD3(0.5, 0.45, 0.35) : SIMD3(0.42, -0.04, -0.52)
            }
            cam.simdPosition = focus + offset
            cam.simdLook(at: focus, up: kUp, localFront: SIMD3(0, 0, -1))
            return renderer.snapshot(atTime: 0, with: CGSize(width: 128, height: 128), antialiasingMode: .multisampling4X)
        }
    }

    private static func draw2D(_ c: Cosmetic) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: true) { r in
            NSColor(srgbRed: 0.86, green: 0.93, blue: 0.98, alpha: 1).setFill(); r.fill()
            if c.slot == .paint {
                BirdIcon.draw(Catalog.species("gull").look.painted(c.id), in: r.insetBy(dx: 10, dy: 10))
            } else {
                TrailIcon.draw(c.id, in: r.insetBy(dx: 12, dy: 12))
            }
            return true
        }
    }
}

/// 2D pictures of trails: a swoosh in the trail's colors, or its sprites along a curve.
enum TrailIcon {
    static func draw(_ id: String, in r: NSRect) {
        func arc(_ offset: CGFloat) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX, y: r.maxY - r.height * 0.2 + offset))
            p.curve(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.25 + offset),
                    controlPoint1: NSPoint(x: r.minX + r.width * 0.45, y: r.maxY + offset),
                    controlPoint2: NSPoint(x: r.minX + r.width * 0.55, y: r.minY + offset))
            return p
        }
        func stroke(_ p: NSBezierPath, _ c: NSColor, _ w: CGFloat) { p.lineWidth = w; p.lineCapStyle = .round; c.setStroke(); p.stroke() }
        func sprite(_ img: CGImage, _ color: NSColor, at t: CGFloat, size: CGFloat) {
            // Along the same curve (approximately).
            let x = r.minX + r.width * t
            let y = r.maxY - r.height * 0.2 - sin(t * .pi) * r.height * 0.28 - t * r.height * 0.35
            let rect = NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY); ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: -rect.midX, y: -rect.midY)
            ctx.clip(to: rect, mask: img)
            color.setFill(); rect.fill()
            ctx.restoreGState()
        }
        let colorful: [NSColor] = [NSColor(srgbRed: 0.95, green: 0.3, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.25, green: 0.6, blue: 0.95, alpha: 1),
                                   NSColor(srgbRed: 0.3, green: 0.75, blue: 0.35, alpha: 1), NSColor(srgbRed: 0.95, green: 0.7, blue: 0.15, alpha: 1)]
        switch id {
        case "contrails":
            stroke(arc(-11), NSColor(white: 1, alpha: 0.95), 11); stroke(arc(11), NSColor(white: 1, alpha: 0.95), 11)
            stroke(arc(-11), NSColor(white: 0.7, alpha: 1), 3); stroke(arc(11), NSColor(white: 0.7, alpha: 1), 3)
        case "neon":
            stroke(arc(-9), NSColor(srgbRed: 1, green: 0.3, blue: 0.85, alpha: 0.5), 12); stroke(arc(-9), NSColor(srgbRed: 1, green: 0.55, blue: 0.95, alpha: 1), 5)
            stroke(arc(9), NSColor(srgbRed: 0.2, green: 0.9, blue: 1, alpha: 0.5), 12); stroke(arc(9), NSColor(srgbRed: 0.6, green: 1, blue: 1, alpha: 1), 5)
        case "rainbow":
            let cols: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
            for (i, c) in cols.enumerated() { stroke(arc(CGFloat(i - 3) * 8 + 4), c, 8.5) }
        case "stardust":
            stroke(arc(0), NSColor(srgbRed: 0.55, green: 0.42, blue: 1, alpha: 0.6), 10)
            for (t, s) in [(0.15, 20.0), (0.4, 14.0), (0.62, 22.0), (0.85, 12.0)] as [(CGFloat, CGFloat)] {
                sprite(TrailSprites.star, NSColor(srgbRed: 0.6, green: 0.55, blue: 1, alpha: 1), at: t, size: s * 1.4)
            }
        case "sparkles":
            for (t, s) in [(0.12, 22.0), (0.35, 16.0), (0.58, 26.0), (0.82, 18.0)] as [(CGFloat, CGFloat)] {
                sprite(TrailSprites.star, NSColor(srgbRed: 1, green: 0.72, blue: 0.1, alpha: 1), at: t, size: s * 1.5)
            }
        case "bubbles":
            for (t, s) in [(0.12, 20.0), (0.36, 28.0), (0.62, 18.0), (0.86, 24.0)] as [(CGFloat, CGFloat)] {
                sprite(TrailSprites.bubble, NSColor(srgbRed: 0.25, green: 0.55, blue: 0.95, alpha: 1), at: t, size: s * 1.4)
            }
        case "hearts":
            for (t, s) in [(0.14, 22.0), (0.4, 30.0), (0.7, 24.0)] as [(CGFloat, CGFloat)] {
                sprite(TrailSprites.heart, NSColor(srgbRed: 1, green: 0.25, blue: 0.5, alpha: 1), at: t, size: s * 1.4)
            }
        case "leaves":
            for (i, (t, s)) in ([(0.12, 24.0), (0.4, 30.0), (0.7, 24.0)] as [(CGFloat, CGFloat)]).enumerated() {
                sprite(TrailSprites.leaf, [NSColor.systemOrange, NSColor.systemRed, NSColor(srgbRed: 0.9, green: 0.7, blue: 0.1, alpha: 1)][i], at: t, size: s * 1.4)
            }
        case "snow":
            for (t, s) in [(0.14, 26.0), (0.42, 20.0), (0.72, 30.0)] as [(CGFloat, CGFloat)] {
                sprite(TrailSprites.flake, NSColor(srgbRed: 0.35, green: 0.55, blue: 0.85, alpha: 1), at: t, size: s * 1.4)
            }
        case "notes":
            for (i, (t, s)) in ([(0.14, 26.0), (0.42, 32.0), (0.74, 26.0)] as [(CGFloat, CGFloat)]).enumerated() {
                sprite(TrailSprites.note, colorful[i], at: t, size: s * 1.4)
            }
        case "confetti":
            for i in 0..<9 {
                let t = CGFloat(i) / 8
                sprite(TrailSprites.square, colorful[i % 4], at: t * 0.9 + 0.05, size: 26)
            }
        case "smoke":
            stroke(arc(-12), NSColor(srgbRed: 0.95, green: 0.25, blue: 0.25, alpha: 0.8), 11)
            stroke(arc(0), NSColor(white: 1, alpha: 0.95), 11)
            stroke(arc(12), NSColor(srgbRed: 0.25, green: 0.45, blue: 0.95, alpha: 0.8), 11)
        case "fire":
            stroke(arc(0), NSColor(srgbRed: 1, green: 0.35, blue: 0.05, alpha: 0.6), 18)
            stroke(arc(0), NSColor(srgbRed: 1, green: 0.7, blue: 0.2, alpha: 1), 9)
            stroke(arc(0), NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 1), 3)
        default:
            break
        }
    }
}

// MARK: - Cards

/// One cosmetic in the Style tab.
final class CosmeticCardView: FlippedView {
    var item: Cosmetic { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }
    var wearing = false { didSet { needsDisplay = true } }
    var owned = false { didSet { needsDisplay = true } }
    var affordable = false { didSet { needsDisplay = true } }
    private var hover = false

    init(_ item: Cosmetic) {
        self.item = item
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

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
        let r = bounds.insetBy(dx: 4, dy: 4)
        let border = isHighlighted ? Wii.blue : (hover ? Wii.blueLight : Wii.border)
        Wii.tile(r, radius: 10, fill: .white, bottom: Wii.tileLow, border: border, borderWidth: isHighlighted ? 3 : 2)
        let side = r.height - 14
        let pic = NSRect(x: r.minX + 8, y: r.minY + 7, width: side, height: side)
        let clip = NSBezierPath(roundedRect: pic, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        if let img = CosmeticThumbs.image(item, ready: { [weak self] in self?.needsDisplay = true }) {
            img.draw(in: pic, from: .zero, operation: .sourceOver, fraction: owned || !item.earned ? 1 : 0.55, respectFlipped: true, hints: nil)
        } else {
            NSColor(srgbRed: 0.86, green: 0.93, blue: 0.98, alpha: 1).setFill(); pic.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Rarity stripe down the picture's edge.
        item.rarity.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: pic.minX - 3, y: pic.minY + 6, width: 3, height: pic.height - 12), xRadius: 1.5, yRadius: 1.5).fill()
        let tx = pic.maxX + 9, tw = r.maxX - tx - 6
        Wii.drawText(item.name, in: NSRect(x: tx, y: r.minY + 9, width: tw, height: 18), size: 12.5, bold: true, truncate: true)
        let status: String
        var color = Wii.textSoft
        if wearing { status = "Wearing"; color = Wii.blue }
        else if owned { status = CosmeticCatalog.isFree(item) ? "Free" : "Owned" }
        else if item.earned { status = "Earn it (Goals)"; color = Rarity.earned.color }
        else { status = "● \(item.cost)"; if !affordable { color = NSColor(srgbRed: 0.8, green: 0.35, blue: 0.3, alpha: 1) } }
        Wii.drawText(status, in: NSRect(x: tx, y: r.minY + 29, width: tw, height: 16), size: 11.5, color: color, truncate: true)
    }
}

// MARK: - Style tab

final class StylePanel: FlippedView {
    let progress: Progress
    /// The outfit changed (bought, worn or taken off).
    var onOutfitChanged: ((Outfit) -> Void)?
    private(set) var slot = CosmeticSlot.hat
    private var selected: Cosmetic?
    private let slots = WiiTabs(CosmeticSlot.allCases.map(\.title))
    private var cards: [CosmeticCardView] = []
    private let preview = BirdPreviewView(frame: .zero)
    private let previewFrame = WiiFrame()
    private let title = WiiLabel(22, bold: true)
    private let rarity = WiiLabel(12, bold: true)
    private let blurb = WiiLabel(13, color: Wii.textSoft)
    private let wearingLine = WiiLabel(12, color: Wii.textSoft)
    private let action = WiiButton("", textSize: 17)
    private let takeOff = WiiButton("Take off", textSize: 14)
    private var species: Species

    init(progress: Progress) {
        self.progress = progress
        species = progress.selected
        super.init(frame: .zero)
        slots.onChange = { [weak self] i in self?.show(slot: CosmeticSlot.allCases[i]) }
        for v in [slots, preview, previewFrame, title, rarity, blurb, wearingLine, action, takeOff] as [NSView] { addSubview(v) }
        action.onClick = { [weak self] in self?.primary() }
        takeOff.onClick = { [weak self] in self?.remove() }
        show(slot: .hat)
    }
    required init?(coder: NSCoder) { fatalError() }

    func willShow() {
        species = progress.selected
        preview.isPlaying = true
        refresh()
    }
    func didHide() { preview.isPlaying = false }

    /// Test hook / tutorial: open a category.
    func show(slot s: CosmeticSlot) {
        slot = s
        slots.selected = CosmeticSlot.allCases.firstIndex(of: s) ?? 0
        let items = CosmeticCatalog.items(s).filter { !$0.secret || progress.ownsCosmetic($0) }
        while cards.count < items.count {
            let c = CosmeticCardView(items[0])
            addSubview(c)
            cards.append(c)
        }
        for (i, c) in cards.enumerated() {
            c.isHidden = i >= items.count
            if i < items.count {
                c.item = items[i]
                let item = items[i]
                c.onSelect = { [weak self] in self?.selected = item; self?.refresh() }
            }
        }
        // Start on what's being worn in this slot (or the first item).
        selected = CosmeticCatalog.item(progress.outfit[s], s) ?? (s == .paint ? CosmeticCatalog.item("classic", .paint) : items.first)
        needsLayout = true
        refresh()
    }

    func refresh() {
        species = progress.selected
        let outfit = progress.outfit
        for c in cards where !c.isHidden {
            let worn = outfit[slot] ?? (slot == .paint ? "classic" : nil)
            c.isHighlighted = c.item.id == selected?.id
            c.wearing = c.item.id == worn
            c.owned = progress.ownsCosmetic(c.item)
            c.affordable = progress.coins >= c.item.cost
        }
        guard let item = selected else { return }
        // Try it on: the preview shows the outfit with this item swapped in.
        var tryOn = outfit
        tryOn[slot] = item.id
        preview.show(species, outfit: tryOn, framing: slot == .trail || slot == .paint ? .full : .portrait)
        title.text = item.name
        rarity.text = item.rarity.name.uppercased()
        rarity.color = item.rarity.color
        blurb.text = item.blurb
        let owned = progress.ownsCosmetic(item)
        let worn = (outfit[slot] ?? (slot == .paint ? "classic" : nil)) == item.id
        takeOff.isHidden = !(worn && slot != .paint)
        if worn {
            action.title = "Wearing it"; action.isEnabled = false
        } else if owned {
            action.title = slot == .paint ? "Paint my bird" : "Wear it"; action.isEnabled = true
        } else if item.earned, let gid = item.goal, let g = GoalCatalog.goal(gid) {
            action.title = "Goal: \(g.detail)"; action.isEnabled = false
        } else {
            action.title = "Buy  ● \(item.cost)"; action.isEnabled = progress.coins >= item.cost
        }
        let parts = CosmeticSlot.allCases.compactMap { s -> String? in
            guard let id = outfit[s], let c = CosmeticCatalog.item(id, s) else { return nil }
            return c.name
        }
        wearingLine.text = parts.isEmpty ? "Wearing: nothing yet — try something on!" : "Wearing: " + parts.joined(separator: ", ")
        needsLayout = true
        needsDisplay = true
    }

    private func primary() {
        guard let item = selected else { return }
        if progress.ownsCosmetic(item) {
            progress.wear(item.id == "classic" ? nil : item, slot: slot)
        } else if !progress.buyCosmetic(item) {
            NSSound.beep(); return
        } else {
            Sounds.shared?.purchase()
        }
        onOutfitChanged?(progress.outfit)
        refresh()
    }

    private func remove() {
        progress.wear(nil, slot: slot)
        onOutfitChanged?(progress.outfit)
        refresh()
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        slots.frame = NSRect(x: 0, y: 0, width: min(W, 520), height: 38)
        let cols = 4
        let cardW = (W + 8) / CGFloat(cols), cardH: CGFloat = 60
        let top: CGFloat = 46
        let shown = cards.filter { !$0.isHidden }
        for (i, c) in shown.enumerated() {
            c.frame = NSRect(x: -4 + CGFloat(i % cols) * cardW, y: top + CGFloat(i / cols) * cardH, width: cardW, height: cardH)
        }
        let rows = CGFloat((max(shown.count, 1) + cols - 1) / cols)
        let dy = top + max(rows, 4) * cardH + 10
        let pw = TabLayout.pictureWidth(W)
        let pictureH = H - dy - TabLayout.actionH - 8
        preview.frame = NSRect(x: 0, y: dy, width: pw, height: max(pictureH, 60))
        previewFrame.frame = preview.frame
        action.frame = NSRect(x: -5, y: H - TabLayout.actionH, width: pw + 10, height: TabLayout.actionH)
        let cx = pw + 24, cw = W - cx
        title.frame = NSRect(x: cx, y: dy - 2, width: cw, height: 30)
        rarity.frame = NSRect(x: cx, y: dy + 30, width: cw, height: 16)
        blurb.frame = NSRect(x: cx, y: dy + 50, width: cw, height: blurb.fittingHeight(width: cw))
        wearingLine.frame = NSRect(x: cx, y: H - 88, width: cw, height: wearingLine.fittingHeight(width: cw))
        takeOff.frame = NSRect(x: cx - 5, y: H - 52, width: 150, height: 50)
    }
}

// MARK: - Goals tab

final class GoalRowView: FlippedView {
    var goal: Goal
    var value: Double = 0 { didSet { needsDisplay = true } }
    var done = false { didSet { needsDisplay = true } }

    init(_ g: Goal) {
        goal = g
        super.init(frame: .zero)
        toolTip = g.detail
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 3, dy: 3)
        Wii.tile(r, radius: 10, fill: done ? NSColor(srgbRed: 0.93, green: 0.98, blue: 0.94, alpha: 1) : .white, bottom: Wii.tileLow,
                 border: done ? NSColor(srgbRed: 0.55, green: 0.82, blue: 0.6, alpha: 1) : Wii.border, borderWidth: 1.5, shadow: false)
        // Badge: a tick when done, otherwise a progress ring.
        let b = NSRect(x: r.minX + 10, y: r.midY - 15, width: 30, height: 30)
        let f = CGFloat(clamp(value / goal.target, 0, 1))
        if done {
            NSColor(srgbRed: 0.28, green: 0.72, blue: 0.4, alpha: 1).setFill(); NSBezierPath(ovalIn: b).fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: b.minX + 8, y: b.midY)); tick.line(to: NSPoint(x: b.minX + 13, y: b.midY + 6))
            tick.line(to: NSPoint(x: b.maxX - 7, y: b.minY + 9))
            tick.lineWidth = 3.2; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
            NSColor.white.setStroke(); tick.stroke()
        } else {
            let ring = NSBezierPath(ovalIn: b.insetBy(dx: 2, dy: 2)); ring.lineWidth = 4
            Wii.tileLow.setStroke(); ring.stroke()
            if f > 0.001 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: b.midX, y: b.midY), radius: b.width / 2 - 2, startAngle: -90, endAngle: -90 + 360 * f, clockwise: false)
                arc.lineWidth = 4; arc.lineCapStyle = .round
                Wii.blue.setStroke(); arc.stroke()
            }
        }
        let tx = b.maxX + 12
        // The reward takes the room it needs (up to half the row); the title gets the rest.
        let reward = goal.rewardText
        let needed = Wii.attributed(reward, font: Wii.font(12.5, bold: true), color: Wii.text, align: .left).size().width + 8
        let rewardW = min(needed, (r.maxX - tx) * 0.55)
        Wii.drawText(goal.title, in: NSRect(x: tx, y: r.minY + 7, width: r.maxX - tx - rewardW - 16, height: 18), size: 13.5, bold: true, truncate: true)
        Wii.drawText(reward, in: NSRect(x: r.maxX - rewardW - 10, y: r.minY + 7, width: rewardW, height: 18), size: 12.5, bold: true,
                     color: goal.cosmetic != nil ? Rarity.earned.color : Wii.text, align: .right, truncate: true)
        // Progress (or Done) on the right; the description gets all the room that leaves.
        let status: String
        if done {
            status = "Done"
        } else {
            let shownValue = goal.metric == .distanceKm ? String(format: "%.1f", min(value, goal.target)) : "\(Int(min(value, goal.target)))"
            let target = goal.metric == .distanceKm ? "\(Int(goal.target)) km" : (goal.metric == .topSpeed ? "\(Int(goal.target)) km/h" : "\(Int(goal.target))")
            status = "\(shownValue) / \(target)"
        }
        let statusW = Wii.attributed(status, font: Wii.font(11, bold: done), color: Wii.textSoft, align: .right).size().width
        Wii.drawText(goal.bonus ? "Bonus · " + goal.detail : goal.detail, in: NSRect(x: tx, y: r.minY + 26, width: r.maxX - tx - statusW - 22, height: 16),
                     size: 12, color: Wii.textSoft, truncate: true)
        Wii.drawText(status, in: NSRect(x: r.maxX - 110, y: r.minY + 26, width: 100, height: 16), size: 11, bold: done,
                     color: done ? NSColor(srgbRed: 0.25, green: 0.6, blue: 0.35, alpha: 1) : Wii.textSoft, align: .right)
    }
}

final class GoalsPanel: FlippedView {
    let progress: Progress
    private var rows: [GoalRowView] = []
    /// There are more goals than fit: they scroll.
    private let scroll = NSScrollView()
    private let content = FlippedView()

    init(progress: Progress) {
        self.progress = progress
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = content
        addSubview(scroll)
        for g in GoalCatalog.all {
            let r = GoalRowView(g)
            content.addSubview(r)
            rows.append(r)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        for r in rows {
            r.value = progress.value(r.goal.metric)
            r.done = progress.isDone(r.goal)
        }
    }

    /// Test hook: scroll to the bottom of the list.
    func debugScrollToEnd() {
        layoutSubtreeIfNeeded()
        content.scroll(NSPoint(x: 0, y: max(0, content.frame.height - scroll.contentView.bounds.height)))
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let colW = (bounds.width - 12 - 10) / 2
        let rowH: CGFloat = 58
        let h = CGFloat((rows.count + 1) / 2) * rowH
        content.frame = NSRect(x: 0, y: 0, width: bounds.width - 10, height: max(h, bounds.height))
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: CGFloat(i % 2) * (colW + 12), y: CGFloat(i / 2) * rowH, width: colW, height: rowH)
        }
    }
}
