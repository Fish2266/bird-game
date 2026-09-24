import AppKit
import SceneKit
import AVFoundation

final class GameSCNView: SCNView {
    weak var app: AppDelegate?
    override var acceptsFirstResponder: Bool { true }

    private func setKey(_ code: UInt16, _ down: Bool) -> Bool {
        guard let game = app?.game else { return false }
        switch code {
        case 123, 0: game.keys.left = down
        case 124, 2: game.keys.right = down
        case 126, 13: game.keys.up = down
        case 125, 1: game.keys.down = down
        case 49: game.keys.flap = down
        default: return false
        }
        return true
    }

    override func keyDown(with e: NSEvent) {
        app?.cheatKey(e.charactersIgnoringModifiers ?? "")
        if setKey(e.keyCode, true) { return }
        guard !e.isARepeat else { return }
        if e.keyCode == 53 { app?.togglePause(); return }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "r": app?.recalibrate()
        case "c": app?.togglePreview()
        case "h": app?.toggleHelp()
        case "n": app?.restart()
        case "m": app?.toggleMute()
        case "f": window?.toggleFullScreen(nil)
        default: super.keyDown(with: e)
        }
    }
    override func keyUp(with e: NSEvent) { if !setKey(e.keyCode, false) { super.keyUp(with: e) } }
    override func flagsChanged(with e: NSEvent) { app?.game?.keys.tuck = e.modifierFlags.contains(.shift) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, SCNSceneRendererDelegate, NSMenuDelegate {
    var window: NSWindow!
    var scnView: GameSCNView!
    var hud: HUDView!
    /// The current world's game. Swapped when you travel; read from the render thread.
    var game: Game? {
        get { gameLock.lock(); defer { gameLock.unlock() }; return _game }
        set { gameLock.lock(); _game = newValue; gameLock.unlock() }
    }
    private var _game: Game?
    private let gameLock = NSLock()
    let shared = SharedControls()
    let camera = CameraManager()
    let tracker = PoseTracker()
    let interpreter = ArmInterpreter()
    var sound: SoundEngine?
    var preview: CameraPreviewView?
    var hudTimer: Timer?
    var muted = false
    let progress = Progress()
    var pauseMenu: PauseMenuView!
    private(set) var isPaused = false
    /// 0…1, saved between launches; 100% by default.
    var hudOpacity: CGFloat = UserDefaults.standard.object(forKey: "hudOpacity") as? CGFloat ?? 1 {
        didSet {
            hud.alphaValue = hudOpacity
            UserDefaults.standard.set(Double(hudOpacity), forKey: "hudOpacity")
        }
    }
    private let cameraMenu = NSMenu(title: "Camera")
    private var frameCount = 0
    private var hudTicks = 0
    private var demoTimer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: screen, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Bird Game"
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black

        sound = SoundEngine()
        let game = makeGame(startWorld())

        scnView = GameSCNView(frame: window.contentView!.bounds)
        scnView.app = self
        scnView.autoresizingMask = [.width, .height]
        scnView.scene = game.scene
        scnView.pointOfView = game.cameraNode
        scnView.delegate = self
        scnView.rendersContinuously = true
        scnView.isPlaying = true
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = Sky.fogColor
        window.contentView!.addSubview(scnView)

        hud = HUDView(frame: window.contentView!.bounds)
        hud.autoresizingMask = [.width, .height]
        hud.alphaValue = hudOpacity
        window.contentView!.addSubview(hud)

        pauseMenu = PauseMenuView(progress: progress)
        pauseMenu.frame = window.contentView!.bounds
        pauseMenu.autoresizingMask = [.width, .height]
        pauseMenu.isHidden = true
        window.contentView!.addSubview(pauseMenu)
        wirePauseMenu()

        hud.setCoins(progress.coins)

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(scnView)
        NSApp.activate(ignoringOtherApps: true)

        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.refreshHUD() }

        if CommandLine.arguments.contains("--demo") {
            startDemo()
        } else {
            startCamera()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidResignActive(_ notification: Notification) {
        if !isPaused && !CommandLine.arguments.contains("--no-autopause") { togglePause() }
    }

    // MARK: Pause / settings / shop

    func togglePause() {
        guard let game else { return }
        isPaused.toggle()
        game.keys = KeyInput()
        game.paused = isPaused
        sound?.setMuted(isPaused || muted)
        if isPaused {
            pauseMenu.setSettings(sound: !muted, preview: hud.showPreview, help: hud.showHelp, hudOpacity: hudOpacity,
                                  cameras: CameraManager.availableDevices().map { ($0.uniqueID, $0.localizedName) },
                                  current: camera.device?.uniqueID)
            pauseMenu.willShow()
            pauseMenu.isHidden = false
            hud.isHidden = true
            window.makeFirstResponder(pauseMenu)
        } else {
            pauseMenu.isHidden = true
            pauseMenu.didHide()
            hud.isHidden = false
            hud.setCoins(progress.coins)
            window.makeFirstResponder(scnView)
        }
    }

    private func wirePauseMenu() {
        pauseMenu.onResume = { [weak self] in self?.togglePause() }
        pauseMenu.onRestart = { [weak self] in self?.restart(); self?.togglePause() }
        pauseMenu.onRecalibrate = { [weak self] in self?.recalibrate(); self?.togglePause() }
        pauseMenu.onSound = { [weak self] on in self?.muted = !on }
        pauseMenu.onPreview = { [weak self] on in self?.hud.showPreview = on }
        pauseMenu.onHelp = { [weak self] on in self?.hud.showHelp = on }
        pauseMenu.onHUDOpacity = { [weak self] v in self?.hudOpacity = v }
        pauseMenu.onCamera = { [weak self] id in
            guard let self, let d = CameraManager.availableDevices().first(where: { $0.uniqueID == id }) else { return }
            self.camera.start(with: d)
        }
        pauseMenu.onBirdChanged = { [weak self] sp in self?.applyBird(sp) }
        pauseMenu.onWorldChanged = { [weak self] in self?.travel() }
        pauseMenu.onKey = { [weak self] chars in self?.cheatKey(chars) }
    }

    // MARK: Test coins

    /// Typing [ ] ; ' in a row grants 100 coins; the reverse ' ; ] [ wipes all saved progress.
    private var cheatBuffer = ""
    func cheatKey(_ chars: String) {
        let grant = "[];'", wipe = "';]["
        guard chars.count == 1, grant.contains(chars) else { cheatBuffer = ""; return }
        cheatBuffer = String((cheatBuffer + chars).suffix(4))
        if cheatBuffer == grant {
            cheatBuffer = ""
            progress.grant(100)
            hud.showBonus(coins: 100, total: progress.coins)
            if isPaused { pauseMenu.refresh() }
        } else if cheatBuffer == wipe {
            cheatBuffer = ""
            resetEverything()
        }
    }

    private func resetEverything() {
        progress.resetAll()
        hudOpacity = 1
        UserDefaults.standard.removeObject(forKey: "hudOpacity")
        if game?.world.kind != .meadow { makeGame(.meadow) }
        applyBird(progress.selected)
        hud.setCoins(progress.coins)
        hud.showNotice("Progress reset")
        Log.write("all progress reset")
        if isPaused {
            pauseMenu.willShow()
            pauseMenu.setSettings(sound: !muted, preview: hud.showPreview, help: hud.showHelp, hudOpacity: hudOpacity,
                                  cameras: CameraManager.availableDevices().map { ($0.uniqueID, $0.localizedName) },
                                  current: camera.device?.uniqueID)
        }
    }

    // MARK: Worlds

    private func startWorld() -> WorldID {
        if let i = CommandLine.arguments.firstIndex(of: "--world"), i + 1 < CommandLine.arguments.count,
           let w = WorldID(rawValue: CommandLine.arguments[i + 1]) { return w }
        return progress.world.kind ?? .meadow
    }

    /// Build a world's game and hook it up to the view, sound, HUD and coins.
    @discardableResult
    private func makeGame(_ id: WorldID) -> Game {
        let g = Game(controls: shared, world: id)
        g.sound = sound
        g.onRing = { [weak self] streak in
            guard let self else { return }
            let gained = self.progress.ringPassed(streak: streak)
            self.hud.showRingFlash(coins: gained, total: self.progress.coins, streak: g.world.isChallenge ? streak : 0)
        }
        g.onHit = { [weak self] coins in
            guard let self else { return }
            let lost = self.progress.lose(coins)
            self.hud.showLoss(coins: lost, total: self.progress.coins)
        }
        g.setSpecies(progress.selected.look, tuning: FlightTuning(points: progress.points(progress.selected)))
        g.paused = isPaused
        game = g
        if let v = scnView {
            v.scene = g.scene
            v.pointOfView = g.cameraNode
        }
        return g
    }

    /// Switch to the world picked in the shop (stays paused behind the menu).
    private func travel() {
        guard let id = progress.world.kind, id != game?.world.kind else { return }
        makeGame(id)
    }

    private func applyBird(_ sp: Species) {
        game?.setSpecies(sp.look, tuning: FlightTuning(points: progress.points(sp)))
    }

    // MARK: Camera + tracking

    private func startCamera() {
        CameraManager.requestAccess { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.shared.publish({ var c = ControlState(); c.hint = "Camera access denied — enable it in System Settings › Privacy & Security › Camera (keyboard works meanwhile)"; return c }(), pose: nil)
                return
            }
            let p = CameraPreviewView(session: self.camera.session)
            self.preview = p
            self.hud.attachPreview(p)
            self.camera.onFrame = { [weak self] pb, t in self?.handleFrame(pb, t) }
            self.camera.onConfigured = { [weak self] in
                guard let self else { return }
                self.preview?.aspectForLayout = self.camera.aspect
                self.preview?.mirror()
                self.hud.needsLayout = true
                self.rebuildCameraMenu()
            }
            self.camera.start(with: nil)
        }
    }

    private func handleFrame(_ pb: CVPixelBuffer, _ t: Double) {
        let raw = tracker.detect(pb, time: t, aspect: camera.aspect)
        let c = interpreter.process(raw, time: t)
        shared.publish(c, pose: raw)
        frameCount += 1
        if frameCount % 90 == 0 {
            Log.write(String(format: "vision %.1fms tracking=%d hands=%d roll=%+.2f pitch=%+.2f tuck=%.2f flap=%.2f/%.2f cal=%d",
                             tracker.lastInferenceMs, c.tracking ? 1 : 0, c.handsVisible, c.roll, c.pitch, c.tuck,
                             c.flapL, c.flapR, c.calibrated ? 1 : 0))
        }
    }

    private func startDemo() {
        var demo = DemoPoseSource()
        let start = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: camera.queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let t = CACurrentMediaTime() - start
            let (_, raw) = demo.pose(at: t)
            self.shared.publish(self.interpreter.process(raw, time: t), pose: raw)
        }
        timer.resume()
        demoTimer = timer
    }

    // MARK: Render loop

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        game?.update(time: time)
    }

    private func refreshHUD() {
        guard let game else { return }
        let s = game.stats
        hud.update(s, pose: shared.pose, cameraName: camera.device?.localizedName ?? "No camera")
        hudTicks += 1
        if hudTicks % 90 == 0 {
            Log.write(String(format: "fps %.1f speed %.0f km/h alt %.0f rings %d tracking %d", s.fps, s.speedKmh, s.altitude, s.score, s.control.tracking ? 1 : 0))
        }
    }

    // MARK: Actions

    func recalibrate() { camera.queue.async { self.interpreter.recalibrate() } }
    func togglePreview() { hud.showPreview.toggle() }
    func toggleHelp() { hud.showHelp.toggle() }
    func toggleMute() { muted.toggle(); sound?.setMuted(muted || isPaused) }
    func restart() { game?.respawnRequested = true }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bird Game", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bird Game", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let gameItem = NSMenuItem()
        main.addItem(gameItem)
        let gameMenu = NSMenu(title: "Game")
        gameMenu.addItem(withTitle: "Pause / Settings / Shop  (Esc)", action: #selector(menuPause), keyEquivalent: "")
        gameMenu.addItem(.separator())
        gameMenu.addItem(withTitle: "Recalibrate Arms", action: #selector(menuRecalibrate), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Restart Flight", action: #selector(menuRestart), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Toggle Camera Preview", action: #selector(menuPreview), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Toggle Help", action: #selector(menuHelp), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Mute", action: #selector(menuMute), keyEquivalent: "")
        gameMenu.addItem(.separator())
        let fs = gameMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        gameItem.submenu = gameMenu

        let camItem = NSMenuItem()
        main.addItem(camItem)
        cameraMenu.delegate = self
        camItem.submenu = cameraMenu
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) { if menu === cameraMenu { rebuildCameraMenu() } }

    private func rebuildCameraMenu() {
        cameraMenu.removeAllItems()
        for d in CameraManager.availableDevices() {
            var title = d.localizedName
            if let f = CameraManager.widestFormat(for: d) {
                let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                title += "  (\(dim.width)×\(dim.height), full view)"
            }
            let item = NSMenuItem(title: title, action: #selector(selectCamera(_:)), keyEquivalent: "")
            item.representedObject = d.uniqueID
            item.target = self
            item.state = d.uniqueID == camera.device?.uniqueID ? .on : .off
            cameraMenu.addItem(item)
        }
    }

    @objc private func selectCamera(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let d = CameraManager.availableDevices().first(where: { $0.uniqueID == id }) else { return }
        camera.start(with: d)
    }
    @objc private func menuPause() { togglePause() }
    @objc private func menuRecalibrate() { recalibrate() }
    @objc private func menuRestart() { restart() }
    @objc private func menuPreview() { togglePreview() }
    @objc private func menuHelp() { toggleHelp() }
    @objc private func menuMute() { toggleMute() }
}
