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
        // The welcome card: Return starts the tutorial, Esc closes it. (What's new: Return closes it too.)
        if let app, let card = app.welcome, !e.isARepeat {
            if e.keyCode == 36 || e.keyCode == 76 {
                if case .firstLaunch = card.kind { app.welcomeStartTutorial() } else { app.dismissWelcome() }
                return
            }
            if e.keyCode == 53 { app.dismissWelcome(); return }
        }
        if e.keyCode == 48 && !e.isARepeat { app?.tutorialKey(back: e.modifierFlags.contains(.shift)); return }
        // The Finale's cutscene: Esc twice skips it; nothing else gets through.
        if let app, app.inCutscene {
            if e.keyCode == 53 && !e.isARepeat { app.cutsceneEsc() }
            return
        }
        if setKey(e.keyCode, true) { return }
        guard !e.isARepeat else { return }
        if e.keyCode == 53 { app?.togglePause(); return }
        if e.keyCode == 36 || e.keyCode == 76 { app?.attack(); return }   // Return / Enter
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "r": app?.recalibrate()
        case "c": app?.togglePreview()
        case "h": app?.toggleHelp()
        case "n": app?.restart()
        case "m": app?.toggleMute()
        case "f": window?.toggleFullScreen(nil)
        case "e": app?.attack()
        case "j": app?.acceptInvite()
        case "t": app?.openChat()
        case "p": app?.takePhoto()
        case "b": app?.jetKey()
        case "[", "]", ";", "'", ",", ".": break   // test codes (no error beep)
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
    let mouth = MouthTracker()
    var sound: SoundEngine?
    var preview: CameraPreviewView?
    var hudTimer: Timer?
    var muted = false
    let progress = Progress()
    let lan = LANSession()
    let director = MatchDirector()
    var pauseMenu: PauseMenuView!
    var chatView: ChatOverlay!
    var cutsceneOverlay: CutsceneOverlay!
    var inCutscene: Bool { game?.cutscene != nil }
    /// The start menu, while it's up.
    private(set) var titleScreen: TitleScreen?
    private var calibratedAtTitle = false
    private(set) var isPaused = false
    private var pendingInvite: Invite?
    private var inviteHide: DispatchWorkItem?
    private var warmupTimer: DispatchWorkItem?
    private var terminating = false
    let tutorial = TutorialController()
    let updater = Updater()
    /// The "update to x?" card, while it's up.
    private var updateCard: UpdateCard?
    /// Versions already announced with a toast this launch.
    private var announcedUpdate: String?
    /// An update found while the welcome card was up (announced once it closes).
    private var toastAfterWelcome: String?
    private var updateTimer: Timer?
    /// Draws instead of SceneKit's view while V-Sync is off.
    private var uncapped: UncappedView?
    private var autoUpdateItem: NSMenuItem?
    /// Welcome (first launch) or what's-new card, while it's up.
    private(set) var welcome: WelcomeView?
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

    var inMultiplayer: Bool { lan.role == .hosting || lan.role == .joined }
    var currentMode: GameMode { game?.mode ?? .freeRoam }
    var currentWorld: WorldID { game?.worldID ?? .meadow }

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenus()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = NSWindow(contentRect: screen, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Bird Game"
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black

        sound = SoundEngine()
        Sounds.shared = sound
        muted = Prefs.muted
        sound?.setMuted(muted)
        sound?.setUIMuted(muted)
        loadProfile()
        let game = makeGame(startWorld(), mode: startMode())

        scnView = GameSCNView(frame: window.contentView!.bounds)
        scnView.app = self
        scnView.autoresizingMask = [.width, .height]
        scnView.scene = game.scene
        scnView.pointOfView = game.cameraNode
        scnView.delegate = self
        scnView.rendersContinuously = true
        scnView.isPlaying = true
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = GraphicsQuality.current.antialiasing
        applyVSync()
        scnView.backgroundColor = Sky.fogColor
        window.contentView!.addSubview(scnView)

        hud = HUDView(frame: window.contentView!.bounds)
        hud.autoresizingMask = [.width, .height]
        hud.alphaValue = hudOpacity
        hud.showPreview = Prefs.showPreview
        hud.showFPS = Prefs.showFPS
        window.contentView!.addSubview(hud)

        chatView = ChatOverlay(frame: window.contentView!.bounds)
        chatView.autoresizingMask = [.width, .height]
        chatView.onSend = { [weak self] text in self?.lan.say(text) }
        chatView.showsLines = Prefs.showChat
        chatView.onClose = { [weak self] in
            guard let self, !self.isPaused else { return }
            self.window.makeFirstResponder(self.scnView)
        }
        window.contentView!.addSubview(chatView)

        cutsceneOverlay = CutsceneOverlay(frame: window.contentView!.bounds)
        cutsceneOverlay.autoresizingMask = [.width, .height]
        cutsceneOverlay.isHidden = true
        window.contentView!.addSubview(cutsceneOverlay)
        hud.setHelpText(jetpack: progress.jetpackOwned && Prefs.jetpack)

        tutorial.host = self
        tutorial.overlay.frame = window.contentView!.bounds
        tutorial.overlay.autoresizingMask = [.width, .height]
        tutorial.overlay.isHidden = true
        window.contentView!.addSubview(tutorial.overlay)

        pauseMenu = PauseMenuView(progress: progress, lan: lan)
        pauseMenu.frame = window.contentView!.bounds
        pauseMenu.autoresizingMask = [.width, .height]
        pauseMenu.isHidden = true
        window.contentView!.addSubview(pauseMenu)
        wirePauseMenu()
        wireLAN()

        wireUpdater()
        // The Style tab's pictures, made in the background once the game is up so the tab opens with them ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { CosmeticThumbs.warmUp() }
        hud.setCoins(progress.coins)
        // Players coming from 0.2 may already have done some goals.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkGoals() }
        let a = CommandLine.arguments
        // The dev copy only (it has its own save): `--open-finale` marks every goal done, to watch The Finale without
        // earning it. The real game ignores it.
        if a.contains("--open-finale"), Bundle.main.bundleIdentifier?.hasSuffix(".devtest") == true {
            progress.debugCompleteGoals(GoalCatalog.required.map(\.id))
        }
        let quickStart = a.contains("--demo") || a.contains("--no-title") || a.contains("--host-lan") || a.contains("--join-lan")
        if quickStart {
            if !a.contains("--demo") && !a.contains("--no-welcome") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showWelcomeIfNeeded() }
            }
        } else {
            showTitle()
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(scnView)
        NSApp.activate(ignoringOtherApps: true)

        hudTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.refreshHUD() }

        if CommandLine.arguments.contains("--demo") {
            startDemo()
        } else {
            startCamera()
        }
        if CommandLine.arguments.contains("--lan") || UserDefaults.standard.bool(forKey: "lan.used") { lan.goOnline() }
        if let i = CommandLine.arguments.firstIndex(of: "--host-lan") {
            let m = i + 1 < CommandLine.arguments.count ? GameMode(rawValue: CommandLine.arguments[i + 1]) ?? .freeRoam : .freeRoam
            lan.goOnline()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.hostGame(mode: m) }
        }
        if CommandLine.arguments.contains("--join-lan") {
            lan.goOnline()
            joinFirstGameWhenFound()
        }
        testHooks()
    }

    /// `--auto-start <s>`: host starts a round after s seconds. `--snapshot-after <s> <file.png>`: save what's on screen.
    private func testHooks() {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--auto-start"), i + 1 < a.count, let t = Double(a[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.hostStartRound() }
        }
        // `--switch-mode-after <s> <mode>`: the host picks another mode (tests that everyone still sees each other).
        if let i = a.firstIndex(of: "--switch-mode-after"), i + 2 < a.count, let t = Double(a[i + 1]), let m = GameMode(rawValue: a[i + 2]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                print("switching to \(m.rawValue)"); fflush(stdout)
                self.play(m, self.currentWorld)
            }
        }
        // `--net-report`: once a second, who this game can see.
        if a.contains("--net-report") {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                let role = "\(self.lan.role)", lobby = self.lan.lobby.players.count
                self.game?.enqueue { g in
                    let seen = g.others.values.filter { !$0.idle && $0.lastHeard > 0 }.count
                    print("net role=\(role) mode=\(g.mode.rawValue) phase=\(g.phase) lobby=\(lobby) others=\(g.others.count) moving=\(seen)")
                    fflush(stdout)
                }
            }
        }
        // `--snapshot-after <s> <file.png>` (repeatable): the 3D view with every overlay on top.
        var k = 0
        while let i = a[k...].firstIndex(of: "--snapshot-after"), i + 2 < a.count, let t = Double(a[i + 1]) {
            let path = a[i + 2]
            k = i + 1
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.saveSnapshot(path) }
        }
        // `--start-tutorial [s]`: start the tutorial after a moment (for testing).
        if let i = a.firstIndex(of: "--start-tutorial") {
            let t = i + 1 < a.count ? Double(a[i + 1]) ?? 1 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.startTutorial() }
        }
        // `--tutorial-step <n> <s>`: jump to a step after s seconds.
        if let i = a.firstIndex(of: "--tutorial-step"), i + 2 < a.count, let n = Int(a[i + 1]), let t = Double(a[i + 2]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.tutorial.go(to: n) }
        }
        // `--pause-after <s> [tab]`: open the menu (on a tab) for snapshots.
        if let i = a.firstIndex(of: "--pause-after"), i + 1 < a.count, let t = Double(a[i + 1]) {
            let tab = i + 2 < a.count ? MenuTab.allCases.first { $0.title.lowercased() == a[i + 2] } : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                if !self.isPaused { self.togglePause() }
                if let tab { self.pauseMenu.select(tab: tab) }
            }
        }
        if let i = a.firstIndex(of: "--quit-after"), i + 1 < a.count, let t = Double(a[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
        if a.contains("--welcome") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.present(WelcomeView(kind: .firstLaunch)) }
        }
    }

    /// Everything on screen into a PNG (the SceneKit view doesn't draw through `cacheDisplay`, so it's composited).
    private func saveSnapshot(_ path: String) {
        guard let v = window.contentView else { return }
        let img = NSImage(size: v.bounds.size)
        img.lockFocus()
        scnView.snapshot().draw(in: v.bounds)
        for sub in v.subviews where sub !== scnView && !sub.isHidden {
            if let rep = sub.bitmapImageRepForCachingDisplay(in: sub.bounds) {
                sub.cacheDisplay(in: sub.bounds, to: rep)
                rep.draw(in: sub.frame)
            }
        }
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { terminating = true; lan.leave() }
    func applicationDidBecomeActive(_ notification: Notification) {
        lan.refreshDiagnostics()
        if let t = titleScreen, !isPaused { window.makeFirstResponder(t) }   // Return / Space still start
    }
    func applicationDidResignActive(_ notification: Notification) {
        // Clicking away pauses a game in progress; on the start menu there's nothing to pause, so it stays as it is.
        if !isPaused && titleScreen == nil && !CommandLine.arguments.contains("--no-autopause") { togglePause() }
    }

    // MARK: Pause / settings / shop

    // MARK: Title screen

    private func showTitle() {
        let t = TitleScreen(frame: window.contentView!.bounds)
        t.autoresizingMask = [.width, .height]
        t.coins = progress.coins
        t.finaleOpen = progress.finaleUnlocked && !progress.finaleSeen
        t.crowned = progress.finaleSeen
        t.onPlay = { [weak self] in self?.leaveTitle() }
        t.onMenu = { [weak self] in self?.togglePause() }
        t.onTutorial = { [weak self] in self?.leaveTitle(tutorial: true) }
        t.onQuit = { NSApp.terminate(nil) }
        t.onKey = { [weak self] chars in self?.cheatKey(chars) }
        window.contentView!.addSubview(t, positioned: .below, relativeTo: pauseMenu)
        titleScreen = t
        game?.attract = true
        hud.isHidden = true
        chatView.isHidden = true
        sound?.setTitleMusic(0.9)
        calibratedAtTitle = shared.control.calibrated
        window.makeFirstResponder(t)
    }

    /// The pause menu's Main Menu button: back to the title screen (out of any LAN game, tutorial or race first).
    func backToTitle() {
        if isPaused { togglePause() }
        guard titleScreen == nil, game?.cutscene == nil else { return }
        let wasOnline = inMultiplayer || lan.role == .joining
        if wasOnline { lan.leave() }
        if tutorial.active { tutorial.stop(completed: false) }
        if currentMode != .freeRoam || wasOnline { _ = makeGame(currentWorld, mode: .freeRoam) }
        showTitle()
    }

    /// Something was started from the menu over the title screen (a world, a mode, The Finale, a LAN game): the title
    /// goes, so it can't sit over the cutscene or the game.
    private func closeTitle() {
        guard let t = titleScreen else { return }
        titleScreen = nil
        t.dismiss()
        game?.attract = false
        sound?.setTitleMusic(0)
        chatView.isHidden = false
        hud.isHidden = isPaused
    }

    func leaveTitle(tutorial: Bool = false) {
        guard let t = titleScreen else { return }
        if isPaused { togglePause() }
        titleScreen = nil
        t.dismiss()
        game?.attract = false
        sound?.setTitleMusic(0)
        hud.isHidden = false
        chatView.isHidden = false
        window.makeFirstResponder(scnView)
        if tutorial {
            startTutorial()
        } else if !CommandLine.arguments.contains("--no-welcome") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcomeIfNeeded() }
        }
    }

    func togglePause() {
        guard let game, game.cutscene == nil else { return }
        if welcome != nil { dismissWelcome() }
        chatView.close()
        isPaused.toggle()
        tutorial.overlay.isHidden = isPaused || !tutorial.active
        chatView.isHidden = isPaused
        game.keys = KeyInput()
        game.paused = isPaused
        updateUncapped()
        sound?.setMuted(isPaused || muted)
        if isPaused {
            pauseMenu.setSettings(settingsValues)
            pauseMenu.setPlaying(mode: currentMode, world: currentWorld)
            lan.refreshDiagnostics()
            pauseMenu.willShow()
            pauseMenu.isHidden = false
            hud.isHidden = true
            window.makeFirstResponder(pauseMenu)
            tutorial.menuOpened()
        } else {
            if updateCard != nil { hideUpdateCard() }
            pauseMenu.endTour()
            pauseMenu.isHidden = true
            pauseMenu.didHide()
            hud.isHidden = titleScreen != nil
            hud.setCoins(progress.coins)
            if let t = titleScreen {
                t.coins = progress.coins
                t.finaleOpen = progress.finaleUnlocked && !progress.finaleSeen
                window.makeFirstResponder(t)
            } else {
                window.makeFirstResponder(scnView)
            }
        }
    }

    private func wirePauseMenu() {
        pauseMenu.onResume = { [weak self] in self?.togglePause() }
        pauseMenu.onRestart = { [weak self] in self?.restart(); self?.togglePause() }
        pauseMenu.onRecalibrate = { [weak self] in self?.recalibrate(); self?.togglePause() }
        let settings = pauseMenu.settings
        settings.onSound = { [weak self] on in self?.setMuted(!on) }
        settings.onHelp = { [weak self] on in self?.hud.showHelp = on }
        settings.onChat = { [weak self] on in Prefs.showChat = on; self?.chatView.showsLines = on }
        settings.onFPS = { [weak self] on in Prefs.showFPS = on; self?.hud.showFPS = on }
        settings.onHUDOpacity = { [weak self] v in self?.hudOpacity = v }
        settings.onPreview = { [weak self] on in Prefs.showPreview = on; self?.hud.showPreview = on }
        settings.onCamera = { [weak self] id in
            guard let self, let d = CameraManager.availableDevices().first(where: { $0.uniqueID == id }) else { return }
            self.camera.start(with: d)
        }
        settings.onGraphics = { [weak self] q in self?.setGraphics(q) }
        settings.onVSync = { [weak self] on in Prefs.vsync = on; self?.applyVSync() }
        settings.onAutoUpdate = { [weak self] on in self?.setAutoUpdate(on) }
        settings.onJetpack = { [weak self] on in
            guard let self else { return }
            Prefs.jetpack = on
            self.game?.jetEquipped = on && self.progress.jetpackOwned
            self.hud.setHelpText(jetpack: on && self.progress.jetpackOwned)
        }
        pauseMenu.onBirdChanged = { [weak self] sp in self?.applyBird(sp) }
        pauseMenu.onWorldChanged = { [weak self] in self?.travel() }
        pauseMenu.onKey = { [weak self] chars in self?.cheatKey(chars) }
        pauseMenu.onPlay = { [weak self] mode, world in self?.play(mode, world) }
        pauseMenu.onStartRound = { [weak self] in self?.hostStartRound(); if self?.isPaused == true { self?.togglePause() } }
        pauseMenu.onHost = { [weak self] in self?.hostGame(mode: self?.currentMode ?? .freeRoam) }
        pauseMenu.onRulesChanged = { [weak self] r in self?.lan.updateLobby(rules: r) }
        pauseMenu.onProfileChanged = { [weak self] name, color in self?.setProfile(name: name, color: color) }
        pauseMenu.onGoOnline = { [weak self] in
            UserDefaults.standard.set(true, forKey: "lan.used")
            self?.lan.goOnline()
        }
        pauseMenu.onOutfitChanged = { [weak self] _ in self?.outfitChanged() }
        pauseMenu.onTutorial = { [weak self] in self?.startTutorial() }
        pauseMenu.onMainMenu = { [weak self] in self?.backToTitle() }
    }

    // MARK: Updates

    private func wireUpdater() {
        updater.onChange = { [weak self] s in self?.updateStateChanged(s) }
        pauseMenu.onUpdateAction = { [weak self] in self?.updateAction() }
        let a = CommandLine.arguments
        guard !a.contains("--demo"), !a.contains("--no-update-check") else { return }
        if let failed = updater.checkLastInstall() {
            // The last update didn't go in: say so, and offer the download page instead.
            announcedUpdate = failed
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.hud.showToast("Bird Game \(failed) didn't install", "Open the menu (Esc) to download it instead", color: Wii.blue)
                self?.updater.check()
            }
        } else {
            // A few seconds in (so launching stays quick)...
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.updater.checkIfDue() }
        }
        // ...then every hour it checks whether 6 hours have passed.
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.updater.checkIfDue() }
    }

    private func updateStateChanged(_ s: Updater.State) {
        pauseMenu.updateRow.show(s, current: AppVersion.short)
        updateCard?.show(s, lanNote: updateLANNote)
        switch s {
        case .available(let r), .manual(let r, _):
            // Say so once (not in the middle of the tutorial; the menu row shows it either way).
            guard announcedUpdate != r.version, !tutorial.active, !isPaused else { return }
            // Behind the welcome card it would go unseen: wait until it's closed.
            guard welcome == nil else { toastAfterWelcome = r.version; return }
            announcedUpdate = r.version
            hud.showToast("Bird Game \(r.version) is here!", "Open the menu (Esc) to update", color: Wii.blue)
        case .idle, .upToDate, .offline:
            // A cancelled or finished check leaves nothing for the card to show.
            if updateCard != nil { hideUpdateCard() }
        default:
            break
        }
    }

    /// The menu row's button.
    private func updateAction() {
        switch updater.state {
        case .available, .manual:
            showUpdateCard()
        case .failed:
            updater.retry()
            if case .available = updater.state { showUpdateCard() }
        case .idle, .upToDate, .offline:
            updater.check()
        case .checking, .downloading, .installing:
            showUpdateCard()
        }
    }

    /// What restarting for an update does to the LAN game.
    private var updateLANNote: String? {
        switch lan.role {
        case .hosting: return "The LAN game you're hosting will end for everyone."
        case .joined: return "You'll leave the LAN game."
        default: return nil
        }
    }

    private func showUpdateCard() {
        if updateCard == nil {
            let card = UpdateCard(frame: window.contentView!.bounds)
            card.autoresizingMask = [.width, .height]
            card.onInstall = { [weak self] in
                guard let self else { return }
                if case .failed = self.updater.state { self.updater.retry() }
                self.updater.install()
            }
            card.onCancel = { [weak self] in
                guard let self else { return }
                switch self.updater.state {
                case .downloading: self.updater.cancel()
                case .installing: return
                case .failed: self.updater.dismissFailure(); self.hideUpdateCard()
                default: self.hideUpdateCard()
                }
            }
            card.onOpenPage = { [weak self] in
                guard let self else { return }
                if case .manual(let r, _) = self.updater.state { NSWorkspace.shared.open(r.page) }
                self.hideUpdateCard()
            }
            window.contentView!.addSubview(card)
            updateCard = card
        }
        updateCard?.show(updater.state, lanNote: updateLANNote)
        window.makeFirstResponder(updateCard)
    }

    private func hideUpdateCard() {
        updateCard?.removeFromSuperview()
        updateCard = nil
        window.makeFirstResponder(isPaused ? pauseMenu : scnView)
    }

    // MARK: Tutorial & welcome

    /// First launch: welcome card (tutorial recommended). After an update: what's new.
    private func showWelcomeIfNeeded() {
        let d = UserDefaults.standard
        let version = AppVersion.short
        let newPlayer = progress.coinsEarned == 0 && progress.totalRings == 0 && !progress.tutorialDone
        if newPlayer && !d.bool(forKey: "welcome.shown") {
            d.set(true, forKey: "welcome.shown")
            d.set(version, forKey: "whatsNew.seen")
            present(WelcomeView(kind: .firstLaunch))
        } else if !newPlayer && d.string(forKey: "whatsNew.seen") != version, let notes = WelcomeView.whatsNew(for: version) {
            d.set(true, forKey: "welcome.shown")
            d.set(version, forKey: "whatsNew.seen")
            present(WelcomeView(kind: .whatsNew(version, notes)))
        } else {
            d.set(version, forKey: "whatsNew.seen")
        }
    }

    private func present(_ w: WelcomeView) {
        guard !isPaused else { return }
        w.frame = window.contentView!.bounds
        w.autoresizingMask = [.width, .height]
        w.onTutorial = { [weak self] in self?.welcomeStartTutorial() }
        w.onDismiss = { [weak self] in self?.dismissWelcome() }
        window.contentView!.addSubview(w, positioned: .below, relativeTo: pauseMenu)
        welcome = w
    }

    func dismissWelcome() {
        welcome?.removeFromSuperview()
        welcome = nil
        window.makeFirstResponder(scnView)
        if toastAfterWelcome != nil {
            toastAfterWelcome = nil
            updateStateChanged(updater.state)
        }
    }

    func welcomeStartTutorial() {
        toastAfterWelcome = nil   // no update message over the tutorial (the menu still shows it)
        dismissWelcome()
        startTutorial()
    }

    /// Start (or restart) the tutorial in the Home Isles.
    func startTutorial() {
        guard !inMultiplayer, lan.role != .joining else {
            NSSound.beep()
            if isPaused { togglePause() }
            hud.showNotice("Leave the LAN game to start the tutorial")
            return
        }
        if tutorial.active { tutorial.stop(completed: false) }
        if isPaused { togglePause() }
        let world = WorldCatalog.info("meadow")
        progress.selectWorld(world)
        let g = makeGame(.meadow, mode: .freeRoam)
        g.setTutorialRings(false)
        hud.showHelp = false
        hud.showResults(nil)
        tutorial.start()
        tutorial.overlay.isHidden = false
        window.makeFirstResponder(scnView)
        Log.write("tutorial started")
    }

    /// Tab: next step; Shift-Tab: back.
    func tutorialKey(back: Bool) {
        guard tutorial.active, !isPaused else { return }
        if back { tutorial.back() } else { tutorial.next() }
    }

    /// Bought, wore or took off a cosmetic: dress the bird and tell everyone in the LAN game.
    private func outfitChanged() {
        let sp = progress.selected
        game?.setSpecies(sp, points: progress.points(sp), outfit: progress.outfit)
        lan.fit = progress.outfit.code
        lan.updateProfile()
        hud.setCoins(progress.coins)
        checkGoals()
        pauseMenu.refresh()
    }

    /// Pay out any goals just reached and say so.
    func checkGoals() {
        let wasOpen = progress.finaleUnlocked
        let done = progress.checkGoals()
        guard !done.isEmpty else { return }
        if !wasOpen && progress.finaleUnlocked {
            // The last goal: the way to The Finale opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
                self?.sound?.fanfare()
                self?.hud.showToast("Every goal is done.", "Something has opened… Esc → Worlds", color: Rarity.legendary.color)
            }
        }
        for g in done {
            // A cosmetic reward says where to find it (it's only put on when that slot was empty).
            let detail = g.cosmetic != nil ? "\(g.rewardText)  ·  it's in Style (Esc)" : (g.rewardText.isEmpty ? g.detail : "\(g.detail)  ·  \(g.rewardText)")
            hud.showToast("Goal complete: \(g.title)", detail)
        }
        sound?.fanfare()
        hud.setCoins(progress.coins)
        // A goal can hand out a cosmetic (worn straight away).
        let sp = progress.selected
        game?.setSpecies(sp, points: progress.points(sp), outfit: progress.outfit)
        lan.fit = progress.outfit.code
        lan.updateProfile()
        if isPaused { pauseMenu.refresh() }
    }

    // MARK: Test coins

    /// Test codes, typed in a row in the game, the menu or on the title screen: [ ] ; ' grants 100 coins, the reverse
    /// ' ; ] [ wipes all saved progress (coins, birds, outfits, everything), , . , . , . , . unlocks every cosmetic, and
    /// [ ] [ ] [ ] [ ] opens The Finale.
    private var cheatBuffer = ""
    func cheatKey(_ chars: String) {
        let grant = "[];'", wipe = "';][", wardrobe = ",.,.,.,.", finale = "[][][][]"
        guard chars.count == 1, (grant + wardrobe).contains(chars) else { cheatBuffer = ""; return }
        cheatBuffer = String((cheatBuffer + chars).suffix(wardrobe.count))
        if cheatBuffer.hasSuffix(grant) {
            cheatBuffer = ""
            progress.grant(100)
            hud.showBonus(coins: 100, total: progress.coins)
            if isPaused { pauseMenu.refresh() }
        } else if cheatBuffer.hasSuffix(wipe) {
            cheatBuffer = ""
            resetEverything()
        } else if cheatBuffer == finale {
            cheatBuffer = ""
            openFinaleByCode()
        } else if cheatBuffer == wardrobe {
            cheatBuffer = ""
            let n = progress.unlockAllCosmetics()
            hud.showToast("Every cosmetic unlocked", n > 0 ? "\(n) new things to wear in Style (Esc)" : "You already had them all",
                          color: Rarity.legendary.color)
            sound?.purchase()
            Log.write("test code: unlocked \(n) cosmetics")
            checkGoals()
            if isPaused { pauseMenu.refresh() }
        }
    }

    private func openFinaleByCode() {
        let already = progress.finaleUnlocked
        if !already {
            progress.openFinaleByCode()
            sound?.purchase()
            Log.write("test code: The Finale opened")
        }
        let title = already ? "The Finale is already open" : "Cheat code: The Finale is open"
        hud.showToast(title, "Esc → Worlds → The Finale", color: Rarity.legendary.color)
        if let t = titleScreen {
            t.finaleOpen = progress.finaleUnlocked && !progress.finaleSeen
            t.flash(title + "  ·  Menu → Worlds → The Finale")
        }
        if isPaused { pauseMenu.refresh() }
    }

    /// Back to a brand-new player: no coins, birds, worlds, outfits or stats (the bird is undressed too).
    private func resetEverything() {
        lan.leave()
        progress.resetAll()
        hudOpacity = 1
        UserDefaults.standard.removeObject(forKey: "hudOpacity")
        loadProfile()
        makeGame(.meadow, mode: .freeRoam)
        hud.setCoins(progress.coins)
        hud.showNotice("Progress reset")
        Log.write("all progress reset")
        if isPaused {
            pauseMenu.willShow()
            pauseMenu.setSettings(settingsValues)
        }
    }

    // MARK: Worlds & modes

    private func startWorld() -> WorldID {
        if let i = CommandLine.arguments.firstIndex(of: "--world"), i + 1 < CommandLine.arguments.count,
           let w = WorldID(rawValue: CommandLine.arguments[i + 1]) { return w }
        return progress.world.kind ?? .meadow
    }

    private func startMode() -> GameMode {
        if let i = CommandLine.arguments.firstIndex(of: "--mode"), i + 1 < CommandLine.arguments.count,
           let m = GameMode(rawValue: CommandLine.arguments[i + 1]) { return m }
        return .freeRoam
    }

    /// Build a world's game in a mode and hook it up to the view, sound, HUD, coins and the network.
    @discardableResult
    private func makeGame(_ id: WorldID, mode: GameMode) -> Game {
        let mp = inMultiplayer
        if mp { closeTitle() }   // into a LAN game from the menu over the title screen
        let sp = progress.selected
        let g = Game(controls: shared, world: id, mode: mode, multiplayer: mp, species: sp, points: progress.points(sp), outfit: progress.outfit)
        g.sound = sound
        progress.flewIn(id.rawValue)
        g.onRing = { [weak self] streak in
            guard let self else { return }
            let gained = self.progress.ringPassed(streak: streak)
            self.hud.showRingFlash(coins: gained, total: self.progress.coins, streak: g.world.isChallenge ? streak : 0)
            self.checkGoals()
        }
        g.onFlight = { [weak self] meters, top in
            self?.progress.addFlight(meters: meters, topKmh: top)
            self?.checkGoals()
        }
        g.onHit = { [weak self] coins in
            guard let self else { return }
            let lost = self.progress.lose(coins)
            self.hud.showLoss(coins: lost, total: self.progress.coins)
        }
        g.onNotice = { [weak self] text in
            if text.hasPrefix("Missed") { self?.hud.showWarning(text) } else { self?.hud.addFeed(text) }
        }
        g.onReward = { [weak self] r in
            guard let self, let c = self.progress.claim(r, world: id.rawValue) else { return }
            self.hud.setCoins(self.progress.coins)
            if r.once {
                self.sound?.chime()
                let list = WorldCatalog.secrets[id.rawValue] ?? []
                let detail = list.contains(r.id) ? "+\(c) coins  ·  secret \(self.progress.secretsFound(id.rawValue)) of \(list.count) here" : "+\(c) coins"
                self.hud.showToast(r.title, detail, color: Wii.blue)
            } else {
                self.hud.addFeed("+\(c) ●  \(r.title)")
            }
            self.checkGoals()
        }
        g.onMatchOver = { [weak self] out in self?.singlePlayerResult(out) }
        g.jetEquipped = progress.jetpackOwned && Prefs.jetpack
        g.onJet = { [weak self] on in self?.hud.addFeed(on ? "Jetpack lit! Clap again to let it go out" : "Jetpack out") }
        g.onKnockout = { [weak self] victim in
            guard let self else { return }
            let c = self.progress.award(8, world: id.rawValue)
            self.progress.knockedOutBird()
            self.hud.setCoins(self.progress.coins)
            self.hud.addFeed("+\(c) ●  knocked out \(victim)")
            self.checkGoals()
        }
        g.onLocalEvent = { [weak self] e in self?.directorEvent(e) }
        if mp {
            g.link = lan
            g.localId = lan.localId
            g.rules = lan.lobby.rules
            g.syncPeers(lan.lobby.players)
            g.slot = lan.lobby.players.firstIndex { $0.id == lan.localId } ?? 0
            if mode == .freeRoam { g.respawn() } else { g.enterWarmup() }
        } else if mode.isRace {
            g.setBest(time: progress.bestTime(mode, id.rawValue), run: Ghosts.load(mode, id))
            g.enqueue { $0.restartMatch() }
        }
        g.paused = isPaused
        g.apply(GraphicsQuality.current)
        g.attract = titleScreen != nil   // a world switch behind the title screen keeps flying itself
        game = g
        mouth.enabled = g.combatOn
        // Compile the new world's shaders (and every attack's, when attacks are possible) in the background,
        // so the first fireball or explosion doesn't stutter.
        if let u = uncapped {
            u.renderer.prepare(g.warmupObjects(), completionHandler: nil)
            u.set(scene: g.scene, camera: g.cameraNode)
        } else if let v = scnView {
            v.prepare(g.warmupObjects(), completionHandler: nil)
            v.scene = g.scene
            v.pointOfView = g.cameraNode
        }
        hud?.showResults(nil)
        return g
    }

    /// Switch to the world picked in the shop (stays paused behind the menu).
    private func travel() {
        closeTitle()
        guard let id = progress.world.kind, id != game?.world.kind else { return }
        if inMultiplayer {
            if lan.role == .hosting { lan.updateLobby(world: id.rawValue) }
            return
        }
        if id == .finale && !progress.finaleSeen { enterFinale(); return }
        makeGame(id, mode: currentMode)
    }

    // MARK: The Finale

    /// Into The Finale. The first time, the end: the walk through the castle, the crown, the jetpack.
    func enterFinale() {
        guard progress.finaleUnlocked, !inMultiplayer else { NSSound.beep(); return }
        closeTitle()
        let info = WorldCatalog.info("finale")
        progress.selectWorld(info)
        let g = makeGame(.finale, mode: .freeRoam)
        guard !progress.finaleSeen else { if isPaused { togglePause() }; return }
        if isPaused { togglePause() }
        if welcome != nil { dismissWelcome() }
        hud.isHidden = true
        g.onCrowned = { [weak self] in
            guard let self else { return }
            self.progress.awardCrown()
            self.outfitChanged()
        }
        g.onCutsceneDone = { [weak self] in self?.finaleDone() }
        g.startFinaleCutscene()
        window.makeFirstResponder(scnView)
        Log.write("finale cutscene started")
    }

    func cutsceneEsc() {
        if cutsceneOverlay.escPressed() { game?.skipCutscene() }
    }

    /// The end of the cutscene: the jetpack is yours (and the crown's on).
    private func finaleDone() {
        progress.finishFinale()
        Prefs.jetpack = true
        game?.jetEquipped = true
        hud.setHelpText(jetpack: true)
        cutsceneOverlay.isHidden = true
        hud.isHidden = false
        sound?.fanfare()
        hud.showToast("You were crowned!", "The Crown of the Sky is yours. It's in Style (Esc)", color: Rarity.legendary.color)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.hud.showToast("The jetpack is yours", "Clap your hands (or press B) to light it. Settings has it on or off", color: Wii.blue)
        }
        outfitChanged()
        Log.write("finale finished")
    }

    /// Play tab: start a mode on a map.
    private func play(_ mode: GameMode, _ world: WorldID) {
        closeTitle()
        switch lan.role {
        case .hosting:
            director.stop()
            lan.updateLobby(mode: mode, world: world.rawValue, running: false)
        case .joined, .joining:
            NSSound.beep()
            return
        default:
            let info = WorldCatalog.info(world.rawValue)
            guard progress.ownsWorld(info) else { NSSound.beep(); return }
            if world == .finale && !progress.finaleSeen { enterFinale(); return }
            progress.selectWorld(info)
            makeGame(world, mode: mode)
        }
        if isPaused { togglePause() }
    }

    private func applyBird(_ sp: Species) {
        game?.setSpecies(sp, points: progress.points(sp), outfit: progress.outfit)
        lan.bird = sp.id
        lan.fit = progress.outfit.code
        lan.updateProfile()
        checkGoals()
    }

    // MARK: Results & coins

    private func singlePlayerResult(_ out: MatchOutcome) {
        var r = MatchResult(title: "", standings: [])
        let world = out.world.rawValue
        if out.mode.isRace, let t = out.time {
            let before = progress.bestTime(out.mode, world)
            let bestMedalBefore = progress.bestMedal(out.mode, world)
            let pb = progress.recordRace(out.mode, world, time: t, won: false, medals: out.medals)
            if out.mode == .ringRace && out.missed == 0 { progress.recordPerfectRace() }
            let medal = Medal.of(t, out.medals)
            if pb, var run = out.ghost {
                run.bird = progress.selected.id
                DispatchQueue.global(qos: .utility).async { Ghosts.save(run, out.mode, out.world) }
                game?.setBest(time: t, run: run)
            }
            // Finishing pays more the fewer rings you miss; medals pay extra (double the first time you reach a new medal
            // on this course); beating your best adds a bonus. Harder worlds pay a little more.
            let firstMedal = medal != nil && (bestMedalBefore == nil || medal! > bestMedalBefore!)
            let total = max(out.gates + out.missed, 1)
            let finish = 40 + 40 * Float(out.gates) / Float(total)
            let extra = Float((pb && before != nil ? 15 : 0) + (medal?.coins ?? 0) * (firstMedal ? 2 : 1))
            r.coins = progress.award(Int(((finish + extra) * WorldCatalog.info(world).raceBonus).rounded()), world: world)
            r.personalBest = pb && before != nil
            r.title = medal.map { "\($0.name) medal!" } ?? "Finished!"
            var rows = [Standing(id: 1, name: "You", color: -1, place: 0, time: t, note: "")]
            if let b = before, !pb { rows.append(Standing(id: 0, name: "Your best", color: 6, place: 0, time: b)) }
            for (m, target) in zip([Medal.gold, .silver, .bronze], out.medals) {
                rows.append(Standing(id: 0, name: m.name, color: m.color, place: 0, time: target))
            }
            // Fastest first, so you can see where your time landed between the medals.
            r.standings = rows.sorted { ($0.time ?? .infinity) < ($1.time ?? .infinity) }
            if out.missed > 0 { r.footer = "\(out.missed) missed \(out.mode == .ringRace ? "ring" : "checkpoint")\(out.missed == 1 ? "" : "s") (+\(out.missed * 5) s)  ·  " }
            r.footer += "Press N to race again  ·  Esc for other modes"
        } else {
            // Placing, plus a coin per hit landed; harder bots pay more.
            let placeBonus = [60, 30, 15]
            let base = out.hits + (out.place <= placeBonus.count ? placeBonus[out.place - 1] : 0)
            let hard = BotSettings.difficulty == 2
            progress.recordFight(won: out.place == 1, knockouts: 0, hard: hard)
            r.coins = progress.award(Int((Float(base) * [0.75, 1, 1.4][BotSettings.difficulty]).rounded()), world: world)
            r.title = out.place == 1 ? "You won!" : "\(ordinal(out.place)) place"
            r.standings = out.standings
            r.footer = "Press N to fight again  ·  Esc for other modes"
        }
        hud.setCoins(progress.coins)
        hud.showResults(r)
        checkGoals()
    }

    private func multiplayerResult(_ standings: [Standing]) {
        let me = lan.localId
        var r = MatchResult(title: "Results", standings: standings)
        for i in r.standings.indices where r.standings[i].id == me { r.standings[i].color = -1; r.standings[i].name += " (you)" }
        if let mine = standings.first(where: { $0.id == me }) {
            let bonus = [45, 25, 15, 8]
            var base = mine.place <= bonus.count ? bonus[mine.place - 1] : 4
            if currentMode.isRace {
                if mine.time == nil { base = 4 } else { base += 20 }
                if let t = mine.time {
                    let medals = game?.track?.medalTimes ?? []
                    progress.recordRace(currentMode, currentWorld.rawValue, time: t, won: mine.place == 1, medals: medals)
                    base += Medal.of(t, medals)?.coins ?? 0
                }
            } else {
                progress.recordFight(won: mine.place == 1, knockouts: 0)
            }
            r.coins = progress.award(base, world: currentWorld.rawValue)
            r.title = mine.place == 1 ? "You won!" : "\(ordinal(mine.place)) place"
        }
        r.footer = lan.role == .hosting ? "Press N to start the next round" : "The next round starts when the host is ready"
        hud.setCoins(progress.coins)
        hud.showResults(r)
        checkGoals()
    }

    // MARK: LAN

    private func loadProfile() {
        let d = UserDefaults.standard
        lan.name = d.string(forKey: "lan.name") ?? "Player \(Int.random(in: 10...99))"
        if d.string(forKey: "lan.name") == nil { d.set(lan.name, forKey: "lan.name") }
        lan.color = d.object(forKey: "lan.color") as? Int ?? Int.random(in: 0..<NameColors.all.count)
        d.set(lan.color, forKey: "lan.color")
        lan.bird = progress.selected.id
        lan.fit = progress.outfit.code
        Game.playerColor = lan.color
    }

    private func setProfile(name: String, color: Int) {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        lan.name = n.isEmpty ? lan.name : n
        lan.color = color
        Game.playerColor = color
        UserDefaults.standard.set(lan.name, forKey: "lan.name")
        UserDefaults.standard.set(color, forKey: "lan.color")
        lan.updateProfile()
    }

    private func wireLAN() {
        lan.onChange = { [weak self] in self?.pauseMenu.lanChanged() }
        lan.onChat = { [weak self] l in
            self?.chatView.add(l)
            self?.pauseMenu.chatChanged()
        }
        lan.onLobby = { [weak self] l in self?.lobbyChanged(l) }
        lan.onMatch = { [weak self] m in self?.apply(m) }
        lan.onEvent = { [weak self] _, e in self?.directorEvent(e) }
        lan.onPeerLeft = { [weak self] id in
            guard let self, let c = self.director.playerLeft(id) else { return }
            self.finishRound(c)
        }
        lan.onInvite = { [weak self] inv in
            guard let self else { return }
            self.pendingInvite = inv
            self.hud.showInvite("\(inv.from) invited you to play — press J to join")
            self.inviteHide?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.hud.showInvite(nil); self?.pendingInvite = nil }
            self.inviteHide = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: w)
            if self.isPaused { self.pauseMenu.lanChanged() }
        }
        lan.onEnded = { [weak self] why in
            guard let self, !self.terminating else { return }
            self.countedLANGame = false
            self.knownPlayers = []
            self.knownNames = [:]
            self.chatView.close()
            self.chatView.reset()
            if why.count < 40 { self.hud.showNotice(why) }
            self.hud.addFeed(why)
            let w = self.progress.world.kind ?? .meadow
            self.makeGame(w, mode: .freeRoam)
            self.pauseMenu.lanChanged()
        }
        director.state = { [weak self] id in self?.lan.latestState(of: id) }
    }

    private var knownPlayers: Set<Int> = []
    private var knownNames: [Int: String] = [:]
    private var countedLANGame = false

    /// The host changed the mode, map or settings (or someone joined / left).
    private func lobbyChanged(_ l: Lobby) {
        guard inMultiplayer else { return }
        let ids = Set(l.players.map(\.id))
        for p in l.players where !knownPlayers.contains(p.id) && p.id != lan.localId && !knownPlayers.isEmpty {
            hud?.addFeed("\(p.name) joined")
            lan.note("\(p.name) joined")
        }
        for id in knownPlayers where !ids.contains(id) && id != lan.localId {
            if let n = knownNames[id] { lan.note("\(n) left") }
        }
        knownPlayers = ids
        knownNames = Dictionary(l.players.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        // Counts toward "Flock together" (once per game joined or hosted).
        if l.players.count >= 2 && !countedLANGame {
            countedLANGame = true
            progress.playedLAN()
            checkGoals()
        }
        let world = WorldID(rawValue: l.world) ?? .meadow
        if game?.multiplayer != true || world != currentWorld || l.mode != currentMode {
            let g = makeGame(world, mode: l.mode)
            if l.running && lan.role == .joined { g.enqueue { $0.joinAsSpectator() } }
        }
        mouth.enabled = l.mode == .pvp || l.rules.pvp
        if isPaused { pauseMenu.setPlaying(mode: currentMode, world: currentWorld) }
    }

    func hostGame(mode: GameMode) {
        guard lan.role == .idle else { return }
        UserDefaults.standard.set(true, forKey: "lan.used")
        lan.bird = progress.selected.id
        knownPlayers = []
        let world = currentWorld
        lan.host(mode: mode, world: world.rawValue, rules: MatchRules())
    }

    /// Host: begin a race / fight for everyone.
    func hostStartRound() {
        guard lan.role == .hosting, currentMode != .freeRoam, !director.running else { return }
        warmupTimer?.cancel()
        let cmd = director.start(mode: currentMode, players: lan.lobby.players)
        lan.broadcast(cmd)
        lan.updateLobby(running: true)
        apply(cmd)
    }

    /// A match command from the host (or the host's own).
    private func apply(_ m: MatchCommand) {
        switch m {
        case .start(let id, let countdown, let slots):
            hud.showResults(nil)
            let me = lan.localId
            game?.enqueue { $0.startMatch(id: id, countdown: countdown, slot: slots[me] ?? 0) }
        case .results(_, let standings):
            game?.enqueue { $0.endMatch() }
            multiplayerResult(standings)
        case .warmup:
            hud.showResults(nil)
            game?.enqueue { $0.enterWarmup() }
        }
    }

    private func directorEvent(_ e: GameEvent) {
        guard lan.role == .hosting, let c = director.handle(e) else { return }
        finishRound(c)
    }

    private func finishRound(_ c: MatchCommand) {
        lan.broadcast(c)
        lan.updateLobby(running: false)
        apply(c)
        // Everyone back to warm-up after a look at the results.
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.lan.role == .hosting, !self.director.running else { return }
            self.lan.broadcast(.warmup)
            self.apply(.warmup)
        }
        warmupTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 14, execute: w)
    }

    func acceptInvite() {
        guard let inv = pendingInvite else { return }
        pendingInvite = nil
        hud.showInvite(nil)
        if inMultiplayer || lan.role == .joining { lan.leave() }
        lan.accept(inv)
    }

    /// Test hook (`--join-lan`): join the first game that shows up.
    private func joinFirstGameWhenFound() {
        if let g = lan.games.first { lan.join(g); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.joinFirstGameWhenFound() }
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
        var c = interpreter.process(raw, time: t)
        let m = mouth.process(pb, pose: raw, time: t)
        c.mouthOpen = m.open
        c.mouthSeen = m.seen
        c.attackCount = m.count
        shared.publish(c, pose: raw)
        frameCount += 1
        if frameCount % 90 == 0 {
            Log.write(String(format: "vision %.1fms tracking=%d hands=%d roll=%+.2f pitch=%+.2f tuck=%.2f flap=%.2f/%.2f cal=%d mouth=%.2f",
                             tracker.lastInferenceMs, c.tracking ? 1 : 0, c.handsVisible, c.roll, c.pitch, c.tuck,
                             c.flapL, c.flapR, c.calibrated ? 1 : 0, c.mouthOpen))
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
        updateLock.lock()
        lastRender = CACurrentMediaTime()
        renderClockOffset = time - lastRender
        game?.update(time: time)
        updateLock.unlock()
    }

    private let updateLock = NSLock()
    private var lastRender = 0.0
    /// SceneKit's clock minus CACurrentMediaTime, so hidden ticks continue the same timeline.
    private var renderClockOffset = 0.0

    /// In a LAN game the world goes on while this window is hidden (minimized, covered, screen asleep), when macOS
    /// stops drawing it: keep the game ticking so your bird, clock and race stay in step with everyone else.
    private func tickHiddenGame() {
        guard inMultiplayer, CACurrentMediaTime() - lastRender > 0.25, updateLock.try() else { return }
        game?.update(time: CACurrentMediaTime() + renderClockOffset)
        updateLock.unlock()
    }

    private func refreshHUD() {
        guard let game else { return }
        if let t = titleScreen {
            // Holding the arms out (calibrating) starts the game.
            let c = shared.control
            t.calibration = CGFloat(c.calibProgress)
            if c.calibrated && !calibratedAtTitle && !isPaused { t.go() }
            calibratedAtTitle = calibratedAtTitle && c.calibrated
        }
        if let o = game.cutsceneOverlay {
            cutsceneOverlay.isHidden = false
            cutsceneOverlay.show(o)
            hud.isHidden = true
        } else if !cutsceneOverlay.isHidden {
            cutsceneOverlay.isHidden = true
            hud.isHidden = isPaused
        }
        let s = game.stats
        hud.update(s, pose: shared.pose, cameraName: camera.device?.localizedName ?? "No camera")
        tutorial.tick()
        welcome?.tick()
        if lan.role == .hosting, let c = director.tick() { finishRound(c) }
        tickHiddenGame()
        chatView.bottomInset = hud.helpTop
        chatView.tick()
        hudTicks += 1
        if hudTicks % 30 == 0 { watchFrameRate(s.fps) }
        if hudTicks % 10 == 0 { updateUncapped() }
        if hudTicks % 90 == 0 {
            Log.write(String(format: "fps %.1f speed %.0f km/h alt %.0f rings %d tracking %d mode %@ players %d", s.fps, s.speedKmh, s.altitude,
                             s.score, s.control.tracking ? 1 : 0, s.mode.rawValue, s.players))
        }
    }

    // MARK: Photos

    /// P: the 3D view without the HUD, saved to Pictures › Bird Game.
    func takePhoto() {
        guard !isPaused else { return }
        let image: NSImage
        if uncapped != nil, let game, let device = scnView.device {
            let r = SCNRenderer(device: device, options: nil)
            r.scene = game.scene
            r.pointOfView = game.cameraNode
            image = r.snapshot(atTime: CACurrentMediaTime() + renderClockOffset, with: scnView.convertToBacking(scnView.bounds).size,
                               antialiasingMode: .multisampling4X)
        } else {
            image = scnView.snapshot()
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Bird Game", isDirectory: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Bird Game \(f.string(from: Date())).png")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var saved = false
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                saved = (try? png.write(to: url)) != nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if saved {
                    self.sound?.click()
                    self.hud.showToast("Photo saved", "Pictures \u{203A} Bird Game", color: Wii.blue)
                } else {
                    NSSound.beep()
                    self.hud.showNotice("Couldn't save the photo")
                }
            }
        }
    }

    // MARK: Settings

    private var settingsValues: SettingsCard.Values {
        SettingsCard.Values(sound: !muted, help: hud.showHelp, chat: Prefs.showChat, fps: Prefs.showFPS, autoUpdate: updater.autoCheck,
                            hudOpacity: hudOpacity, cameras: CameraManager.availableDevices().map { ($0.uniqueID, $0.localizedName) },
                            currentCamera: camera.device?.uniqueID, preview: hud.showPreview, graphics: GraphicsQuality.pinned,
                            automaticGraphics: GraphicsQuality.automatic, vsync: Prefs.vsync,
                            screenMaxFPS: window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60,
                            jetpack: progress.jetpackOwned ? Prefs.jetpack : nil)
    }

    // MARK: Graphics

    private var slowSeconds = 0
    private var watchingSince = CACurrentMediaTime()
    private let graphicsMenu = NSMenu(title: "Graphics")

    /// Automatic graphics: flying that stays choppy (under 40 fps for most of 10 seconds) steps the level down.
    private func watchFrameRate(_ fps: Float) {
        guard GraphicsQuality.pinned == nil, !isPaused, welcome == nil, NSApp.isActive,
              window.occlusionState.contains(.visible), CACurrentMediaTime() - watchingSince > 8, fps > 0 else {
            slowSeconds = 0
            return
        }
        slowSeconds = fps < 40 ? slowSeconds + 1 : max(0, slowSeconds - 2)
        guard slowSeconds >= 10, GraphicsQuality.automatic != .low,
              let lower = GraphicsQuality(rawValue: GraphicsQuality.automatic.rawValue - 1) else { return }
        slowSeconds = 0
        GraphicsQuality.automatic = lower
        applyGraphics()
        Log.write(String(format: "graphics: %.0f fps, automatic level now %@", fps, lower.title))
        hud.showToast("Graphics set to \(lower.title)", "To keep flying smooth (Game menu \u{2192} Graphics)", color: Wii.blue)
    }

    private func applyGraphics() {
        let q = GraphicsQuality.current
        scnView.antialiasingMode = q.antialiasing
        uncapped?.set(samples: q.samples)
        game?.apply(q)
        watchingSince = CACurrentMediaTime()
        rebuildGraphicsMenu()
    }

    private func rebuildGraphicsMenu() {
        graphicsMenu.removeAllItems()
        let auto = graphicsMenu.addItem(withTitle: "Automatic (\(GraphicsQuality.automatic.title))", action: #selector(selectGraphics(_:)), keyEquivalent: "")
        auto.tag = -1
        auto.target = self
        auto.state = GraphicsQuality.pinned == nil ? .on : .off
        graphicsMenu.addItem(.separator())
        for q in GraphicsQuality.allCases.reversed() {
            let item = graphicsMenu.addItem(withTitle: q.title, action: #selector(selectGraphics(_:)), keyEquivalent: "")
            item.tag = q.rawValue
            item.target = self
            item.state = GraphicsQuality.pinned == q ? .on : .off
        }
    }

    @objc private func selectGraphics(_ item: NSMenuItem) {
        setGraphics(item.tag < 0 ? nil : GraphicsQuality(rawValue: item.tag))
    }

    /// nil = automatic (starting again from what this Mac can do).
    private func setGraphics(_ q: GraphicsQuality?) {
        if let q {
            GraphicsQuality.pinned = q
        } else {
            GraphicsQuality.pinned = nil
            GraphicsQuality.automatic = GraphicsQuality.hardwareDefault
        }
        applyGraphics()
    }

    /// V-Sync on: SceneKit's view draws, 60 fps in step with the screen. Off: the uncapped renderer draws instead,
    /// as fast as the Mac can (SceneKit's view can't go past the screen's refresh rate).
    private func applyVSync() {
        guard let scnView else { return }
        if Prefs.vsync {
            scnView.preferredFramesPerSecond = 60
            guard let u = uncapped else { return }
            u.stop()
            u.removeFromSuperview()
            uncapped = nil
            scnView.scene = game?.scene
            scnView.pointOfView = game?.cameraNode
            scnView.isPlaying = true
            scnView.rendersContinuously = true
            Log.write("v-sync on")
        } else {
            guard uncapped == nil, let device = scnView.device,
                  let u = UncappedView(device: device, delegate: self, clock: { [weak self] in CACurrentMediaTime() + (self?.renderClockOffset ?? 0) })
            else { return }
            // SceneKit's view stops drawing (and lets go of the scene) while this one draws.
            scnView.rendersContinuously = false
            scnView.isPlaying = false
            scnView.scene = nil
            u.frame = scnView.frame
            u.autoresizingMask = [.width, .height]
            window.contentView!.addSubview(u, positioned: .above, relativeTo: scnView)
            u.set(scene: game?.scene, camera: game?.cameraNode)
            u.set(samples: GraphicsQuality.current.samples)
            u.set(visible: true, paced: isPaused)
            uncapped = u
            u.start()
            Log.write("v-sync off: uncapped renderer")
        }
    }

    /// The uncapped renderer only draws while the window can be seen, and at 60 fps while the menu is open.
    private func updateUncapped() {
        guard let u = uncapped else { return }
        u.set(visible: window.occlusionState.contains(.visible) && !window.isMiniaturized, paced: isPaused)
    }

    private func setAutoUpdate(_ on: Bool) {
        updater.autoCheck = on
        autoUpdateItem?.state = on ? .on : .off
        if on { updater.checkIfDue() }
    }

    // MARK: Actions

    func recalibrate() { camera.queue.async { self.interpreter.recalibrate() } }
    func togglePreview() { hud.showPreview.toggle(); Prefs.showPreview = hud.showPreview }
    func toggleHelp() { hud.showHelp.toggle() }
    func toggleMute() { setMuted(!muted) }
    func setMuted(_ m: Bool) {
        muted = m
        Prefs.muted = m
        sound?.setMuted(muted || isPaused)
        sound?.setUIMuted(muted)
    }
    func attack() { game?.keys.attack = true }
    /// B: light the jetpack or put it out (once it's yours and on your back).
    func jetKey() {
        guard progress.jetpackOwned, Prefs.jetpack else { return }
        game?.keys.jet = true
    }

    /// T: type a message to everyone in the LAN game.
    func openChat() {
        guard inMultiplayer, !isPaused else { return }
        game?.keys = KeyInput()
        chatView.open()
    }

    /// N: respawn / race again / (host) start the next round.
    func restart() {
        if lan.role == .hosting && currentMode != .freeRoam, let g = game, g.phase == .warmup || g.phase == .done, !director.running {
            hostStartRound()
            return
        }
        if !inMultiplayer { hud.showResults(nil) }
        game?.respawnRequested = true
    }

    // MARK: Menus

    private func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bird Game", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let check = appMenu.addItem(withTitle: "Check for Updates\u{2026}", action: #selector(menuCheckForUpdates), keyEquivalent: "")
        check.target = self
        let auto = appMenu.addItem(withTitle: "Check for Updates Automatically", action: #selector(menuAutoUpdates(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = updater.autoCheck ? .on : .off
        autoUpdateItem = auto
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Bird Game", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let gameItem = NSMenuItem()
        main.addItem(gameItem)
        let gameMenu = NSMenu(title: "Game")
        gameMenu.addItem(withTitle: "Pause / Modes / LAN / Shop  (Esc)", action: #selector(menuPause), keyEquivalent: "")
        gameMenu.addItem(.separator())
        gameMenu.addItem(withTitle: "Recalibrate Arms", action: #selector(menuRecalibrate), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Restart  (N)", action: #selector(menuRestart), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Toggle Camera Preview", action: #selector(menuPreview), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Toggle Help", action: #selector(menuHelp), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Mute", action: #selector(menuMute), keyEquivalent: "")
        let gfx = gameMenu.addItem(withTitle: "Graphics", action: nil, keyEquivalent: "")
        gfx.submenu = graphicsMenu
        rebuildGraphicsMenu()
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
    @objc private func menuCheckForUpdates() {
        if !isPaused { togglePause() }
        updater.check()
    }
    @objc private func menuAutoUpdates(_ item: NSMenuItem) {
        setAutoUpdate(!updater.autoCheck)
    }
    @objc private func menuPause() { togglePause() }
    @objc private func menuRecalibrate() { recalibrate() }
    @objc private func menuRestart() { restart() }
    @objc private func menuPreview() { togglePreview() }
    @objc private func menuHelp() { toggleHelp() }
    @objc private func menuMute() { toggleMute() }
}

extension AppDelegate: TutorialHost {
    var tutorialStats: HUDStats { game?.stats ?? HUDStats() }
    var tutorialControl: ControlState { shared.control }
    var tutorialPaused: Bool { isPaused }
    func tutorialRecalibrate() { recalibrate() }
    func tutorialRings(_ on: Bool) { game?.setTutorialRings(on) }
    func tutorialTargets(_ on: Bool) {
        game?.setPracticeTargets(on)
        // (The practice flag changes on the render thread, so don't read combatOn back here.)
        mouth.enabled = on || (game?.matchCombat ?? false)
    }
    func tutorialBigPreview(_ on: Bool) {
        hud.previewScale = on ? 1.5 : 1
        if on { hud.showPreview = true }
    }
    func tutorialStartMenuTour() {
        pauseMenu.startTour { [weak self] in self?.tutorial.menuTourFinished() }
    }
    func tutorialSound(_ success: Bool) { if success { sound?.success() } }
    func tutorialFinished(completed: Bool) {
        game?.restoreRings()
        game?.setPracticeTargets(false)
        mouth.enabled = game?.matchCombat ?? false
        hud.previewScale = 1
        tutorial.overlay.isHidden = true
        if completed {
            progress.finishTutorial()
            checkGoals()
            Log.write("tutorial finished")
        } else {
            hud.showNotice("Tutorial closed")
            hud.addFeed("Restart the tutorial any time: Esc \u{2192} Tutorial")
        }
    }
}
