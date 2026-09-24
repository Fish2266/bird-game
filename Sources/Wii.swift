import AppKit

// Calm, Wii-menu-inspired UI kit: light grey/white rounded tiles with thin grey borders, pill buttons
// with a white-to-grey gradient and a sky-blue rim, dark grey Hiragino Sans (the closest Mac font to
// Nintendo's Rodin), and a single blue accent.

enum Wii {
    static let text = NSColor(srgbRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
    static let textSoft = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 1)
    static let blue = NSColor(srgbRed: 0.20, green: 0.745, blue: 0.93, alpha: 1)      // #34BEED
    static let blueLight = NSColor(srgbRed: 0.72, green: 0.90, blue: 0.98, alpha: 1)
    static let border = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1)     // #ccc
    static let tile = NSColor(srgbRed: 0.973, green: 0.973, blue: 0.973, alpha: 1)    // #f8f8f8
    static let tileLow = NSColor(srgbRed: 0.92, green: 0.925, blue: 0.93, alpha: 1)
    static let coinGold = NSColor(srgbRed: 0.93, green: 0.72, blue: 0.20, alpha: 1)

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    // MARK: Icons

    private static var iconCache: [String: NSImage] = [:]

    /// Flat gold coin.
    static func coin(_ size: CGFloat) -> NSImage {
        let key = "coin\(size)"
        if let img = iconCache[key] { return img }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            coinGold.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill()
            let inner = NSBezierPath(ovalIn: r.insetBy(dx: size * 0.24, dy: size * 0.24))
            inner.lineWidth = max(1, size * 0.08)
            NSColor.white.withAlphaComponent(0.6).setStroke(); inner.stroke()
            return true
        }
        iconCache[key] = img
        return img
    }

    // MARK: Text

    /// "●" in text becomes a coin icon.
    static func attributed(_ s: String, font: NSFont, color: NSColor, align: NSTextAlignment,
                           truncate: Bool = false) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = align
        para.lineBreakMode = truncate ? .byTruncatingTail : .byWordWrapping
        para.lineSpacing = font.pointSize * 0.25
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let out = NSMutableAttributedString()
        for ch in s {
            if ch == "●" {
                let a = NSTextAttachment()
                let size = (font.capHeight * 1.3).rounded()
                a.image = coin(size)
                a.bounds = CGRect(x: 0, y: (font.capHeight - size) / 2, width: size, height: size)
                let s = NSMutableAttributedString(attachment: a)
                s.addAttributes([.paragraphStyle: para], range: NSRange(location: 0, length: s.length))
                out.append(s)
            } else {
                out.append(NSAttributedString(string: String(ch), attributes: attrs))
            }
        }
        return out
    }

    /// Draw text in a flipped view.
    static func drawText(_ s: String, in rect: NSRect, size: CGFloat, bold: Bool = false, color: NSColor = text,
                         align: NSTextAlignment = .left, centerV: Bool = false, truncate: Bool = false) {
        let str = attributed(s, font: font(size, bold: bold), color: color, align: align, truncate: truncate)
        var r = rect
        if centerV {
            let h = str.boundingRect(with: NSSize(width: rect.width, height: 10_000), options: [.usesLineFragmentOrigin]).height
            r.origin.y += max(0, (rect.height - h) / 2)
            r.size.height = h + 2
        }
        str.draw(with: r, options: truncate ? [.truncatesLastVisibleLine, .usesLineFragmentOrigin] : [.usesLineFragmentOrigin])
    }

    static func textHeight(_ s: String, width: CGFloat, size: CGFloat, bold: Bool = false) -> CGFloat {
        attributed(s, font: font(size, bold: bold), color: text, align: .left)
            .boundingRect(with: NSSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height.rounded(.up) + 2
    }

    // MARK: Shapes

    /// Rounded tile: near-white fill, thin grey border, very soft shadow. Call inside a flipped view.
    static func tile(_ r: NSRect, radius: CGFloat = 12, fill: NSColor = tile, bottom: NSColor? = nil,
                     border: NSColor = border, borderWidth: CGFloat = 2, shadow: Bool = true, bevel: Bool = true) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        if shadow {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.10)
            sh.shadowBlurRadius = 8
            sh.shadowOffset = NSSize(width: 0, height: -2)
            sh.set()
            fill.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let bottom {
            NSGradient(colorsAndLocations: (fill, 0), (fill, 0.65), (bottom, 1))?.draw(in: path, angle: 90)
        } else {
            fill.setFill(); path.fill()
        }
        if bevel { bevelEdges(r.insetBy(dx: borderWidth, dy: borderWidth), radius: max(radius - borderWidth, 2)) }
        let bp = NSBezierPath(roundedRect: r.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                              xRadius: radius - borderWidth / 2, yRadius: radius - borderWidth / 2)
        bp.lineWidth = borderWidth
        border.setStroke(); bp.stroke()
    }

    /// Raised-edge look: a bright line along the inner top edge and a soft shade along the inner bottom.
    static func bevelEdges(_ r: NSRect, radius: CGFloat, strength: CGFloat = 1) {
        NSGraphicsContext.saveGraphicsState()
        let inner = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        inner.addClip()
        let hi = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75).offsetBy(dx: 0, dy: 1),
                              xRadius: radius, yRadius: radius)
        hi.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.95 * strength).setStroke(); hi.stroke()
        let lo = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75).offsetBy(dx: 0, dy: -1.5),
                              xRadius: radius, yRadius: radius)
        lo.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.07 * strength).setStroke(); lo.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Wii Sports-style glossy button face: glassy bright upper half with a crisp shine line,
    /// a soft light bounce at the bottom, bevelled edges and a blue rim.
    static func glossy(_ r: NSRect, radius: CGFloat, rim: NSColor = blue, rimWidth: CGFloat = 2.5,
                       pressed: Bool = false, glow: Bool = false, tint: NSColor = .white,
                       maxGlass: CGFloat = .greatestFiniteMagnitude, depth: CGFloat = 1) {
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowColor = glow ? blue.withAlphaComponent(0.6) : NSColor.black.withAlphaComponent(0.16)
        sh.shadowBlurRadius = glow ? 10 : (r.height > 300 ? 16 : 5)
        sh.shadowOffset = glow ? .zero : NSSize(width: 0, height: -2)
        sh.set()
        rim.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()

        let face = r.insetBy(dx: rimWidth, dy: rimWidth)
        let fr = max(radius - rimWidth, 2)
        let fp = NSBezierPath(roundedRect: face, xRadius: fr, yRadius: fr)
        let base = tint
        let cool = NSColor(srgbRed: 0.62, green: 0.71, blue: 0.79, alpha: 1)
        let darker = base.blended(withFraction: (pressed ? 0.5 : 0.38) * depth, of: cool) ?? base
        let mid = base.blended(withFraction: 0.22 * depth, of: cool) ?? base
        NSGraphicsContext.saveGraphicsState()
        fp.addClip()
        // glass: bright upper half (capped on tall panels) ending in a crisp horizon line
        let glassH = min(face.height * 0.5, maxGlass)
        let gf = glassH / max(face.height, 1)
        // body: cooler blue-grey just below the glass that brightens again toward the bottom edge
        NSGradient(colorsAndLocations: (mid, 0), (darker, gf), (mid, min(gf + 0.35, 0.9)), (base, 1))?.draw(in: face, angle: 90)
        let glass = NSRect(x: face.minX + 1.5, y: face.minY + 1.5, width: face.width - 3, height: glassH)
        let gp = NSBezierPath(roundedRect: glass, xRadius: max(fr - 1.5, 2), yRadius: max(fr - 1.5, 2))
        NSGradient(starting: NSColor.white.withAlphaComponent(pressed ? 0.6 : 1.0),
                   ending: NSColor.white.withAlphaComponent(pressed ? 0.35 : 0.82))?.draw(in: gp, angle: 90)
        // light bounce along the bottom edge
        let bounce = NSRect(x: face.minX + face.width * 0.12, y: face.maxY - face.height * 0.22,
                            width: face.width * 0.76, height: face.height * 0.2)
        NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.55))?
            .draw(in: NSBezierPath(ovalIn: bounce), angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        bevelEdges(face, radius: fr, strength: pressed ? 0.4 : 1)
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

final class WiiLabel: FlippedView {
    var text = "" { didSet { if text != oldValue { needsDisplay = true } } }
    var size: CGFloat = 15 { didSet { needsDisplay = true } }
    var bold = false
    var color: NSColor = Wii.text { didSet { needsDisplay = true } }
    var align: NSTextAlignment = .left { didSet { needsDisplay = true } }
    var centerV = false

    convenience init(_ size: CGFloat, bold: Bool = false, color: NSColor = Wii.text) {
        self.init(frame: .zero)
        self.size = size
        self.bold = bold
        self.color = color
    }

    func fittingHeight(width: CGFloat) -> CGFloat { Wii.textHeight(text, width: width, size: size, bold: bold) }

    override func draw(_ dirtyRect: NSRect) {
        Wii.drawText(text, in: bounds, size: size, bold: bold, color: color, align: align, centerV: centerV)
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsDisplay = true }
}

/// Plain rounded panel (the translucent white tile used across the HUD and menus).
final class WiiPanel: FlippedView {
    var fill = NSColor.white.withAlphaComponent(0.88) { didSet { needsDisplay = true } }
    var borderColor = Wii.border { didSet { needsDisplay = true } }
    var radius: CGFloat = 12
    var inset: CGFloat = 4

    var contentRect: NSRect { bounds.insetBy(dx: inset, dy: inset) }
    override func draw(_ dirtyRect: NSRect) {
        Wii.glossy(contentRect, radius: radius, rim: borderColor, rimWidth: 2, maxGlass: 30)
    }
}

/// Wii-style pill button: white-to-grey gradient with a sky-blue rim that thickens on hover.
final class WiiButton: FlippedView {
    var title: String { didSet { needsDisplay = true } }
    var textSize: CGFloat
    var isEnabled = true { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onClick: (() -> Void)?
    private var hover = false
    private var pressed = false

    init(_ title: String, textSize: CGFloat = 15) {
        self.title = title
        self.textSize = textSize
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; pressed = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        needsDisplay = true
        if fire { onClick?() }
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        var r = bounds.insetBy(dx: 5, dy: 5)
        if pressed { r = r.offsetBy(dx: 0, dy: 1) }
        let radius = min(12, r.height * 0.3)
        let live = isEnabled
        Wii.glossy(r, radius: radius, rim: live ? Wii.blue : Wii.border, rimWidth: hover && live ? 3.5 : 2.5,
                   pressed: pressed, glow: hover && live)
        Wii.drawText(title, in: r.insetBy(dx: 12, dy: 0).offsetBy(dx: 0, dy: 1), size: textSize, bold: true,
                     color: live ? Wii.text : Wii.textSoft.withAlphaComponent(0.7), align: .center, centerV: true)
    }
}

/// "Label ........ On / Off" row; the value is a small two-segment switch.
final class WiiToggle: FlippedView {
    var title: String
    var isOn = false { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setOn(_ on: Bool) { isOn = on }

    override func mouseDown(with event: NSEvent) { isOn.toggle(); onChange?(isOn) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        let segW: CGFloat = 46, h: CGFloat = 28
        let box = NSRect(x: bounds.width - segW * 2, y: (bounds.height - h) / 2, width: segW * 2, height: h)
        Wii.drawText(title, in: NSRect(x: 0, y: 0, width: box.minX - 8, height: bounds.height), size: 14, centerV: true)
        Wii.tile(box, radius: 8, fill: Wii.tileLow, border: Wii.border, borderWidth: 1.5, shadow: false, bevel: false)
        let sel = isOn ? NSRect(x: box.minX, y: box.minY, width: segW, height: h) : NSRect(x: box.midX, y: box.minY, width: segW, height: h)
        Wii.glossy(sel.insetBy(dx: 1, dy: 1), radius: 7, rim: Wii.blue, rimWidth: 2)
        Wii.drawText("On", in: NSRect(x: box.minX, y: box.minY + 1, width: segW, height: h), size: 12, bold: isOn,
                     color: isOn ? Wii.text : Wii.textSoft, align: .center, centerV: true)
        Wii.drawText("Off", in: NSRect(x: box.midX, y: box.minY + 1, width: segW, height: h), size: 12, bold: !isOn,
                     color: !isOn ? Wii.text : Wii.textSoft, align: .center, centerV: true)
    }
}

/// Label with a value that cycles on click.
final class WiiSelector: FlippedView {
    var title: String
    var value = "" { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hover = false

    init(_ title: String) {
        self.title = title
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
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        Wii.drawText(title, in: NSRect(x: 0, y: 0, width: bounds.width, height: 20), size: 13, color: Wii.textSoft)
        let pill = NSRect(x: 0, y: 22, width: bounds.width, height: bounds.height - 24)
        Wii.tile(pill, radius: 8, fill: .white, bottom: Wii.tileLow, border: hover ? Wii.blue : Wii.border, borderWidth: 2, shadow: false)
        Wii.drawText(value, in: pill.insetBy(dx: 14, dy: 0).offsetBy(dx: 0, dy: 1), size: 14, centerV: true)
        Wii.drawText("›", in: NSRect(x: pill.maxX - 26, y: pill.minY, width: 16, height: pill.height), size: 18,
                     color: Wii.textSoft, centerV: true)
    }
}

/// Labelled slider: a sunken groove, blue fill and a glossy bevelled knob. Value is 0…1.
final class WiiSlider: FlippedView {
    var title: String
    var value: CGFloat = 1 { didSet { needsDisplay = true } }
    var onChange: ((CGFloat) -> Void)?

    init(_ title: String) {
        self.title = title
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var track: NSRect { NSRect(x: 12, y: 30, width: bounds.width - 24, height: 10) }
    override func mouseDown(with event: NSEvent) { set(from: event) }
    override func mouseDragged(with event: NSEvent) { set(from: event) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    private func set(from event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let v = min(max((p.x - track.minX) / track.width, 0), 1)
        value = (v * 100).rounded() / 100
        onChange?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        Wii.drawText(title, in: NSRect(x: 12, y: 0, width: bounds.width - 84, height: 22), size: 14)
        Wii.drawText("\(Int((value * 100).rounded()))%", in: NSRect(x: bounds.width - 72, y: 0, width: 60, height: 22),
                     size: 14, bold: true, color: Wii.textSoft, align: .right)
        let t = track
        // sunken groove
        let groove = NSBezierPath(roundedRect: t, xRadius: 5, yRadius: 5)
        NSGradient(starting: NSColor(white: 0.80, alpha: 1), ending: NSColor(white: 0.93, alpha: 1))?.draw(in: groove, angle: 90)
        groove.lineWidth = 1; Wii.border.setStroke(); groove.stroke()
        let fill = NSRect(x: t.minX, y: t.minY, width: t.width * value, height: t.height)
        if fill.width > 1 {
            let fp = NSBezierPath(roundedRect: fill, xRadius: 5, yRadius: 5)
            NSGradient(starting: Wii.blueLight, ending: Wii.blue)?.draw(in: fp, angle: 90)
        }
        let knob = NSRect(x: t.minX + t.width * value - 11, y: t.midY - 14, width: 22, height: 28)
        Wii.glossy(knob, radius: 6, rim: Wii.blue, rimWidth: 2)
    }
}

/// Rounded grey frame drawn over another view (video, 3D preview).
final class WiiFrame: NSView {
    var radius: CGFloat = 12
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        p.lineWidth = 2
        Wii.border.setStroke(); p.stroke()
    }
}
