import AppKit
import QuartzCore

// The tutorial: a short guided flight that teaches the arm controls (checking each move with the camera), then the
// rings, attacking, the handy keys and a tour of the menu. Steps finish by themselves when you do the move; you can
// also skip, go back or jump to any step.

// MARK: - Steps

/// What the tutorial's little figure acts out.
enum TutorialFigure { case inView, tPose, flap, turn, armsUp, armsDown, tuck, rings, mouth, keys, menu, done }

struct TutorialStep {
    let id: String
    /// Name in the step list.
    let short: String
    let title: String
    let body: String
    let figure: TutorialFigure
    /// Small print (keyboard alternative, where it matters).
    var note = ""
    /// Info steps move on by themselves after this many seconds (nil = do the move to continue).
    var readTime: Double? = nil
}

enum TutorialSteps {
    static let all: [TutorialStep] = [
        TutorialStep(id: "view", short: "Get in view", title: "Step into view",
                     body: "Stand about two big steps back from your Mac, so your head, arms and hands all fit in the camera picture (bottom right).",
                     figure: .inView, note: "No camera? Fly with the arrow keys and Space, and press Tab to skip ahead."),
        TutorialStep(id: "calibrate", short: "Calibrate", title: "Arms out like wings",
                     body: "Stretch both arms straight out to the sides and hold still for a second. That tells the game where \u{201C}level\u{201D} is for you.",
                     figure: .tPose, note: "Controls feel off later? Press R and do this again."),
        TutorialStep(id: "flap", short: "Flap", title: "Flap to fly",
                     body: "Flap your arms down, like big wing beats. Bigger, faster flaps give more power: you speed up and climb.",
                     figure: .flap, note: "Keyboard: hold Space."),
        TutorialStep(id: "turn", short: "Turn", title: "Tilt to turn",
                     body: "Tip your arms like a plane's wings. Raise your left arm and lower your right to turn right. Do the opposite to turn left. Leaning works too.",
                     figure: .turn, note: "Keyboard: \u{2190} \u{2192}"),
        TutorialStep(id: "up", short: "Arms up", title: "Arms UP = fly UP",
                     body: "Hold both arms up a little, just above your shoulders. The bird points its nose up and climbs. The higher you hold them, the steeper you climb (and the more speed you lose).",
                     figure: .armsUp, note: "Keyboard: \u{2191}"),
        TutorialStep(id: "down", short: "Arms down", title: "Arms down = fly down",
                     body: "Lower both arms a little, below your shoulders, to point the nose down and pick up speed. Flying too slowly makes you stall: lower your arms or flap to get going again.",
                     figure: .armsDown, note: "Keyboard: \u{2193}"),
        TutorialStep(id: "dive", short: "Dive", title: "Tuck in to dive",
                     body: "Pin your arms against your sides to fold your wings and dive. It's the fastest way to fly. Spread your arms again to pull out (before the ground!).",
                     figure: .tuck, note: "Keyboard: hold Shift."),
        TutorialStep(id: "rings", short: "Rings", title: "Fly through the rings",
                     body: "Golden rings earn you coins \u{25CF}. The arrow at the top of the screen always points to the next one. Fly through three.",
                     figure: .rings),
        TutorialStep(id: "attack", short: "Attack", title: "Open wide to attack",
                     body: "In fights, face another bird to lock on (red brackets), then open your mouth WIDE to fire your bird's attack. Pop one of the balloons ahead to try it.",
                     figure: .mouth, note: "Keyboard: Return. Attacks work in PvP Fight, and in LAN games with PvP on."),
        TutorialStep(id: "keys", short: "Handy keys", title: "Handy keys",
                     body: "R  recalibrate if the controls feel off\nH  show or hide help\nC  camera picture on or off\nN  restart, or race again\nP  take a photo of your bird\nM  mute     F  full screen",
                     figure: .keys, readTime: 14),
        TutorialStep(id: "menu", short: "The menu", title: "Open the menu",
                     body: "Walk up to your Mac and press Esc. The menu is where you pick modes and maps, buy birds and outfits, and play with friends.",
                     figure: .menu),
        TutorialStep(id: "done", short: "Done!", title: "You're ready to fly!",
                     body: "Tutorial complete: +100 \u{25CF} and a Graduation Cap. Try a Ring Race next, or just explore. Have fun!",
                     figure: .done, readTime: 9),
    ]
}

/// The tour of the pause menu (one highlight per tab, then the left column).
struct MenuTourStop {
    let part: MenuPart
    let tab: MenuTab?
    let title: String
    let text: String
}

enum MenuTour {
    static let stops: [MenuTourStop] = [
        MenuTourStop(part: .tabArea, tab: .play, title: "Play",
                     text: "Pick a mode and a map: Free Roam, Ring Race, Speed Race, or a PvP Fight against bots. Every mode pays coins."),
        MenuTourStop(part: .tabArea, tab: .birds, title: "Birds",
                     text: "Buy new birds with your coins. Each one flies differently and has its own attack. Upgrade their stats here too."),
        MenuTourStop(part: .tabArea, tab: .style, title: "Style",
                     text: "Hats, glasses, scarves, trails and paint jobs. Click anything to try it on before you buy it."),
        MenuTourStop(part: .tabArea, tab: .worlds, title: "Worlds",
                     text: "Unlock the Volcano, the Glow Caves and Dogfight. They're harder, and pay more."),
        MenuTourStop(part: .tabArea, tab: .goals, title: "Goals",
                     text: "Goals earn bonus coins and special outfits you can't buy anywhere else."),
        MenuTourStop(part: .tabArea, tab: .lan, title: "Play with friends",
                     text: "Everyone on the same Wi-Fi can fly together. One person hosts, the others join. In a game, press T to chat."),
        MenuTourStop(part: .recalibrate, tab: nil, title: "Recalibrate and the tutorial",
                     text: "If flying ever feels off, recalibrate and hold your arms out again. You can run this tutorial again from here any time."),
        MenuTourStop(part: .settings, tab: nil, title: "Settings",
                     text: "Sound, the camera and its picture, the HUD, chat, graphics and updates are all in here."),
        MenuTourStop(part: .resume, tab: nil, title: "That's the tour!",
                     text: "Press Resume (or Esc) to get back to flying."),
    ]
}

// MARK: - Controller

/// What the tutorial needs from the app.
protocol TutorialHost: AnyObject {
    var tutorialStats: HUDStats { get }
    var tutorialControl: ControlState { get }
    var tutorialPaused: Bool { get }
    func tutorialRecalibrate()
    func tutorialRings(_ on: Bool)
    func tutorialTargets(_ on: Bool)
    func tutorialBigPreview(_ on: Bool)
    func tutorialStartMenuTour()
    func tutorialSound(_ success: Bool)
    func tutorialFinished(completed: Bool)
}

final class TutorialController {
    weak var host: TutorialHost?
    /// Seconds (tests replace this with a simulated clock).
    var clock: () -> Double = { CACurrentMediaTime() }
    let overlay = TutorialOverlay()
    private(set) var index = 0
    private(set) var active = false
    private var done: [Bool] = Array(repeating: false, count: TutorialSteps.all.count)
    var step: TutorialStep { TutorialSteps.all[index] }

    // Progress within the current step.
    private var started: Double = 0
    private var lastTick: Double = 0
    private var baseFlaps = 0, baseRings = 0, baseHits = 0
    private var baseAltitude: Float = 0
    private var hold: Double = 0, holdLeft: Double = 0, holdRight: Double = 0, flapHold: Double = 0
    private var succeededAt: Double?
    private var tourDone = false

    init() {
        overlay.onBack = { [weak self] in self?.back() }
        overlay.onSkip = { [weak self] in self?.next() }
        overlay.onClose = { [weak self] in self?.stop(completed: false) }
        overlay.onJump = { [weak self] i in self?.go(to: i) }
    }

    func start() {
        active = true
        done = Array(repeating: false, count: TutorialSteps.all.count)
        overlay.isHidden = false
        go(to: 0)
    }

    func stop(completed: Bool) {
        guard active else { return }
        leave(TutorialSteps.all[index])
        active = false
        overlay.isHidden = true
        host?.tutorialFinished(completed: completed)
    }

    func next() {
        guard active else { return }
        if index + 1 >= TutorialSteps.all.count { stop(completed: true); return }
        go(to: index + 1)
    }

    func back() { if active && index > 0 { go(to: index - 1) } }

    func go(to i: Int) {
        guard active, TutorialSteps.all.indices.contains(i) else { return }
        leave(TutorialSteps.all[index])
        index = i
        enter(TutorialSteps.all[i])
    }

    /// Set up the world for a step.
    private func enter(_ s: TutorialStep) {
        started = clock()
        lastTick = started
        succeededAt = nil
        hold = 0; holdLeft = 0; holdRight = 0; flapHold = 0
        tourDone = false
        let st = host?.tutorialStats ?? HUDStats()
        let c = host?.tutorialControl ?? ControlState()
        baseFlaps = c.flapCount
        baseRings = st.score
        baseHits = st.practiceHits
        baseAltitude = st.altitude
        host?.tutorialBigPreview(s.id == "view" || s.id == "calibrate")
        if s.id == "calibrate" { host?.tutorialRecalibrate() }
        if s.id == "rings" { host?.tutorialRings(true) }
        if s.id == "attack" { host?.tutorialTargets(true) }
        if s.id == "done" { done[index] = true }
        overlay.show(step: s, index: index, count: TutorialSteps.all.count, done: done)
        overlay.status = ""
        overlay.statusGood = false
        overlay.progress = nil
    }

    private func leave(_ s: TutorialStep) {
        if s.id == "attack" { host?.tutorialTargets(false) }
        if s.id == "view" || s.id == "calibrate" { host?.tutorialBigPreview(false) }
    }

    /// The menu tour reached its end.
    func menuTourFinished() {
        guard active, step.id == "menu" else { return }
        tourDone = true
    }

    /// Called ~30 times a second.
    func tick() {
        guard active, let host else { return }
        let now = clock()
        let dt = min(now - lastTick, 0.1)
        lastTick = now
        overlay.tick()
        let s = host.tutorialStats, c = host.tutorialControl
        let keyboard = s.usingKeyboard
        var ok = false
        var status = ""
        var progress: Double?
        switch step.id {
        case "view":
            if keyboard { ok = true; status = "Using the keyboard. That works too!" }
            else if !c.tracking { status = "Looking for you\u{2026}" }
            else if c.handsVisible < 2 { status = "I can see you. Now step back until both hands show."; hold = 0 }
            else { hold += dt; status = "Both hands in view. Hold it\u{2026}"; progress = hold / 1; ok = hold >= 1 }
        case "calibrate":
            if keyboard { ok = true; status = "Keyboard players can skip this one." }
            else if c.calibrated { ok = true }
            else if !c.tracking { status = "Step back into view" }
            else if c.calibProgress > 0.02 { status = "Hold still\u{2026}"; progress = Double(c.calibProgress) }
            else { status = "Arms straight out to the sides" }
        case "flap":
            let flaps = c.flapCount - baseFlaps
            if s.input.flapL + s.input.flapR > 0.6 { flapHold += dt }
            ok = flaps >= 4 || (keyboard && flapHold >= 1.5)
            status = keyboard ? "Hold Space to flap" : "Flaps: \(min(flaps, 4)) of 4"
            progress = keyboard ? flapHold / 1.5 : Double(min(flaps, 4)) / 4
        case "turn":
            if s.input.roll < -0.35 { holdLeft += dt }
            if s.input.roll > 0.35 { holdRight += dt }
            let l = holdLeft >= 1.2, r = holdRight >= 1.2
            ok = l && r
            status = "Turn left \(l ? "\u{2713}" : "\u{2026}")      Turn right \(r ? "\u{2713}" : "\u{2026}")"
            progress = (min(holdLeft, 1.2) + min(holdRight, 1.2)) / 2.4
        case "up":
            if s.input.pitch > 0.22 { hold += dt }
            ok = hold >= 2
            let gained = max(0, s.altitude - baseAltitude)
            status = hold > 0.05 ? String(format: "Climbing! +%.0f m", gained) : "Arms up a little, above your shoulders"
            progress = hold / 2
        case "down":
            if s.input.pitch < -0.22 { hold += dt }
            ok = hold >= 1.5
            status = hold > 0.05 ? String(format: "Diving down  %.0f km/h", s.speedKmh) : "Arms down a little, below your shoulders"
            progress = hold / 1.5
        case "dive":
            if s.input.tuck > 0.6 { hold += dt }
            ok = hold >= 1.2
            status = hold > 0.05 ? String(format: "Whoosh!  %.0f km/h", s.speedKmh) : "Arms pinned to your sides"
            if s.agl < 25 && s.input.tuck > 0.3 { status = "Pull up! Spread your arms" }
            progress = hold / 1.2
        case "rings":
            let n = s.score - baseRings
            ok = n >= 3
            status = s.ringDistance > 0 ? String(format: "Rings: %d of 3     next one %.0f m", min(n, 3), s.ringDistance) : "Rings: \(min(n, 3)) of 3"
            progress = Double(min(n, 3)) / 3
        case "attack":
            let n = s.practiceHits - baseHits
            ok = n >= 1
            if let lock = s.lockName, s.lockInRange { status = keyboard ? "Locked on \(lock). Press Return!" : "Locked on! Open your mouth WIDE" ; _ = lock }
            else if s.lockName != nil { status = "Get a bit closer\u{2026}" }
            else { status = "Turn to face a balloon" }
            if !keyboard && !s.mouthSeen { status += "  (face the camera)" }
        case "menu":
            if host.tutorialPaused && !tourDone {
                status = "Follow the highlights in the menu"
            } else if tourDone {
                ok = !host.tutorialPaused
                status = host.tutorialPaused ? "Press Resume to fly" : ""
            } else {
                status = "Press Esc"
            }
        default:
            break
        }
        if let rt = step.readTime {
            let left = rt - (now - started)
            progress = min(1, (now - started) / rt)
            if left <= 0 { ok = true }
        }
        overlay.progress = progress
        if ok && succeededAt == nil {
            succeededAt = now
            done[index] = true
            if step.readTime == nil {
                host.tutorialSound(true)
                overlay.status = step.id == "menu" ? "\u{2713} Great!" : "\u{2713} Nice!"
                overlay.statusGood = true
            }
            overlay.markDone(index)
        }
        if let at = succeededAt {
            if now - at > (step.readTime == nil ? 1.3 : 0) { next() }
            return
        }
        overlay.status = status
        overlay.statusGood = false
    }

    /// The pause menu just opened while on the menu step.
    func menuOpened() {
        guard active, step.id == "menu", !tourDone else { return }
        host?.tutorialStartMenuTour()
    }
}

// MARK: - Figures

/// Simple animated stick figure (and a few icons) showing each move, as if you were looking in a mirror.
final class PoseFigureView: FlippedView {
    var figure = TutorialFigure.tPose { didSet { needsDisplay = true } }
    private let ink = NSColor(srgbRed: 0.22, green: 0.24, blue: 0.3, alpha: 1)
    private let accent = Wii.blue
    private let green = NSColor(srgbRed: 0.25, green: 0.72, blue: 0.4, alpha: 1)

    func tick() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let t = CGFloat(CACurrentMediaTime())
        let r = bounds
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).addClip()
        NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.97, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.84, green: 0.92, blue: 0.98, alpha: 1))?
            .draw(in: r, angle: 90)
        let c = NSPoint(x: r.midX, y: r.midY + 12)
        let s = min(r.height / 170, r.width / 260)
        switch figure {
        case .inView:
            // A camera frame around the player.
            let f = NSRect(x: c.x - 78 * s, y: c.y - 86 * s, width: 156 * s, height: 150 * s)
            let frame = NSBezierPath(roundedRect: f, xRadius: 10, yRadius: 10)
            frame.lineWidth = 3
            frame.setLineDash([9, 6], count: 2, phase: t * 12)
            accent.setStroke(); frame.stroke()
            let cam = NSRect(x: c.x - 14 * s, y: f.minY - 20 * s, width: 28 * s, height: 16 * s)
            accent.setFill(); NSBezierPath(roundedRect: cam, xRadius: 4, yRadius: 4).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: cam.midX - 4 * s, y: cam.midY - 4 * s, width: 8 * s, height: 8 * s)).fill()
            person(c, s * 0.78, 12 + 4 * sin(t * 2), 12 + 4 * sin(t * 2))
            label("2 steps back", at: NSPoint(x: c.x, y: f.maxY + 8 * s), size: 12)
        case .tPose:
            person(c, s, 0, 0)
            let k = (sin(t * 2.5) + 1) / 2
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 118 * s, y: c.y - 60 * s - 4, width: 236 * s, height: 16))
            ring.lineWidth = 2
            accent.withAlphaComponent(0.25 + 0.5 * k).setStroke(); ring.stroke()
            label("hold still", at: NSPoint(x: c.x, y: c.y + 78 * s), size: 12)
        case .flap:
            // Fast downstroke, slower upstroke.
            let ph = (t * 1.25).truncatingRemainder(dividingBy: 1)
            let a: CGFloat = ph < 0.35 ? 40 - 80 * (ph / 0.35) : -40 + 80 * ((ph - 0.35) / 0.65)
            person(c, s, a, a)
            if ph < 0.35 {
                for side: CGFloat in [-1, 1] {
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: c.x + side * 92 * s, y: c.y - 60 * s))
                    p.curve(to: NSPoint(x: c.x + side * 92 * s, y: c.y + 10 * s), controlPoint1: NSPoint(x: c.x + side * 118 * s, y: c.y - 40 * s),
                            controlPoint2: NSPoint(x: c.x + side * 118 * s, y: c.y - 10 * s))
                    p.lineWidth = 3; p.lineCapStyle = .round
                    accent.withAlphaComponent(0.7).setStroke(); p.stroke()
                }
            }
            label("flap down hard", at: NSPoint(x: c.x, y: c.y + 78 * s), size: 12)
        case .turn:
            let right = sin(t * 2.1) > 0
            let tilt: CGFloat = 30
            // Mirror view: the arm on the screen's left is the player's left.
            person(c, s, right ? tilt : -tilt, right ? -tilt : tilt, lean: right ? 6 : -6)
            label(right ? "turn right \u{2192}" : "\u{2190} turn left", at: NSPoint(x: c.x, y: c.y + 78 * s), size: 13, bold: true)
        case .armsUp:
            let a: CGFloat = 32 + 4 * sin(t * 3)
            person(c, s, a, a)
            arrow(from: NSPoint(x: r.maxX - 34, y: c.y + 30 * s), to: NSPoint(x: r.maxX - 34, y: c.y - 60 * s), green)
            label("up!", at: NSPoint(x: c.x, y: c.y + 78 * s), size: 13, bold: true, color: green)
        case .armsDown:
            let a: CGFloat = -32 - 4 * sin(t * 3)
            person(c, s, a, a)
            arrow(from: NSPoint(x: r.maxX - 34, y: c.y - 55 * s), to: NSPoint(x: r.maxX - 34, y: c.y + 35 * s), accent)
            label("down", at: NSPoint(x: c.x, y: c.y + 78 * s), size: 13, bold: true, color: accent)
        case .tuck:
            person(c, s, -84, -84)
            arrow(from: NSPoint(x: r.maxX - 56, y: c.y - 55 * s), to: NSPoint(x: r.maxX - 22, y: c.y + 30 * s), accent)
            label("dive!", at: NSPoint(x: c.x, y: c.y + 78 * s), size: 13, bold: true, color: accent)
        case .rings:
            let ring = NSRect(x: c.x - 40 * s, y: c.y - 62 * s, width: 80 * s, height: 110 * s)
            let back = NSBezierPath(ovalIn: ring); back.lineWidth = 10 * s
            Wii.coinGold.setStroke(); back.stroke()
            let x = c.x - 110 * s + ((t * 50).truncatingRemainder(dividingBy: 220)) * s
            BirdIcon.draw(BirdLook(), in: NSRect(x: x - 22 * s, y: c.y - 30 * s, width: 44 * s, height: 44 * s))
            // The HUD's arrow.
            let a = NSBezierPath()
            let top = NSPoint(x: r.midX, y: r.minY + 12)
            a.move(to: NSPoint(x: top.x, y: top.y)); a.line(to: NSPoint(x: top.x + 9, y: top.y + 22))
            a.line(to: NSPoint(x: top.x, y: top.y + 16)); a.line(to: NSPoint(x: top.x - 9, y: top.y + 22)); a.close()
            NSColor.white.setFill(); a.fill(); a.lineWidth = 2; accent.setStroke(); a.stroke()
        case .mouth:
            let open = (sin(t * 2.4) + 1) / 2
            let face = NSRect(x: c.x - 58 * s, y: c.y - 70 * s, width: 116 * s, height: 124 * s)
            NSColor(srgbRed: 1, green: 0.88, blue: 0.74, alpha: 1).setFill(); NSBezierPath(ovalIn: face).fill()
            ink.setFill()
            for side: CGFloat in [-1, 1] { NSBezierPath(ovalIn: NSRect(x: c.x + side * 22 * s - 6 * s, y: c.y - 30 * s, width: 12 * s, height: 14 * s)).fill() }
            let mh = (6 + 44 * open) * s
            let mouth = NSRect(x: c.x - 18 * s, y: c.y + 8 * s, width: 36 * s, height: mh)
            NSColor(srgbRed: 0.55, green: 0.12, blue: 0.14, alpha: 1).setFill(); NSBezierPath(ovalIn: mouth).fill()
            if open > 0.8 { label("AHH!", at: NSPoint(x: c.x + 92 * s, y: c.y - 60 * s), size: 16, bold: true, color: NSColor(srgbRed: 0.9, green: 0.25, blue: 0.2, alpha: 1)) }
            // Lock-on brackets.
            let b = NSRect(x: r.maxX - 70, y: c.y - 10, width: 44, height: 44)
            NSColor(srgbRed: 0.95, green: 0.3, blue: 0.25, alpha: 1).setStroke()
            for (p, dx, dy) in [(NSPoint(x: b.minX, y: b.minY), 1, 1), (NSPoint(x: b.maxX, y: b.minY), -1, 1),
                                (NSPoint(x: b.minX, y: b.maxY), 1, -1), (NSPoint(x: b.maxX, y: b.maxY), -1, -1)] as [(NSPoint, CGFloat, CGFloat)] {
                let br = NSBezierPath(); br.lineWidth = 3
                br.move(to: NSPoint(x: p.x + dx * 12, y: p.y)); br.line(to: p); br.line(to: NSPoint(x: p.x, y: p.y + dy * 12)); br.stroke()
            }
        case .keys:
            // Two rows of four (the second row one short), centred.
            let keys = ["R", "H", "C", "N", "P", "M", "F"]
            for (i, k) in keys.enumerated() {
                let row = CGFloat(i / 4), col = CGFloat(i % 4)
                let inRow = CGFloat(i < 4 ? 4 : keys.count - 4)
                let x0 = c.x - (inRow * 78 - 14) * s / 2
                keycap(k, NSRect(x: x0 + col * 78 * s, y: c.y - 62 * s + row * 66 * s, width: 64 * s, height: 54 * s))
            }
        case .menu:
            let k = 1 + 0.06 * sin(t * 4)
            keycap("esc", NSRect(x: c.x - 55 * s * k, y: c.y - 48 * s * k, width: 110 * s * k, height: 80 * s * k), size: 26)
        case .done:
            // A big star.
            let p = NSBezierPath()
            for i in 0..<10 {
                let a = CGFloat(i) / 10 * 2 * .pi - .pi / 2 + sin(t) * 0.1
                let rad: CGFloat = (i % 2 == 0 ? 62 : 26) * s
                let pt = NSPoint(x: c.x + cos(a) * rad, y: c.y - 4 * s + sin(a) * rad)
                if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
            }
            p.close()
            Wii.coinGold.setFill(); p.fill()
            p.lineWidth = 3; NSColor(srgbRed: 0.85, green: 0.6, blue: 0.1, alpha: 1).setStroke(); p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let border = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        border.lineWidth = 1.5; Wii.border.setStroke(); border.stroke()
    }

    /// A person facing you. Arm angles in degrees above horizontal (screen-left arm first).
    private func person(_ c: NSPoint, _ s: CGFloat, _ left: CGFloat, _ right: CGFloat, lean: CGFloat = 0) {
        let lw = 7 * s
        let neck = NSPoint(x: c.x + lean * s * 0.5, y: c.y - 44 * s)
        let hip = NSPoint(x: c.x, y: c.y + 22 * s)
        ink.setStroke(); ink.setFill()
        func line(_ a: NSPoint, _ b: NSPoint) {
            let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = lw; p.lineCapStyle = .round; p.stroke()
        }
        NSBezierPath(ovalIn: NSRect(x: neck.x - 14 * s, y: neck.y - 34 * s, width: 28 * s, height: 30 * s)).fill()
        line(neck, hip)
        let shoulders = [NSPoint(x: neck.x - 22 * s, y: neck.y + 6 * s), NSPoint(x: neck.x + 22 * s, y: neck.y + 6 * s)]
        line(shoulders[0], shoulders[1])
        line(hip, NSPoint(x: c.x - 16 * s, y: c.y + 70 * s)); line(hip, NSPoint(x: c.x + 16 * s, y: c.y + 70 * s))
        for (i, deg) in [left, right].enumerated() {
            let side: CGFloat = i == 0 ? -1 : 1
            let a = deg * .pi / 180
            let sh = shoulders[i]
            let elbow = NSPoint(x: sh.x + side * cos(a) * 34 * s, y: sh.y - sin(a) * 34 * s)
            let hand = NSPoint(x: elbow.x + side * cos(a) * 32 * s, y: elbow.y - sin(a) * 32 * s)
            accent.setStroke()
            line(sh, elbow); line(elbow, hand)
            accent.setFill(); NSBezierPath(ovalIn: NSRect(x: hand.x - 6 * s, y: hand.y - 6 * s, width: 12 * s, height: 12 * s)).fill()
            ink.setStroke(); ink.setFill()
        }
    }

    private func arrow(from a: NSPoint, to b: NSPoint, _ color: NSColor) {
        let p = NSBezierPath(); p.move(to: a); p.line(to: b)
        p.lineWidth = 7; p.lineCapStyle = .round
        color.setStroke(); p.stroke()
        let d = atan2(b.y - a.y, b.x - a.x)
        let head = NSBezierPath()
        head.move(to: NSPoint(x: b.x + cos(d) * 6, y: b.y + sin(d) * 6))
        head.line(to: NSPoint(x: b.x + cos(d + 2.5) * 18, y: b.y + sin(d + 2.5) * 18))
        head.line(to: NSPoint(x: b.x + cos(d - 2.5) * 18, y: b.y + sin(d - 2.5) * 18))
        head.close()
        color.setFill(); head.fill()
    }

    private func keycap(_ k: String, _ r: NSRect, size: CGFloat = 22) {
        Wii.tile(r, radius: 9, fill: .white, bottom: Wii.tileLow, border: Wii.border, borderWidth: 2)
        Wii.drawText(k, in: r.offsetBy(dx: 0, dy: -2), size: size, bold: true, color: ink, align: .center, centerV: true)
    }

    private func label(_ s: String, at p: NSPoint, size: CGFloat, bold: Bool = false, color: NSColor? = nil) {
        Wii.drawText(s, in: NSRect(x: p.x - 110, y: p.y, width: 220, height: size + 8), size: size, bold: bold, color: color ?? Wii.textSoft, align: .center)
    }
}

// MARK: - The tutorial card

/// Card at the bottom left while the tutorial runs: step dots (click to jump), the move, a live status line and
/// Back / Skip buttons.
final class TutorialOverlay: NSView {
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    var onClose: (() -> Void)?
    var onJump: ((Int) -> Void)?
    var status = "" { didSet { if status != oldValue { statusLabel.text = status } } }
    var statusGood = false { didSet { statusLabel.color = statusGood ? NSColor(srgbRed: 0.18, green: 0.62, blue: 0.32, alpha: 1) : Wii.blue } }
    var progress: Double? { didSet { bar.fraction = progress; bar.isHidden = progress == nil } }

    private let card = WiiPanel()
    private let header = WiiLabel(12, bold: true, color: Wii.textSoft)
    private let dots = StepDotsView()
    private let title = WiiLabel(25, bold: true)
    private let figureView = PoseFigureView()
    private let body = WiiLabel(17)
    private let statusLabel = WiiLabel(16, bold: true, color: Wii.blue)
    private let bar = ThinBar()
    private let note = WiiLabel(12.5, color: Wii.textSoft)
    private let backButton = WiiButton("\u{2039} Back", textSize: 14)
    private let skipButton = WiiButton("Skip \u{203A}   Tab", textSize: 14)
    private let closeButton = WiiButton("Exit", textSize: 13)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(card)
        for v in [header, dots, title, figureView, body, statusLabel, bar, note, backButton, skipButton, closeButton] as [NSView] { card.addSubview(v) }
        card.borderColor = Wii.blue
        backButton.onClick = { [weak self] in self?.onBack?() }
        skipButton.onClick = { [weak self] in self?.onSkip?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        closeButton.toolTip = "Leave the tutorial (you can start it again from the menu)"
        dots.onPick = { [weak self] i in self?.onJump?(i) }
        bar.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Only the card takes clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let v = super.hitTest(point), v !== self else { return nil }
        return v
    }

    func show(step: TutorialStep, index: Int, count: Int, done: [Bool]) {
        header.text = "TUTORIAL  \u{00B7}  STEP \(index + 1) OF \(count)"
        title.text = step.title
        body.text = step.body
        note.text = step.note
        figureView.figure = step.figure
        dots.count = count
        dots.current = index
        dots.done = done
        backButton.isEnabled = index > 0
        skipButton.title = index == count - 1 ? "Finish \u{203A}" : "Skip \u{203A}   Tab"
        needsLayout = true
    }

    func markDone(_ i: Int) {
        var d = dots.done
        if d.indices.contains(i) { d[i] = true }
        dots.done = d
    }

    func tick() { figureView.tick() }

    override func layout() {
        super.layout()
        let w: CGFloat = 430
        let h = min(560, bounds.height - 330)
        card.frame = NSRect(x: 16, y: 16, width: w, height: max(h, 420))
        let c = card.contentRect
        let W = c.width - 36, x = c.minX + 18
        var y = c.minY + 16
        header.frame = NSRect(x: x, y: y, width: W - 70, height: 16)
        closeButton.frame = NSRect(x: c.maxX - 88, y: y - 12, width: 80, height: 38)
        y += 22
        dots.frame = NSRect(x: x - 2, y: y, width: W + 4, height: 24); y += 30
        title.frame = NSRect(x: x, y: y, width: W, height: 32); y += 38
        let figH = min(150, max(90, card.frame.height - 400))
        figureView.frame = NSRect(x: x, y: y, width: W, height: figH); y += figH + 12
        body.frame = NSRect(x: x, y: y, width: W, height: body.fittingHeight(width: W)); y += body.frame.height + 8
        let buttonsY = c.maxY - 54
        note.frame = NSRect(x: x, y: buttonsY - 40, width: W, height: 36)
        statusLabel.frame = NSRect(x: x, y: max(y, buttonsY - 82), width: W, height: 22)
        bar.frame = NSRect(x: x, y: statusLabel.frame.maxY + 5, width: W, height: 7)
        backButton.frame = NSRect(x: x - 5, y: buttonsY, width: 120, height: 46)
        skipButton.frame = NSRect(x: c.maxX - 18 - 170 + 5, y: buttonsY, width: 170, height: 46)
    }
}

/// Numbered dots for the steps: done ones filled green, the current one blue. Click to jump.
final class StepDotsView: FlippedView {
    var count = 0 { didSet { needsDisplay = true } }
    var current = 0 { didSet { needsDisplay = true } }
    var done: [Bool] = [] { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?

    private var pitch: CGFloat { count > 0 ? bounds.width / CGFloat(count) : 1 }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.x / pitch)
        if i >= 0 && i < count { onPick?(i) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.x / pitch)
        toolTip = TutorialSteps.all.indices.contains(i) ? "\(i + 1). \(TutorialSteps.all[i].short)" : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(22, pitch - 4)
        for i in 0..<count {
            let r = NSRect(x: CGFloat(i) * pitch + (pitch - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            let p = NSBezierPath(ovalIn: r)
            let isDone = done.indices.contains(i) && done[i]
            if i == current {
                Wii.blue.setFill(); p.fill()
            } else if isDone {
                NSColor(srgbRed: 0.3, green: 0.72, blue: 0.42, alpha: 1).setFill(); p.fill()
            } else {
                Wii.tileLow.setFill(); p.fill()
                p.lineWidth = 1.5; Wii.border.setStroke(); p.stroke()
            }
            let ink = i == current || isDone ? NSColor.white : Wii.textSoft
            Wii.drawText(isDone && i != current ? "\u{2713}" : "\(i + 1)", in: r.offsetBy(dx: 0, dy: 0.5), size: 10.5, bold: true, color: ink,
                         align: .center, centerV: true)
        }
    }
}

/// A thin rounded progress bar (nil = empty).
final class ThinBar: FlippedView {
    var fraction: Double? { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Wii.tileLow.setFill(); track.fill()
        if let f = fraction, f > 0.001 {
            let fill = NSRect(x: r.minX, y: r.minY, width: r.width * CGFloat(min(f, 1)), height: r.height)
            (f >= 1 ? NSColor(srgbRed: 0.3, green: 0.72, blue: 0.42, alpha: 1) : Wii.blue).setFill()
            NSBezierPath(roundedRect: fill, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        }
    }
}

// MARK: - Welcome / what's new

/// A card in the middle of the screen: welcome on the very first launch (tutorial recommended), or what's new after
/// an update.
final class WelcomeView: NSView {
    enum Kind { case firstLaunch, whatsNew(String, [String]) }

    /// What to list after updating to `version`: the notes of the release the updater installed, or the built-in list
    /// for 0.3 (which players reach by downloading it by hand). nil = nothing to say.
    static func whatsNew(for version: String) -> [String]? {
        if let saved = UserDefaults.standard.dictionary(forKey: Updater.installedNotesKey),
           saved["version"] as? String == version, let notes = saved["notes"] as? [String], !notes.isEmpty {
            return Array(notes.prefix(6))
        }
        if version.hasPrefix("0.3") {
            return ["Style: hats, glasses, scarves, trails and paint jobs (Esc \u{2192} Style)",
                    "Two new birds: the Hummingbird and the Snowy Owl",
                    "Goals that unlock special outfits",
                    "A tutorial for the controls and the menus",
                    "Updates install themselves from the menu",
                    "Prettier worlds, P to take photos, and lots of fixes"]
        }
        return nil
    }
    var onTutorial: (() -> Void)?
    var onDismiss: (() -> Void)?
    private let card = WiiPanel()
    private let title = WiiLabel(30, bold: true)
    private let text = WiiLabel(16)
    private let primary = WiiButton("", textSize: 18)
    private let secondary = WiiButton("", textSize: 15)
    private let hint = WiiLabel(12.5, color: Wii.textSoft)
    private let bird = PoseFigureView()

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor
        addSubview(card)
        card.borderColor = Wii.blue
        card.glass = 70
        for v in [title, text, primary, secondary, hint, bird] as [NSView] { card.addSubview(v) }
        title.align = .center
        title.centerV = true
        text.align = .center
        hint.align = .center
        switch kind {
        case .firstLaunch:
            title.text = "Welcome to Bird Game!"
            text.text = "You fly by flapping your arms in front of your Mac's camera. The tutorial shows you every move in a couple of minutes, then gives you 100 coins and a Graduation Cap."
            primary.title = "Start the tutorial"
            secondary.title = "Skip, I'll just fly"
            hint.text = "You can start the tutorial any time from the menu (Esc).   Return starts it, Esc skips."
            bird.figure = .flap
        case .whatsNew(let v, let notes):
            title.text = "What's new in Bird Game \(v)"
            text.text = notes.map { "\u{2022} " + $0 }.joined(separator: "\n")
            text.align = .left
            primary.title = "Got it"
            secondary.title = "Try the tutorial"
            hint.text = v.hasPrefix("0.3") ? "Coin rewards were rebalanced, so every mode pays fairly." : ""
            bird.figure = .done
        }
        if case .whatsNew = kind {
            primary.onClick = { [weak self] in self?.onDismiss?() }
            secondary.onClick = { [weak self] in self?.onTutorial?() }
        } else {
            primary.onClick = { [weak self] in self?.onTutorial?() }
            secondary.onClick = { [weak self] in self?.onDismiss?() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func tick() { bird.tick() }
    override func mouseDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        let w: CGFloat = 600
        let h = max(482, 220 + 8 + text.fittingHeight(width: w - 76) + 150)
        card.frame = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        let c = card.contentRect
        let x = c.minX + 34, W = c.width - 68
        // The card's subviews are laid out top-down (WiiPanel is flipped). The title sits in the white header band.
        let header = card.headerRect
        title.frame = header
        bird.frame = NSRect(x: c.midX - 110, y: header.maxY + 14, width: 220, height: 120)
        text.frame = NSRect(x: x, y: c.minY + 220, width: W, height: text.fittingHeight(width: W))
        primary.frame = NSRect(x: c.midX - 190, y: c.maxY - 132, width: 380, height: 60)
        secondary.frame = NSRect(x: c.midX - 130, y: c.maxY - 72, width: 260, height: 46)
        hint.frame = NSRect(x: x, y: c.maxY - 22, width: W, height: 18)
    }
}

// MARK: - Menu tour highlights

/// Dims the pause menu except for one part, with a speech bubble explaining it.
final class CoachMarkView: NSView {
    var hole = NSRect.zero { didSet { needsDisplay = true; needsLayout = true } }
    var onNext: (() -> Void)?
    var onSkip: (() -> Void)?
    private let bubble = WiiPanel()
    private let title = WiiLabel(18, bold: true)
    private let text = WiiLabel(14)
    private let step = WiiLabel(11.5, bold: true, color: Wii.textSoft)
    private let next = WiiButton("Next \u{203A}", textSize: 15)
    private let skip = WiiButton("Skip tour", textSize: 12)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(bubble)
        bubble.borderColor = Wii.blue
        for v in [title, text, step, next, skip] as [NSView] { bubble.addSubview(v) }
        next.onClick = { [weak self] in self?.onNext?() }
        skip.onClick = { [weak self] in self?.onSkip?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ stop: MenuTourStop, index: Int, count: Int) {
        title.text = stop.title
        text.text = stop.text
        step.text = "MENU TOUR  \u{00B7}  \(index + 1) OF \(count)"
        next.title = index == count - 1 ? "Done \u{2713}" : "Next \u{203A}"
        skip.isHidden = index == count - 1
        needsLayout = true
    }

    /// Everything outside the bubble is blocked, so the tour can't be clicked past by accident.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }
    override func mouseDown(with event: NSEvent) {}

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        let h = NSBezierPath(roundedRect: hole, xRadius: 14, yRadius: 14)
        dim.append(h)
        dim.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.42).setFill(); dim.fill()
        h.lineWidth = 3
        Wii.blue.setStroke(); h.stroke()
    }

    override func layout() {
        super.layout()
        let w: CGFloat = 400
        let hTitle: CGFloat = 26
        let textH = Wii.textHeight(text.text, width: w - 40, size: 14)
        let h = 20 + 16 + 6 + hTitle + 6 + textH + 70
        // Beside the highlight: to its left when there's room, otherwise below or above.
        var r = NSRect(x: hole.minX - w - 18, y: hole.midY - h / 2, width: w, height: h)
        if r.minX < 10 {
            r.origin.x = min(max(hole.midX - w / 2, 10), bounds.width - w - 10)
            r.origin.y = hole.minY - h - 14 >= 10 ? hole.minY - h - 14 : min(hole.maxY + 14, bounds.height - h - 10)
        }
        r.origin.y = min(max(r.minY, 10), bounds.height - h - 10)
        bubble.frame = r
        let c = bubble.contentRect
        var y = c.minY + 14
        step.frame = NSRect(x: c.minX + 18, y: y, width: c.width - 36, height: 16); y += 20
        title.frame = NSRect(x: c.minX + 18, y: y, width: c.width - 36, height: hTitle); y += hTitle + 4
        text.frame = NSRect(x: c.minX + 18, y: y, width: c.width - 36, height: textH)
        next.frame = NSRect(x: c.maxX - 18 - 150 + 5, y: c.maxY - 58, width: 150, height: 48)
        skip.frame = NSRect(x: c.minX + 13, y: c.maxY - 54, width: 110, height: 40)
    }
}
