import AppKit

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
    menu.setSettings(sound: true, preview: true, help: false, hudOpacity: 1, cameras: [("a", "FaceTime HD Camera")], current: "a")
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
    menu.debugShowWorld("volcano")
    snap(".worlds.png")
    menu.setPlaying(mode: .ringRace, world: .meadow)
    menu.debugShowTab(0)
    snap(".play.png")
    menu.debugShowTab(1)
    snap(".lan.png")
    let fake = LANSession()
    fake.name = "Connor"; fake.color = 0
    let menu2 = PauseMenuView(progress: p, lan: fake)
    menu2.frame = menu.frame
    win.contentView = menu2
    menu2.willShow()
    fake.debugFill(hosting: true)
    menu2.debugShowTab(1)
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
    win.contentView = menu
    menu.setPlaying(mode: .pvp, world: .meadow)
    menu.debugShowTab(0)
    snap(".play-pvp.png")
    p.lowerLevel(Catalog.species("sparrow"), .agility)
    menu.debugShowTab(2)
    snap(".birds.png")
    if let pv = findPreview(menu),
       let tiff = pv.snapshot().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".preview.png"))
    }
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
    snap(".race.png")
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
    s.banner = nil; s.alive = true; s.lives = 2; s.health = 71; s.lockName = "Gustav"; s.lockInRange = true; s.markers = []
    s.showCompass = true; s.markers = [CompassMarker(name: "Gustav", color: 3, bearing: 0.2, distance: 90, above: 10),
                                        CompassMarker(name: "Pip", color: 6, bearing: -1.9, distance: 300, above: -20)]
    hud.update(s, pose: nil, cameraName: "FaceTime HD Camera")
    snap(".fight.png")
    hud.showResults(MatchResult(title: "Silver medal!", standings: [
        Standing(id: 1, name: "You", color: -1, place: 0, time: 123.27, note: "1 missed"),
        Standing(id: 0, name: "Gold", color: Medal.gold.color, place: 0, time: 113),
        Standing(id: 0, name: "Silver", color: Medal.silver.color, place: 0, time: 133),
        Standing(id: 0, name: "Bronze", color: Medal.bronze.color, place: 0, time: 160)],
        coins: 96, personalBest: true, footer: "1 missed ring (+5 s)  ·  Press N to race again  ·  Esc for other modes"))
    snap(".results.png")
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

if args.contains("--scenario-test") {
    ScenarioTest.run()
    exit(0)
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

if let i = args.firstIndex(of: "--world-shots") {
    WorldShots.run(dir: i + 1 < args.count ? args[i + 1] : "Resources/worlds")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
