import SceneKit
import simd

// MARK: - Weapons

struct WeaponSpec {
    var count = 1
    /// Seconds between projectiles of one volley (0 = all at once, fanned by `spread`).
    var burst: Float = 0
    var spread: Float = 0
    var speed: Float
    var accel: Float = 0
    var maxSpeed: Float = 0
    var life: Float
    /// Homing turn rate, rad/s.
    var homing: Float
    var damage: Float
    var knock: Float
    var radius: Float
    /// Explosion radius (0 = none). Birds inside take part of the damage.
    var blast: Float = 0
    /// Burn damage per second for 3 s.
    var burn: Float = 0
    var cooldown: Float
    /// Hit radius growth per second (the gust widens as it travels).
    var growth: Float = 0

    /// Seconds of reach, used for aim assist.
    var range: Float { min(speed * life + accel * life * life * 0.5, (maxSpeed > 0 ? maxSpeed : speed) * life) }
}

extension WeaponKind {
    /// Base stats at Attack 5. Tuned so a steady stream of hits takes ~10–15 s to knock a bird out:
    /// cheap birds plink, expensive ones hit harder, but nobody dies in two seconds.
    var spec: WeaponSpec {
        switch self {
        case .pebble:
            return WeaponSpec(speed: 90, life: 2.0, homing: 2.2, damage: 9, knock: 6, radius: 2.2, cooldown: 1.1)
        case .seeds:
            return WeaponSpec(count: 5, spread: 0.06, speed: 100, life: 1.0, homing: 1.6, damage: 2.6, knock: 2, radius: 1.9, cooldown: 1.3)
        case .gust:
            return WeaponSpec(speed: 70, life: 1.3, homing: 0.9, damage: 5, knock: 22, radius: 2.8, cooldown: 1.8, growth: 5)
        case .feathers:
            return WeaponSpec(count: 3, burst: 0.1, speed: 140, life: 1.2, homing: 2.8, damage: 4, knock: 3, radius: 1.9, cooldown: 1.2)
        case .missiles:
            return WeaponSpec(count: 2, burst: 0.2, spread: 0.16, speed: 55, accel: 70, maxSpeed: 120, life: 3, homing: 3.2,
                              damage: 8, knock: 9, radius: 2.4, blast: 5, cooldown: 2.0)
        case .fire:
            return WeaponSpec(count: 3, spread: 0.12, speed: 80, life: 2, homing: 2.8, damage: 5, knock: 6, radius: 2.6,
                              blast: 4, burn: 2.5, cooldown: 1.8)
        }
    }

    /// The spec after the bird's attack stat (points 1…15; 5 = as listed).
    func scaled(attack a: Int) -> WeaponSpec {
        var s = spec
        let p = Float(clamp(a, 1, StatRules.maxPoints))
        s.damage *= (0.8 + 0.04 * p) * 1.3
        s.burn *= (0.8 + 0.04 * p) * 1.3
        s.cooldown *= 1.1 - 0.02 * p
        if s.count > 1 && a >= 13 { s.count += 1 }
        return s
    }
}

/// Anything that can be shot or rammed.
struct CombatTarget {
    let id: Int
    let pos: SIMD3<Float>
    let vel: SIMD3<Float>
    var radius: Float = 1.1
}

enum Aim {
    /// Lock-on: the best bird in a wide cone ahead. The current lock is kept while it stays roughly ahead,
    /// so the target doesn't flicker between birds.
    static func lock(from origin: SIMD3<Float>, forward: SIMD3<Float>, range: Float, current: Int?,
                     targets: [CombatTarget]) -> Int? {
        func angle(_ t: CombatTarget) -> (Float, Float) {
            let to = t.pos - origin
            let d = max(simd_length(to), 0.01)
            return (acos(clamp(simd_dot(to / d, forward), -1, 1)), d)
        }
        if let c = current, let t = targets.first(where: { $0.id == c }) {
            let (a, d) = angle(t)
            if a < 1.25 && d < range * 1.6 { return c }
        }
        var best: (Int, Float)?
        for t in targets {
            let (a, d) = angle(t)
            guard a < 1.1, d < range * 1.3, d > 1 else { continue }
            let score = a + d / range * 0.6
            if best == nil || score < best!.1 { best = (t.id, score) }
        }
        return best?.0
    }

    /// Lead-corrected direction toward a target.
    static func lead(from origin: SIMD3<Float>, ownerVel: SIMD3<Float>, spec: WeaponSpec, target t: CombatTarget) -> SIMD3<Float> {
        let speed = spec.maxSpeed > 0 ? (spec.speed + spec.maxSpeed) * 0.5 : spec.speed
        let d = simd_distance(t.pos, origin)
        let p = t.pos + (t.vel - ownerVel * 0.3) * min(d / speed, 1.5)
        return simd_normalize(p - origin)
    }
}

// MARK: - Projectiles

final class Combat {
    let root = SCNNode()

    private struct Projectile {
        var owner: Int
        var weapon: WeaponKind
        var spec: WeaponSpec
        var pos: SIMD3<Float>
        var vel: SIMD3<Float>
        var target: Int?
        var life: Float
        var radius: Float
        var cosmetic: Bool
        var node: SCNNode
        var delay: Float
        var age: Float = 0
        /// Launch sound already played (a fanned volley plays one sound, a burst one per shot).
        var sounded: Bool
    }

    private var projectiles: [Projectile] = []
    private var pools: [WeaponKind: [SCNNode]] = [:]
    private var effects: [(SCNNode, WeaponKind, Float)] = []
    private var burstPool: [WeaponKind: [SCNNode]] = [:]

    /// Launch a volley. `cosmetic` volleys (from other players) are shown but never deal damage here.
    func fire(_ shot: Shot, cosmetic: Bool) {
        let spec = shot.weapon.scaled(attack: shot.attack)
        let side = simd_normalize(simd_cross(shot.dir, kUp).x.isFinite ? simd_cross(shot.dir, kUp) : SIMD3(1, 0, 0))
        let up = simd_normalize(simd_cross(side, shot.dir))
        for i in 0..<spec.count {
            var dir = shot.dir
            if spec.spread > 0 && spec.count > 1 {
                let k = Float(i) - Float(spec.count - 1) / 2
                // Fan horizontally; odd volleys (seeds) also scatter a little vertically.
                let v: Float = shot.weapon == .seeds ? (i % 2 == 0 ? 0.03 : -0.03) : 0
                dir = simd_normalize(dir + side * k * spec.spread + up * v)
            }
            let delay = spec.burst * Float(i)
            let node = acquire(shot.weapon)
            node.isHidden = delay > 0
            let vel = dir * spec.speed + shot.ownerVel * 0.35
            var sp = spec
            if shot.assist { sp.homing *= 1.6; sp.radius += 0.8 }
            projectiles.append(Projectile(owner: shot.owner, weapon: shot.weapon, spec: sp, pos: shot.origin + dir * 1.2, vel: vel,
                                          target: shot.target, life: spec.life, radius: sp.radius, cosmetic: cosmetic,
                                          node: node, delay: delay, sounded: i > 0 && spec.burst == 0))
        }
    }

    /// Moves every projectile; returns the hits dealt by non-cosmetic ones. `origins` gives each owner's
    /// current position so burst shots leave from the bird, not from where it was.
    func update(dt: Float, targets: [CombatTarget], origins: [Int: (SIMD3<Float>, SIMD3<Float>)],
                sound: SoundEngine?, listener: SIMD3<Float>) -> [HitReport] {
        var hits: [HitReport] = []
        let byId = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in projectiles.indices.reversed() {
            var p = projectiles[i]
            if p.delay > 0 {
                p.delay -= dt
                if let (o, f) = origins[p.owner] {
                    p.pos = o + f * 1.2
                    p.vel = simd_normalize(p.vel) * p.spec.speed
                }
                if p.delay <= 0 { p.node.isHidden = false }
                projectiles[i] = p
                continue
            }
            if !p.sounded {
                p.sounded = true
                playLaunch(p.weapon, at: p.pos, listener: listener, sound: sound)
            }
            p.age += dt
            if let trail = p.node.particleSystems?.first ?? p.node.childNodes.last?.particleSystems?.first {
                trail.birthRate = p.age > 0.08 ? Combat.trailRate(p.weapon) : 0
            }
            let prev = p.pos
            var speed = simd_length(p.vel)
            if p.spec.accel > 0 { speed = min(speed + p.spec.accel * dt, p.spec.maxSpeed) }
            var dir = p.vel / max(simd_length(p.vel), 1e-4)
            if let tid = p.target, let t = byId[tid], p.spec.homing > 0 {
                let lead = t.pos + t.vel * min(simd_distance(t.pos, p.pos) / max(speed, 1), 0.8)
                let want = simd_normalize(lead - p.pos)
                let ang = acos(clamp(simd_dot(dir, want), -1, 1))
                let maxTurn = p.spec.homing * dt
                if ang > 1e-4 {
                    let axis = simd_cross(dir, want)
                    if simd_length(axis) > 1e-5 {
                        dir = simd_quatf(angle: min(ang, maxTurn), axis: simd_normalize(axis)).act(dir)
                    } else { dir = want }
                }
            }
            p.vel = dir * speed
            p.pos += p.vel * dt
            p.life -= dt
            p.radius += p.spec.growth * dt

            var boom = false
            // Terrain / ceiling
            let g = TerrainShape.ground(p.pos.x, p.pos.z)
            if p.pos.y < g + 0.3 { boom = true }
            if let c = TerrainShape.ceiling(p.pos.x, p.pos.z), p.pos.y > c - 0.3 { boom = true }

            // Birds
            if !boom {
                let seg = p.pos - prev
                let l2 = max(simd_length_squared(seg), 1e-6)
                for t in targets where t.id != p.owner {
                    let k = clamp(simd_dot(t.pos - prev, seg) / l2, 0, 1)
                    let d = simd_distance(prev + seg * k, t.pos)
                    guard d < p.radius + t.radius else { continue }
                    boom = true
                    if !p.cosmetic {
                        let push = simd_normalize(simd_normalize(p.vel) + SIMD3(0, 0.3, 0))
                        hits.append(HitReport(from: p.owner, to: t.id, damage: p.spec.damage, impulse: push * p.spec.knock,
                                              burn: p.spec.burn, source: .shot, weapon: p.weapon))
                    }
                    // A gust keeps going and can shove several birds.
                    if p.weapon == .gust { boom = false; p.life = min(p.life, 0.25) }
                    break
                }
            }

            if boom && p.spec.blast > 0 && !p.cosmetic {
                for t in targets where t.id != p.owner && !hits.contains(where: { $0.to == t.id && $0.from == p.owner && $0.source == .shot }) {
                    let d = simd_distance(t.pos, p.pos)
                    guard d < p.spec.blast else { continue }
                    let f = 1 - d / p.spec.blast
                    let away = d > 0.1 ? (t.pos - p.pos) / d : SIMD3(0, 1, 0)
                    hits.append(HitReport(from: p.owner, to: t.id, damage: p.spec.damage * 0.6 * f, impulse: away * p.spec.knock * f,
                                          burn: p.spec.burn * f, source: .shot, weapon: p.weapon))
                }
            }

            p.node.simdPosition = p.pos
            if simd_length(p.vel) > 0.1 { p.node.simdOrientation = simd_quatf(from: SIMD3(0, 0, -1), to: simd_normalize(p.vel)) }
            if p.weapon == .gust {
                let s = p.radius / p.spec.radius
                p.node.simdScale = SIMD3(repeating: s)
                p.node.opacity = CGFloat(clamp(p.life / 0.4, 0, 1) * 0.9)
            }

            if boom || p.life <= 0 {
                if boom || p.spec.blast > 0 { explode(p.weapon, at: p.pos, listener: listener, sound: sound) }
                release(p.weapon, p.node)
                projectiles.remove(at: i)
            } else {
                projectiles[i] = p
            }
        }

        for i in effects.indices.reversed() {
            effects[i].2 -= dt
            if effects[i].2 <= 0 {
                let (n, w, _) = effects[i]
                n.removeFromParentNode()
                burstPool[w, default: []].append(n)
                effects.remove(at: i)
            }
        }
        return hits
    }

    func clear() {
        for p in projectiles { release(p.weapon, p.node) }
        projectiles.removeAll()
    }

    var activeCount: Int { projectiles.count }

    // MARK: Sounds & effects

    private func playLaunch(_ w: WeaponKind, at p: SIMD3<Float>, listener: SIMD3<Float>, sound: SoundEngine?) {
        let g = smoothstep(260, 5, simd_distance(p, listener))
        guard g > 0.01 else { return }
        switch w {
        case .pebble, .seeds, .feathers: sound?.gunshot(gain: g * 0.45, pan: 0)
        case .gust, .missiles, .fire: sound?.whiz(gain: g * 0.8)
        }
    }

    private func explode(_ w: WeaponKind, at p: SIMD3<Float>, listener: SIMD3<Float>, sound: SoundEngine?) {
        let g = smoothstep(300, 10, simd_distance(p, listener))
        if g > 0.01 {
            if w == .missiles { sound?.eruption(g * 0.35) } else if w == .fire { sound?.eruption(g * 0.25) }
        }
        // Reuse a finished burst of the same kind instead of building a new particle system every time.
        let n: SCNNode
        if let pooled = burstPool[w]?.popLast() {
            n = pooled
        } else {
            n = Combat.burst(w)
        }
        n.simdPosition = p
        n.particleSystems?.first?.reset()
        root.addChildNode(n)
        effects.append((n, w, 1.0))
    }

    /// Every projectile model and spark burst, for compiling their shaders before the first shot
    /// (so the first fireball doesn't hitch).
    static func warmupNodes() -> [SCNNode] {
        WeaponKind.allCases.flatMap { [model($0), burst($0)] }
    }

    /// A one-shot spray of sparks for a projectile hitting something.
    private static func burst(_ w: WeaponKind) -> SCNNode {
        let color: NSColor
        var size: CGFloat = 1.4
        switch w {
        case .missiles: color = NSColor(srgbRed: 1, green: 0.62, blue: 0.2, alpha: 1); size = 3.2
        case .fire: color = NSColor(srgbRed: 1, green: 0.42, blue: 0.08, alpha: 1); size = 2.8
        case .gust: color = NSColor(white: 1, alpha: 0.7); size = 2.5
        case .seeds: color = NSColor(srgbRed: 0.85, green: 0.72, blue: 0.45, alpha: 1); size = 0.6
        default: color = NSColor(srgbRed: 0.8, green: 0.75, blue: 0.65, alpha: 1)
        }
        let big = w == .missiles || w == .fire
        let ps = SCNParticleSystem()
        ps.loops = false
        ps.emissionDuration = 0.05
        ps.birthRate = big ? 360 : 240
        ps.particleLifeSpan = big ? 0.6 : 0.35
        ps.particleLifeSpanVariation = 0.15
        ps.emitterShape = SCNSphere(radius: 0.3)
        ps.birthLocation = .surface
        ps.spreadingAngle = 180
        ps.particleVelocity = size * 5
        ps.particleVelocityVariation = size * 2.5
        ps.particleSize = size * 0.42
        ps.particleSizeVariation = size * 0.15
        ps.particleColor = color
        ps.particleImage = Combat.dot
        ps.blendMode = w == .seeds || w == .pebble ? .alpha : .additive
        ps.isLightingEnabled = false
        ps.particleIntensity = 1.4
        let fade = CAKeyframeAnimation()
        fade.values = [1, 0.8, 0]
        fade.keyTimes = [0, 0.4, 1]
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        let n = SCNNode()
        n.addParticleSystem(ps)
        n.castsShadow = false
        return n
    }

    static let dot: CGImage = makeImage(width: 32, height: 32) { x, y in
        let d = simd_length(SIMD2(Float(x) - 15.5, Float(y) - 15.5)) / 16
        return SIMD4(1, 1, 1, max(0, 1 - d) * max(0, 1 - d))
    }

    // MARK: Projectile models

    private func acquire(_ w: WeaponKind) -> SCNNode {
        if let n = pools[w]?.popLast() {
            n.isHidden = false
            n.opacity = 1
            n.simdScale = SIMD3(repeating: 1)
            for ps in n.particleSystems ?? [] { ps.reset() }
            n.childNodes.forEach { c in c.particleSystems?.forEach { $0.reset() } }
            root.addChildNode(n)
            return n
        }
        let n = Combat.model(w)
        root.addChildNode(n)
        return n
    }

    private func release(_ w: WeaponKind, _ n: SCNNode) {
        n.isHidden = true
        n.removeFromParentNode()
        pools[w, default: []].append(n)
    }

    private static func glow(_ c: NSColor, _ intensity: CGFloat = 1.6) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c
        m.diffuse.intensity = intensity
        return m
    }

    /// Trail particles per second for each projectile.
    static func trailRate(_ w: WeaponKind) -> CGFloat {
        switch w {
        case .pebble: return 40
        case .seeds: return 0
        case .gust: return 70
        case .feathers: return 60
        case .missiles: return 50
        case .fire: return 60
        }
    }

    private static func trail(_ color: NSColor, size: CGFloat, life: CGFloat, rate: CGFloat, additive: Bool, grow g: CGFloat = 2.2) -> SCNParticleSystem {
        let ps = SCNParticleSystem()
        ps.birthRate = rate
        ps.particleLifeSpan = life
        ps.particleLifeSpanVariation = life * 0.3
        ps.particleSize = size
        ps.particleSizeVariation = size * 0.3
        ps.particleColor = color
        ps.particleImage = dot
        ps.blendMode = additive ? .additive : .alpha
        ps.isLightingEnabled = false
        ps.emitterShape = SCNSphere(radius: 0.1)
        ps.particleVelocity = 0.5
        ps.spreadingAngle = 180
        let fade = CAKeyframeAnimation()
        fade.values = [0.9, 0]
        fade.keyTimes = [0, 1]
        let grow = CAKeyframeAnimation()
        grow.values = [1, g]
        grow.keyTimes = [0, 1]
        ps.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade),
                                  .size: SCNParticlePropertyController(animation: grow)]
        return ps
    }

    /// Projectile models point along -Z.
    static func model(_ w: WeaponKind) -> SCNNode {
        let n = SCNNode()
        n.castsShadow = false
        switch w {
        case .pebble:
            let g = SCNSphere(radius: 0.32)
            g.segmentCount = 10
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(srgbRed: 0.62, green: 0.58, blue: 0.52, alpha: 1)
            m.emission.contents = NSColor(white: 0.35, alpha: 1)
            m.roughness.contents = 0.9
            g.materials = [m]
            n.addChildNode(SCNNode(geometry: g))
            n.addParticleSystem(trail(NSColor(white: 1, alpha: 0.5), size: 0.25, life: 0.25, rate: trailRate(.pebble), additive: false))
        case .seeds:
            let g = SCNSphere(radius: 0.16)
            g.segmentCount = 8
            g.materials = [glow(NSColor(srgbRed: 0.95, green: 0.82, blue: 0.5, alpha: 1), 1.3)]
            let s = SCNNode(geometry: g)
            s.scale = SCNVector3(0.8, 0.8, 1.4)
            n.addChildNode(s)
        case .gust:
            let t = SCNTorus(ringRadius: 2.2, pipeRadius: 0.35)
            t.ringSegmentCount = 32
            t.pipeSegmentCount = 8
            let m = glow(NSColor(white: 1, alpha: 0.55), 1.2)
            m.blendMode = .add
            m.writesToDepthBuffer = false
            t.materials = [m]
            let ring = SCNNode(geometry: t)
            ring.eulerAngles.x = .pi / 2
            n.addChildNode(ring)
            let inner = SCNNode(geometry: SCNTorus(ringRadius: 1.3, pipeRadius: 0.22))
            inner.geometry?.materials = [m]
            inner.eulerAngles.x = .pi / 2
            inner.position = SCNVector3(0, 0, 1.4)
            n.addChildNode(inner)
            n.addParticleSystem(trail(NSColor(white: 1, alpha: 0.35), size: 1.1, life: 0.35, rate: trailRate(.gust), additive: true))
        case .feathers:
            let g = SCNBox(width: 0.1, height: 0.03, length: 0.9, chamferRadius: 0.015)
            g.materials = [glow(NSColor(srgbRed: 0.75, green: 0.9, blue: 1, alpha: 1), 2)]
            n.addChildNode(SCNNode(geometry: g))
            let vane = SCNNode(geometry: SCNBox(width: 0.28, height: 0.02, length: 0.35, chamferRadius: 0.01))
            vane.geometry?.materials = g.materials
            vane.position = SCNVector3(0, 0, 0.3)
            n.addChildNode(vane)
            n.addParticleSystem(trail(NSColor(srgbRed: 0.6, green: 0.85, blue: 1, alpha: 0.7), size: 0.18, life: 0.2, rate: trailRate(.feathers), additive: true))
        case .missiles:
            let body = SCNCapsule(capRadius: 0.16, height: 1.2)
            let m = SCNMaterial()
            m.lightingModel = .physicallyBased
            m.diffuse.contents = NSColor(white: 0.85, alpha: 1)
            m.metalness.contents = 0.5
            m.roughness.contents = 0.4
            body.materials = [m]
            let b = SCNNode(geometry: body)
            b.eulerAngles.x = .pi / 2
            n.addChildNode(b)
            let tip = SCNNode(geometry: SCNSphere(radius: 0.17))
            tip.geometry?.materials = [glow(NSColor(srgbRed: 1, green: 0.25, blue: 0.2, alpha: 1), 1.8)]
            tip.position = SCNVector3(0, 0, -0.55)
            n.addChildNode(tip)
            let flame = SCNNode(geometry: SCNSphere(radius: 0.2))
            flame.geometry?.materials = [glow(NSColor(srgbRed: 1, green: 0.8, blue: 0.4, alpha: 1), 3)]
            flame.position = SCNVector3(0, 0, 0.62)
            n.addChildNode(flame)
            let smoke = SCNNode()
            smoke.position = SCNVector3(0, 0, 0.7)
            smoke.addParticleSystem(trail(NSColor(white: 0.85, alpha: 0.55), size: 0.6, life: 1.0, rate: trailRate(.missiles), additive: false))
            n.addChildNode(smoke)
        case .fire:
            let g = SCNSphere(radius: 0.55)
            g.segmentCount = 12
            g.materials = [glow(NSColor(srgbRed: 1, green: 0.6, blue: 0.15, alpha: 1), 3)]
            n.addChildNode(SCNNode(geometry: g))
            let core = SCNNode(geometry: SCNSphere(radius: 0.3))
            core.geometry?.materials = [glow(NSColor(srgbRed: 1, green: 0.95, blue: 0.7, alpha: 1), 4)]
            n.addChildNode(core)
            n.addParticleSystem(trail(NSColor(srgbRed: 1, green: 0.45, blue: 0.08, alpha: 1), size: 0.7, life: 0.35, rate: trailRate(.fire), additive: true, grow: 1.6))
        }
        return n
    }
}

// MARK: - Health

/// Health, burning and knock-out state for one bird (the local player or a bot).
struct Fighter {
    static let maxHealth: Float = 100
    static let startLives = 3
    var health: Float = Fighter.maxHealth
    var lives = Fighter.startLives
    var burn: Float = 0
    var burnTime: Float = 0
    var burnFrom = 0
    var cooldown: Float = 0
    var lastAttacker = 0
    var lastHitTime: Float = -100
    /// Last time a hit shoved the bird (hits close together only shove a little).
    var lastKnockTime: Float = -100
    /// Seconds of spawn protection left.
    var shield: Float = 0
    var alive: Bool { health > 0 }
    /// Out of lives (fights).
    var eliminated: Bool { lives <= 0 }

    /// Back to full health with a moment of spawn protection (lives are kept).
    mutating func reset(shield s: Float = 2) {
        health = Fighter.maxHealth; burn = 0; burnTime = 0; cooldown = 0; lastAttacker = 0; shield = s
    }

    /// A fresh round.
    mutating func newRound() { reset(); lives = Fighter.startLives }

    /// Returns true if this hit knocked the bird out.
    mutating func take(_ h: HitReport, now: Float) -> Bool {
        guard alive, shield <= 0 else { return false }
        health -= h.damage
        if h.burn > 0 { burn = max(burn, h.burn); burnTime = 3; burnFrom = h.from }
        if h.from != 0 { lastAttacker = h.from }
        lastHitTime = now
        return health <= 0
    }

    /// How much of a shove to apply now: full, or a little if the last one was very recent.
    mutating func knockScale(now: Float) -> Float {
        defer { lastKnockTime = now }
        return now - lastKnockTime < 0.45 ? 0.25 : 1
    }

    mutating func heal(_ amount: Float) { health = min(Fighter.maxHealth, health + amount); burn = 0; burnTime = 0 }

    /// Ticks burning and timers; returns true if the burn knocked the bird out.
    mutating func tick(_ dt: Float) -> Bool {
        cooldown = max(0, cooldown - dt)
        shield = max(0, shield - dt)
        guard alive, burnTime > 0 else { return false }
        burnTime -= dt
        health -= burn * dt
        if burnTime <= 0 { burn = 0 }
        if health <= 0 { lastAttacker = burnFrom; return true }
        return false
    }
}
