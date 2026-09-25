import SceneKit
import simd

/// Races, fights, other birds and the network — everything layered on top of free flight.
extension Game {
    var isKnockedOut: Bool { !fighter.alive }
    var weaponSpec: WeaponSpec { species.weapon.scaled(attack: combatTuning.attack) }

    private func notice(_ text: String) {
        guard let cb = onNotice else { return }
        DispatchQueue.main.async { cb(text) }
    }

    private func name(of id: Int) -> String {
        if id == localId { return "You" }
        if let b = bots.first(where: { $0.id == id }) { return b.avatar.name }
        return others[id]?.name ?? peers.first { $0.id == id }?.name ?? "Someone"
    }

    // MARK: Starting and restarting

    /// N / Restart: what "start over" means depends on the mode.
    func requestRestart() {
        switch mode {
        case .freeRoam:
            fighter.reset(); respawnIn = 0
            respawn()
        case .ringRace, .speedRace:
            if !multiplayer { restartMatch(); return }
            if phase == .running && participating && finishTime == nil { backOnCourse() } else if phase != .countdown { enterWarmup() }
        case .pvp:
            if !multiplayer { restartMatch(); return }
            if phase == .warmup { enterWarmup() }
        }
    }

    private func resetRound() {
        phase = .warmup
        clock = 0
        nextGate = 0
        gateStates = [:]
        penalty = 0
        gatesPassed = 0
        gatesMissed = 0
        splits = []
        pathHint = 0
        progressS = 0
        offCourseFor = 0
        lastSafeS = 0
        finishTime = nil
        splitText = nil
        recording = nil
        knockedOut = []
        knockouts = 0
        hitsLanded = 0
        spectating = nil
        respawnIn = 0
        fightClock = 0
        participating = true
        banner = nil
        fighter.newRound()
        lockTarget = nil
        reticle.isHidden = true
        combat.clear()
        track?.refresh(next: 0, states: [:])
        arena?.reset()
        orbs?.reset()
    }

    /// Put the local bird on its start spot for `slot`.
    private func placeOnGrid(_ slot: Int, fighters: Int) {
        if let track {
            let (p, yaw) = track.gridPose(slot: slot)
            place(at: p, yaw: yaw, speed: 14)
            pathHint = 0
        } else if let arena {
            let (p, yaw) = arena.spawn(slot: slot, count: fighters, spawnYaw: spawn.1)
            place(at: p, yaw: yaw, speed: 16)
        } else {
            respawn()
        }
    }

    /// Single player: straight into a countdown (bots join fights).
    func restartMatch() {
        resetRound()
        slot = 0
        if mode == .pvp {
            if bots.isEmpty { spawnBots(BotSettings.count) }
            for (i, b) in bots.enumerated() {
                let (p, yaw) = arena!.spawn(slot: i + 1, count: bots.count + 1, spawnYaw: spawn.1)
                b.place(p, yaw: yaw)
            }
            rules.showLocation = true
        }
        placeOnGrid(0, fighters: bots.count + 1)
        phase = .countdown
        countdownLeft = 3
        ghost?.bird.node.removeFromParentNode()
        ghost = nil
        if mode.isRace, let run = bestRun {
            let g = GhostBird(run: run)
            scene.rootNode.addChildNode(g.bird.node)
            ghost = g
            g.update(time: 0, dt: 1)
        }
    }

    /// LAN: fly around freely until the host starts the next round.
    func enterWarmup() {
        resetRound()
        placeOnGrid(slot, fighters: max(peers.count, 2))
        if mode == .freeRoam { respawn() }
    }

    /// LAN: the host started a round.
    func startMatch(id: Int, countdown: Double, slot: Int) {
        resetRound()
        matchId = id
        self.slot = slot
        placeOnGrid(slot, fighters: max(peers.count, 2))
        phase = .countdown
        countdownLeft = Float(countdown)
    }

    /// LAN: the host sent the results.
    func endMatch() {
        phase = .done
        banner = nil
        if !fighter.alive { fighter.reset() }
        spectating = nil
        participating = true
    }

    /// Joined in the middle of a round: watch until the next one.
    func joinAsSpectator() {
        participating = false
        banner = "Round in progress — you'll join the next one"
    }

    func setBest(time: Double?, run: GhostRun?) {
        bestTime = time
        bestRun = run
        bestSplits = run?.splits ?? []
    }

    // MARK: Bots

    func spawnBots(_ n: Int) {
        var rng = SplitMix64(seed: UInt64(Date().timeIntervalSince1970 * 1000))
        let tier = Catalog.playable.firstIndex { $0.id == species.id } ?? 0
        var names = BotPilot.names.shuffled(using: &rng)
        var colors = Array(0..<NameColors.all.count).shuffled(using: &rng)
        let level = BotSettings.difficulty
        colors.removeAll { $0 == Game.playerColor }
        for i in 0..<n {
            // Birds around your own tier (a notch lower on Easy, higher on Hard), so fights are fair.
            let pick = clamp(tier + (level - 1) + Int(rng.float(-1.5, 1.99)), 0, Catalog.playable.count - 1)
            let sp = Catalog.playable[pick]
            let skill: Float = [rng.float(0.05, 0.3), rng.float(0.35, 0.7), rng.float(0.75, 1.0)][level]
            let upgrades = [0, Int(rng.float(0, Float(sp.maxLevel) * 0.6 + 0.99)), sp.maxLevel][level]
            let b = BotPilot(id: 100 + i, name: names.removeFirst(), color: colors.removeFirst(), species: sp,
                             levels: upgrades, skill: skill, seed: rng.next())
            bots.append(b)
            othersRoot.addChildNode(b.avatar.root)
        }
    }

    // MARK: Per frame

    func updateMatch(dt: Float, prev: SIMD3<Float>) {
        matchWarning = nil
        splitTimer = max(0, splitTimer - dt)
        obstacleCooldown = max(0, obstacleCooldown - dt)
        wallCooldown = max(0, wallCooldown - dt)

        if phase == .countdown {
            let before = countdownLeft
            countdownLeft -= dt
            if ceil(before) != ceil(countdownLeft) && countdownLeft > 0 { sound?.beep(go: false) }
            if countdownLeft <= 0 {
                phase = .running
                clock = 0
                flight.speed = 20
                sound?.beep(go: true)
                if mode.isRace && !multiplayer { recording = GhostRun(); recording?.bird = species.id; recordTimer = 0 }
            }
        } else if phase == .running {
            clock += Double(dt)
            fightClock += dt
            if mode == .pvp && fightClock >= Game.fightLimit { checkFightOverTime() }
        }

        // Out of the fight: ← / → switch who you're watching.
        if spectating != nil {
            let (l, r) = (keys.left, keys.right)
            if (l && !spectateKeys.0) || (r && !spectateKeys.1) {
                let live = liveFighters()
                if let cur = spectating, let i = live.firstIndex(of: cur), live.count > 1 {
                    spectating = live[(i + (r ? 1 : live.count - 1)) % live.count]
                } else {
                    spectating = live.first
                }
            }
            spectateKeys = (l, r)
        }

        if let track { updateRace(track, dt: dt, prev: prev) }
        if let arena { updateArena(arena, dt: dt) }
        updateFight(dt: dt)
        updateBots(dt: dt)
        checkCollisions(dt: dt)

        // Knocked out outside a fight: come back after a moment.
        if respawnIn > 0 {
            respawnIn -= dt
            if respawnIn <= 0 {
                respawnIn = 0
                fighter.reset()
                if let track, phase == .running {
                    let (p, yaw) = track.resetPose(atArc: lastSafeS)
                    place(at: p, yaw: yaw, speed: 18)
                    pathHint = track.index(atArc: lastSafeS)
                } else if mode == .freeRoam {
                    respawn()
                } else if phase == .running, let (p, yaw) = safeArenaSpot() {
                    place(at: p, yaw: yaw, speed: 16)
                    fighter.reset(shield: 3)
                } else {
                    placeOnGrid(slot, fighters: max(peers.count, 2))
                }
                link?.send(event: .respawned(id: localId))
            }
        }
    }

    // MARK: Races

    private func updateRace(_ track: RaceTrack, dt: Float, prev: SIMD3<Float>) {
        track.update(time: elapsed, dt: dt, near: flight.pos)
        if let g = ghost {
            g.update(time: phase == .running ? Float(clock) : 0, dt: dt)
        }

        // Obstacles are solid in every phase.
        if let push = track.collide(flight.pos, radius: 0.9, time: elapsed) {
            flight.pos += push
            if obstacleCooldown == 0 {
                let n = simd_normalize(push)
                flight.nudge(n * 11 * combatTuning.knockTaken)
                flight.speed *= 0.85
                shake = min(1, shake + 0.6)
                sound?.impact(8, water: false)
                obstacleCooldown = 0.6
            }
        }
        matchWarning = track.warning(flight.pos, time: elapsed)

        let (s, off) = track.nearest(flight.pos, hint: &pathHint)
        if s < progressS + 150 { progressS = max(progressS, s) }
        guard phase == .running, participating, finishTime == nil else { return }

        // Ghost recording (10 Hz).
        if recording != nil {
            recordTimer -= dt
            if recordTimer <= 0 {
                recordTimer += 1 / GhostRun.rate
                recording?.record(pos: flight.pos, rot: flight.orientation, wings: SIMD3(wingState.x, wingState.y, wingState.w))
            }
        }

        // Boost rings.
        for b in track.boosts where b.passed(prev: prev, now: flight.pos) {
            flight.speed = min(flight.speed + 14, flight.tuning.maxSpeed)
            shake = min(1, shake + 0.25)
            sound?.chime()
        }

        // Gates.
        if nextGate < track.gates.count {
            let g = track.gates[nextGate]
            let a = simd_dot(prev - g.center, g.normal), b = simd_dot(flight.pos - g.center, g.normal)
            var passed = false, missed = false
            if a < 0 && b >= 0 {
                let hit = prev + (flight.pos - prev) * (a / (a - b))
                let d = simd_distance(hit, g.center)
                if d < g.radius + 1.2 { passed = true } else if d < g.radius + 80 { missed = true }
            }
            if !passed && !missed && progressS > g.s + (mode == .ringRace ? 110 : 70) { missed = true }
            if passed || missed { resolveGate(track, passed: passed) }
        }

        // Straying too far from the course puts you back on it.
        if off > track.corridor {
            offCourseFor += dt
            if offCourseFor > 3 { backOnCourse() }
        } else {
            offCourseFor = max(0, offCourseFor - dt * 2)
        }
    }

    private func resolveGate(_ track: RaceTrack, passed: Bool) {
        let i = nextGate
        let g = track.gates[i]
        splits.append(clock + penalty)
        if passed {
            gatesPassed += 1
            gateStates[i] = .passed
            sound?.chime()
            lastSafeS = g.s
        } else {
            gatesMissed += 1
            penalty += 5
            gateStates[i] = .missed
            sound?.hit(.wall)
            shake = min(1, shake + 0.3)
            notice(mode == .ringRace ? "Missed ring!  +5 s" : "Missed checkpoint!  +5 s")
            lastSafeS = max(lastSafeS, g.s)
        }
        if i < bestSplits.count {
            let diff = (clock + penalty) - bestSplits[i]
            splitText = String(format: "%@%.2f", diff < 0 ? "−" : "+", abs(diff))
            splitAhead = diff < 0
            splitTimer = 3
        }
        nextGate += 1
        track.refresh(next: nextGate, states: gateStates)
        if nextGate >= track.gates.count { finishRace() }
    }

    private func finishRace() {
        let total = clock + penalty
        finishTime = total
        sound?.chime()
        if var run = recording {
            run.splits = splits
            recording = run
        }
        if multiplayer {
            banner = "Finished in \(raceClock(total))! Waiting for the others…"
            let e = GameEvent.finished(id: localId, time: total)
            link?.send(event: e)
            if let cb = onLocalEvent { DispatchQueue.main.async { cb(e) } }
        } else {
            phase = .done
            let out = MatchOutcome(mode: mode, world: worldID, place: 1, of: 1, time: total, gates: gatesPassed, missed: gatesMissed,
                                   ghost: recording, medals: track?.medalTimes ?? [])
            if let cb = onMatchOver { DispatchQueue.main.async { cb(out) } }
        }
    }

    /// Back to the last gate you passed.
    func backOnCourse() {
        guard let track else { return }
        let (p, yaw) = track.resetPose(atArc: lastSafeS)
        place(at: p, yaw: yaw, speed: 18)
        pathHint = track.index(atArc: lastSafeS)
        progressS = lastSafeS
        offCourseFor = 0
        notice("Back on course")
    }

    // MARK: Fights

    private func updateArena(_ arena: Arena, dt: Float) {
        arena.update(fightTime: phase == .running ? fightClock : nil, time: elapsed)
        orbs?.update(dt: dt, time: elapsed)
        if let push = arena.constrain(flight), participating {
            if wallCooldown == 0 {
                flight.nudge(push * 10 * combatTuning.knockTaken)
                shake = min(1, shake + 0.3)
                sound?.hit(.wall)
                wallCooldown = 1.2
                if phase == .running && fighter.alive {
                    applyToMe(HitReport(from: 0, to: localId, damage: 5, impulse: .zero, source: .border))
                }
            }
        }
        if arena.distanceToWall(flight.pos) < 60 { matchWarning = arena.shrinking ? "The wall is closing in!" : "Arena wall ahead" }
        // Health orbs
        if inCombat, fighter.health < Fighter.maxHealth, let i = orbs?.touching(flight.pos) {
            orbs?.take(i)
            fighter.heal(HealthOrbs.heal)
            sound?.chime()
            notice("+\(Int(HealthOrbs.heal)) health")
            link?.send(event: .pickup(orb: i, by: localId))
        }
    }

    /// Can the local bird shoot / be shot right now?
    var inCombat: Bool {
        guard combatOn, participating, fighter.alive, !paused else { return false }
        if mode == .pvp { return phase == .running || (multiplayer && phase == .warmup) }
        return phase != .countdown
    }

    private func updateFight(dt: Float) {
        guard combatOn else { reticle.isHidden = true; return }
        if fighter.tick(dt) { knockOut(killer: fighter.lastAttacker) }

        // Lock-on: the best bird in a wide cone ahead; attacks home in on it.
        let spec = weaponSpec
        let others = targets(excluding: localId)
        lockTarget = inCombat ? Aim.lock(from: flight.pos, forward: flight.forward, range: spec.range, current: lockTarget, targets: others) : nil
        let locked = others.first { $0.id == lockTarget }
        if let t = locked {
            let d = simd_distance(t.pos, cameraPosition)
            reticle.isHidden = false
            reticle.simdPosition = t.pos
            reticle.simdScale = SIMD3(repeating: max(3, d * 0.07))
            let inRange = simd_distance(t.pos, flight.pos) < spec.range
            reticle.geometry?.firstMaterial?.multiply.contents = inRange ? NSColor(srgbRed: 1, green: 0.3, blue: 0.25, alpha: 1)
                : NSColor(srgbRed: 1, green: 0.9, blue: 0.4, alpha: 1)
        } else {
            reticle.isHidden = true
        }

        // Attack: mouth opened wide (edge from the tracker) or the attack key.
        let c = controls.control
        if lastAttackCount < 0 { lastAttackCount = c.attackCount }
        var trigger = false
        if c.attackCount != lastAttackCount { lastAttackCount = c.attackCount; trigger = true }
        if keys.attack { keys.attack = false; trigger = true }
        if trigger && inCombat && fighter.cooldown <= 0 {
            let dir = locked.map { Aim.lead(from: flight.pos, ownerVel: flight.velocity, spec: spec, target: $0) } ?? flight.forward
            let shot = Shot(owner: localId, weapon: species.weapon, attack: combatTuning.attack, origin: flight.pos + flight.forward * 0.8,
                            dir: dir, ownerVel: flight.velocity, target: locked?.id, assist: true)
            combat.fire(shot, cosmetic: false)
            link?.send(event: .fire(shot))
            fighter.cooldown = spec.cooldown
        }
    }

    /// Birds that can be hit right now.
    func targets(excluding id: Int? = nil) -> [CombatTarget] {
        var t: [CombatTarget] = []
        if inCombat && id != localId { t.append(CombatTarget(id: localId, pos: flight.pos, vel: flight.velocity)) }
        for b in bots where b.fighter.alive && b.id != id {
            t.append(CombatTarget(id: b.id, pos: b.flight.pos, vel: b.flight.velocity))
        }
        for o in others.values where o.alive && !o.spectator && !o.paused && o.id != id {
            t.append(CombatTarget(id: o.id, pos: o.pos, vel: o.vel))
        }
        return t
    }

    /// A start spot as far as possible from everyone else (respawning mid-fight).
    func safeArenaSpot() -> (SIMD3<Float>, Float)? {
        guard let arena else { return nil }
        let everyone = targets()
        var best: ((SIMD3<Float>, Float), Float)?
        for k in 0..<8 {
            let spot = arena.spawn(slot: k, count: 8, spawnYaw: spawn.1)
            guard arena.distanceToWall(spot.0) > 20 else { continue }
            let near = everyone.map { simd_distance($0.pos, spot.0) }.min() ?? 1e9
            if best == nil || near > best!.1 { best = (spot, near) }
        }
        return best?.0 ?? arena.spawn(slot: 0, count: 1, spawnYaw: spawn.1)
    }

    private func updateBots(dt: Float) {
        guard !bots.isEmpty else {
            runCombat(dt: dt)
            return
        }
        var claims: [Int: Int] = [:]
        for b in bots where b.fighter.alive { if let t = b.target { claims[t, default: 0] += 1 } }
        for b in bots {
            if phase == .countdown || phase == .warmup {
                b.hold(dt: dt)
                continue
            }
            if !b.fighter.alive {
                if b.respawnIn > 0 {
                    b.respawnIn -= dt
                    if b.respawnIn <= 0, let (p, yaw) = safeArenaSpot() { b.respawn(p, yaw: yaw) }
                }
                b.step(dt: dt, runtime: runtime, arena: arena)
                continue
            }
            if b.fighter.tick(dt) { botKnockedOut(b, killer: b.fighter.lastAttacker); continue }
            var mine = claims
            if let t = b.target { mine[t, default: 1] -= 1 }
            if let shot = b.think(dt: dt, targets: targets(excluding: b.id), claims: mine, orbs: orbs?.active ?? [], arena: arena,
                                  runtime: runtime) {
                combat.fire(shot, cosmetic: false)
            }
            b.step(dt: dt, runtime: runtime, arena: arena)
            if b.fighter.health < Fighter.maxHealth, let i = orbs?.touching(b.flight.pos) {
                orbs?.take(i)
                b.fighter.heal(HealthOrbs.heal)
            }
        }
        runCombat(dt: dt)
    }

    private func runCombat(dt: Float) {
        var origins: [Int: (SIMD3<Float>, SIMD3<Float>)] = [localId: (flight.pos, flight.forward)]
        for b in bots { origins[b.id] = (b.flight.pos, b.flight.forward) }
        for o in others.values { origins[o.id] = (o.pos, o.forward) }
        let hits = combat.update(dt: dt, targets: targets(), origins: origins, sound: sound, listener: cameraPosition)
        for h in hits { route(h) }
    }

    /// Deliver a hit decided on this machine.
    private func route(_ h: HitReport) {
        if h.from == localId && h.to != localId && h.source == .shot { hitsLanded += 1 }
        if h.to == localId {
            applyToMe(h)
        } else if let b = bots.first(where: { $0.id == h.to }) {
            if b.apply(h, now: elapsed) { botKnockedOut(b, killer: h.from) }
        } else if others[h.to] != nil {
            link?.send(event: .hit(h))
        }
    }

    func applyToMe(_ h: HitReport) {
        guard participating, fighter.alive, !paused else { return }
        debugEvent?(String(format: "hit from %d %@ %@ dmg %.1f knock %.1f", h.from, h.source.rawValue, h.weapon?.rawValue ?? "-",
                           h.damage, simd_length(h.impulse * combatTuning.knockTaken)))
        if h.impulse != .zero && fighter.shield <= 0 {
            // Back-to-back hits only shove a little, so you're never juggled out of control.
            flight.nudge(h.impulse * combatTuning.knockTaken * fighter.knockScale(now: elapsed))
            shake = min(1, shake + (h.source == .ram ? 0.4 : 0.2))
            sound?.hit(h.source == .ram ? .wall : .bullet)
        }
        guard combatOn || h.source == .border, h.damage > 0 else { return }
        if fighter.take(h, now: elapsed) { knockOut(killer: h.from) }
    }

    private func knockOut(killer: Int) {
        fighter.health = 0
        shake = 0.8
        sound?.impact(10, water: false)
        let by = killer != 0 && killer != localId ? " by \(name(of: killer))" : ""
        if mode == .pvp && phase == .running {
            fighter.lives -= 1
            if fighter.lives <= 0 {
                participating = false
                banner = "Out of lives\(by)"
                if !multiplayer { knockedOut.append(localId) }
                spectating = liveFighters().first
                if multiplayer {
                    let e = GameEvent.eliminated(id: localId)
                    link?.send(event: e)
                    if let cb = onLocalEvent { DispatchQueue.main.async { cb(e) } }
                }
            } else {
                respawnIn = 3
                notice("Knocked out\(by)! \(fighter.lives) \(fighter.lives == 1 ? "life" : "lives") left")
            }
            if !multiplayer { checkFightOver() }
        } else {
            respawnIn = 3
            banner = nil
            notice("Knocked out\(by)!")
        }
        if multiplayer {
            let e = GameEvent.died(victim: localId, killer: killer)
            link?.send(event: e)
            if let cb = onLocalEvent { DispatchQueue.main.async { cb(e) } }
        }
    }

    private func botKnockedOut(_ b: BotPilot, killer: Int) {
        guard !knockedOut.contains(b.id) else { return }
        b.fighter.health = 0
        b.fighter.lives -= 1
        if killer == localId {
            knockouts += 1
            if let cb = onKnockout { let n = b.avatar.name; DispatchQueue.main.async { cb(n) } }
        } else if let k = bots.first(where: { $0.id == killer }) {
            k.knockouts += 1
        }
        let who = killer == localId ? "You knocked out \(b.avatar.name)" : "\(b.avatar.name) was knocked out"
        if b.fighter.lives <= 0 {
            knockedOut.append(b.id)
            notice(who + " — they're out!")
        } else {
            b.respawnIn = 3.5
            notice(who + "!")
        }
        if spectating == b.id { spectating = liveFighters().first }
        checkFightOver()
    }

    /// Ids of birds still in the fight (for spectating).
    private func liveFighters() -> [Int] {
        bots.filter { !$0.fighter.eliminated }.map(\.id) + others.values.filter { !$0.spectator }.map(\.id)
    }

    private func checkFightOver() {
        guard mode == .pvp, !multiplayer, phase == .running else { return }
        let meIn = participating && !fighter.eliminated
        let botsIn = bots.filter { !$0.fighter.eliminated }
        let timeUp = fightClock >= Game.fightLimit
        guard (meIn ? 1 : 0) + botsIn.count <= 1 || timeUp else { return }
        phase = .done
        // Still flying first (most lives, then most health), then the last knocked out, and so on.
        var alive: [(Int, Int, Float)] = botsIn.map { ($0.id, $0.fighter.lives, $0.fighter.health) }
        if meIn { alive.append((localId, fighter.lives, fighter.health)) }
        var order = alive.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 > $1.2 }.map(\.0)
        order += knockedOut.reversed()
        let standings = order.enumerated().map { i, id -> Standing in
            if id == localId { return Standing(id: id, name: "You", color: -1, place: i + 1, knockouts: knockouts) }
            let b = bots.first { $0.id == id }!
            return Standing(id: id, name: b.avatar.name, color: b.avatar.colorIndex, place: i + 1, knockouts: b.knockouts,
                            note: b.species.name)
        }
        let place = (order.firstIndex(of: localId) ?? order.count - 1) + 1
        let out = MatchOutcome(mode: mode, world: worldID, place: place, of: order.count, knockouts: knockouts, hits: hitsLanded,
                               standings: standings)
        banner = nil
        reticle.isHidden = true
        if let cb = onMatchOver { DispatchQueue.main.async { cb(out) } }
    }

    /// Single player: time's up.
    private func checkFightOverTime() { checkFightOver() }

    // MARK: Bumping into each other

    private func checkCollisions(dt: Float) {
        for k in ramCooldown.keys { ramCooldown[k]! -= dt }
        let on = multiplayer ? rules.collisions : (mode == .pvp)
        guard on, participating, fighter.alive, !paused, phase != .countdown else { return }
        let me = flight.pos, myV = flight.velocity
        var candidates: [(id: Int, pos: SIMD3<Float>, vel: SIMD3<Float>, bot: BotPilot?)] = []
        for b in bots where b.fighter.alive { candidates.append((b.id, b.flight.pos, b.flight.velocity, b)) }
        for o in others.values where o.alive && !o.spectator && !o.paused { candidates.append((o.id, o.pos, o.vel, nil)) }
        for c in candidates {
            let d = simd_distance(c.pos, me)
            guard d < 2.4, d > 0.01, (ramCooldown[c.id] ?? 0) <= 0 else { continue }
            let n = (c.pos - me) / d
            let closing = simd_dot(myV - c.vel, n)
            guard closing > 1.5 else { continue }
            ramCooldown[c.id] = 0.8
            debugEvent?(String(format: "collision with %d closing %.1f", c.id, closing))
            flight.pos -= n * (2.4 - d) * 0.5
            sound?.impact(min(closing / 2, 12), water: false)
            shake = min(1, shake + 0.3)
            // A big shove for whoever got hit; it only hurts in a fight when it's a real dive-bomb (fast).
            func ram(_ power: Float) -> (Float, Float) {
                (min(8 + closing * 1.1, 34) * power, combatOn && closing > 22 ? (closing - 18) * 0.6 * power : 0)
            }
            let mine = simd_dot(myV, n), theirs = simd_dot(c.vel, -n)
            if mine >= theirs {
                let (k, dmg) = ram(combatTuning.ramPower)
                route(HitReport(from: localId, to: c.id, damage: dmg, impulse: n * k + SIMD3(0, 4, 0), source: .ram))
                flight.nudge(-n * 3 * combatTuning.knockTaken)
            } else if let b = c.bot {
                let (k, dmg) = ram(b.tuning.ramPower)
                applyToMe(HitReport(from: b.id, to: localId, damage: dmg, impulse: -n * k + SIMD3(0, 4, 0), source: .ram))
            }
            // A network player who rammed us sends the hit themselves.
        }
    }

    // MARK: Network

    func tickNetwork(dt: Float, now: Double) {
        guard let link else { return }
        let inbox = link.drain()
        if let p = inbox.peers {
            peers = p
            let ids = Set(p.map(\.id))
            for (id, o) in others where !ids.contains(id) {
                o.root.removeFromParentNode()
                others.removeValue(forKey: id)
            }
            for info in p where info.id != localId {
                if let o = others[info.id] {
                    o.setIdentity(name: info.name, color: info.color)
                } else {
                    let o = OtherBird(id: info.id, name: info.name, color: info.color, species: info.bird)
                    others[info.id] = o
                    othersRoot.addChildNode(o.root)
                }
            }
        }
        if let r = inbox.rules { rules = r }
        for s in inbox.states where s.id != localId { others[s.id]?.push(s, at: now) }
        for e in inbox.events { handle(e) }
    }

    private func handle(_ e: GameEvent) {
        switch e {
        case .fire(let shot):
            if shot.owner != localId { combat.fire(shot, cosmetic: true) }
        case .hit(let h):
            if h.to == localId { applyToMe(h) }
        case .died(let victim, let killer):
            guard victim != localId else { return }
            if killer == localId {
                knockouts += 1
                let n = name(of: victim)
                if let cb = onKnockout { DispatchQueue.main.async { cb(n) } }
                notice("You knocked out \(n)!")
            } else {
                notice(killer != 0 ? "\(name(of: killer)) knocked out \(name(of: victim))" : "\(name(of: victim)) was knocked out")
            }
            if spectating == victim { spectating = liveFighters().first { $0 != victim } }
        case .finished(let id, let time):
            if id != localId { notice("\(name(of: id)) finished — \(raceClock(time))") }
        case .respawned:
            break
        case .eliminated(let id):
            if id != localId { notice("\(name(of: id)) is out!") }
        case .pickup(let orb, _):
            orbs?.take(orb)
        }
    }

    func updateOthers(dt: Float, now: Double) {
        let showLoc = multiplayer ? rules.showLocation : mode == .pvp
        let showHealth = combatOn
        let cam = cameraPosition
        for o in others.values {
            o.interpolate(now: now)
            o.updateVisuals(camera: cam, dt: dt, showLocation: showLoc, showHealth: showHealth)
        }
        for b in bots { b.avatar.updateVisuals(camera: cam, dt: dt, showLocation: showLoc, showHealth: showHealth) }
    }

    func publishState(dt: Float) {
        stateTimer += dt
        guard stateTimer >= 1.0 / 30.0, let link else { return }
        stateTimer = 0
        var f = 0
        if fighter.alive && participating { f |= NetState.alive }
        if paused { f |= NetState.paused }
        if finishTime != nil { f |= NetState.finished }
        if !participating { f |= NetState.spectator }
        if fighter.burnTime > 0 { f |= NetState.burning }
        let prog = Float(nextGate) + (finishTime != nil ? 1 : 0) + (track.map { progressS / max($0.length, 1) } ?? 0) * 0.001
        link.send(state: NetState(id: localId, p: flight.pos, q: flight.orientation.vector, v: flight.velocity, w: wingState,
                                  hp: fighter.health, flags: f, bird: species.id, progress: prog, lives: fighter.lives))
    }

    // MARK: HUD

    func fillMatchStats(_ s: inout HUDStats) {
        s.mode = mode
        s.multiplayer = multiplayer
        s.phase = phase
        s.countdown = countdownLeft
        s.players = others.count + 1
        if let track {
            s.raceTime = finishTime ?? (phase == .running ? clock + penalty : 0)
            s.penalty = penalty
            let n = track.gates.count
            s.gateLabel = (mode == .ringRace ? "Ring" : "Checkpoint") + " \(min(nextGate + 1, n)) / \(n)"
            if nextGate < n && phase != .done {
                (s.ringDistance, s.ringBearing, s.ringAbove) = pointer(to: track.gates[nextGate].center)
            }
            s.offCourse = offCourseFor > 0.3 ? max(0, 3 - offCourseFor) : 0
            if splitTimer > 0 { s.split = splitText; s.splitAhead = splitAhead }
            s.ghost = ghost != nil
            s.medals = track.medalTimes
            if multiplayer && participating {
                let mine = Float(nextGate) + (finishTime != nil ? 1 : 0) + progressS / max(track.length, 1) * 0.001
                let racers = others.values.filter { !$0.spectator }
                let ahead = racers.filter { $0.progress > mine + 0.0005 }.count
                s.place = "\(ordinal(ahead + 1)) of \(racers.count + 1)"
            }
        }
        if combatOn {
            s.combat = true
            s.health = fighter.health
            s.burning = fighter.burnTime > 0
            s.alive = fighter.alive
            let spec = weaponSpec
            s.reload = 1 - clamp(fighter.cooldown / max(spec.cooldown, 0.01), 0, 1)
            s.weaponName = species.weapon.name
            s.mouth = controls.control.mouthOpen
            s.mouthSeen = controls.control.mouthSeen
            s.respawnIn = respawnIn
            s.lives = mode == .pvp ? fighter.lives : 0
            if let l = lockTarget {
                s.lockName = name(of: l)
                let p = others[l]?.pos ?? bots.first { $0.id == l }?.flight.pos ?? flight.pos
                s.lockInRange = simd_distance(p, flight.pos) < spec.range
            }
            if mode == .pvp {
                let otherFighters = bots.count + others.values.filter { !$0.spectator }.count
                s.fighters = otherFighters + 1
                s.fightersLeft = bots.filter { !$0.fighter.eliminated }.count + others.values.filter { !$0.spectator }.count
                    + (participating && !fighter.eliminated ? 1 : 0)
            }
        }
        var b = banner
        if b == nil && multiplayer && phase == .warmup && mode != .freeRoam { b = "Warm-up — waiting for the host to start" }
        if let sp = spectating, mode == .pvp, phase == .running {
            b = (banner ?? "Out") + " — watching \(name(of: sp))" + (liveFighters().count > 1 ? "   (← → to switch)" : "")
        }
        if phase == .countdown {
            switch mode {
            case .ringRace: b = "Fly through every ring in order — each one you miss costs 5 s"
            case .speedRace: b = "Follow the sky road through the checkpoints — blue rings boost you"
            case .pvp: b = "Face a bird to lock on, then open your mouth wide to attack"
            case .freeRoam: break
            }
        }
        if mode == .pvp, let arena {
            s.fightTimeLeft = max(0, Game.fightLimit - fightClock)
            let untilShrink = Arena.holdTime - fightClock
            if phase != .running { s.wallStatus = "" }
            else if untilShrink > 0 { s.wallStatus = "Wall closes in \(Int(ceil(untilShrink))) s" }
            else if arena.radius > arena.baseRadius * Arena.minFraction + 1 { s.wallStatus = "The wall is closing in" }
            else { s.wallStatus = "Arena at its smallest" }
        }
        s.banner = b
        if let w = matchWarning { s.threat = w }

        let showLoc = multiplayer ? rules.showLocation : mode == .pvp
        s.showCompass = showLoc && (!others.isEmpty || !bots.isEmpty)
        if s.showCompass {
            var f = cameraForward
            f.y = 0
            f = simd_length(f) > 1e-3 ? simd_normalize(f) : SIMD3(0, 0, -1)
            let me = flight.pos
            func marker(_ name: String, _ color: Int, _ p: SIMD3<Float>) -> CompassMarker {
                let to = p - me
                let flat = SIMD3(to.x, 0, to.z)
                let fl = simd_length(flat) > 1e-3 ? simd_normalize(flat) : f
                let cross = f.x * fl.z - f.z * fl.x
                return CompassMarker(name: name, color: color, bearing: atan2(cross, simd_dot(f, fl)), distance: simd_length(to), above: to.y)
            }
            for o in others.values where o.alive && !o.spectator { s.markers.append(marker(o.name, o.colorIndex, o.pos)) }
            for bt in bots where bt.fighter.alive { s.markers.append(marker(bt.avatar.name, bt.avatar.colorIndex, bt.flight.pos)) }
        }
    }
}

/// What the game needs from a LAN session.
protocol NetLink: AnyObject {
    var localId: Int { get }
    func send(state: NetState)
    func send(event: GameEvent)
    /// Everything received since the last call.
    func drain() -> NetInbox
}

struct NetInbox {
    var states: [NetState] = []
    var events: [GameEvent] = []
    var peers: [PeerInfo]?
    var rules: MatchRules?
}

struct PeerInfo: Codable, Equatable {
    var id: Int
    var name: String
    var color: Int
    var bird: String
}
