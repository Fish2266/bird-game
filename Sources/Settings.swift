import AppKit
import SceneKit

/// Everything that isn't part of playing: sound, the camera and its picture, the HUD, chat, graphics and updates.
/// Opens over the pause menu from its Settings button; Esc, Return or Done closes it.
///
/// Laid out on one grid: every row is the same height, labels start at the same x, controls end at the same x, and
/// the two columns share row positions (a section title in the right column takes a row, so the rows still line up).
final class SettingsCard: NSView {
    var onClose: (() -> Void)?
    var onSound: ((Bool) -> Void)?
    var onHelp: ((Bool) -> Void)?
    var onChat: ((Bool) -> Void)?
    var onHUDOpacity: ((CGFloat) -> Void)?
    var onFPS: ((Bool) -> Void)?
    var onCamera: ((String) -> Void)?
    var onPreview: ((Bool) -> Void)?
    /// nil = automatic.
    var onGraphics: ((GraphicsQuality?) -> Void)?
    var onVSync: ((Bool) -> Void)?
    var onAutoUpdate: ((Bool) -> Void)?

    private let card = WiiPanel()
    private let title = WiiLabel(26, bold: true)
    private let gameHeader = WiiLabel(12, bold: true, color: Wii.textSoft)
    private let cameraHeader = WiiLabel(12, bold: true, color: Wii.textSoft)
    private let screenHeader = WiiLabel(12, bold: true, color: Wii.textSoft)
    let soundBox = WiiToggle("Sound")
    let helpBox = WiiToggle("Show help")
    let chatBox = WiiToggle("Show chat")
    let fpsBox = WiiToggle("Show frame rate")
    let updatesBox = WiiToggle("Check for updates")
    let opacitySlider = WiiSlider("HUD opacity")
    let cameraSelector = WiiSelector("Camera")
    let previewBox = WiiToggle("Camera picture")
    let graphicsSelector = WiiSelector("Graphics")
    let vsyncBox = WiiToggle("V-Sync")
    private let vsyncNote = WiiLabel(12, color: Wii.textSoft)
    private let done = WiiButton("Done", textSize: 17)

    private var cameras: [(id: String, name: String)] = []
    private var cameraIndex = 0
    /// nil = automatic.
    private var graphics: GraphicsQuality?
    private var automaticGraphics = GraphicsQuality.high
    private var screenMaxFPS = 60

    // The grid.
    static let header: CGFloat = 62
    private static let row: CGFloat = 44
    private static let section: CGFloat = 30
    private static let control: CGFloat = 186

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor
        addSubview(card)
        card.borderColor = Wii.blue
        card.glass = SettingsCard.header
        title.text = "Settings"
        title.align = .center
        title.centerV = true
        gameHeader.text = "GAME"
        cameraHeader.text = "CAMERA"
        screenHeader.text = "SCREEN"
        for h in [gameHeader, cameraHeader, screenHeader] { h.centerV = true }
        for s in [cameraSelector, graphicsSelector] { s.inline = true; s.pillWidth = SettingsCard.control }
        opacitySlider.inline = true
        opacitySlider.trackWidth = SettingsCard.control
        for v in [title, gameHeader, cameraHeader, screenHeader, soundBox, helpBox, chatBox, fpsBox, updatesBox, opacitySlider,
                  cameraSelector, previewBox, graphicsSelector, vsyncBox, vsyncNote, done] as [NSView] {
            card.addSubview(v)
        }
        soundBox.onChange = { [weak self] on in self?.onSound?(on) }
        helpBox.onChange = { [weak self] on in self?.onHelp?(on) }
        chatBox.onChange = { [weak self] on in self?.onChat?(on) }
        fpsBox.onChange = { [weak self] on in self?.onFPS?(on) }
        updatesBox.onChange = { [weak self] on in self?.onAutoUpdate?(on) }
        opacitySlider.onChange = { [weak self] v in self?.onHUDOpacity?(v) }
        previewBox.onChange = { [weak self] on in self?.onPreview?(on) }
        vsyncBox.onChange = { [weak self] on in
            self?.onVSync?(on)
            self?.updateVSyncNote()
        }
        cameraSelector.onClick = { [weak self] in self?.nextCamera() }
        graphicsSelector.onClick = { [weak self] in self?.nextGraphics() }
        done.onClick = { [weak self] in self?.onClose?() }
        cameraSelector.toolTip = "Click to switch cameras"
        graphicsSelector.toolTip = "Automatic picks a level for your Mac and steps down if flying gets choppy"
        updatesBox.toolTip = "Look for a new version when the game starts and every few hours"
        fpsBox.toolTip = "The small frame counter under your speed"
    }
    required init?(coder: NSCoder) { fatalError() }

    // Clicks outside the card don't reach the menu underneath.
    override func mouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 || e.keyCode == 36 || e.keyCode == 76 { onClose?(); return }
        super.keyDown(with: e)
    }

    struct Values {
        var sound: Bool
        var help: Bool
        var chat: Bool
        var fps: Bool
        var autoUpdate: Bool
        var hudOpacity: CGFloat
        var cameras: [(id: String, name: String)]
        var currentCamera: String?
        var preview: Bool
        var graphics: GraphicsQuality?
        var automaticGraphics: GraphicsQuality
        var vsync: Bool
        /// The screen's highest refresh rate.
        var screenMaxFPS: Int
    }

    func show(_ v: Values) {
        soundBox.setOn(v.sound)
        helpBox.setOn(v.help)
        chatBox.setOn(v.chat)
        fpsBox.setOn(v.fps)
        updatesBox.setOn(v.autoUpdate)
        opacitySlider.value = v.hudOpacity
        cameras = v.cameras
        cameraIndex = v.cameras.firstIndex { $0.id == v.currentCamera } ?? 0
        cameraSelector.value = cameras.isEmpty ? "No camera" : cameras[cameraIndex].name
        previewBox.setOn(v.preview)
        graphics = v.graphics
        automaticGraphics = v.automaticGraphics
        graphicsSelector.value = graphicsName
        vsyncBox.setOn(v.vsync)
        screenMaxFPS = v.screenMaxFPS
        updateVSyncNote()
    }

    /// What V-Sync is doing right now, and what the screen itself can show.
    private func updateVSyncNote() {
        vsyncNote.text = vsyncBox.isOn
            ? "Locked to 60 fps. Your screen can show \(screenMaxFPS)."
            : "Unlocked: as fast as your Mac can go.\nYour screen can show \(screenMaxFPS)."
        needsLayout = true
    }

    private var graphicsName: String { graphics.map(\.title) ?? "Automatic (\(automaticGraphics.title))" }

    private func nextCamera() {
        guard cameras.count > 1 else { NSSound.beep(); return }
        cameraIndex = (cameraIndex + 1) % cameras.count
        cameraSelector.value = cameras[cameraIndex].name
        onCamera?(cameras[cameraIndex].id)
    }

    /// Automatic → High → Balanced → Low → Automatic.
    private func nextGraphics() {
        switch graphics {
        case nil: graphics = .high
        case .high?: graphics = .balanced
        case .balanced?: graphics = .low
        case .low?: graphics = nil
        }
        onGraphics?(graphics)
        if graphics == nil { automaticGraphics = GraphicsQuality.automatic }
        graphicsSelector.value = graphicsName
    }

    override func layout() {
        super.layout()
        let R = SettingsCard.row, S = SettingsCard.section
        let pad: CGFloat = 34, gap: CGFloat = 48, w: CGFloat = 720
        // Header band, section titles, six rows, the note's room, then Done.
        let noteRoom: CGFloat = 8
        let contentH = SettingsCard.header + 3 + 12 + S + 6 * R + noteRoom + 18 + 54 + 22
        let h = contentH + card.inset * 2
        card.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
        let c = card.contentRect
        let colW = ((c.width - pad * 2 - gap) / 2).rounded(.down)
        let lx = c.minX + pad, rx = c.maxX - pad - colW
        let header = card.headerRect
        title.frame = header

        let sectionTop = header.maxY + 12
        let rowsTop = sectionTop + S
        func rowFrame(_ x: CGFloat, _ i: Int) -> NSRect { NSRect(x: x, y: rowsTop + CGFloat(i) * R, width: colW, height: R) }

        // Left: GAME, six rows.
        gameHeader.frame = NSRect(x: lx, y: sectionTop, width: colW, height: S)
        let leftRows: [NSView] = [soundBox, helpBox, chatBox, fpsBox, updatesBox, opacitySlider]
        for (i, v) in leftRows.enumerated() { v.frame = rowFrame(lx, i) }

        // Right: CAMERA (two rows), SCREEN in row 2's place, two rows, then the V-Sync note under them.
        cameraHeader.frame = NSRect(x: rx, y: sectionTop, width: colW, height: S)
        cameraSelector.frame = rowFrame(rx, 0)
        previewBox.frame = rowFrame(rx, 1)
        let screenRow = rowFrame(rx, 2)
        screenHeader.frame = NSRect(x: rx, y: screenRow.maxY - S, width: colW, height: S)
        graphicsSelector.frame = rowFrame(rx, 3)
        vsyncBox.frame = rowFrame(rx, 4)
        let noteH = vsyncNote.fittingHeight(width: colW)
        vsyncNote.frame = NSRect(x: rx, y: rowFrame(rx, 5).minY + 2, width: colW, height: noteH)

        let doneY = rowsTop + 6 * R + noteRoom + 18
        done.frame = NSRect(x: (c.midX - 110).rounded(), y: doneY, width: 220, height: 54)
    }
}

/// Settings kept between launches.
enum Prefs {
    private static let d = UserDefaults.standard
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }

    static var muted: Bool { get { bool("sound.muted", false) } set { d.set(newValue, forKey: "sound.muted") } }
    static var showPreview: Bool { get { bool("hud.preview", true) } set { d.set(newValue, forKey: "hud.preview") } }
    static var showChat: Bool { get { bool("chat.show", true) } set { d.set(newValue, forKey: "chat.show") } }
    static var showFPS: Bool { get { bool("hud.fps", true) } set { d.set(newValue, forKey: "hud.fps") } }
    static var vsync: Bool { get { bool("graphics.vsync", true) } set { d.set(newValue, forKey: "graphics.vsync") } }
}

