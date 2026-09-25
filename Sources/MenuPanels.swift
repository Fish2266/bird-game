import AppKit

// The "Play" (modes & maps) and "LAN" tabs of the pause menu.

/// Card for one game mode.
final class ModeCardView: FlippedView {
    let mode: GameMode
    var onSelect: (() -> Void)?
    var isHighlighted = false { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    private var hover = false

    init(_ mode: GameMode) {
        self.mode = mode
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
    override func mouseDown(with event: NSEvent) { if enabled { onSelect?() } }
    override func resetCursorRects() { if enabled { addCursorRect(bounds, cursor: .pointingHand) } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 5, dy: 5)
        let border = isHighlighted ? Wii.blue : (hover && enabled ? Wii.blueLight : Wii.border)
        Wii.tile(r, radius: 10, fill: .white, bottom: Wii.tileLow, border: border, borderWidth: isHighlighted ? 3 : 2)
        let icon = NSRect(x: r.minX + 12, y: r.midY - 17, width: 34, height: 34)
        Wii.glossy(icon, radius: 17, rim: isHighlighted ? Wii.blue : Wii.border, rimWidth: 2)
        ModeIcon.draw(mode, in: icon.insetBy(dx: 7, dy: 7), color: enabled ? (isHighlighted ? Wii.blue : Wii.text) : Wii.textSoft)
        let tx = icon.maxX + 10, tw = r.maxX - tx - 8
        Wii.drawText(mode.title, in: NSRect(x: tx, y: r.minY + 12, width: tw, height: 20), size: 13, bold: true,
                     color: enabled ? Wii.text : Wii.textSoft, truncate: true)
        Wii.drawText(isCurrent ? "Playing now" : detail, in: NSRect(x: tx, y: r.minY + 33, width: tw, height: 18), size: 12,
                     color: isCurrent ? Wii.blue : Wii.textSoft, truncate: true)
    }
}

/// Small line-art icons for the game modes (drawn in a flipped view).
enum ModeIcon {
    static func draw(_ mode: GameMode, in r: NSRect, color: NSColor) {
        color.setStroke()
        color.setFill()
        let p = NSBezierPath()
        p.lineWidth = 2.4
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        switch mode {
        case .freeRoam:
            // A bird soaring.
            BirdIcon.draw(BirdLook(), in: r.insetBy(dx: -2, dy: -2), mono: color)
        case .ringRace:
            // A course of rings getting smaller into the distance.
            for (k, f) in [(0, 1.0), (1, 0.66), (2, 0.4)] as [(Int, CGFloat)] {
                let d = r.height * f
                let x = r.minX + [0, 0.5, 0.82][k] * r.width
                let ring = NSBezierPath(ovalIn: NSRect(x: x - d * 0.25, y: r.midY - d / 2, width: d * 0.62, height: d))
                ring.lineWidth = k == 0 ? 2.6 : 2
                ring.stroke()
            }
        case .speedRace:
            // Two chevrons: fast forward.
            for k in 0..<2 {
                let x0 = r.minX + CGFloat(k) * r.width * 0.42
                let c = NSBezierPath()
                c.lineWidth = 2.6
                c.lineCapStyle = .round
                c.lineJoinStyle = .round
                c.move(to: NSPoint(x: x0, y: r.minY + 1))
                c.line(to: NSPoint(x: x0 + r.width * 0.45, y: r.midY))
                c.line(to: NSPoint(x: x0, y: r.maxY - 1))
                c.stroke()
            }
        case .pvp:
            // A crosshair.
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2))
            ring.lineWidth = 2.2
            ring.stroke()
            for (a, b) in [(NSPoint(x: r.midX, y: r.minY - 1), NSPoint(x: r.midX, y: r.minY + r.height * 0.32)),
                           (NSPoint(x: r.midX, y: r.maxY + 1), NSPoint(x: r.midX, y: r.maxY - r.height * 0.32)),
                           (NSPoint(x: r.minX - 1, y: r.midY), NSPoint(x: r.minX + r.width * 0.32, y: r.midY)),
                           (NSPoint(x: r.maxX + 1, y: r.midY), NSPoint(x: r.maxX - r.width * 0.32, y: r.midY))] {
                p.move(to: a); p.line(to: b)
            }
            p.stroke()
            NSBezierPath(ovalIn: NSRect(x: r.midX - 2, y: r.midY - 2, width: 4, height: 4)).fill()
        }
    }
}

/// Play tab: pick a mode and a map, then start.
final class PlayPanel: FlippedView {
    let progress: Progress
    let lan: LANSession
    var onPlay: ((GameMode, WorldID) -> Void)?
    var onStartRound: (() -> Void)?

    private var modeCards: [ModeCardView] = []
    private var mapCards: [ShopCardView] = []
    private let modeHeader = WiiLabel(13, bold: true, color: Wii.textSoft)
    private let mapHeader = WiiLabel(13, bold: true, color: Wii.textSoft)
    private let art = WorldArtView()
    private let artFrame = WiiFrame()
    private let title = WiiLabel(22, bold: true)
    private let blurb = WiiLabel(13, color: Wii.textSoft)
    private var info: [WiiLabel] = []
    private let start = WiiButton("", textSize: 17)
    private let round = WiiButton("Start round for everyone", textSize: 15)
    private let botCount = WiiSelector("Bots")
    private let botLevel = WiiSelector("Difficulty")
    private(set) var mode = GameMode.freeRoam
    private(set) var world = WorldID.meadow
    private var playingMode = GameMode.freeRoam
    private var playingWorld = WorldID.meadow

    init(progress: Progress, lan: LANSession) {
        self.progress = progress
        self.lan = lan
        super.init(frame: .zero)
        modeHeader.text = "MODE"
        mapHeader.text = "MAP"
        for v in [modeHeader, mapHeader, art, artFrame, title, blurb, start, round, botCount, botLevel] as [NSView] { addSubview(v) }
        botCount.onClick = { [weak self] in BotSettings.count = BotSettings.count % 5 + 1; self?.refresh() }
        botLevel.onClick = { [weak self] in BotSettings.difficulty = (BotSettings.difficulty + 1) % 3; self?.refresh() }
        for m in GameMode.allCases {
            let c = ModeCardView(m)
            c.onSelect = { [weak self] in self?.mode = m; self?.refresh() }
            addSubview(c)
            modeCards.append(c)
        }
        for w in WorldCatalog.all where !w.comingSoon {
            let c = ShopCardView(.world(w))
            c.onSelect = { [weak self] in if let k = w.kind { self?.world = k; self?.refresh() } }
            addSubview(c)
            mapCards.append(c)
        }
        for _ in 0..<4 {
            let l = WiiLabel(13)
            l.centerV = true
            addSubview(l)
            info.append(l)
        }
        start.onClick = { [weak self] in
            guard let self else { return }
            self.onPlay?(self.mode, self.world)
        }
        round.onClick = { [weak self] in self?.onStartRound?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setPlaying(mode: GameMode, world: WorldID) {
        playingMode = mode
        playingWorld = world
        self.mode = mode
        self.world = world
        refresh()
    }

    func refresh() {
        let host = lan.role == .hosting, client = lan.role == .joined
        for c in modeCards {
            c.isHighlighted = c.mode == mode
            c.isCurrent = c.mode == playingMode
            c.enabled = !client
            switch c.mode {
            case .freeRoam: c.detail = "Endless rings"
            case .ringRace, .speedRace:
                let best = progress.bestTime(c.mode, world.rawValue)
                let medal = progress.bestMedal(c.mode, world.rawValue).map { "  ·  \($0.name)" } ?? ""
                c.detail = best.map { "Best " + raceClock($0) + medal } ?? "No time yet"
            case .pvp: c.detail = host || client ? "Last bird flying" : "You vs \(BotSettings.count) bot\(BotSettings.count == 1 ? "" : "s")"
            }
        }
        for c in mapCards {
            guard case .world(let w) = c.item else { continue }
            c.isHighlighted = w.kind == world
            c.isEquipped = w.kind == playingWorld
            c.owned = progress.ownsWorld(w) || client
            c.affordable = progress.coins >= w.cost
        }
        let w = WorldCatalog.info(world.rawValue)
        art.world = w
        title.text = "\(mode.title) · \(w.name)"
        blurb.text = mode.blurb
        var rows: [String] = []
        switch mode {
        case .freeRoam:
            rows = ["The original game: fly anywhere and chase endless rings.", w.isChallenge ? "Hazards: \(w.hazards)" : "No hazards — just fly.",
                    "Rings earn coins (×\(Int(w.ringMultiplier)) here)."]
        case .ringRace, .speedRace:
            let best = progress.bestTime(mode, w.id).map(raceClock) ?? "—"
            let medal = progress.bestMedal(mode, w.id).map { " (\($0.name))" } ?? ""
            rows = [mode == .ringRace ? "16 rings on a fixed course. Miss one: +5 seconds." : "Follow the glowing sky road through every checkpoint.",
                    "Beat the target times for bronze, silver and gold medals.",
                    "Your best: \(best)\(medal)" + (host || client ? "" : "   ·   race your ghost")]
        case .pvp:
            rows = ["Face a bird to lock on, then open your mouth wide (or press Return).",
                    "Green orbs heal you. Every bird has its own attack.",
                    host || client ? "Out of lives? Watch until the round ends." : "The arena wall starts closing after 45 seconds."]
        }
        if client { rows.append("The host picks the mode and map.") } else if host { rows.append("Everyone in your game switches with you.") }
        for (i, l) in info.enumerated() { l.text = i < rows.count ? rows[i] : "" }

        let owned = progress.ownsWorld(w) || client
        let same = mode == playingMode && world == playingWorld
        let bots = mode == .pvp && !host && !client
        botCount.isHidden = !bots
        botLevel.isHidden = !bots
        botCount.value = "\(BotSettings.count)"
        botLevel.value = BotSettings.difficulties[BotSettings.difficulty]
        round.isHidden = !(host && same && mode != .freeRoam)
        if client {
            start.title = "Host picks the mode"; start.isEnabled = false
        } else if !owned {
            start.title = "Unlock this map in Worlds"; start.isEnabled = false
        } else if host {
            start.title = same ? "Everyone's here" : "Switch everyone"; start.isEnabled = !same
        } else if same && mode == .freeRoam {
            start.title = "You're here"; start.isEnabled = false
        } else {
            start.title = same ? "Restart \(mode.title)" : (mode == .freeRoam ? "Fly here" : "Start \(mode.title)"); start.isEnabled = true
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width
        modeHeader.isHidden = true
        mapHeader.isHidden = true
        for (i, c) in modeCards.enumerated() { c.frame = TabLayout.cardFrame(i, areaW: W, top: 0) }
        for (i, c) in mapCards.enumerated() { c.frame = TabLayout.cardFrame(i + TabLayout.columns, areaW: W, top: 0) }
        let dy = TabLayout.detailTop
        let dh = bounds.height - dy
        let pw = TabLayout.pictureWidth(W)
        art.frame = NSRect(x: 0, y: dy, width: pw, height: dh - TabLayout.actionH - 12)
        artFrame.frame = art.frame
        start.frame = NSRect(x: -5, y: dy + dh - TabLayout.actionH, width: pw + 10, height: TabLayout.actionH)
        let cx = pw + 28, cw = W - cx
        title.frame = NSRect(x: cx, y: dy - 4, width: cw, height: 30)
        blurb.frame = NSRect(x: cx, y: dy + 30, width: cw, height: blurb.fittingHeight(width: cw))
        var y = dy + 30 + max(blurb.frame.height, 36) + 14
        for l in info { l.frame = NSRect(x: cx, y: y, width: cw, height: 28); y += 32 }
        // Extra controls line up with the main button at the bottom of the text column.
        let selW = min(170, (cw - 16) / 2)
        botCount.frame = NSRect(x: cx, y: dy + dh - 58, width: selW, height: 56)
        botLevel.frame = NSRect(x: cx + selW + 16, y: dy + dh - 58, width: selW, height: 56)
        round.frame = NSRect(x: cx - 5, y: dy + dh - TabLayout.actionH, width: min(300, cw), height: TabLayout.actionH)
    }
}

/// Wii-style rounded text field for the player name.
final class WiiTextField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = Wii.font(15, bold: true)
        textColor = Wii.text
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 2
        layer?.borderColor = Wii.border.cgColor
        let c = PaddedCell(textCell: "")
        c.isEditable = true
        c.isSelectable = true
        c.usesSingleLineMode = true
        c.lineBreakMode = .byTruncatingTail
        c.font = font
        c.textColor = textColor
        cell = c
    }
    required init?(coder: NSCoder) { fatalError() }
    override func becomeFirstResponder() -> Bool {
        layer?.borderColor = Wii.blue.cgColor
        return super.becomeFirstResponder()
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        layer?.borderColor = Wii.border.cgColor
    }
}

/// Text cell inset from the rounded edge and centred vertically.
private final class PaddedCell: NSTextFieldCell {
    private func padded(_ r: NSRect) -> NSRect {
        let h = cellSize(forBounds: r).height
        return NSRect(x: r.minX + 10, y: r.minY + max(0, (r.height - h) / 2), width: r.width - 20, height: h)
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { padded(super.drawingRect(forBounds: rect)) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: padded(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: padded(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

/// Color dots for the nametag.
final class ColorPicker: FlippedView {
    var selected = 0 { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.x / 30)
        guard i >= 0, i < NameColors.all.count else { return }
        selected = i
        onChange?(i)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<NameColors.all.count {
            let r = NSRect(x: CGFloat(i) * 30 + 3, y: (bounds.height - 24) / 2, width: 24, height: 24)
            if i == selected {
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -3, dy: -3))
                ring.lineWidth = 2.5
                Wii.text.setStroke(); ring.stroke()
            }
            NameColors.ns(i).setFill(); NSBezierPath(ovalIn: r).fill()
        }
    }
}

/// A row in a LAN list: color dot, title, subtitle and up to two buttons.
private final class LANRow: FlippedView {
    let dot = ColorDot()
    let title = WiiLabel(14, bold: true)
    let sub = WiiLabel(12, color: Wii.textSoft)
    let a = WiiButton("", textSize: 12)
    let b = WiiButton("", textSize: 12)

    final class ColorDot: FlippedView {
        var color: NSColor? { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            guard let color else { return }
            color.setFill(); NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for v in [dot, title, sub, a, b] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        Wii.tile(bounds.insetBy(dx: 1, dy: 2), radius: 9, fill: .white, bottom: Wii.tileLow, border: Wii.border, borderWidth: 1.5,
                 shadow: false)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        dot.frame = NSRect(x: 12, y: (h - 14) / 2, width: 14, height: 14)
        let bw: CGFloat = 92
        var right = bounds.width - 6
        if !b.isHidden { b.frame = NSRect(x: right - bw, y: (h - 38) / 2, width: bw, height: 38); right -= bw + 2 }
        if !a.isHidden { a.frame = NSRect(x: right - bw, y: (h - 38) / 2, width: bw, height: 38); right -= bw + 2 }
        title.frame = NSRect(x: 34, y: 6, width: right - 40, height: 18)
        sub.frame = NSRect(x: 34, y: 25, width: right - 40, height: 16)
    }
}

/// LAN tab: name & color, host / join / invite, host settings and the player list.
final class LANPanel: FlippedView, NSTextFieldDelegate {
    let lan: LANSession
    var onHost: (() -> Void)?
    var onRulesChanged: ((MatchRules) -> Void)?
    var onProfileChanged: ((String, Int) -> Void)?
    var onGoOnline: (() -> Void)?
    var onStartRound: (() -> Void)?
    /// What's being played right now (hosting starts with it).
    var playing = (GameMode.freeRoam, WorldID.meadow)

    private let nameLabel = WiiLabel(13, bold: true, color: Wii.textSoft)
    private let nameField = WiiTextField(frame: .zero)
    private let colorLabel = WiiLabel(13, bold: true, color: Wii.textSoft)
    private let colors = ColorPicker()
    private let status = WiiLabel(13, color: Wii.textSoft)
    private let online = WiiButton("Go online", textSize: 16)
    private let offlineInfo = WiiLabel(13, color: Wii.textSoft)
    private let leftHeader = WiiLabel(15, bold: true)
    private let rightHeader = WiiLabel(15, bold: true)
    private let hostButton = WiiButton("Host a game", textSize: 15)
    private let leaveButton = WiiButton("", textSize: 15)
    private let collisions = WiiToggle("Collisions")
    private let pvp = WiiToggle("PvP (attacks)")
    private let showLocation = WiiToggle("Show location")
    private let ruleNotes = [WiiLabel(12, color: Wii.textSoft), WiiLabel(12, color: Wii.textSoft), WiiLabel(12, color: Wii.textSoft)]
    private let gameInfo = WiiLabel(13, color: Wii.textSoft)
    private let startRound = WiiButton("Start round", textSize: 15)
    private let emptyLeft = WiiLabel(13, color: Wii.textSoft)
    private let emptyRight = WiiLabel(13, color: Wii.textSoft)
    private let inviteHeader = WiiLabel(15, bold: true)
    private var leftRows: [LANRow] = []
    private var rightRows: [LANRow] = []
    private var inviteRows: [LANRow] = []

    init(lan: LANSession) {
        self.lan = lan
        super.init(frame: .zero)
        nameLabel.text = "YOUR NAME"
        colorLabel.text = "NAMETAG COLOR"
        nameField.delegate = self
        nameField.placeholderString = "Your name"
        offlineInfo.text = "Play with friends on the same Wi-Fi or network — no server needed. Going online lets other Bird Games on your network see your name so they can invite you. macOS may ask to allow local network access."
        emptyLeft.text = "No games on your network yet. Ask a friend to host, or host one yourself."
        ruleNotes[0].text = "Flying into a bird knocks it flying (Ram vs Weight)."
        ruleNotes[1].text = "Attacks work in every mode, not just PvP Fight."
        ruleNotes[2].text = "Everyone glows through walls, with a compass."
        for v in [nameLabel, nameField, colorLabel, colors, status, online, offlineInfo, leftHeader, rightHeader, hostButton, leaveButton,
                  collisions, pvp, showLocation, gameInfo, startRound, emptyLeft, emptyRight, inviteHeader] + ruleNotes as [NSView] { addSubview(v) }
        startRound.onClick = { [weak self] in self?.onStartRound?() }
        colors.onChange = { [weak self] i in self?.commitProfile(color: i) }
        online.onClick = { [weak self] in self?.onGoOnline?() }
        hostButton.onClick = { [weak self] in self?.onHost?() }
        leaveButton.onClick = { [weak self] in self?.lan.leave() }
        for t in [collisions, pvp, showLocation] { t.onChange = { [weak self] _ in self?.rulesToggled() } }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Name editing
    func controlTextDidEndEditing(_ obj: Notification) { commitProfile(color: colors.selected) }
    private func commitProfile(color: Int) { onProfileChanged?(nameField.stringValue, color) }

    private func rulesToggled() {
        guard lan.role == .hosting else { refresh(); return }
        onRulesChanged?(MatchRules(collisions: collisions.isOn, pvp: pvp.isOn, showLocation: showLocation.isOn))
    }

    private func rows(_ list: inout [LANRow], count: Int) {
        while list.count < count { let r = LANRow(); addSubview(r); list.append(r) }
        for (i, r) in list.enumerated() { r.isHidden = i >= count }
    }

    func refresh() {
        if nameField.currentEditor() == nil { nameField.stringValue = lan.name }
        colors.selected = lan.color
        let role = lan.role
        let isOnline = role != .offline
        online.isHidden = isOnline
        offlineInfo.isHidden = isOnline
        status.text = lan.status
        status.isHidden = role == .hosting || role == .joined
        for v in [leftHeader, rightHeader, hostButton, leaveButton, collisions, pvp, showLocation, gameInfo, startRound, emptyLeft, emptyRight,
                  inviteHeader] + ruleNotes as [NSView] { v.isHidden = !isOnline }
        guard isOnline else {
            rows(&leftRows, count: 0); rows(&rightRows, count: 0); rows(&inviteRows, count: 0)
            needsLayout = true
            return
        }
        let inGame = role == .hosting || role == .joined
        hostButton.isHidden = inGame
        leaveButton.isHidden = !inGame
        leaveButton.title = role == .hosting ? "Stop hosting" : "Leave game"
        for t in [collisions, pvp, showLocation] { t.isHidden = !inGame }
        for l in ruleNotes { l.isHidden = !inGame }
        let l = lan.lobby
        let where_ = "\(l.mode.title) on \(WorldCatalog.info(l.world).name)"
        switch role {
        case .hosting: gameInfo.text = where_ + "  ·  pick another in the Play tab"
        case .joined: gameInfo.text = where_ + (l.running ? "  ·  round in progress" : "")
        default: gameInfo.text = "You'll host \(playing.0.title) on \(WorldCatalog.info(playing.1.rawValue).name)."
        }
        startRound.isHidden = !(role == .hosting && l.mode != .freeRoam)
        startRound.isEnabled = !l.running
        startRound.title = l.running ? "Round under way" : "Start round"
        let r = lan.lobby.rules
        collisions.setOn(r.collisions); pvp.setOn(r.pvp); showLocation.setOn(r.showLocation)
        for t in [collisions, pvp, showLocation] { t.alphaValue = role == .hosting ? 1 : 0.55 }

        if inGame {
            leftHeader.text = role == .hosting ? "Your game" : "In \(lan.lobby.hostName)'s game"
            emptyLeft.isHidden = true
            rows(&leftRows, count: 0)
            // Right: players
            let players = lan.lobby.players
            rightHeader.text = "Players  \(players.count)/\(LANSession.maxPlayers)"
            rows(&rightRows, count: players.count)
            for (i, p) in players.enumerated() {
                let row = rightRows[i]
                row.dot.color = NameColors.ns(p.color)
                row.title.text = p.name + (p.id == lan.localId ? " (you)" : "") + (p.id == 1 ? " · host" : "")
                row.sub.text = Catalog.species(p.bird).name
                row.a.isHidden = true
                row.b.isHidden = !(role == .hosting && p.id != 1)
                row.b.title = "Kick"
                let id = p.id
                row.b.onClick = { [weak self] in self?.lan.kick(id) }
            }
            emptyRight.isHidden = true
            // Invites (host): nearby players not already in a game.
            if role == .hosting {
                let peers = lan.nearby.filter { !$0.inGame }
                inviteHeader.text = "Invite nearby players"
                inviteHeader.isHidden = false
                rows(&inviteRows, count: peers.count)
                for (i, p) in peers.enumerated() {
                    let row = inviteRows[i]
                    row.dot.color = NameColors.ns(p.color)
                    row.title.text = p.name
                    row.sub.text = "On your network"
                    row.a.isHidden = true
                    row.b.isHidden = false
                    let done = lan.invited.contains(p.service)
                    row.b.title = done ? "Invited" : "Invite"
                    row.b.isEnabled = !done
                    row.b.onClick = { [weak self] in self?.lan.invite(p) }
                }
                emptyLeft.isHidden = !peers.isEmpty
                emptyLeft.text = peers.isEmpty ? "Nobody else is online yet. Friends show up here once they open the LAN tab." : ""
            } else {
                inviteHeader.isHidden = true
                rows(&inviteRows, count: 0)
            }
        } else {
            leftHeader.text = "Games on your network"
            inviteHeader.isHidden = true
            rows(&inviteRows, count: 0)
            let invites = lan.invites
            let games = lan.games
            rows(&leftRows, count: invites.count + games.count)
            for (i, inv) in invites.enumerated() {
                let row = leftRows[i]
                row.dot.color = NameColors.ns(inv.color)
                row.title.text = "\(inv.from) invited you!"
                row.sub.text = "Join their game?"
                row.a.isHidden = false; row.a.title = "Join"; row.a.isEnabled = true
                row.a.onClick = { [weak self] in self?.lan.accept(inv) }
                row.b.isHidden = false; row.b.title = "Ignore"; row.b.isEnabled = true
                row.b.onClick = { [weak self] in self?.lan.dismiss(inv) }
            }
            for (k, g) in games.enumerated() {
                let row = leftRows[invites.count + k]
                row.dot.color = NameColors.ns(g.color)
                row.title.text = "\(g.hostName)'s game"
                row.sub.text = "\(g.mode.title) · \(WorldCatalog.info(g.world).name) · \(g.players)/\(LANSession.maxPlayers)"
                row.a.isHidden = true
                row.b.isHidden = false; row.b.title = "Join"; row.b.isEnabled = g.players < LANSession.maxPlayers
                row.b.onClick = { [weak self] in self?.lan.join(g) }
            }
            emptyLeft.isHidden = !(invites.isEmpty && games.isEmpty)
            emptyLeft.text = "No games on your network yet. Ask a friend to host, or host one yourself."
            rightHeader.text = "Online nearby"
            let peers = lan.nearby
            rows(&rightRows, count: peers.count)
            for (i, p) in peers.enumerated() {
                let row = rightRows[i]
                row.dot.color = NameColors.ns(p.color)
                row.title.text = p.name
                row.sub.text = p.inGame ? "In a game" : "Online"
                row.a.isHidden = true; row.b.isHidden = true
            }
            emptyRight.isHidden = !peers.isEmpty
            emptyRight.text = "Nobody else yet."
        }
        for r in leftRows + rightRows + inviteRows { r.needsLayout = true }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let W = bounds.width, H = bounds.height
        nameLabel.frame = NSRect(x: 0, y: 0, width: 220, height: 16)
        nameField.frame = NSRect(x: 0, y: 20, width: 240, height: 32)
        colorLabel.frame = NSRect(x: 262, y: 0, width: 240, height: 16)
        colors.frame = NSRect(x: 258, y: 20, width: 30 * CGFloat(NameColors.all.count), height: 32)
        status.frame = NSRect(x: 0, y: 60, width: W, height: 34)
        online.frame = NSRect(x: -5, y: 92, width: 220, height: 56)
        offlineInfo.frame = NSRect(x: 0, y: 156, width: min(W, 560), height: 80)

        let colW = (W - 32) / 2
        let top: CGFloat = status.isHidden ? 76 : 98
        leftHeader.frame = NSRect(x: 0, y: top, width: colW, height: 22)
        rightHeader.frame = NSRect(x: colW + 32, y: top, width: colW, height: 22)
        var y = top + 28
        if lan.role == .hosting || lan.role == .joined {
            gameInfo.frame = NSRect(x: 0, y: top + 24, width: colW, height: 18)
            y = top + 52
            for (i, t) in [collisions, pvp, showLocation].enumerated() {
                t.frame = NSRect(x: 0, y: y, width: colW, height: 30)
                ruleNotes[i].frame = NSRect(x: 0, y: y + 32, width: colW - 8, height: 16)
                y += 58
            }
            y += 6
            inviteHeader.frame = NSRect(x: 0, y: y, width: colW, height: 22); y += 26
            for r in inviteRows where !r.isHidden { r.frame = NSRect(x: 0, y: y, width: colW, height: 46); y += 48 }
            emptyLeft.frame = NSRect(x: 0, y: y, width: colW, height: 40)
        } else {
            for r in leftRows where !r.isHidden { r.frame = NSRect(x: 0, y: y, width: colW, height: 46); y += 48 }
            emptyLeft.frame = NSRect(x: 0, y: y, width: colW, height: 40)
        }
        var ry = top + 28
        for r in rightRows where !r.isHidden { r.frame = NSRect(x: colW + 32, y: ry, width: colW, height: 46); ry += 48 }
        emptyRight.frame = NSRect(x: colW + 32, y: ry, width: colW, height: 20)
        hostButton.frame = NSRect(x: -5, y: H - 56, width: 240, height: 56)
        leaveButton.frame = NSRect(x: -5, y: H - 56, width: 240, height: 56)
        startRound.frame = NSRect(x: leaveButton.frame.maxX + 8, y: H - 56, width: 240, height: 56)
        if lan.role == .idle { gameInfo.frame = NSRect(x: hostButton.frame.maxX + 14, y: H - 35, width: W - hostButton.frame.maxX - 14, height: 18) }
    }
}
