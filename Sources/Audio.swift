import AVFoundation

// MARK: - DSP building blocks

/// Zero-delay-feedback state-variable filter (Cytomic/Simper). `bp` peaks at gain Q.
private struct SVF {
    var ic1: Float = 0, ic2: Float = 0
    var a1: Float = 1, a2: Float = 0, a3: Float = 0

    mutating func set(_ fc: Float, q: Float, sr: Float) {
        let g = tan(Float.pi * min(max(fc, 10), sr * 0.45) / sr)
        let k = 1 / q
        a1 = 1 / (1 + g * (g + k)); a2 = g * a1; a3 = g * a2
    }

    @inline(__always) mutating func tick(_ v0: Float) -> (lp: Float, bp: Float) {
        let v3 = v0 - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, v1)
    }
}

private struct Pink {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0
    @inline(__always) mutating func tick(_ w: Float) -> Float {
        b0 = 0.99765 * b0 + w * 0.0990460
        b1 = 0.96300 * b1 + w * 0.2965164
        b2 = 0.57000 * b2 + w * 1.0526913
        return (b0 + b1 + b2 + w * 0.1848) * 0.2
    }
}

@inline(__always) private func ease(_ cur: Float, _ target: Float, _ rate: Float, _ dt: Float) -> Float {
    cur + (target - cur) * (1 - exp(-rate * dt))
}

// MARK: - Synth

/// All sound is synthesized: layered wind that reacts to speed, diving, banking, stalling and ground
/// proximity; wingbeats that follow the actual wing motion; plus ring chimes and touchdown hits.
final class BirdSynth {
    let sr: Float

    // Inputs, written from the game thread every frame (benign races on floats).
    var airspeed: Float = 0      // m/s
    var tuck: Float = 0          // 0…1
    var stall: Float = 0         // 0…1
    var roll: Float = 0          // rad
    var ground: Float = 0        // 0…1, how close to the ground/water
    var wingDown: (Float, Float) = (0, 0)  // downstroke angular speed per wing, rad/s
    var wingUp: (Float, Float) = (0, 0)    // upstroke angular speed, rad/s
    var volume: Float = 0.85

    // One-shots
    private var chimeT: Float = 10, chimePhase: (Float, Float, Float) = (0, 0, 0)
    private var thump: Float = 0, thumpPhase: Float = 0, thumpFreq: Float = 70
    private var splash: Float = 0

    // World sounds (all silent in World 1)
    var volcanoRumble: Float = 0                // volcano ground rumble 0…1
    // Engine targets for up to 3 planes (fixed-size so the game thread never reallocates what audio reads).
    var engFreqT = SIMD3<Float>(95, 95, 95), engGainT = SIMD3<Float>(0, 0, 0), engPanT = SIMD3<Float>(0, 0, 0)
    var caveAmbience = false
    private var rumbleS: Float = 0
    private var rumbleF = SVF()
    private var boom: Float = 0, boomPhase: Float = 0
    private var blast: Float = 0
    private var blastF = SVF()
    private var engPhase: [Float] = [0, 0, 0], engGain: [Float] = [0, 0, 0], engFreq: [Float] = [95, 95, 95], engPan: [Float] = [0, 0, 0]
    private var engF = [SVF(), SVF(), SVF()]
    private let shotCount = 16
    private let shotT = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private let shotGain = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private let shotPan = UnsafeMutablePointer<Float>.allocate(capacity: 16)
    private var shotNext = 0
    private var shotF = SVF()
    private var whizT: Float = 10, whizGain: Float = 0
    private var whizF = SVF()
    private var hitT: Float = 10, hitKind = 0
    private var hitF = SVF()
    private var dripTimer: Float = 1, dripT: Float = 10, dripFreq: Float = 1800, dripPhase: Float = 0
    private var echo = [Float](repeating: 0, count: 48000)
    private var echoPos = 0
    private var splashFilter = SVF()

    // Smoothed controls
    private var sp: Float = 0, tk: Float = 0, st: Float = 0, rl: Float = 0, gr: Float = 0, vol: Float = 0
    private var gust: Float = 1, gustTarget: Float = 1, gustTimer: Float = 0
    private var buffet: Float = 0
    private var down: (Float, Float) = (0, 0), up: (Float, Float) = (0, 0)

    // Per-voice state
    private var seed: UInt32 = 0x1234567
    private var pinkL = Pink(), pinkR = Pink()
    private var windL = SVF(), windR = SVF(), howl = SVF(), rumble = SVF(), rush = SVF()
    private var whistle1 = SVF(), whistle2 = SVF(), stallF = SVF()
    private var whump = [SVF(), SVF()], thud = [SVF(), SVF()], feather = [SVF(), SVF()], rustle = [SVF(), SVF()]
    private var flutterPhase: (Float, Float) = (0, 0), stallPhase: Float = 0

    // Per-block gains
    private var gWind: Float = 0, gHowl: Float = 0, gRumble: Float = 0, gRush: Float = 0, gWhistle: Float = 0, gStall: Float = 0
    private var gWhump: (Float, Float) = (0, 0), gThud: (Float, Float) = (0, 0), gFeather: (Float, Float) = (0, 0), gRustle: (Float, Float) = (0, 0)
    private var flutterInc: (Float, Float) = (0, 0)

    init(sampleRate: Float) {
        sr = sampleRate
        for i in 0..<16 { shotT[i] = 1; shotGain[i] = 0; shotPan[i] = 0 }
        rumble.set(55, q: 0.7, sr: sr)
        rush.set(3200, q: 0.7, sr: sr)
        stallF.set(1400, q: 1.3, sr: sr)
        for i in 0..<2 {
            feather[i].set(1900, q: 1.1, sr: sr)
            rustle[i].set(850, q: 0.9, sr: sr)
            thud[i].set(110, q: 0.9, sr: sr)
        }
    }

    func chime() { chimeT = 0; chimePhase = (0, 0, 0) }
    func eruption(_ strength: Float) { boom = max(boom, strength); blast = max(blast, strength); boomPhase = 0 }
    func gunshot(gain: Float, pan: Float) {
        let i = shotNext % shotCount
        shotGain[i] = gain; shotPan[i] = pan; shotT[i] = 0
        shotNext = i + 1
    }
    func whiz(gain: Float) { whizT = 0; whizGain = gain }
    /// 0 = lava, 1 = bullet, 2 = wall.
    func hit(_ kind: Int) { hitT = 0; hitKind = kind }
    func impact(_ strength: Float, water: Bool) {
        if water { splash = min(1, 0.35 + strength / 12) } else { thump = min(1, 0.25 + strength / 14); thumpPhase = 0; thumpFreq = 85 }
    }

    @inline(__always) private func white() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(Int32(bitPattern: seed)) / Float(Int32.max)
    }

    private func control(_ dt: Float) {
        sp = ease(sp, airspeed / 60, 5, dt)
        tk = ease(tk, tuck, 6, dt)
        st = ease(st, stall, 5, dt)
        rl = ease(rl, abs(roll), 4, dt)
        gr = ease(gr, ground, 4, dt)
        vol = ease(vol, volume, 6, dt)

        // Wind gusts: a slow random walk so the air never sounds static.
        gustTimer -= dt
        if gustTimer <= 0 {
            gustTarget = 0.7 + 0.3 * (white() + 1)
            gustTimer = 1.0 + 0.6 * white()
        }
        gust = ease(gust, gustTarget, 1.4, dt)
        buffet = ease(buffet, 0.5 + 0.5 * white(), 25, dt)

        let s = min(sp, 1.8)
        windL.set(160 + 2300 * pow(s, 1.5) * (0.8 + 0.3 * gust), q: 0.6, sr: sr)
        windR.set(170 + 2250 * pow(s, 1.5) * (0.8 + 0.3 * gust), q: 0.6, sr: sr)
        gWind = (0.05 + 0.75 * pow(s, 1.6)) * gust * (1 - 0.5 * st)
        howl.set(260 + 420 * s + 120 * gust, q: 2.2, sr: sr)
        gHowl = (0.05 + 0.25 * rl) * pow(s, 1.3) * gust
        gRumble = pow(max(s - 0.45, 0), 1.4) * 2.2 * (0.45 + 0.75 * buffet)
        gRush = gr * pow(s, 1.2) * 0.35
        let wf = 420 + 1500 * s
        whistle1.set(wf, q: 22, sr: sr)
        whistle2.set(wf * 1.53, q: 26, sr: sr)
        gWhistle = (tk * smoothstep(0.35, 1.2, s) + 0.35 * smoothstep(1.1, 1.7, s)) * 0.045
        gStall = st * min(s * 4, 1) * 0.5

        // Wings: envelopes track real wing angular speed; attack fast, release slower.
        let targetsDown = (min(wingDown.0 / 6, 1.5), min(wingDown.1 / 6, 1.5))
        let targetsUp = (min(wingUp.0 / 6, 1.5), min(wingUp.1 / 6, 1.5))
        down.0 = ease(down.0, targetsDown.0, targetsDown.0 > down.0 ? 45 : 10, dt)
        down.1 = ease(down.1, targetsDown.1, targetsDown.1 > down.1 ? 45 : 10, dt)
        up.0 = ease(up.0, targetsUp.0, targetsUp.0 > up.0 ? 30 : 10, dt)
        up.1 = ease(up.1, targetsUp.1, targetsUp.1 > up.1 ? 30 : 10, dt)
        for i in 0..<2 {
            let d = i == 0 ? down.0 : down.1, u = i == 0 ? up.0 : up.1
            whump[i].set(150 + 220 * d, q: 1.3, sr: sr)
            let gw = pow(d, 1.3) * 1.1, gt = pow(d, 1.2) * 2.6, gf = d * 0.1 + u * 0.08, gr2 = u * 0.16
            let inc = 2 * Float.pi * (22 + 26 * d + 16 * u) / sr
            if i == 0 { gWhump.0 = gw; gThud.0 = gt; gFeather.0 = gf; gRustle.0 = gr2; flutterInc.0 = inc }
            else { gWhump.1 = gw; gThud.1 = gt; gFeather.1 = gf; gRustle.1 = gr2; flutterInc.1 = inc }
        }
        splashFilter.set(300 + 2500 * splash, q: 0.7, sr: sr)

        rumbleS = ease(rumbleS, volcanoRumble, 4, dt)
        rumbleF.set(48, q: 0.8, sr: sr)
        blastF.set(250 + 1800 * blast, q: 0.7, sr: sr)
        let gT = engGainT, fT = engFreqT, pT = engPanT
        for i in 0..<3 {
            engGain[i] = ease(engGain[i], gT[i], 6, dt)
            engFreq[i] = ease(engFreq[i], fT[i], 8, dt)
            engPan[i] = ease(engPan[i], pT[i], 8, dt)
            engF[i].set(engFreq[i] * 6, q: 1.2, sr: sr)
        }
        shotF.set(1400, q: 0.8, sr: sr)
        whizF.set(3800 - 2600 * min(whizT / 0.35, 1), q: 3, sr: sr)
        hitF.set(hitKind == 1 ? 900 : 400, q: 0.9, sr: sr)
        if caveAmbience {
            dripTimer -= dt
            if dripTimer <= 0 { dripT = 0; dripPhase = 0; dripFreq = 1400 + 1400 * (white() * 0.5 + 0.5); dripTimer = 0.4 + 2.2 * (white() * 0.5 + 0.5) }
        }
    }

    func render(_ L: UnsafeMutablePointer<Float>, _ R: UnsafeMutablePointer<Float>, _ n: Int) {
        let block = 32
        var i = 0
        let dtS = 1 / sr
        while i < n {
            let m = min(block, n - i)
            control(Float(m) * dtS)
            for j in i..<(i + m) {
                let w1 = white(), w2 = white(), w3 = white(), w4 = white()
                let pl = pinkL.tick(w1), pr = pinkR.tick(w2)

                // Wind layers
                var l = windL.tick(pl).lp * gWind
                var r = windR.tick(pr).lp * gWind
                let h = howl.tick((pl + pr) * 0.5).bp * gHowl
                l += h; r += h
                let rum = rumble.tick(w3).lp * gRumble
                l += rum; r += rum
                let rs = rush.tick(w4).bp * gRush
                l += rs * 0.8; r += rs
                let wh = (whistle1.tick(w3).bp + 0.6 * whistle2.tick(w4).bp) * gWhistle
                l += wh; r += wh
                if gStall > 0.001 {
                    stallPhase += 2 * Float.pi * 13 / sr
                    let am = pow(0.5 + 0.5 * sin(stallPhase), 3)
                    let sv = stallF.tick(w1).bp * am * gStall
                    l += sv; r += sv
                }

                // Wings (left wing favours the left channel)
                for k in 0..<2 {
                    let gw = k == 0 ? gWhump.0 : gWhump.1
                    let gf = k == 0 ? gFeather.0 : gFeather.1
                    let gru = k == 0 ? gRustle.0 : gRustle.1
                    let gt = k == 0 ? gThud.0 : gThud.1
                    if gw + gf + gru + gt < 0.0005 { continue }
                    let src = k == 0 ? w3 : w4
                    var v = whump[k].tick(src).bp * gw + thud[k].tick(src).lp * gt
                    var ph = k == 0 ? flutterPhase.0 : flutterPhase.1
                    ph += (k == 0 ? flutterInc.0 : flutterInc.1) * (0.85 + 0.3 * abs(white()))
                    if ph > 2 * .pi { ph -= 2 * .pi }
                    if k == 0 { flutterPhase.0 = ph } else { flutterPhase.1 = ph }
                    let am = pow(0.5 + 0.5 * sin(ph), 2.5)
                    v += feather[k].tick(src).bp * gf * am
                    v += rustle[k].tick(k == 0 ? w1 : w2).bp * gru * (0.6 + 0.4 * am)
                    if k == 0 { l += v * 0.9; r += v * 0.5 } else { l += v * 0.5; r += v * 0.9 }
                }

                // One-shots
                if chimeT < 1.8 {
                    chimeT += dtS
                    chimePhase.0 += 2 * .pi * 1046.5 * dtS
                    chimePhase.1 += 2 * .pi * 1568.0 * dtS
                    chimePhase.2 += 2 * .pi * 2093.0 * dtS
                    let env = exp(-chimeT * 3.2) * min(1, chimeT * 300)
                    let c = (sin(chimePhase.0) * 0.14 + sin(chimePhase.1) * 0.09 + sin(chimePhase.2) * 0.05 * exp(-chimeT * 6)) * env
                    l += c; r += c
                }
                if thump > 0.0005 {
                    thumpFreq = max(40, thumpFreq - 60 * dtS)
                    thumpPhase += 2 * .pi * thumpFreq * dtS
                    let t = (sin(thumpPhase) * 0.8 + w1 * 0.25) * thump
                    l += t; r += t
                    thump *= 1 - 7 * dtS
                }
                if splash > 0.0005 {
                    let sv = splashFilter.tick(w2).lp * splash * 1.2
                    l += sv * (0.8 + 0.4 * w3); r += sv * (0.8 + 0.4 * w4)
                    splash *= 1 - 2.2 * dtS
                }

                // Volcano: rumble and eruption blasts
                if rumbleS > 0.002 || boom > 0.002 {
                    let rv = rumbleF.tick(w1).lp * rumbleS * 3.2
                    boomPhase += 2 * .pi * 38 * dtS
                    let bv = sin(boomPhase) * boom * 0.7 + blastF.tick(w2).lp * blast * 1.1
                    l += rv + bv; r += rv + bv
                    boom *= 1 - 1.8 * dtS
                    blast *= 1 - 1.2 * dtS
                }
                // Biplane engines: buzzy saw with a propeller throb
                for e in 0..<3 where engGain[e] > 0.002 {
                    engPhase[e] += engFreq[e] * dtS
                    if engPhase[e] > 1 { engPhase[e] -= 1 }
                    let saw = engPhase[e] * 2 - 1
                    let throb = 0.6 + 0.4 * sin(engPhase[e] * 2 * .pi * 0.5)
                    let v = engF[e].tick(saw + w3 * 0.3).bp * engGain[e] * 0.45 * throb
                    l += v * (1 - engPan[e]) * 0.7; r += v * (1 + engPan[e]) * 0.7
                }
                // Machine-gun shots
                for k in 0..<shotCount where shotT[k] < 0.12 {
                    shotT[k] += dtS
                    let env = exp(-shotT[k] * 45) * shotGain[k]
                    let v = (shotF.tick(w4).bp * 1.6 + w4 * 0.25) * env
                    l += v * (1 - shotPan[k] * 0.7); r += v * (1 + shotPan[k] * 0.7)
                }
                if whizT < 0.35 {
                    whizT += dtS
                    let v = whizF.tick(w1).bp * whizGain * 1.4 * sin(Float.pi * whizT / 0.35)
                    l += v; r += v
                }
                if hitT < 0.3 {
                    hitT += dtS
                    let env = exp(-hitT * 16)
                    let v = (hitF.tick(w2).bp * 1.8 + sin(hitT * 2 * .pi * 90) * 0.6) * env
                    l += v; r += v
                }
                // Caves: water drips with a long echo
                var dry: Float = 0
                if dripT < 0.25 {
                    dripT += dtS
                    dripPhase += 2 * .pi * dripFreq * (1 + dripT * 3) * dtS
                    dry = sin(dripPhase) * exp(-dripT * 30) * 0.12
                }
                if caveAmbience {
                    let delayed = echo[echoPos]
                    echo[echoPos] = dry + delayed * 0.45
                    echoPos = (echoPos + 1) % Int(sr * 0.33)
                    l += dry + delayed * 0.8; r += dry * 0.6 + delayed
                }

                L[j] = tanh(l * 0.9) * vol
                R[j] = tanh(r * 0.9) * vol
            }
            i += m
        }
    }
}

// MARK: - Engine wrapper

final class SoundEngine {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode!
    let synth: BirdSynth
    private var muted = false

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sr = rate > 0 ? rate : 48000
        synth = BirdSynth(sampleRate: Float(sr))
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        source = AVAudioSourceNode(format: format) { [synth] _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers.count > 1 ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : l
            synth.render(l, r, Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try? engine.start()
    }

    func setFlight(speed: Float, tuck: Float, stall: Float, roll: Float, ground: Float) {
        synth.airspeed = speed; synth.tuck = tuck; synth.stall = stall; synth.roll = roll; synth.ground = ground
    }
    func setWings(downL: Float, downR: Float, upL: Float, upR: Float) {
        synth.wingDown = (downL, downR); synth.wingUp = (upL, upR)
    }
    func chime() { synth.chime() }
    func impact(_ strength: Float, water: Bool) { synth.impact(strength, water: water) }
    func setMuted(_ m: Bool) { muted = m; synth.volume = m ? 0 : 0.85 }
    func setRumble(_ v: Float) { synth.volcanoRumble = v }
    func eruption(_ strength: Float) { synth.eruption(strength) }
    func setEngines(_ e: [(Float, Float, Float)]) {
        var f = SIMD3<Float>(95, 95, 95), g = SIMD3<Float>(0, 0, 0), p = SIMD3<Float>(0, 0, 0)
        for (i, v) in e.prefix(3).enumerated() { f[i] = v.0; g[i] = v.1; p[i] = v.2 }
        synth.engFreqT = f; synth.engGainT = g; synth.engPanT = p
    }
    func gunshot(gain: Float, pan: Float) { synth.gunshot(gain: gain, pan: pan) }
    func whiz(gain: Float) { synth.whiz(gain: gain) }
    func hit(_ kind: HitKind) { synth.hit(kind == .lava ? 0 : kind == .bullet ? 1 : 2) }
    func setCaveAmbience(_ on: Bool) { synth.caveAmbience = on }
    /// Silence all world-specific loops (used when switching worlds).
    func resetWorld() { synth.volcanoRumble = 0; synth.engGainT = .zero; synth.caveAmbience = false }
}
