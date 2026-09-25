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
    private(set) var isPaused = false
    private var pendingInvite: Invite?
    private var inviteHide: DispatchWorkItem?
    private var warmupTimer: DispatchWorkItem?
    private var terminating = false
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
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = Sky.fogColor
        window.contentView!.addSubview(scnView)

        hud = HUDView(frame: window.contentView!.bounds)
        hud.autoresizingMask = [.width, .height]
        hud.alphaValue = hudOpacity
        window.contentView!.addSubview(hud)

        pauseMenu = PauseMenuView(progress: progress, lan: lan)
        pauseMenu.frame = window.contentView!.bounds
        pauseMenu.autoresizingMask = [.width, .height]
        pauseMenu.isHidden = true
        window.contentView!.addSubview(pauseMenu)
        wirePauseMenu()
        wireLAN()

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
        if let i = a.firstIndex(of: "--snapshot-after"), i + 2 < a.count, let t = Double(a[i + 1]) {
            let path = a[i + 2]
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, let v = self.window.contentView else { return }
                let img = NSImage(size: v.bounds.size)
                img.lockFocus()
                self.scnView.snapshot().draw(in: v.bounds)
                if let rep = self.hud.bitmapImageRepForCachingDisplay(in: self.hud.bounds) {
                    self.hud.cacheDisplay(in: self.hud.bounds, to: rep)
                    rep.draw(in: v.bounds)
                }
                img.unlockFocus()
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { terminating = true; lan.leave() }
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
            pauseMenu.setPlaying(mode: currentMode, world: currentWorld)
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
        pauseMenu.onPlay = { [weak self] mode, world in self?.play(mode, world) }
        pauseMenu.onStartRound = { [weak self] in self?.hostStartRound(); if self?.isPaused == true { self?.togglePause() } }
        pauseMenu.onHost = { [weak self] in self?.hostGame(mode: self?.currentMode ?? .freeRoam) }
        pauseMenu.onRulesChanged = { [weak self] r in self?.lan.updateLobby(rules: r) }
        pauseMenu.onProfileChanged = { [weak self] name, color in self?.setProfile(name: name, color: color) }
        pauseMenu.onGoOnline = { [weak self] in
            UserDefaults.standard.set(true, forKey: "lan.used")
            self?.lan.goOnline()
        }
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
            pauseMenu.setSettings(sound: !muted, preview: hud.showPreview, help: hud.showHelp, hudOpacity: hudOpacity,
                                  cameras: CameraManager.availableDevices().map { ($0.uniqueID, $0.localizedName) },
                                  current: camera.device?.uniqueID)
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
        let sp = progress.selected
        let g = Game(controls: shared, world: id, mode: mode, multiplayer: mp, species: sp, points: progress.points(sp))
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
        g.onNotice = { [weak self] text in
            if text.hasPrefix("Missed") { self?.hud.showWarning(text) } else { self?.hud.addFeed(text) }
        }
        g.onMatchOver = { [weak self] out in self?.singlePlayerResult(out) }
        g.onKnockout = { [weak self] victim in
            guard let self else { return }
            let c = self.progress.award(8, world: id.rawValue)
            self.hud.setCoins(self.progress.coins)
            self.hud.addFeed("+\(c) ●  knocked out \(victim)")
        }
        g.onLocalEvent = { [weak self] e in self?.directorEvent(e) }
        if mp {
            g.link = lan
            g.localId = lan.localId
            g.rules = lan.lobby.rules
            g.peers = lan.lobby.players
            g.slot = lan.lobby.players.firstIndex { $0.id == lan.localId } ?? 0
            if mode == .freeRoam { g.respawn() } else { g.enterWarmup() }
        } else if mode.isRace {
            g.setBest(time: progress.bestTime(mode, id.rawValue), run: Ghosts.load(mode, id))
            g.enqueue { $0.restartMatch() }
        }
        g.paused = isPaused
        game = g
        mouth.enabled = g.combatOn
        // Compile the new world's shaders (and every attack's, when attacks are possible) in the background,
        // so the first fireball or explosion doesn't stutter.
        let warm: [Any] = [g.scene] + (mode == .pvp || mp ? Combat.warmupNodes() : [])
        scnView?.prepare(warm, completionHandler: nil)
        if let v = scnView {
            v.scene = g.scene
            v.pointOfView = g.cameraNode
        }
        hud?.showResults(nil)
        return g
    }

    /// Switch to the world picked in the shop (stays paused behind the menu).
    private func travel() {
        guard let id = progress.world.kind, id != game?.world.kind else { return }
        if inMultiplayer {
            if lan.role == .hosting { lan.updateLobby(world: id.rawValue) }
            return
        }
        makeGame(id, mode: currentMode)
    }

    /// Play tab: start a mode on a map.
    private func play(_ mode: GameMode, _ world: WorldID) {
        switch lan.role {
        case .hosting:
            director.stop()
            lan.updateLobby(mode: mode, world: world.rawValue, running: false)
        case .joined:
            NSSound.beep()
            return
        default:
            let info = WorldCatalog.info(world.rawValue)
            guard progress.ownsWorld(info) else { NSSound.beep(); return }
            progress.selectWorld(info)
            makeGame(world, mode: mode)
        }
        if isPaused { togglePause() }
    }

    private func applyBird(_ sp: Species) {
        game?.setSpecies(sp, points: progress.points(sp))
        lan.bird = sp.id
        lan.updateProfile()
    }

    // MARK: Results & coins

    private func singlePlayerResult(_ out: MatchOutcome) {
        var r = MatchResult(title: "", standings: [])
        let world = out.world.rawValue
        if out.mode.isRace, let t = out.time {
            let before = progress.bestTime(out.mode, world)
            let bestMedalBefore = progress.bestMedal(out.mode, world)
            let pb = progress.recordRace(out.mode, world, time: t, won: false, medals: out.medals)
            let medal = Medal.of(t, out.medals)
            if pb, var run = out.ghost {
                run.bird = progress.selected.id
                DispatchQueue.global(qos: .utility).async { Ghosts.save(run, out.mode, out.world) }
                game?.setBest(time: t, run: run)
            }
            // Medal bonus, doubled the first time you reach a new medal on this course.
            let firstMedal = medal != nil && (bestMedalBefore == nil || medal! > bestMedalBefore!)
            let base = out.gates * 3 + 25 + (pb ? 15 : 0) + (medal?.coins ?? 0) * (firstMedal ? 2 : 1)
            r.coins = progress.award(base, world: world)
            r.personalBest = pb && before != nil
            r.title = medal.map { "\($0.name) medal!" } ?? "Finished!"
            var rows = [Standing(id: 1, name: "You", color: -1, place: 0, time: t,
                                 note: "")]
            if let b = before, !pb { rows.append(Standing(id: 0, name: "Your best", color: 6, place: 0, time: b)) }
            for (m, target) in zip([Medal.gold, .silver, .bronze], out.medals) {
                rows.append(Standing(id: 0, name: m.name, color: m.color, place: 0, time: target))
            }
            r.standings = rows
            if out.missed > 0 { r.footer = "\(out.missed) missed \(out.mode == .ringRace ? "ring" : "checkpoint")\(out.missed == 1 ? "" : "s") (+\(out.missed * 5) s)  ·  " }
            r.footer += "Press N to race again  ·  Esc for other modes"
        } else {
            let placeBonus = [50, 20, 10]
            let base = out.hits + (out.place <= placeBonus.count ? placeBonus[out.place - 1] : 0)
            progress.recordFight(won: out.place == 1, knockouts: out.knockouts)
            r.coins = progress.award(base, world: world)
            r.title = out.place == 1 ? "You won!" : "\(ordinal(out.place)) place"
            r.standings = out.standings
            r.footer = "Press N to fight again  ·  Esc for other modes"
        }
        hud.setCoins(progress.coins)
        hud.showResults(r)
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
    }

    // MARK: LAN

    private func loadProfile() {
        let d = UserDefaults.standard
        lan.name = d.string(forKey: "lan.name") ?? "Player \(Int.random(in: 10...99))"
        if d.string(forKey: "lan.name") == nil { d.set(lan.name, forKey: "lan.name") }
        lan.color = d.object(forKey: "lan.color") as? Int ?? Int.random(in: 0..<NameColors.all.count)
        d.set(lan.color, forKey: "lan.color")
        lan.bird = progress.selected.id
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
            if why.count < 40 { self.hud.showNotice(why) }
            self.hud.addFeed(why)
            let w = self.progress.world.kind ?? .meadow
            self.makeGame(w, mode: .freeRoam)
            self.pauseMenu.lanChanged()
        }
        director.state = { [weak self] id in self?.lan.latestState(of: id) }
    }

    private var knownPlayers: Set<Int> = []

    /// The host changed the mode, map or settings (or someone joined / left).
    private func lobbyChanged(_ l: Lobby) {
        guard inMultiplayer else { return }
        let ids = Set(l.players.map(\.id))
        for p in l.players where !knownPlayers.contains(p.id) && p.id != lan.localId && !knownPlayers.isEmpty {
            hud?.addFeed("\(p.name) joined")
        }
        knownPlayers = ids
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
        if inMultiplayer { lan.leave() }
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
        game?.update(time: time)
    }

    private func refreshHUD() {
        guard let game else { return }
        let s = game.stats
        hud.update(s, pose: shared.pose, cameraName: camera.device?.localizedName ?? "No camera")
        if lan.role == .hosting, let c = director.tick() { finishRound(c) }
        hudTicks += 1
        if hudTicks % 90 == 0 {
            Log.write(String(format: "fps %.1f speed %.0f km/h alt %.0f rings %d tracking %d mode %@ players %d", s.fps, s.speedKmh, s.altitude,
                             s.score, s.control.tracking ? 1 : 0, s.mode.rawValue, s.players))
        }
    }

    // MARK: Actions

    func recalibrate() { camera.queue.async { self.interpreter.recalibrate() } }
    func togglePreview() { hud.showPreview.toggle() }
    func toggleHelp() { hud.showHelp.toggle() }
    func toggleMute() { muted.toggle(); sound?.setMuted(muted || isPaused) }
    func attack() { game?.keys.attack = true }

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
