import AppKit
import AVFoundation

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-test") {
    let dir = i + 1 < args.count ? args[i + 1] : "render-test"
    let secs = i + 2 < args.count ? Double(args[i + 2]) ?? 20 : 20
    let species = i + 3 < args.count ? args[i + 3] : "gull"
    let world = i + 4 < args.count ? WorldID(rawValue: args[i + 4]) ?? .meadow : .meadow
    let mode = i + 5 < args.count ? GameMode(rawValue: args[i + 5]) ?? .freeRoam : .freeRoam
    RenderTest.run(outDir: dir, seconds: secs, species: species, world: world, mode: mode)
    exit(0)
}

if let i = args.firstIndex(of: "--menu-snapshot") {
    // Lays out the pause/shop screen offscreen with a throwaway save and writes a PNG.
    let key = "progress.snapshot-test"
    UserDefaults.standard.removeObject(forKey: key)
    let p = Progress(key: key)
    p.grant(260)
    p.buy(Catalog.species("sparrow"))
    p.upgrade(Catalog.species("sparrow"), .agility)
    p.upgrade(Catalog.species("sparrow"), .agility)
    p.upgrade(Catalog.species("sparrow"), .power)
    let menu = PauseMenuView(progress: p, lan: LANSession())
    menu.frame = NSRect(x: 0, y: 0, width: 1440, height: 900)
    let win = NSWindow(contentRect: menu.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = menu
    menu.setSettings(SettingsCard.Values(sound: true, help: false, chat: true, fps: true, autoUpdate: true, hudOpacity: 1,
                                         cameras: [("a", "FaceTime HD Camera")], currentCamera: "a", preview: true, graphics: nil,
                                         automaticGraphics: .high, vsync: true, screenMaxFPS: 120))
    menu.willShow()
    menu.layoutSubtreeIfNeeded()
    if let rep = menu.bitmapImageRepForCachingDisplay(in: menu.bounds) {
        menu.cacheDisplay(in: menu.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    func findPreview(_ v: NSView) -> BirdPreviewView? {
        if let p = v as? BirdPreviewView { return p }
        for sub in v.subviews { if let p = findPreview(sub) { return p } }
        return nil
    }
    func snap(_ suffix: String) {
        menu.layoutSubtreeIfNeeded()
        if let rep = menu.bitmapImageRepForCachingDisplay(in: menu.bounds) {
            menu.cacheDisplay(in: menu.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + suffix))
        }
    }
    menu.showSettings()
    snap(".settings.png")
    menu.setSettings(SettingsCard.Values(sound: true, help: true, chat: false, fps: true, autoUpdate: true, hudOpacity: 0.6,
                                         cameras: [("a", "Logitech BRIO Ultra HD Pro Webcam")], currentCamera: "a", preview: false,
                                         graphics: .balanced, automaticGraphics: .high, vsync: false, screenMaxFPS: 60))
    snap(".settings-off.png")
    menu.hideSettings()
    menu.debugShowWorld("volcano")
    snap(".worlds.png")
    menu.setPlaying(mode: .ringRace, world: .meadow)
    menu.debugShowTab(.play)
    snap(".play.png")
    menu.debugShowTab(.lan)
    snap(".lan.png")
    p.grant(900)
    p.buyCosmetic(CosmeticCatalog.item("tophat", .hat)!)
    p.buyCosmetic(CosmeticCatalog.item("aviators", .eyes)!)
    p.buyCosmetic(CosmeticCatalog.item("scarf", .neck)!)
    // Card pictures: time the background warm-up (a second run loads them from the disk cache).
    let warmStart = CACurrentMediaTime()
    var warmed = false
    CosmeticThumbs.warmUp { warmed = true }
    while !warmed { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    print(String(format: "cosmetic pictures ready in %.2f s", CACurrentMediaTime() - warmStart))
    menu.debugShowTab(.style)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    snap(".style.png")
    menu.stylePanel.show(slot: .trail)
    snap(".style-trails.png")
    menu.stylePanel.show(slot: .paint)
    snap(".style-paint.png")
    menu.startTour {}
    snap(".tour-1.png")
    menu.debugAdvanceTour(6)
    snap(".tour-7.png")
    menu.endTour()
    // The try-on previews (an SCNView doesn't draw into the snapshot above).
    for (slot, name) in [(CosmeticSlot.hat, "hat"), (.trail, "trail")] {
        menu.stylePanel.show(slot: slot)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        var views: [BirdPreviewView] = []
        func collect(_ v: NSView) { if let p = v as? BirdPreviewView, !p.isHidden, p.frame.width > 0 { views.append(p) }; v.subviews.forEach(collect) }
        collect(menu.stylePanel)
        if let pv = views.first, let tiff = pv.snapshot().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".style-preview-\(name).png"))
        }
    }
    // Portraits of the new birds (big owl head, tiny hummingbird).
    for id in ["owl", "hummingbird"] {
        p.grant(1000)
        p.buy(Catalog.species(id))
        menu.debugShowTab(.style)
        menu.stylePanel.show(slot: .hat)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        var views: [BirdPreviewView] = []
        func collect(_ v: NSView) { if let p = v as? BirdPreviewView, !p.isHidden, p.frame.width > 0 { views.append(p) }; v.subviews.forEach(collect) }
        collect(menu.stylePanel)
        if let pv = views.first, let tiff = pv.snapshot().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".style-preview-\(id).png"))
        }
    }
    for id in ["hummingbird", "owl"] {
        menu.debugShowBird(Catalog.species(id))
        snap(".birds-\(id).png")
    }
    p.select(Catalog.species("sparrow"))
    p.checkGoals()
    menu.debugShowTab(.goals)
    snap(".goals.png")
    let fake = LANSession()
    fake.name = "Connor"; fake.color = 0
    let menu2 = PauseMenuView(progress: p, lan: fake)
    menu2.frame = menu.frame
    win.contentView = menu2
    menu2.willShow()
    fake.debugFill(hosting: true)
    menu2.debugShowTab(.lan)
    menu2.layoutSubtreeIfNeeded()
    if let rep = menu2.bitmapImageRepForCachingDisplay(in: menu2.bounds) {
        menu2.cacheDisplay(in: menu2.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".lan-host.png"))
    }
    fake.debugFill(hosting: false)
    menu2.lanChanged()
    menu2.layoutSubtreeIfNeeded()
    if let rep = menu2.bitmapImageRepForCachingDisplay(in: menu2.bounds) {
        menu2.cacheDisplay(in: menu2.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".lan-idle.png"))
    }
    fake.debugFill(hosting: false, problems: [.firewall], managed: true)
    menu2.lanChanged()
    menu2.layoutSubtreeIfNeeded()
    if let rep = menu2.bitmapImageRepForCachingDisplay(in: menu2.bounds) {
        menu2.cacheDisplay(in: menu2.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".lan-firewall.png"))
    }
    win.contentView = menu
    menu.setPlaying(mode: .pvp, world: .meadow)
    menu.debugShowTab(.play)
    snap(".play-pvp.png")
    p.lowerLevel(Catalog.species("sparrow"), .agility)
    menu.debugShowTab(.birds)
    snap(".birds.png")
    if let pv = findPreview(menu),
       let tiff = pv.snapshot().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".preview.png"))
    }
    // Updates: the menu row in each state, and the card on top.
    let rel = Updater.Release(version: "0.4", tag: "v0.4", notes: ["Seasonal worlds: autumn leaves and snowy peaks", "Four new hats", "Faster LAN joining"],
                              dmg: URL(string: "https://example.com/b.dmg")!, size: 11_400_000, sha256: nil, page: URL(string: "https://example.com")!)
    for (name, st) in [("idle", Updater.State.idle), ("available", .available(rel)), ("downloading", .downloading(rel, 0.42)),
                       ("offline", .offline("offline")), ("failed", .failed("The download failed."))] {
        menu.updateRow.show(st, current: "0.3")
        snap(".update-\(name).png")
    }
    let card = UpdateCard(frame: menu.bounds)
    menu.addSubview(card)
    for (name, st) in [("card", Updater.State.available(rel)), ("card-downloading", .downloading(rel, 0.42)),
                       ("card-manual", .manual(rel, "Bird Game is running straight from the installer. Drag it into Applications first."))] {
        card.show(st, lanNote: name == "card" ? "You'll leave the LAN game." : nil)
        snap(".update-\(name).png")
    }
    card.removeFromSuperview()
    UserDefaults.standard.removeObject(forKey: key)
    exit(0)
}

if let i = args.firstIndex(of: "--hud-snapshot") {
    // HUD over a flat sky color with made-up stats, for checking layout offscreen.
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor(srgbRed: 0.45, green: 0.62, blue: 0.85, alpha: 1).cgColor
    let hud = HUDView(frame: root.bounds)
    root.addSubview(hud)
    let win = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.contentView = root
    var s = HUDStats()
    s.speedKmh = 87; s.altitude = 142; s.agl = 96; s.score = 7; s.ringDistance = 184; s.ringBearing = 0.5; s.ringAbove = 30
    s.control.tracking = true; s.control.ready = true; s.control.hint = "Hold your arms out like wings to calibrate"
    s.input.roll = 0.5; s.input.pitch = 0.3; s.input.flapL = 0.8; s.input.flapR = 0.8; s.fps = 60
    s.streakEnabled = true; s.streak = 4; s.threat = "Plane on your tail!"
    hud.setCoins(245)
    hud.update(s, pose: nil, cameraName: "FaceTime HD Camera")
    hud.showRingFlash(coins: 5, total: 250)
    func snap(_ suffix: String) {
        root.layoutSubtreeIfNeeded()
        if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
            root.cacheDisplay(in: root.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + suffix))
        }
    }
    snap("")
    hud.showHelp = true
    snap(".help.png")
    hud.showHelp = false
    // The camera picture on (an empty capture session: no camera needed) and off: the flap meter moves into its corner.
    hud.attachPreview(CameraPreviewView(session: AVCaptureSession()))
    snap(".picture-on.png")
    hud.showPreview = false
    snap(".picture-off.png")
    hud.showPreview = true
    // A LAN ring race with the fight settings on.
    s.mode = .ringRace; s.multiplayer = true; s.phase = .running; s.raceTime = 83.42; s.gateLabel = "Ring 7 / 16"; s.penalty = 5
    s.place = "2nd of 4"; s.combat = true; s.health = 64; s.reload = 0.6; s.weaponName = "Homing Missiles"; s.mouth = 0.4; s.mouthSeen = true
    s.showCompass = true; s.players = 4; s.threat = nil; s.streakEnabled = false
    s.lives = 2; s.lockName = "Alex"; s.lockInRange = true
    s.markers = [CompassMarker(name: "Alex", color: 5, bearing: 0.4, distance: 120, above: 30),
                 CompassMarker(name: "Sam", color: 2, bearing: -2.2, distance: 640, above: -5),
                 CompassMarker(name: "Riley", color: 7, bearing: 1.6, distance: 60, above: 0)]
    hud.update(s, pose: nil, cameraName: "FaceTime HD Camera")
    hud.addFeed("Alex finished — 1:58.20")
    hud.addFeed("You knocked out Sam!")
    let chat = ChatOverlay(frame: root.bounds)
    root.addSubview(chat)
    chat.bottomInset = hud.helpTop
    chat.add(ChatLine(id: 0, name: "", color: 0, text: "Riley joined", system: true))
    chat.add(ChatLine(id: 2, name: "Alex", color: 5, text: "gg that last ring was brutal"))
    chat.add(ChatLine(id: 3, name: "Sam", color: 2, text: "wait for me at the start next round, I keep clipping the arch and ending up in the lava"))
    snap(".race.png")
    chat.open()
    snap(".chat.png")
    chat.removeFromSuperview()
    // Single-player fight with results up.
    s.mode = .pvp; s.multiplayer = false; s.gateLabel = ""; s.place = nil; s.fighters = 4; s.fightersLeft = 2; s.ringDistance = 0
    s.banner = "Out of lives by Gustav — watching Pip   (← → to switch)"; s.alive = false; s.lives = 0
    s.phase = .running; s.fightTimeLeft = 222; s.wallStatus = "The wall is closing in"
    hud.update(s, pose: nil, cameraName: "FaceTime HD Camera")
    hud.showResults(MatchResult(title: "2nd place", standings: [
        Standing(id: 101, name: "Gustav", color: 3, place: 1, knockouts: 2, note: "Golden Eagle"),
        Standing(id: 1, name: "You", color: -1, place: 2, knockouts: 1),
        Standing(id: 102, name: "Pip", color: 6, place: 3, note: "Sparrow"),
        Standing(id: 103, name: "Squawk", color: 0, place: 4, note: "Seagull")], coins: 34, footer: "Press N to fight again  ·  Esc for other modes"))
    hud.showInvite("Alex invited you to play — press J to join")
    snap(".pvp.png")
    hud.showResults(nil); hud.showInvite(nil)
    // The tutorial card, the welcome cards and a goal toast.
    hud.showResults(nil); hud.showInvite(nil)
    let tut = TutorialOverlay(frame: root.bounds)
    root.addSubview(tut)
    for (k, step) in TutorialSteps.all.enumerated() where ["up", "flap", "attack", "keys"].contains(step.id) {
        tut.show(step: step, index: k, count: TutorialSteps.all.count, done: (0..<TutorialSteps.all.count).map { $0 < k })
        tut.status = step.id == "up" ? "Climbing! +12 m" : "Flaps: 2 of 4"
        tut.progress = 0.6
        snap(".tutorial-\(step.id).png")
    }
    tut.removeFromSuperview()
    for (name, kind) in [("welcome", WelcomeView.Kind.firstLaunch), ("whatsnew", .whatsNew("0.3", WelcomeView.whatsNew(for: "0.3") ?? []))] {
        let w = WelcomeView(kind: kind)
        w.frame = root.bounds
        root.addSubview(w)
        snap(".\(name).png")
        w.removeFromSuperview()
    }
    hud.showToast("Goal complete: Ring collector", "Fly through 250 rings  ·  +150 ●")
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    snap(".toast.png")
    s.banner = nil; s.alive = true; s.lives = 2; s.health = 71; s.lockName = "Gustav"; s.lockInRange = true; s.markers = []
    s.showCompass = true; s.markers = [CompassMarker(name: "Gustav", color: 3, bearing: 0.2, distance: 90, above: 10),
                                        CompassMarker(name: "Pip", color: 6, bearing: -1.9, distance: 300, above: -20)]
    hud.update(s, pose: nil, cameraName: "FaceTime HD Camera")
    snap(".fight.png")
    hud.showResults(MatchResult(title: "Silver medal!", standings: [
        Standing(id: 0, name: "Gold", color: Medal.gold.color, place: 0, time: 113),
        Standing(id: 1, name: "You", color: -1, place: 0, time: 123.27),
        Standing(id: 0, name: "Silver", color: Medal.silver.color, place: 0, time: 133),
        Standing(id: 0, name: "Bronze", color: Medal.bronze.color, place: 0, time: 160)],
        coins: 96, personalBest: true, footer: "1 missed ring (+5 s)  ·  Press N to race again  ·  Esc for other modes"))
    snap(".results.png")
    // A single-player fight won, and a full LAN race.
    hud.showResults(MatchResult(title: "You won!", standings: [
        Standing(id: 1, name: "You", color: -1, place: 1, time: nil, knockouts: 3),
        Standing(id: 101, name: "Captain Feathers", color: 2, place: 2, time: nil, knockouts: 1),
        Standing(id: 102, name: "Squawk", color: 5, place: 3, time: nil, knockouts: 0, note: "out"),
        Standing(id: 103, name: "Gustav", color: 7, place: 4, time: nil, knockouts: 0, note: "out")],
        coins: 88, personalBest: false, footer: "Press N to fight again  ·  Esc for other modes"))
    snap(".results-fight.png")
    let lanNames = ["Alex", "Connor (you)", "Sam", "Riley", "Jordan the Magnificent", "Pip", "Max", "Lee"]
    var lanRows: [Standing] = []
    for k in 1...8 {
        let time: Double? = k == 8 ? nil : 95 + Double(k) * 3.7
        let note = k == 8 ? "did not finish" : (k == 3 ? "1 missed" : "")
        lanRows.append(Standing(id: k, name: lanNames[k - 1], color: k == 2 ? -1 : k % 9, place: k, time: time,
                                knockouts: k == 4 ? 2 : 0, note: note))
    }
    hud.showResults(MatchResult(title: "2nd place", standings: lanRows, coins: 47, personalBest: false,
                                footer: "The next round starts when the host is ready"))
    snap(".results-lan.png")
    exit(0)
}

if let i = args.firstIndex(of: "--audio-test") {
    AudioTest.run(path: args[i + 1])
    exit(0)
}

if let i = args.firstIndex(of: "--gallery") {
    Gallery.run(dir: i + 1 < args.count ? args[i + 1] : "gallery", only: i + 2 < args.count ? WorldID(rawValue: args[i + 2]) : nil)
    exit(0)
}

if let i = args.firstIndex(of: "--pvp-sim") {
    func arg(_ k: Int, _ d: String) -> String { i + k < args.count ? args[i + k] : d }
    PvPSim.run(bird: arg(1, "gull"), world: WorldID(rawValue: arg(2, "meadow")) ?? .meadow, seconds: Double(arg(3, "120")) ?? 120, pilot: arg(4, "demo"))
    exit(0)
}

if let i = args.firstIndex(of: "--perf-test") {
    PerfTest.run(bird: i + 1 < args.count ? args[i + 1] : "phoenix", seconds: i + 2 < args.count ? Double(args[i + 2]) ?? 15 : 15)
    exit(0)
}

if let i = args.firstIndex(of: "--cosmetic-gallery") {
    CosmeticGallery.run(dir: i + 1 < args.count ? args[i + 1] : "cosmetics", filter: i + 2 < args.count ? args[i + 2] : nil)
    exit(0)
}

if let i = args.firstIndex(of: "--economy-sim") {
    EconomySim.run(minutes: i + 1 < args.count ? Double(args[i + 1]) ?? 5 : 5)
    exit(0)
}

if args.contains("--tutorial-test") {
    TutorialTest.run()
    exit(0)
}

if args.contains("--scenario-test") {
    ScenarioTest.run()
    exit(0)
}

if args.contains("--update-test") {
    UpdateTest.run()
}

if args.contains("--net-test") {
    NetTest.run()
    exit(0)
}

if args.contains("--dogfight-test") {
    // A bird gliding straight and level: how often do the planes land hits?
    TerrainShape.active = FarmTerrain()
    let rt = DogfightRuntime()
    let f = FlightModel()
    f.reset(at: SIMD3(0, 160, 0), yaw: 0)
    var hits = 0
    for i in 0..<(60 * 120) {
        _ = f.step(1.0 / 60, FlightInput(roll: 0, pitch: 0.1, tuck: 0, flapL: i % 40 < 20 ? 0.6 : 0, flapR: i % 40 < 20 ? 0.6 : 0))
        hits += rt.update(dt: 1.0 / 60, time: Float(i) / 60, flight: f, sound: nil).count
    }
    print("straight flight for 120 s: \(rt.shotsFired) shots, \(hits) hits; shots from front/side/back: \(rt.shotDirs)")
    exit(0)
}

if let i = args.firstIndex(of: "--render-path-test") {
    RenderPathTest.run(dir: i + 1 < args.count ? args[i + 1] : "render-path")
    exit(0)
}

if args.contains("--uncapped-test") {
    UncappedTest.run()
    exit(0)
}

if args.contains("--frame-test") {
    // The Settings card's "Test max frame rate", on a freshly flown Home Isles scene at a Retina window's size.
    let g = Game(controls: SharedControls(), world: .meadow, terrainRadius: 5)
    g.synchronousTerrain = true
    for k in 0..<90 { g.update(time: Double(k) / 60) }
    let device = MTLCreateSystemDefaultDevice()!
    for (q, samples) in [("High", 4), ("Balanced", 2), ("Low", 1)] {
        let fps = FrameRateTest.run(scene: g.scene, camera: g.cameraNode, device: device, size: CGSize(width: 2880, height: 1800),
                                    samples: samples, seconds: 3)
        print(String(format: "%@ (%dx MSAA): %.0f fps uncapped at 2880x1800", q, samples, fps ?? -1))
    }
    exit(0)
}

if let i = args.firstIndex(of: "--soak-test") {
    SoakTest.run(seconds: i + 1 < args.count ? Double(args[i + 1]) ?? 240 : 240)
    exit(0)
}

if let i = args.firstIndex(of: "--obstacle-shots") {
    ObstacleShots.run(dir: i + 1 < args.count ? args[i + 1] : "obstacles")
    exit(0)
}

if let i = args.firstIndex(of: "--world-shots") {
    WorldShots.run(dir: i + 1 < args.count ? args[i + 1] : "Resources/worlds")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
