import AppKit

/// Over the cutscene: letterbox bars, the captions (big gold titles and plain lines), the fades from and to black, and
/// a quiet note that Esc twice skips it.
final class CutsceneOverlay: NSView {
    private var o = FinaleCutscene.Overlay()
    private var skipNote: CGFloat = 0
    private var skipAsked: CFTimeInterval = -10

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ overlay: FinaleCutscene.Overlay) {
        if overlay != o { o = overlay; needsDisplay = true }
        let wanted: CGFloat = CACurrentMediaTime() - skipAsked < 3 ? 1 : 0
        if wanted != skipNote { skipNote = wanted; needsDisplay = true }
    }

    /// Esc once: say how to skip. Returns true if this press should skip (the second within three seconds).
    func escPressed() -> Bool {
        let now = CACurrentMediaTime()
        if now - skipAsked < 3 { skipAsked = -10; return true }
        skipAsked = now
        needsDisplay = true
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        if o.black > 0.001 {
            NSColor.black.withAlphaComponent(CGFloat(o.black)).setFill()
            NSBezierPath(rect: r).fill()
        }
        let bar = r.height * 0.11 * CGFloat(o.bars)
        if bar > 0.5 {
            NSColor.black.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: r.width, height: bar)).fill()
            NSBezierPath(rect: NSRect(x: 0, y: r.height - bar, width: r.width, height: bar)).fill()
        }
        if !o.caption.isEmpty && o.alpha > 0.01 {
            let a = CGFloat(o.alpha)
            let size: CGFloat = o.big ? min(r.width / 14, 72) : min(r.width / 40, 30)
            let color = o.gold ? NSColor(srgbRed: 1, green: 0.84, blue: 0.42, alpha: a) : NSColor(white: 1, alpha: a)
            let font = Wii.font(size, bold: o.big)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.7 * a)
            shadow.shadowBlurRadius = o.big ? 14 : 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .shadow: shadow, .paragraphStyle: para]
            if o.big { attrs[.kern] = size * 0.12 }
            let text = NSAttributedString(string: o.caption, attributes: attrs)
            let h = text.size().height
            let y = o.big ? r.height * 0.36 - h / 2 : r.height - bar - h - r.height * 0.06
            text.draw(in: NSRect(x: 40, y: y, width: r.width - 80, height: h + 4))
            if !o.sub.isEmpty {
                let sub = NSAttributedString(string: o.sub, attributes: [.font: Wii.font(min(r.width / 52, 22), bold: false),
                                                                         .foregroundColor: NSColor(white: 1, alpha: a * 0.92), .shadow: shadow,
                                                                         .paragraphStyle: para])
                sub.draw(in: NSRect(x: 40, y: y + h + 14, width: r.width - 80, height: sub.size().height + 4))
            }
        }
        let note = skipNote > 0 ? "Press Esc again to skip" : "Esc Esc to skip"
        let na = skipNote > 0 ? 0.9 : 0.35 * CGFloat(o.bars)
        if na > 0.01 {
            let s = NSAttributedString(string: note, attributes: [.font: Wii.font(13, bold: false), .foregroundColor: NSColor(white: 1, alpha: na)])
            let sz = s.size()
            s.draw(at: NSPoint(x: r.width - sz.width - 24, y: r.height - max(bar, 30) / 2 - sz.height / 2))
        }
    }
}
