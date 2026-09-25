import SceneKit
import simd

/// Another bird in the world — a LAN player (positions interpolated from the network) or a bot.
/// Carries a nametag, an optional health bar and the "show location" glow.
final class OtherBird {
    let id: Int
    let root = SCNNode()
    private(set) var bird: BirdNode
    private(set) var speciesId: String
    private(set) var name: String
    private(set) var colorIndex: Int
    let isBot: Bool

    // Current (interpolated) state
    var pos = SIMD3<Float>(0, 0, 0)
    var vel = SIMD3<Float>(0, 0, 0)
    var rot = simd_quatf(angle: 0, axis: kUp)
    var wings = SIMD4<Float>(0.1, 0.1, 0, 0)
    var hp: Float = Fighter.maxHealth
    var flags = NetState.alive
    var progress: Float = 0
    var forward: SIMD3<Float> { rot.act(SIMD3(0, 0, -1)) }
    var alive: Bool { flags & NetState.alive != 0 }
    var spectator: Bool { flags & NetState.spectator != 0 }
    var paused: Bool { flags & NetState.paused != 0 }
    var finished: Bool { flags & NetState.finished != 0 }
    /// Seen a state recently (network players).
    var lastHeard: Double = 0

    private let tag = SCNNode()
    private let tagPlane = SCNNode()
    private let hpBack = SCNNode()
    private let hpFill = SCNNode()
    private let marker = SCNNode()
    private var fire: SCNNode?
    private var glowing = false
    private var snaps: [(t: Double, s: NetState)] = []
    private var deadFade: Float = 0

    init(id: Int, name: String, color: Int, species: String, bot: Bool = false) {
        self.id = id
        self.name = name
        colorIndex = color
        speciesId = species
        isBot = bot
        bird = BirdNode(look: Catalog.species(species).look)
        root.addChildNode(bird.node)

        let bb = SCNBillboardConstraint()
        bb.freeAxes = .all
        tag.constraints = [bb]
        tagPlane.geometry = SCNPlane(width: 3.2, height: 0.8)
        tagPlane.castsShadow = false
        tag.addChildNode(tagPlane)
        hpBack.geometry = SCNPlane(width: 2.4, height: 0.16)
        hpBack.geometry?.materials = [OtherBird.flat(NSColor(white: 0.1, alpha: 0.7))]
        hpBack.position = SCNVector3(0, -0.55, 0.001)
        tag.addChildNode(hpBack)
        hpFill.geometry = SCNPlane(width: 2.4, height: 0.12)
        hpFill.geometry?.materials = [OtherBird.flat(NSColor(srgbRed: 0.35, green: 0.9, blue: 0.4, alpha: 1))]
        hpFill.position = SCNVector3(0, -0.55, 0.002)
        tag.addChildNode(hpFill)
        tag.renderingOrder = 900
        root.addChildNode(tag)

        let diamond = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        diamond.geometry?.materials = [OtherBird.flat(NSColor.white)]
        diamond.eulerAngles.z = .pi / 4
        marker.addChildNode(diamond)
        marker.constraints = [bb]
        marker.isHidden = true
        root.addChildNode(marker)
        applyIdentity()
    }

    private static func flat(_ c: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }

    func setIdentity(name: String, color: Int) {
        guard name != self.name || color != colorIndex else { return }
        self.name = name
        colorIndex = color
        applyIdentity()
    }

    private func applyIdentity() {
        let m = SCNMaterial()
        m.lightingModel = .constant
        let img = OtherBird.tagImage(name, color: NameColors.ns(colorIndex), bot: isBot)
        m.diffuse.contents = img
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        tagPlane.geometry = SCNPlane(width: 0.8 * img.size.width / img.size.height, height: 0.8)
        tagPlane.geometry?.materials = [m]
        marker.childNodes.first?.geometry?.materials.first?.diffuse.contents = NameColors.ns(colorIndex)
        if glowing { bird.setOutline(NameColors.ns(colorIndex)) }
    }

    func setSpecies(_ sp: String) {
        guard sp != speciesId else { return }
        speciesId = sp
        let fresh = BirdNode(look: Catalog.species(sp).look)
        fresh.node.simdTransform = bird.node.simdTransform
        bird.node.removeFromParentNode()
        root.addChildNode(fresh.node)
        bird = fresh
        if glowing { bird.setOutline(NameColors.ns(colorIndex)) }
    }

    /// Nametag pill: the player's color with their name in white.
    static func tagImage(_ name: String, color: NSColor, bot: Bool) -> NSImage {
        let label = bot ? "\(name) (bot)" : name
        let textW = (label as NSString).size(withAttributes: [.font: Wii.font(34, bold: true)]).width
        return NSImage(size: NSSize(width: max(200, textW + 90), height: 80), flipped: false) { r in
            let pill = NSBezierPath(roundedRect: r.insetBy(dx: 3, dy: 8), xRadius: 32, yRadius: 32)
            NSColor(white: 0.08, alpha: 0.72).setFill(); pill.fill()
            pill.lineWidth = 5
            color.setStroke(); pill.stroke()
            let dot = NSRect(x: 20, y: r.midY - 11, width: 22, height: 22)
            color.setFill(); NSBezierPath(ovalIn: dot).fill()
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: Wii.font(34, bold: true), .foregroundColor: NSColor.white, .paragraphStyle: para]
            (label as NSString).draw(in: NSRect(x: 48, y: r.midY - 23, width: r.width - 66, height: 46), withAttributes: attrs)
            return true
        }
    }

    // MARK: Network interpolation

    func push(_ s: NetState, at t: Double) {
        snaps.append((t, s))
        if snaps.count > 12 { snaps.removeFirst(snaps.count - 12) }
        lastHeard = t
        flags = s.flags
        hp = s.hp
        progress = s.progress
        setSpecies(s.bird)
    }

    /// Show the network bird ~100 ms in the past, blending between the two states around that time.
    func interpolate(now: Double) {
        guard let last = snaps.last else { return }
        let rt = now - 0.1
        var a = snaps[0], b = last
        if rt <= snaps[0].t {
            a = snaps[0]; b = snaps[0]
        } else {
            for i in 0..<(snaps.count - 1) where snaps[i].t <= rt && snaps[i + 1].t >= rt { a = snaps[i]; b = snaps[i + 1]; break }
        }
        if rt > last.t {
            // Late packet: coast on the last velocity for a moment.
            let ahead = Float(min(rt - last.t, 0.25))
            pos = last.s.p + last.s.v * ahead
            vel = last.s.v
            rot = simd_quatf(vector: last.s.q)
            wings = last.s.w
            return
        }
        let k = b.t > a.t ? Float((rt - a.t) / (b.t - a.t)) : 1
        // Teleports (respawn, race start) shouldn't slide across the map.
        if simd_distance(a.s.p, b.s.p) > 60 { pos = b.s.p } else { pos = a.s.p + (b.s.p - a.s.p) * k }
        vel = a.s.v + (b.s.v - a.s.v) * k
        rot = simd_slerp(simd_quatf(vector: a.s.q), simd_quatf(vector: b.s.q), k)
        wings = a.s.w + (b.s.w - a.s.w) * k
    }

    // MARK: Visuals

    func updateVisuals(camera: SIMD3<Float>, dt: Float, showLocation: Bool, showHealth: Bool) {
        let visible = !spectator && (alive || deadFade > 0)
        deadFade = alive ? 1 : max(0, deadFade - dt * 0.8)
        root.isHidden = !visible
        guard visible else { return }
        bird.node.simdPosition = pos
        bird.node.simdOrientation = rot
        if alive {
            bird.pose(left: WingPose(elevation: wings.x, bend: wings.z), right: WingPose(elevation: wings.y, bend: wings.z),
                      fold: wings.w, pitchIn: 0, rollIn: 0, dt: dt)
            bird.node.opacity = paused ? 0.55 : 1
        } else {
            // Knocked out: tumble and fade.
            bird.node.simdOrientation = rot * simd_quatf(angle: (1 - deadFade) * 9, axis: SIMD3(1, 0.3, 0))
            bird.node.opacity = CGFloat(deadFade)
        }
        if showLocation != glowing {
            glowing = showLocation
            bird.setOutline(showLocation ? NameColors.ns(colorIndex) : nil)
        }

        let d = simd_distance(camera, pos)
        // Constant-ish size on screen past ~12 m.
        let s = max(1, d / 12)
        tag.simdPosition = pos + SIMD3(0, 1.3 + 0.45 * s, 0)
        tag.simdScale = SIMD3(repeating: s)
        tag.isHidden = !alive || (!showLocation && d > 260)
        let depth = !showLocation
        tagPlane.geometry?.firstMaterial?.readsFromDepthBuffer = depth
        hpBack.isHidden = !showHealth
        hpFill.isHidden = !showHealth
        if showHealth {
            let f = CGFloat(clamp(hp / Fighter.maxHealth, 0, 1))
            // Left-anchored: shrink toward the bar's left end.
            hpFill.scale = SCNVector3(max(f, 0.001), 1, 1)
            hpFill.position = SCNVector3(-1.2 + 1.2 * max(f, 0.001), -0.55, 0.002)
            let c = f > 0.5 ? NSColor(srgbRed: 0.35, green: 0.9, blue: 0.4, alpha: 1)
                : (f > 0.25 ? NSColor(srgbRed: 0.98, green: 0.78, blue: 0.2, alpha: 1) : NSColor(srgbRed: 0.95, green: 0.3, blue: 0.25, alpha: 1))
            hpFill.geometry?.firstMaterial?.diffuse.contents = c
            hpBack.geometry?.firstMaterial?.readsFromDepthBuffer = depth
            hpFill.geometry?.firstMaterial?.readsFromDepthBuffer = depth
        }
        // Far away: a colored diamond so you can always spot them.
        marker.isHidden = !showLocation || !alive || d < 60
        if !marker.isHidden {
            // Sits right on the bird, which is only a few pixels across this far away.
            marker.simdPosition = pos
            marker.simdScale = SIMD3(repeating: d * 0.011)
            marker.childNodes.first?.geometry?.firstMaterial?.readsFromDepthBuffer = false
        }
        // Drawn after the world so see-through pieces aren't painted over (back to front: tag, bar, fill).
        let base = showLocation ? 1001 : 900
        tagPlane.renderingOrder = base
        hpBack.renderingOrder = base + 1
        hpFill.renderingOrder = base + 2
        marker.childNodes.first?.renderingOrder = 1004

        let burning = flags & NetState.burning != 0 && alive
        if burning && fire == nil {
            let n = SCNNode()
            let ps = SCNParticleSystem()
            ps.particleLifeSpan = 0.45
            ps.particleSize = 0.55
            ps.particleColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 1)
            ps.particleImage = Combat.dot
            ps.blendMode = .additive
            ps.emitterShape = SCNSphere(radius: 0.5)
            ps.particleVelocity = 2
            ps.emittingDirection = SCNVector3(0, 1, 0)
            ps.isLightingEnabled = false
            n.addParticleSystem(ps)
            root.addChildNode(n)
            fire = n
        }
        if let f = fire {
            f.simdPosition = pos
            f.particleSystems?.first?.birthRate = burning ? 60 : 0
        }
    }

    /// Wing pose to publish for this bird (bots fill this in themselves).
    func setPose(pos p: SIMD3<Float>, rot q: simd_quatf, vel v: SIMD3<Float>, wings w: SIMD4<Float>) {
        pos = p; rot = q; vel = v; wings = w
    }
}
