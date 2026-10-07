import AppKit

/// The start menu when the game opens: the title over a slow cinematic flight past your bird, a little theme tune,
/// and Play / Menu / Tutorial / Quit. Holding your arms out like wings (which calibrates you) starts the game too, as
/// do Return and Space. When The Finale has opened and is still unvisited, a gold line says something has.
final class TitleScreen: NSView {
    var onPlay: (() -> Void)?
    var onMenu: (() -> Void)?
    var onTutorial: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Every key typed (for the test codes).
    var onKey: ((String) -> Void)?

    private let play = WiiButton("Play", textSize: 26)
    private let menuButton = WiiButton("Menu", textSize: 17)
    private let tutorial = WiiButton("Tutorial", textSize: 17)
    private let quit = WiiButton("Quit", textSize: 17)
    private var clock: CGFloat = 0
    private var timer: Timer?
    /// 0…1: how far through holding the arms out (calibrating) the player is.
    var calibration: CGFloat = 0 { didSet { if abs(calibration - oldValue) > 0.01 { needsDisplay = true } } }
    var finaleOpen = false { didSet { needsDisplay = true } }
    var crowned = false { didSet { needsDisplay = true } }
    var coins = 0 { didSet { needsDisplay = true } }
    var version = AppVersion.short
    private var leaving = false
    /// A message shown for a few seconds (a cheat code going in).
    private var flashText = ""
    private var flashAt: CGFloat = -100

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for b in [play, menuButton, tutorial, quit] { addSubview(b) }
        play.onClick = { [weak self] in self?.go() }
        menuButton.onClick = { [weak self] in self?.onMenu?() }
        tutorial.onClick = { [weak self] in self?.onTutorial?() }
        quit.onClick = { [weak self] in self?.onQuit?() }
        play.toolTip = "Return, Space, or hold your arms out like wings"
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.clock += 1.0 / 30
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { timer?.invalidate() }

    func go() {
        guard !leaving else { return }
        leaving = true
        onPlay?()
    }

    /// Fade out and remove.
    func dismiss() {
        timer?.invalidate()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    func flash(_ text: String) {
        flashText = text
        flashAt = clock
        needsDisplay = true
    }

    override func keyDown(with e: NSEvent) {
        let chars = e.charactersIgnoringModifiers ?? ""
        onKey?(chars)
        switch e.keyCode {
        case 36, 76, 49: go()
        case 53: onMenu?()
        default:
            if "[];',.".contains(chars) && chars.count == 1 { return }   // part of a code: no error beep
            super.keyDown(with: e)
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        let top = h * 0.58
        play.frame = NSRect(x: (w - 300) / 2, y: top, width: 300, height: 66)
        let small: CGFloat = 150, gap: CGFloat = 14
        let rowW = small * 3 + gap * 2
        for (i, b) in [menuButton, tutorial, quit].enumerated() {
            b.frame = NSRect(x: (w - rowW) / 2 + CGFloat(i) * (small + gap), y: top + 84, width: small, height: 46)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        // Darken the top and bottom a little so the words read over any sky.
        NSGradient(colors: [NSColor(white: 0, alpha: 0.42), NSColor(white: 0, alpha: 0)], atLocations: [0, 1], colorSpace: .sRGB)?
            .draw(in: NSRect(x: 0, y: 0, width: r.width, height: r.height * 0.45), angle: 90)
        NSGradient(colors: [NSColor(white: 0, alpha: 0), NSColor(white: 0, alpha: 0.55)], atLocations: [0, 1], colorSpace: .sRGB)?
            .draw(in: NSRect(x: 0, y: r.height * 0.5, width: r.width, height: r.height * 0.5), angle: 90)
        drawLogo(r)
        // The hint: arms out to start, with a ring filling as you hold it.
        let hintY = r.height * 0.58 + 152
        let hint = NSAttributedString(string: "Hold your arms out like wings to start  ·  or press Return",
                                      attributes: [.font: Wii.font(16, bold: false), .foregroundColor: NSColor(white: 1, alpha: 0.92)])
        let hs = hint.size()
        let ringD: CGFloat = 22
        let total = hs.width + ringD + 12
        let x0 = (r.width - total) / 2
        hint.draw(at: NSPoint(x: x0 + ringD + 12, y: hintY))
        let ring = NSRect(x: x0, y: hintY + (hs.height - ringD) / 2, width: ringD, height: ringD)
        NSColor(white: 1, alpha: 0.3).setStroke()
        let back = NSBezierPath(ovalIn: ring.insetBy(dx: 2, dy: 2)); back.lineWidth = 3; back.stroke()
        if calibration > 0.01 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: ring.midX, y: ring.midY), radius: ringD / 2 - 2, startAngle: -90, endAngle: -90 + 360 * calibration, clockwise: false)
            arc.lineWidth = 3; arc.lineCapStyle = .round
            NSColor(srgbRed: 0.45, green: 0.85, blue: 1, alpha: 1).setStroke(); arc.stroke()
        }
        // Something has opened.
        if finaleOpen {
            let a = 0.65 + 0.35 * sin(clock * 2)
            let s = NSAttributedString(string: "✦  A door has opened  ✦", attributes: [.font: Wii.font(15, bold: true),
                                                                                    .foregroundColor: NSColor(srgbRed: 1, green: 0.82, blue: 0.4, alpha: a)])
            s.draw(at: NSPoint(x: (r.width - s.size().width) / 2, y: hintY + 34))
        }
        // A cheat code just went in.
        let since = clock - flashAt
        if since < 5 && !flashText.isEmpty {
            let a = min(1, (5 - since) / 0.8)
            let s = NSAttributedString(string: flashText, attributes: [.font: Wii.font(17, bold: true),
                                                                      .foregroundColor: NSColor(srgbRed: 1, green: 0.86, blue: 0.45, alpha: a)])
            s.draw(at: NSPoint(x: (r.width - s.size().width) / 2, y: hintY + 64))
        }
        // Corner notes: version, coins.
        let v = NSAttributedString(string: "Bird Game \(version)", attributes: [.font: Wii.font(13), .foregroundColor: NSColor(white: 1, alpha: 0.6)])
        v.draw(at: NSPoint(x: 22, y: r.height - 34))
        let c = NSAttributedString(string: "● \(coins)", attributes: [.font: Wii.font(16, bold: true),
                                                                   .foregroundColor: NSColor(srgbRed: 1, green: 0.85, blue: 0.35, alpha: 0.95)])
        c.draw(at: NSPoint(x: r.width - c.size().width - 24, y: 22))
    }

    /// "Bird Game" big and bold: white with a deep blue outline and a soft shadow, a shine sweeping across now and
    /// then, bobbing gently; the version in a gold badge (with a crown on it once you've been crowned).
    private func drawLogo(_ r: NSRect) {
        let size = min(r.width / 7.5, 150)
        let bob = sin(clock * 1.3) * 5
        let font = Wii.font(size, bold: true)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let center = NSPoint(x: r.midX, y: r.height * 0.26 + bob)
        let base: [NSAttributedString.Key: Any] = [.font: font, .kern: size * 0.04, .paragraphStyle: para]
        let measure = NSAttributedString(string: "Bird Game", attributes: base).size()
        let rect = NSRect(x: center.x - measure.width / 2 - 40, y: center.y - measure.height / 2, width: measure.width + 80, height: measure.height)
        // The outline and the fill as one group, casting a single shadow (a shadow per letter would fall across the
        // next letter's outline).
        var outline = base
        outline[.strokeColor] = NSColor(srgbRed: 0.1, green: 0.28, blue: 0.62, alpha: 1)
        outline[.strokeWidth] = 14
        outline[.foregroundColor] = NSColor(srgbRed: 0.1, green: 0.28, blue: 0.62, alpha: 1)
        var fill = base
        fill[.foregroundColor] = NSColor.white
        if let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            // Shadow offsets ignore the view's flip: negative y is down.
            cg.setShadow(offset: CGSize(width: 0, height: -7), blur: 20, color: NSColor(srgbRed: 0.02, green: 0.08, blue: 0.25, alpha: 0.75).cgColor)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            NSAttributedString(string: "Bird Game", attributes: outline).draw(in: rect)
            NSAttributedString(string: "Bird Game", attributes: fill).draw(in: rect)
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        // The shine: a pale band slanting across the letters every few seconds.
        let cycle = clock.truncatingRemainder(dividingBy: 4.5)
        if cycle < 1.2, let ctx = NSGraphicsContext.current {
            let u = cycle / 1.2
            ctx.saveGraphicsState()
            let text = NSAttributedString(string: "Bird Game", attributes: fill)
            // Clip to the letters by drawing them into a mask image.
            let img = NSImage(size: rect.size, flipped: true) { b in text.draw(in: b); return true }
            if let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.cgContext.saveGState()
                ctx.cgContext.translateBy(x: rect.minX, y: rect.maxY)
                ctx.cgContext.scaleBy(x: 1, y: -1)
                ctx.cgContext.clip(to: CGRect(origin: .zero, size: rect.size), mask: cg)
                let x = -rect.width * 0.3 + rect.width * 1.6 * u
                let band = NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 0.85), NSColor(white: 1, alpha: 0)])
                ctx.cgContext.rotate(by: -0.35)
                band?.draw(in: NSRect(x: x, y: -rect.height, width: rect.width * 0.22, height: rect.height * 3), angle: 0)
                ctx.cgContext.restoreGState()
            }
            ctx.restoreGraphicsState()
        }
        // The version badge.
        let badgeText = NSAttributedString(string: crowned ? "♛ \(version)" : version,
                                           attributes: [.font: Wii.font(size * 0.2, bold: true), .foregroundColor: NSColor(srgbRed: 0.35, green: 0.22, blue: 0.02, alpha: 1)])
        let bs = badgeText.size()
        let badge = NSRect(x: rect.maxX - 60 - bs.width / 2, y: rect.maxY - size * 0.18, width: bs.width + 26, height: bs.height + 10)
        let pill = NSBezierPath(roundedRect: badge, xRadius: badge.height / 2, yRadius: badge.height / 2)
        NSGradient(starting: NSColor(srgbRed: 1, green: 0.88, blue: 0.45, alpha: 1), ending: NSColor(srgbRed: 0.95, green: 0.68, blue: 0.2, alpha: 1))?
            .draw(in: pill, angle: 90)
        NSColor(srgbRed: 0.6, green: 0.4, blue: 0.08, alpha: 1).setStroke(); pill.lineWidth = 2; pill.stroke()
        badgeText.draw(at: NSPoint(x: badge.minX + 13, y: badge.minY + 5))
        // Tagline.
        let tag = NSAttributedString(string: "Flap your arms. Fly anywhere.", attributes: [.font: Wii.font(size * 0.16), .foregroundColor: NSColor(white: 1, alpha: 0.88),
                                                                                       .paragraphStyle: para])
        tag.draw(in: NSRect(x: 0, y: rect.maxY + 6, width: r.width, height: tag.size().height + 4))
    }
}
