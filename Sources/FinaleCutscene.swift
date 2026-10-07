import SceneKit
import simd

// The end of everything: The Finale's cutscene. The castle at sunset with fireworks going up; the bird walks across
// the drawbridge between cheering crowds as the heralds sound their trumpets, through the courtyard, in at the great
// doors and down the red carpet to the throne. The King lifts the Crown of the Sky and sets it on the bird's head
// while a choir sings; attendants bring a chest, it opens in a blaze of light, and out rises the jetpack, which
// straps itself on. It lights — and the bird blasts straight up through the Crown Lantern into a sky full of
// fireworks. Then it's yours to fly.

final class FinaleCutscene {
    struct Caption {
        let from: Float, to: Float
        let text: String
        var sub: String = ""
        var big = false
        var gold = false
    }

    /// What the overlay shows now (read on the main thread).
    struct Overlay: Equatable {
        var caption = ""
        var sub = ""
        var big = false
        var gold = false
        /// 0…1 caption fade, letterbox bars, and the fade from/to black.
        var alpha: Float = 0
        var bars: Float = 0
        var black: Float = 0
    }

    static let duration: Float = 56
    private(set) var t: Float = 0
    var finished: Bool { t >= FinaleCutscene.duration }
    /// The bird is drawn this much bigger while it walks among the people.
    static let birdScale: Float = 1.9

    static let captions: [Caption] = [
        Caption(from: 1.2, to: 5.4, text: "THE FINALE", big: true, gold: true),
        Caption(from: 7.4, to: 12.4, text: "Every goal. Every course. Every secret."),
        Caption(from: 14.2, to: 19.4, text: "The whole kingdom came to see you."),
        Caption(from: 21.6, to: 25.6, text: "Champion of the skies, step forward."),
        Caption(from: 34.6, to: 38.2, text: "The Crown of the Sky", big: true, gold: true),
        Caption(from: 38.8, to: 41.6, text: "And one more thing…"),
        Caption(from: 43.6, to: 48.4, text: "THE JETPACK", sub: "Clap your hands (or press B) to light it. Clap again to let it go out.", big: true, gold: true),
        Caption(from: 50.6, to: 55.2, text: "Fly anywhere. As fast as you dare."),
    ]

    // Cues, each fired once.
    private var fired = Set<String>()
    var onCrowned: (() -> Void)?
    var onJetpack: (() -> Void)?

    private let crown: SCNNode
    private let chest = SCNNode()
    private let lid = SCNNode()
    private let chestGlow: SCNNode
    private var chestBeam: SCNNode?
    private let gift: JetpackRig
    private let props = SCNNode()
    private var giftAttached = false
    private var crownAttached = false
    /// Where the bird is and how it stands (for the game to draw).
    private(set) var birdPos = SIMD3<Float>(0, FinaleLayout.ground, 190)
    private(set) var birdYaw: Float = 0
    private(set) var walking: Float? = nil
    private(set) var birdPitch: Float = 0
    private(set) var throttle: Float = 0
    private(set) var scale: Float = FinaleCutscene.birdScale
    /// The bird's own size (a sparrow is small, an eagle big): the cutscene scales it so every bird stands as tall.
    var birdSize: Float = 1 { didSet { scale = honoree } }
    private var honoree: Float { min(3, max(1.6, FinaleCutscene.birdScale * 1.1 / max(birdSize, 0.3))) }
    private(set) var hidden = false

    init(scene: SCNScene) {
        var anim: [CosmeticAnimator] = []
        crown = CosmeticModels.hat("skycrown", animators: &anim) ?? SCNNode()
        let c = SCNNode()
        c.addChildNode(crown)
        crownAnimators = anim
        crownHolder = c
        gift = JetpackRig()
        // The chest: dark wood, gold bands, a lid on a hinge, light inside.
        let wood = Shapes.mat(NSColor(srgbRed: 0.42, green: 0.24, blue: 0.12, alpha: 1), rough: 0.7)
        let gold = Shapes.mat(NSColor(srgbRed: 1, green: 0.78, blue: 0.3, alpha: 1), rough: 0.2, metal: 1)
        // An open box (walls and a floor, dark inside), so there's something to look into when the lid goes up.
        let inside = Shapes.mat(NSColor(srgbRed: 0.16, green: 0.08, blue: 0.04, alpha: 1), rough: 0.9)
        for z: Float in [-0.41, 0.41] {
            chest.addChildNode(Shapes.node(SCNBox(width: 1.4, height: 0.8, length: 0.08, chamferRadius: 0.02), wood, at: SIMD3(0, 0.4, z)))
        }
        for x: Float in [-0.66, 0.66] {
            chest.addChildNode(Shapes.node(SCNBox(width: 0.08, height: 0.8, length: 0.74, chamferRadius: 0.02), wood, at: SIMD3(x, 0.4, 0)))
        }
        chest.addChildNode(Shapes.node(SCNBox(width: 1.24, height: 0.1, length: 0.74, chamferRadius: 0), inside, at: SIMD3(0, 0.05, 0)))
        // Gold bands round the outside, and a lock plate on the front.
        for x: Float in [-0.5, 0.5] {
            for z: Float in [-0.455, 0.455] {
                chest.addChildNode(Shapes.node(SCNBox(width: 0.09, height: 0.82, length: 0.02, chamferRadius: 0.005), gold, at: SIMD3(x, 0.4, z)))
            }
        }
        chest.addChildNode(Shapes.node(SCNBox(width: 0.22, height: 0.2, length: 0.03, chamferRadius: 0.01), gold, at: SIMD3(0, 0.62, 0.46)))
        // The lid hinges along the far edge (−z, away from the bird) and lifts at the edge facing the bird, so it swings
        // away from it, never through it.
        lid.simdPosition = SIMD3(0, 0.8, -0.45)
        lid.addChildNode(Shapes.node(SCNBox(width: 1.42, height: 0.2, length: 0.92, chamferRadius: 0.06), wood, at: SIMD3(0, 0.1, 0.46)))
        for x: Float in [-0.5, 0.5] {
            lid.addChildNode(Shapes.node(SCNBox(width: 0.09, height: 0.21, length: 0.93, chamferRadius: 0.01), gold, at: SIMD3(x, 0.1, 0.46)))
        }
        lid.addChildNode(Shapes.node(SCNBox(width: 0.24, height: 0.12, length: 0.04, chamferRadius: 0.01), gold, at: SIMD3(0, 0.04, 0.93)))
        chest.addChildNode(lid)
        // The light inside: a warm glow filling the box, a soft beam rising out of it, and a lamp lighting the faces round it.
        chestGlow = SCNNode()
        let pool = SCNNode(geometry: SCNPlane(width: 1.22, height: 0.72))
        pool.geometry?.materials = [Shapes.glow(NSColor(srgbRed: 1, green: 0.86, blue: 0.55, alpha: 1), 2.2)]
        pool.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3(1, 0, 0))
        pool.simdPosition = SIMD3(0, 0.62, 0)
        chestGlow.addChildNode(pool)
        let beamMat = SCNMaterial()
        beamMat.lightingModel = .constant
        beamMat.diffuse.contents = NSColor(srgbRed: 1, green: 0.88, blue: 0.6, alpha: 1)
        beamMat.blendMode = .add
        beamMat.writesToDepthBuffer = false
        beamMat.isDoubleSided = true
        beamMat.transparency = 0.22
        let beam = SCNNode(geometry: SCNCone(topRadius: 0.95, bottomRadius: 0.55, height: 2.6))
        beam.geometry?.materials = [beamMat]
        beam.simdPosition = SIMD3(0, 0.62 + 1.3, 0)
        beam.castsShadow = false
        chestGlow.addChildNode(beam)
        chestBeam = beam
        let lamp = SCNLight()
        lamp.type = .omni
        lamp.color = NSColor(srgbRed: 1, green: 0.8, blue: 0.5, alpha: 1)
        lamp.intensity = 140
        lamp.attenuationStartDistance = 0.3
        lamp.attenuationEndDistance = 4.5
        let lampNode = SCNNode()
        lampNode.light = lamp
        lampNode.simdPosition = SIMD3(0, 1.2, 0)
        chestGlow.addChildNode(lampNode)
        chestGlow.isHidden = true
        chest.addChildNode(chestGlow)
        props.addChildNode(chest)
        props.addChildNode(crownHolder)
        props.addChildNode(gift.node)
        scene.rootNode.addChildNode(props)
    }
    private let crownHolder: SCNNode
    private let crownAnimators: [CosmeticAnimator]

    func remove() { props.removeFromParentNode() }

    /// Jump to the end (Esc twice): everything given, the bird already climbing out.
    func skip() {
        if t < 52 { t = 52 }
    }

    /// The overlay for time `t`.
    var overlay: Overlay {
        var o = Overlay()
        o.bars = smoothstep(0, 1.2, t) * (1 - smoothstep(54.5, 56, t))
        o.black = max(1 - smoothstep(0, 1.4, t), 0)
        for c in FinaleCutscene.captions where t >= c.from && t <= c.to {
            o.caption = c.text; o.sub = c.sub; o.big = c.big; o.gold = c.gold
            o.alpha = smoothstep(c.from, c.from + 0.6, t) * (1 - smoothstep(c.to - 0.6, c.to, t))
        }
        return o
    }

    private func once(_ cue: String, at time: Float, _ body: () -> Void) {
        guard t >= time, !fired.contains(cue) else { return }
        fired.insert(cue)
        body()
    }

    /// Advance the scene; returns where the camera is, where it looks, and its field of view. (Then the game puts the
    /// bird where `birdPos` etc. say, and calls `placeProps` so the crown and the jetpack land on it exactly.)
    func advance(_ dt: Float, rt: FinaleRuntime, sound: SoundEngine?) -> (SIMD3<Float>, SIMD3<Float>, Float) {
        t += dt
        lastDt = dt
        let L = FinaleLayout.self
        let g = L.ground
        let life = rt.life
        rt.fireworks.intensity = t < 6 ? 0.6 : (t > 35 && t < 38 ? 1 : (t > 48 ? 1 : 0.15))
        sound?.setFinaleMusic(t < 54 ? 1 : 1 - smoothstep(54, 56, t))
        life.celebrate = t > 35.5 && t < 38.5 ? 1 : (t > 46.5 ? 0.9 : 0)
        life.lookUp = smoothstep(46, 48.5, t)

        // Cues.
        once("fanfare1", at: 6.4) { sound?.heraldFanfare() }
        once("fanfare2", at: 20.4) { sound?.heraldFanfare() }
        once("choir", at: 33.0) { sound?.choir(gain: 1) }
        once("confetti1", at: 35.4) { confetti(rt, 2.2) }
        once("confetti2", at: 44.0) { confetti(rt, 1.6) }
        once("crowned", at: 35.6) {
            crownAttached = true
            onCrowned?()
            for k in 0..<4 { rt.fireworks.burst(at: SIMD3(Float(k - 2) * 50, g + 150 + Float(k % 2) * 30, -40)) }
        }
        once("jetpack", at: 44.2) {
            giftAttached = true
            onJetpack?()
        }
        once("ignite", at: 46.6) { sound?.jetIgnite() }
        once("liftoff", at: 48.6) { for k in 0..<6 { rt.fireworks.burst(at: SIMD3(cos(Float(k)) * 80, g + 130 + Float(k) * 12, -60 + sin(Float(k)) * 80)) } }

        // The bird.
        hidden = false
        walking = nil
        throttle = 0
        birdPitch = 0
        scale = honoree
        var eye = SIMD3<Float>(0, 0, 0), look = SIMD3<Float>(0, 0, -1), fov: Float = 55
        func walk(from z0: Float, to z1: Float, _ t0: Float, _ t1: Float, y: Float = g) {
            let u = clamp((t - t0) / (t1 - t0), 0, 1)
            let z = lerp(z0, z1, u)
            // Up onto the drawbridge's planks (a hand's height above the road) and down again at the gate.
            let deck = 0.25 * smoothstep(L.ditchOut + 4.6, L.ditchOut + 3.6, z) * smoothstep(L.gateZ + 5.4, L.gateZ + 6.4, z)
            birdPos = SIMD3(0, y + deck, z)
            birdYaw = 0
            walking = (t - t0) * 9
        }
        switch t {
        case ..<6:
            // The castle at sunset, the fireworks going up; slowly in.
            hidden = true
            birdPos = SIMD3(0, g, 190)
            let u = smoothstep(0, 6, t)
            eye = simd_mix(SIMD3(210, 175, 470), SIMD3(140, 120, 330), SIMD3(repeating: u))
            look = SIMD3(0, g + 34, -20)
            fov = 52
        case ..<13:
            // Up the road between the cheering crowds, seen from ahead; then, as the bird steps onto the drawbridge,
            // the camera swings round behind it to show the gate it's walking into.
            walk(from: 174, to: 133, 6, 13)
            let u = smoothstep(8.8, 12.2, t)
            let a = lerp(0.32, Float.pi - 0.26, u)
            // Higher mid-swing, so the bridge's curb doesn't hide the bird.
            eye = birdPos + SIMD3(8.6 * sin(a), 2.6 + 1.4 * sin(u * .pi) + 0.3 * u, -8.6 * cos(a))
            // Keep looking at the bird until the camera is most of the way round, then lift to the gate.
            look = birdPos + simd_mix(SIMD3(0, 1.2, 0), SIMD3(0, 4.2, -26), SIMD3(repeating: smoothstep(11.0, 12.9, t)))
            fov = 56
        case ..<20:
            // The courtyard, from ahead, the gatehouse behind.
            walk(from: 98, to: 66, 13, 20)
            eye = birdPos + SIMD3(2.6, 3.0, -10.5)
            look = birdPos + SIMD3(0, 1.6, 0)
            fov = 56
        case ..<26:
            // In at the great doors: from inside, the bird against the light.
            walk(from: 3, to: -15, 20, 26)
            let u = smoothstep(20, 26, t)
            eye = SIMD3(1.5, g + 3.4 + u * 2.2, -27 + u * 3)
            look = birdPos + SIMD3(0, 1.4, 0)
            fov = 60
        case ..<31:
            // Down the carpet to the dais, and a hop up onto it.
            if t < 30 {
                walk(from: -30, to: -59, 26, 30)
            } else {
                let u = smoothstep(30, 31, t)
                birdPos = SIMD3(0, g + L.daisHeight * u + sin(u * .pi) * 0.7, lerp(-59, -63, u))
                walking = 30 * 9 + u * 3
            }
            eye = birdPos + SIMD3(0.8, 3.2, 9.5)
            look = birdPos + SIMD3(0, 2.6, -10)
            fov = 58
        case ..<37.5:
            // The crowning, from the side: the King lifts the crown, it floats over and down.
            birdPos = SIMD3(0, g + L.daisHeight, -63)
            birdYaw = 0
            walking = 0
            let orbit = (t - 31) * 0.05
            eye = SIMD3(8.8 * cos(orbit) - 0.5, g + L.daisHeight + 4.2, -59.5 + 2.4 * sin(orbit))
            look = SIMD3(0, g + L.daisHeight + 2.2, -65.8)
            fov = 54
        case ..<45.5:
            // The gift: the chest, the light, the jetpack rising and strapping on.
            birdPos = SIMD3(0, g + L.daisHeight, -63)
            birdYaw = smoothstep(37.5, 39, t) * 0.5 * (1 - smoothstep(43.5, 45, t))
            walking = 0
            let u = smoothstep(37.5, 45.5, t)
            // From the right-hand side, the bird and the chest side by side; easing round behind it as the jetpack
            // comes over to its back (never straight behind, where the bird would hide the chest).
            eye = birdPos + simd_mix(SIMD3(6.4, 3.0, -1.2), SIMD3(5.2, 3.6, 4.6), SIMD3(repeating: u))
            look = birdPos + SIMD3(0, 1.2, -0.5)
            fov = 54
        case ..<48.6:
            // It lights: a crouch, then the flame.
            birdPos = SIMD3(0, g + L.daisHeight - 0.15 * smoothstep(45.5, 46.4, t), -63)
            birdYaw = 0
            walking = 0
            throttle = smoothstep(46.5, 46.9, t)
            birdPitch = 0.6 * smoothstep(46.6, 48.6, t)
            eye = birdPos + SIMD3(-3.2, 1.0, 4.2)
            look = birdPos + SIMD3(0, 2.2, 0)
            fov = 60
        case ..<50.4:
            // Straight up through the Crown Lantern, seen from the floor.
            let u = t - 48.6
            birdPos = SIMD3(0, g + L.daisHeight + 7 * u * u + 3 * u, -63 + u * 1.2)
            birdPitch = 1.45
            throttle = 1
            eye = SIMD3(4.5, g + 1.6, -55)
            look = birdPos
            fov = 66
        default:
            // Out of the top and away, over the castle, into the fireworks.
            let u = t - 50.4
            let y = g + L.daisHeight + 7 * 1.8 * 1.8 + 3 * 1.8 + 30 * u + 2.5 * u * u
            birdPos = SIMD3(0, y, -60.8 + 6 * u * u)
            birdPitch = 1.45 - 0.9 * smoothstep(51.5, 55, t)
            birdYaw = .pi * smoothstep(52.5, 55.5, t)
            throttle = 1
            scale = lerp(honoree, 1, smoothstep(51, 54, t))
            // Close by as it bursts out of the lantern, swinging round behind it as it levels off southward.
            let a = 0.6 + 1.9 * smoothstep(50.4, 55.5, t)
            // Further back at first (the whole lantern in view as the bird bursts out of it), then in close.
            let r = t < 52 ? lerp(22, 14, smoothstep(50.4, 52, t)) : lerp(14, 7, smoothstep(52, 55.5, t))
            eye = birdPos + SIMD3(cos(a) * r * 0.6, lerp(-5, 2.2, smoothstep(50.4, 54.5, t)), sin(a) * r * 0.6 - r * 0.8 * smoothstep(53, 55.5, t))
            // Never inside the roof or the lantern: above the roof line, and outside the lantern's drum.
            eye.y = max(eye.y, L.lanternTop + 16)
            var flat = SIMD2(eye.x, eye.z - L.lanternZ)
            if simd_length(flat) < L.lanternRadius + 14 { flat = simd_normalize(flat + SIMD2(0.01, 0)) * (L.lanternRadius + 14) }
            eye.x = flat.x; eye.z = flat.y + L.lanternZ
            look = birdPos + SIMD3(0, 0.5, 4 * smoothstep(53, 56, t))
            look.y = max(look.y, L.lanternTop)   // aim at the lantern's top until the bird comes out of it
            fov = 60
        }

        // The people.
        life.honoree = birdPos
        life.kingLift = smoothstep(31.4, 32.6, t) * (1 - smoothstep(35.2, 36.4, t))
        life.attendantsForward = smoothstep(37.6, 39.6, t) * (1 - smoothstep(45, 47, t))
        return (eye, look, fov)
    }
    private var lastDt: Float = 0

    /// Confetti showering down over the dais for a moment.
    private func confetti(_ rt: FinaleRuntime, _ seconds: Float) {
        confettiOff = t + seconds
        confettiSystem.birthRate = 520
    }
    private var confettiOff: Float = 0
    private lazy var confettiSystem: SCNParticleSystem = {
        let ps = SCNParticleSystem()
        ps.birthRate = 0
        ps.emitterShape = SCNBox(width: 22, height: 0.5, length: 18, chamferRadius: 0)
        ps.birthLocation = .volume
        ps.particleVelocity = 1.5
        ps.spreadingAngle = 180
        ps.particleLifeSpan = 6
        ps.particleLifeSpanVariation = 1.5
        ps.particleSize = 0.16
        ps.particleSizeVariation = 0.05
        ps.acceleration = SCNVector3(0, -2.2, 0)
        ps.particleAngularVelocity = 300
        ps.particleAngularVelocityVariation = 300
        ps.particleColor = NSColor(srgbRed: 0.9, green: 0.5, blue: 0.5, alpha: 1)
        ps.particleColorVariation = SCNVector4(1, 0.4, 0.2, 0)
        ps.particleImage = TrailSprites.square
        ps.blendMode = .alpha
        ps.isLightingEnabled = false
        let n = SCNNode()
        n.simdPosition = SIMD3(0, FinaleLayout.ground + 19, -62)
        n.addParticleSystem(ps)
        props.addChildNode(n)
        return ps
    }()

    /// The crown and the jetpack, placed against the bird as it now stands: they end exactly where the bird wears them.
    func placeProps(hat: simd_float4x4, body: simd_float4x4, rt: FinaleRuntime) {
        let L = FinaleLayout.self
        let life = rt.life
        if confettiOff > 0 && t >= confettiOff { confettiSystem.birthRate = 0; confettiOff = 0 }
        gift.straps.isHidden = true
        func parts(_ m: simd_float4x4) -> (SIMD3<Float>, simd_quatf, Float) {
            let s = simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
            let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z) / s, SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z) / s,
                                  SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z) / s)
            return (SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z), simd_quatf(r), s)
        }
        // The crown: held up by the King, floated over, set on the head; gone once it's really on.
        crownHolder.isHidden = crownAttached || t < 31 || t > 37.5
        if !crownHolder.isHidden {
            let (hp, hq, hs) = parts(hat)
            let king = SIMD3<Float>(0.4, L.ground + L.daisHeight, -68.5)
            let held = king + SIMD3(0, 2.15 * FinaleLife.scale * 1.25 + 0.9 * life.kingLift, 0)
            let u = smoothstep(33, 35.5, t)
            var p = simd_mix(held, hp + SIMD3(0, 1.6, 0), SIMD3(repeating: smoothstep(0, 0.7, u)))
            p = simd_mix(p, hp, SIMD3(repeating: smoothstep(0.7, 1, u)))
            crownHolder.simdPosition = p
            crownHolder.simdOrientation = simd_slerp(yawQuat(t * 0.9), hq, smoothstep(0.55, 1, u))
            // Big enough to see in the King's grasp, the bird's size by the time it lands.
            crownHolder.simdScale = SIMD3(repeating: lerp(hs * 1.4, hs, smoothstep(0.5, 1, u)))
            for a in crownAnimators { a(lastDt, 0, t) }
        }
        // The chest, opening; the jetpack rising out of the light and onto the bird's back.
        let showChest = t > 36 && t < 47.5
        chest.isHidden = !showChest
        if showChest {
            let carrying = life.attendantsForward > 0.02 && life.attendantsForward < 0.98
            chest.simdPosition = life.chestPosition + SIMD3(0, 0.25 * FinaleLife.scale + (carrying ? 0.06 * abs(sin(t * 7)) : 0), 0)
            chest.simdScale = SIMD3(repeating: 1.25)
            // Up and over on its hinge, away from the bird (negative: the bird-side edge rises), past upright so it rests open.
            lid.simdOrientation = simd_quatf(angle: -1.95 * smoothstep(39.6, 40.8, t), axis: SIMD3(1, 0, 0))
            chestGlow.isHidden = t < 39.7
            // The beam swells as the lid opens and the jetpack rises, then fades once it's away.
            let shine = smoothstep(39.7, 40.8, t) * (1 - smoothstep(43.8, 45.2, t))
            chestBeam?.geometry?.firstMaterial?.transparency = CGFloat(0.06 + 0.24 * shine + 0.03 * sin(t * 7))
            chestBeam?.simdScale = SIMD3(1, 0.4 + 0.6 * shine, 1)
            chestBeam?.simdPosition = SIMD3(0, 0.62 + 1.3 * (0.4 + 0.6 * shine), 0)
        }
        gift.node.isHidden = giftAttached || t < 40.4 || t > 45
        if !gift.node.isHidden {
            let (bp, bq, bs) = parts(body)
            let from = life.chestPosition + SIMD3(0, 1.3 * FinaleLife.scale, 0)
            let up = smoothstep(40.4, 42.2, t), over = smoothstep(42.3, 44.1, t)
            var p = from + SIMD3(0, 1.4 * up, 0)
            p = simd_mix(p, bp + SIMD3(0, 1.0 * (1 - over), 0), SIMD3(repeating: over))
            gift.node.simdPosition = p
            gift.node.simdOrientation = simd_slerp(yawQuat(t * 1.6), bq, over)
            gift.node.simdScale = SIMD3(repeating: lerp(bs * 1.5, bs, over))
            gift.update(throttle: 0, time: t, speed: 0)
        }
    }
}
