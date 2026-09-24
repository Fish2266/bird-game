import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--render-test") {
    let dir = i + 1 < args.count ? args[i + 1] : "render-test"
    let secs = i + 2 < args.count ? Double(args[i + 2]) ?? 20 : 20
    let species = i + 3 < args.count ? args[i + 3] : "gull"
    let world = i + 4 < args.count ? WorldID(rawValue: args[i + 4]) ?? .meadow : .meadow
    RenderTest.run(outDir: dir, seconds: secs, species: species, world: world)
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
    let menu = PauseMenuView(progress: p)
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
    menu.debugShowWorld("volcano")
    menu.layoutSubtreeIfNeeded()
    if let rep = menu.bitmapImageRepForCachingDisplay(in: menu.bounds) {
        menu.cacheDisplay(in: menu.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1] + ".worlds.png"))
    }
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
    root.layoutSubtreeIfNeeded()
    if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}

if let i = args.firstIndex(of: "--audio-test") {
    AudioTest.run(path: args[i + 1])
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
