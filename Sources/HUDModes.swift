import AppKit

// HUD pieces for races, fights and LAN games.

/// Compass for "show location": other birds as colored dots around you (up = where you're looking).
final class CompassView: FlippedView {
    var markers: [CompassMarker] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let size = min(bounds.width, 150)
        let dial = NSRect(x: (bounds.width - size) / 2, y: 0, width: size, height: size).insetBy(dx: 6, dy: 6)
        Wii.glossy(dial, radius: dial.width / 2, rim: Wii.border, rimWidth: 2, maxGlass: dial.height * 0.45)
        let c = NSPoint(x: dial.midX, y: dial.midY)
        let r = dial.width / 2 - 12
        // Range rings
        for k in [0.5, 1.0] as [CGFloat] {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r * k, y: c.y - r * k, width: r * 2 * k, height: r * 2 * k))
            ring.lineWidth = 1
            Wii.border.withAlphaComponent(0.8).setStroke(); ring.stroke()
        }
        // You: a small arrow pointing up.
        let me = NSBezierPath()
        me.move(to: NSPoint(x: c.x, y: c.y - 9)); me.line(to: NSPoint(x: c.x + 6, y: c.y + 6))
        me.line(to: NSPoint(x: c.x, y: c.y + 3)); me.line(to: NSPoint(x: c.x - 6, y: c.y + 6)); me.close()
        Wii.blue.setFill(); me.fill()
        Wii.drawText("ahead", in: NSRect(x: dial.minX, y: dial.minY + 3, width: dial.width, height: 12), size: 9,
                     color: Wii.textSoft, align: .center)
        for m in markers.sorted(by: { $0.distance > $1.distance }) {
            // Distance on a log scale: 50 m near the middle, 1.5 km at the rim.
            let k = CGFloat(clamp((log(max(m.distance, 20)) - log(20)) / (log(1500) - log(20)), 0.18, 1))
            let a = CGFloat(m.bearing)
            let p = NSPoint(x: c.x + sin(a) * r * k, y: c.y - cos(a) * r * k)
            let col = NameColors.ns(m.color)
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            col.setFill(); dot.fill()
            dot.lineWidth = 1.5
            NSColor.white.setStroke(); dot.stroke()
            if m.above > 25 || m.above < -25 {
                Wii.drawText(m.above > 0 ? "▲" : "▼", in: NSRect(x: p.x + 5, y: p.y - 12, width: 12, height: 12), size: 8, color: col)
            }
        }
        // Nearest few by name under the dial.
        var y = dial.maxY + 8
        for m in markers.sorted(by: { $0.distance < $1.distance }).prefix(4) {
            let dot = NSRect(x: 8, y: y + 4, width: 9, height: 9)
            NameColors.ns(m.color).setFill(); NSBezierPath(ovalIn: dot).fill()
            let d = m.distance < 1000 ? String(format: "%.0f m", m.distance) : String(format: "%.1f km", m.distance / 1000)
            Wii.drawText(m.name, in: NSRect(x: 22, y: y, width: bounds.width - 90, height: 16), size: 12, bold: true, color: .white, truncate: true)
            Wii.drawText(d, in: NSRect(x: bounds.width - 70, y: y, width: 64, height: 16), size: 12, color: .white, align: .right)
            y += 18
        }
    }
}

/// Health, attack reload and the mouth meter.
final class CombatBox: FlippedView {
    var health: Float = 100
    var burning = false
    var reload: Float = 1
    var weapon = ""
    var mouth: Float = 0
    var mouthSeen = false
    var keyboard = false
    var left = ""
    var respawn: Float = 0
    var lives = 0
    var lock: String?
    var lockInRange = false

    func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        Wii.glossy(r, radius: 12, rim: Wii.border, rimWidth: 2, maxGlass: 30)
        let x = r.minX + 16, w = r.width - 32
        // Health
        Wii.drawText(respawn > 0 ? String(format: "Back in %.0f…", ceil(respawn)) : (burning ? "Health  🔥" : "Health"),
                     in: NSRect(x: x, y: r.minY + 10, width: w * 0.6, height: 16), size: 12, bold: true)
        Wii.drawText(String(format: "%.0f", max(health, 0)), in: NSRect(x: x, y: r.minY + 10, width: w, height: 16), size: 12,
                     bold: true, color: Wii.textSoft, align: .right)
        let hb = NSRect(x: x, y: r.minY + 30, width: w, height: 10)
        bar(hb, CGFloat(clamp(health / Fighter.maxHealth, 0, 1)),
            health > 50 ? NSColor(srgbRed: 0.30, green: 0.80, blue: 0.35, alpha: 1)
                : (health > 25 ? NSColor(srgbRed: 0.95, green: 0.72, blue: 0.15, alpha: 1) : NSColor(srgbRed: 0.92, green: 0.26, blue: 0.22, alpha: 1)))
        // Attack
        Wii.drawText(weapon, in: NSRect(x: x, y: r.minY + 48, width: w * 0.7, height: 16), size: 12, bold: true, truncate: true)
        Wii.drawText(reload >= 1 ? "Ready" : "Reloading", in: NSRect(x: x, y: r.minY + 48, width: w, height: 16), size: 11,
                     color: reload >= 1 ? Wii.blue : Wii.textSoft, align: .right)
        bar(NSRect(x: x, y: r.minY + 68, width: w, height: 7), CGFloat(reload), reload >= 1 ? Wii.blue : Wii.blueLight)
        // Lock-on and the mouth meter
        let red = NSColor(srgbRed: 0.85, green: 0.22, blue: 0.18, alpha: 1)
        let how = keyboard ? "press Return" : (mouthSeen ? "open wide!" : "face the camera")
        let hint: String
        var hintColor = Wii.textSoft
        if let lock {
            hint = lockInRange ? "Locked on \(lock) — \(how)" : "\(lock) — get closer"
            hintColor = lockInRange ? red : Wii.text
        } else {
            hint = "No target ahead — turn toward a bird"
        }
        Wii.drawText(hint, in: NSRect(x: x, y: r.minY + 82, width: w - 40, height: 16), size: 11, bold: lock != nil, color: hintColor, truncate: true)
        let m = NSRect(x: r.maxX - 16 - 30, y: r.minY + 80, width: 30, height: 18)
        let mp = NSBezierPath(roundedRect: m, xRadius: 9, yRadius: 9)
        Wii.tileLow.setFill(); mp.fill()
        let open = CGFloat(clamp(mouth, 0, 1))
        let mouthShape = NSBezierPath(ovalIn: NSRect(x: m.midX - 10, y: m.midY - max(1.5, 8 * open), width: 20, height: max(3, 16 * open)))
        (open > 0.85 ? NSColor(srgbRed: 0.92, green: 0.3, blue: 0.25, alpha: 1) : Wii.text).setFill(); mouthShape.fill()
        if lives > 0 || respawn > 0 {
            let red = NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: 1)
            for i in 0..<Fighter.startLives {
                CombatBox.heart(in: NSRect(x: x + CGFloat(i) * 20, y: r.maxY - 23, width: 15, height: 14), filled: i < lives, color: red)
            }
            Wii.drawText(lives == 1 ? "Last life!" : "\(lives) lives", in: NSRect(x: x + 66, y: r.maxY - 23, width: w - 66, height: 16),
                         size: 12, bold: true, color: lives == 1 ? red : Wii.textSoft)
        }
    }

    /// A heart shape (flipped view: point at the bottom).
    static func heart(in r: NSRect, filled: Bool, color: NSColor) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.midX, y: r.maxY))
        p.curve(to: NSPoint(x: r.minX, y: r.minY + r.height * 0.32), controlPoint1: NSPoint(x: r.midX - r.width * 0.2, y: r.maxY - r.height * 0.18),
                controlPoint2: NSPoint(x: r.minX, y: r.minY + r.height * 0.6))
        p.curve(to: NSPoint(x: r.midX, y: r.minY + r.height * 0.22), controlPoint1: NSPoint(x: r.minX, y: r.minY - r.height * 0.08),
                controlPoint2: NSPoint(x: r.midX, y: r.minY))
        p.curve(to: NSPoint(x: r.maxX, y: r.minY + r.height * 0.32), controlPoint1: NSPoint(x: r.midX, y: r.minY),
                controlPoint2: NSPoint(x: r.maxX, y: r.minY - r.height * 0.08))
        p.curve(to: NSPoint(x: r.midX, y: r.maxY), controlPoint1: NSPoint(x: r.maxX, y: r.minY + r.height * 0.6),
                controlPoint2: NSPoint(x: r.midX + r.width * 0.2, y: r.maxY - r.height * 0.18))
        p.close()
        if filled { color.setFill(); p.fill() }
        p.lineWidth = 1.5
        (filled ? color : Wii.border).setStroke(); p.stroke()
    }

    private func bar(_ rect: NSRect, _ f: CGFloat, _ color: NSColor) {
        let track = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSGradient(starting: NSColor(white: 0.82, alpha: 1), ending: NSColor(white: 0.94, alpha: 1))?.draw(in: track, angle: 90)
        if f > 0.01 {
            let fill = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width * f, height: rect.height),
                                    xRadius: rect.height / 2, yRadius: rect.height / 2)
            color.setFill(); fill.fill()
        }
        track.lineWidth = 1
        Wii.text.withAlphaComponent(0.3).setStroke(); track.stroke()
    }
}

/// Race clock, gate count, penalty and split.
final class RaceBox: FlippedView {
    var time = "0:00.00"
    var gates = ""
    var penalty: Double = 0
    var split: String?
    var ahead = false
    var place: String?
    var ghost = false

    func refresh() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        Wii.glossy(r, radius: 12, rim: Wii.border, rimWidth: 2, maxGlass: 30)
        Wii.drawText(time, in: NSRect(x: r.minX + 16, y: r.minY + 8, width: r.width - 32, height: 38), size: 30, bold: true)
        if let place {
            Wii.drawText(place, in: NSRect(x: r.minX + 16, y: r.minY + 16, width: r.width - 32, height: 24), size: 16, bold: true,
                         color: Wii.blue, align: .right)
        } else if let split {
            Wii.drawText(split, in: NSRect(x: r.minX + 16, y: r.minY + 16, width: r.width - 32, height: 24), size: 16, bold: true,
                         color: ahead ? NSColor(srgbRed: 0.2, green: 0.65, blue: 0.3, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.3, blue: 0.25, alpha: 1),
                         align: .right)
        }
        var line = gates
        if penalty > 0 { line += String(format: "   +%.0f s penalty", penalty) }
        Wii.drawText(line, in: NSRect(x: r.minX + 16, y: r.minY + 50, width: r.width - 32, height: 18), size: 13,
                     color: penalty > 0 ? NSColor(srgbRed: 0.8, green: 0.3, blue: 0.25, alpha: 1) : Wii.textSoft)
        if ghost {
            Wii.drawText("Ghost: your best run", in: NSRect(x: r.minX + 16, y: r.minY + 70, width: r.width - 32, height: 16), size: 11,
                         color: Wii.textSoft)
        }
    }
}

/// End-of-round results.
final class ResultsView: FlippedView {
    var result: MatchResult? { didSet { needsDisplay = true } }

    // One table: a white title band, equal-height rows (place, colour dot, name, then note / time / KOs in fixed
    // right-aligned columns), the coins, and a footer line.
    private static let band: CGFloat = 64
    private static let gap: CGFloat = 14
    private static let rowH: CGFloat = 32
    private static let side: CGFloat = 30

    var height: CGFloat {
        let rows = CGFloat(result?.standings.count ?? 0)
        let footer: CGFloat = (result?.footer.isEmpty ?? true) ? 0 : 24
        return 8 + ResultsView.band + ResultsView.gap + rows * ResultsView.rowH + 14 + 30 + footer + 22
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let res = result else { return }
        let r = bounds.insetBy(dx: 4, dy: 4)
        Wii.glossy(r, radius: 16, rim: Wii.blue, rimWidth: 2.5, maxGlass: ResultsView.band)
        // The white band sits 4 pt inside the edge (the 2.5 pt rim and its 1.5 pt highlight).
        let band = NSRect(x: r.minX + 4, y: r.minY + 4, width: r.width - 8, height: ResultsView.band)
        Wii.drawText(res.title, in: band, size: 28, bold: true, align: .center, centerV: true)

        let left = r.minX + ResultsView.side, right = r.maxX - ResultsView.side
        let rowH = ResultsView.rowH
        let hasPlace = res.standings.contains { $0.place > 0 }
        let hasTime = res.standings.contains { $0.time != nil }
        let hasKO = res.standings.contains { $0.knockouts > 0 }
        let placeW: CGFloat = hasPlace ? 46 : 0
        let koW: CGFloat = hasKO ? 58 : 0
        let timeW: CGFloat = hasTime ? 80 : 0
        let timeRight = right - koW
        let noteRight = timeRight - (hasTime ? timeW + 12 : 0)
        let noteW: CGFloat = 130
        var y = band.maxY + ResultsView.gap
        for s in res.standings {
            let row = NSRect(x: left, y: y, width: right - left, height: rowH)
            let you = s.color == -1 || s.name == "You"
            if you {
                Wii.blueLight.withAlphaComponent(0.6).setFill()
                NSBezierPath(roundedRect: row.insetBy(dx: -10, dy: 2), xRadius: 8, yRadius: 8).fill()
            }
            if s.place > 0 {
                // The podium in medal colours (dark enough to read on the light card).
                let podium = [NSColor(srgbRed: 0.78, green: 0.56, blue: 0.05, alpha: 1), NSColor(srgbRed: 0.46, green: 0.49, blue: 0.54, alpha: 1),
                              NSColor(srgbRed: 0.66, green: 0.38, blue: 0.18, alpha: 1)]
                Wii.drawText(ordinal(s.place), in: NSRect(x: left, y: row.minY, width: placeW, height: rowH), size: 15, bold: true,
                             color: s.place <= 3 ? podium[s.place - 1] : Wii.text, centerV: true)
            }
            let dotX = left + placeW
            (s.color >= 0 ? NameColors.ns(s.color) : (Medal.ns(s.color) ?? Wii.blue)).setFill()
            NSBezierPath(ovalIn: NSRect(x: dotX, y: row.midY - 6, width: 12, height: 12)).fill()
            // Right-hand columns: KOs at the edge, the time left of them, a note left of the time (or in its place).
            if s.knockouts > 0 {
                Wii.drawText("\(s.knockouts) KO", in: NSRect(x: right - koW, y: row.minY, width: koW, height: rowH), size: 15,
                             color: Wii.textSoft, align: .right, centerV: true)
            }
            var used = right - koW
            if let t = s.time {
                Wii.drawText(raceClock(t), in: NSRect(x: timeRight - timeW, y: row.minY, width: timeW, height: rowH), size: 15,
                             bold: you, color: you ? Wii.text : Wii.textSoft, align: .right, centerV: true)
                used = timeRight - timeW
            }
            if !s.note.isEmpty {
                // A row without a time puts its note where the time would be ("did not finish"); in a table with no
                // times at all (a fight) it goes in the rightmost column with the KOs ("out").
                let noteEnd = s.time != nil ? noteRight : (hasTime ? timeRight : (s.knockouts > 0 ? right - koW : right))
                Wii.drawText(s.note, in: NSRect(x: noteEnd - noteW, y: row.minY, width: noteW, height: rowH), size: 14,
                             color: Wii.textSoft, align: .right, centerV: true)
                used = min(used, noteEnd - Wii.attributed(s.note, font: Wii.font(14), color: Wii.textSoft, align: .left).size().width)
            }
            let nameX = dotX + 20
            Wii.drawText(s.name, in: NSRect(x: nameX, y: row.minY, width: max(40, used - 12 - nameX), height: rowH), size: 15,
                         bold: you, centerV: true, truncate: true)
            y += rowH
        }
        y += 14
        var coinLine = res.coins > 0 ? "+\(res.coins) ●" : ""
        if res.personalBest { coinLine += (coinLine.isEmpty ? "" : "     ") + "New personal best!" }
        Wii.drawText(coinLine, in: NSRect(x: r.minX, y: y, width: r.width, height: 30), size: 20, bold: true, align: .center, centerV: true)
        if !res.footer.isEmpty {
            Wii.drawText(res.footer, in: NSRect(x: r.minX + 16, y: y + 32, width: r.width - 32, height: 20), size: 13, color: Wii.textSoft,
                         align: .center, centerV: true, truncate: true)
        }
    }
}

/// A few recent messages (knock-outs, finishes, who joined) that fade away.
final class FeedView: FlippedView {
    private var lines: [(String, Date)] = []

    func add(_ s: String) {
        lines.append((s, Date()))
        if lines.count > 5 { lines.removeFirst() }
        needsDisplay = true
    }

    func tick() {
        let before = lines.count
        lines.removeAll { Date().timeIntervalSince($0.1) > 7 }
        if lines.count != before || !lines.isEmpty { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 0
        for (s, t) in lines {
            let age = Date().timeIntervalSince(t)
            let a = CGFloat(clamp(7 - age, 0, 1))
            let h: CGFloat = 26
            let text = Wii.attributed(s, font: Wii.font(13, bold: true), color: .white, align: .right)
            let w = min(text.size().width + 24, bounds.width)
            let pill = NSRect(x: bounds.width - w, y: y, width: w, height: h)
            NSColor(white: 0.08, alpha: 0.5 * a).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 13, yRadius: 13).fill()
            Wii.drawText(s, in: pill.insetBy(dx: 12, dy: 0), size: 13, bold: true, color: NSColor.white.withAlphaComponent(a),
                         align: .right, centerV: true)
            y += h + 4
        }
    }
}
