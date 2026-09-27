import AppKit

/// Chat messages, newest at the bottom, long ones wrapped. Used over the game and in the LAN tab.
final class ChatLinesView: FlippedView {
    struct Entry { var line: ChatLine; var at: Date }
    var entries: [Entry] = [] { didSet { needsDisplay = true } }
    /// Over the game, lines fade after this many seconds (nil = always shown).
    var fadeAfter: Double?
    /// Dark pills over the game; plain text on the light menu.
    var onDark = true
    var textSize: CGFloat = 13
    /// Shown when there are no messages (menu only).
    var emptyText = ""

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func add(_ l: ChatLine) {
        entries.append(Entry(line: l, at: Date()))
        if entries.count > 40 { entries.removeFirst(entries.count - 40) }
    }

    private func alpha(_ e: Entry) -> CGFloat {
        guard let f = fadeAfter else { return 1 }
        return CGFloat(clamp(f - Date().timeIntervalSince(e.at), 0, 1))
    }

    var anyVisible: Bool { entries.contains { alpha($0) > 0 } }

    private func text(_ l: ChatLine, alpha a: CGFloat) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if l.system {
            let c = onDark ? NSColor(white: 0.82, alpha: 1) : Wii.textSoft
            s.append(NSAttributedString(string: l.text, attributes: [.font: Wii.font(textSize - 1), .foregroundColor: c.withAlphaComponent(a)]))
        } else {
            s.append(NSAttributedString(string: l.name + "  ", attributes: [.font: Wii.font(textSize, bold: true),
                                                                          .foregroundColor: NameColors.ns(l.color).withAlphaComponent(a)]))
            let c = onDark ? NSColor.white : Wii.text
            s.append(NSAttributedString(string: l.text, attributes: [.font: Wii.font(textSize), .foregroundColor: c.withAlphaComponent(a)]))
        }
        return s
    }

    override func draw(_ dirtyRect: NSRect) {
        let padX: CGFloat = onDark ? 12 : 12, padY: CGFloat = onDark ? 5 : 2
        let maxW = bounds.width - padX * 2
        guard maxW > 20 else { return }
        if !onDark {
            // A light panel so the chat reads as one box in the menu.
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(0.55).setFill(); box.fill()
            Wii.border.setStroke(); box.lineWidth = 1.5; box.stroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).setClip()
        }
        if entries.isEmpty, !emptyText.isEmpty {
            Wii.drawText(emptyText, in: bounds.insetBy(dx: padX, dy: 10), size: textSize, color: Wii.textSoft)
            return
        }
        var y = bounds.height - (onDark ? 0 : 6)
        for e in entries.reversed() {
            let a = alpha(e)
            guard a > 0 else { continue }
            let t = text(e.line, alpha: a)
            let r = t.boundingRect(with: NSSize(width: maxW, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = ceil(r.height) + padY * 2
            y -= h
            guard y >= (onDark ? 0 : 4) else { break }
            if onDark {
                let pill = NSRect(x: 0, y: y, width: min(ceil(r.width) + padX * 2, bounds.width), height: h)
                NSColor(white: 0.08, alpha: 0.55 * a).setFill()
                NSBezierPath(roundedRect: pill, xRadius: min(13, h / 2), yRadius: min(13, h / 2)).fill()
            }
            t.draw(with: NSRect(x: padX, y: y + padY, width: maxW, height: h), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y -= onDark ? 4 : 3
        }
    }
}

/// In-game chat, bottom left: recent messages fade away; T opens a box to type in (Return sends, Esc closes).
final class ChatOverlay: NSView, NSTextFieldDelegate {
    private let lines = ChatLinesView()
    private let field = WiiTextField(frame: .zero)
    var onSend: ((String) -> Void)?
    /// Typing finished (sent or closed): give the keyboard back to the game.
    var onClose: (() -> Void)?
    private(set) var typing = false
    /// Room to leave at the bottom (the help box sits there when it's shown).
    var bottomInset: CGFloat = 16 { didSet { if bottomInset != oldValue { needsLayout = true } } }
    static let fade: Double = 15

    override init(frame: NSRect) {
        super.init(frame: frame)
        lines.fadeAfter = ChatOverlay.fade
        addSubview(lines)
        field.isHidden = true
        field.delegate = self
        field.target = self
        field.action = #selector(send)
        field.placeholderAttributedString = NSAttributedString(string: "Message everyone  (Return to send, Esc to close)",
            attributes: [.foregroundColor: Wii.textSoft.withAlphaComponent(0.8), .font: Wii.font(14)])
        addSubview(field)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Only the text box takes clicks; everything else goes to the game.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard typing, let v = super.hitTest(point), v === field || v.isDescendant(of: field) else { return nil }
        return v
    }

    /// Show messages over the game (Settings). Typing (T) still shows the conversation while the box is open.
    var showsLines = true { didSet { updateLines() } }
    private func updateLines() { lines.isHidden = !(showsLines || typing) }

    func add(_ l: ChatLine) { lines.add(l) }
    func reset() { lines.entries = [] }

    func open() {
        guard !typing else { return }
        typing = true
        updateLines()
        field.isHidden = false
        field.stringValue = ""
        lines.fadeAfter = nil
        needsLayout = true
        window?.makeFirstResponder(field)
    }

    func close() {
        guard typing else { return }
        typing = false
        updateLines()
        field.isHidden = true
        field.stringValue = ""
        // Everything already read fades away now.
        lines.entries = lines.entries.map { ChatLinesView.Entry(line: $0.line, at: min($0.at, Date().addingTimeInterval(-ChatOverlay.fade + 4))) }
        lines.fadeAfter = ChatOverlay.fade
        needsLayout = true
        onClose?()
    }

    @objc private func send() {
        let t = field.stringValue
        if ChatLine.clean(t) != nil { onSend?(t) }
        close()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { close(); return true }
        return false
    }

    /// Called ~30 times a second to animate fading.
    func tick() { if lines.anyVisible { lines.needsDisplay = true } }

    override func layout() {
        super.layout()
        let w = min(440, max(300, bounds.width / 2 - 300))
        var y = bottomInset
        field.frame = NSRect(x: 16, y: y, width: w, height: 34)
        if typing { y += 42 }
        lines.frame = NSRect(x: 16, y: y, width: w, height: typing ? 260 : 170)
    }
}
