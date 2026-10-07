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
    /// Menu / reward sounds have their own volume: they still play in the pause menu (where the world is silenced).
    var uiVolume: Float = 0.85
    private let uiCount = 24
    private let uiT = UnsafeMutablePointer<Float>.allocate(capacity: 24)
    private let uiF = UnsafeMutablePointer<Float>.allocate(capacity: 24)
    private let uiG = UnsafeMutablePointer<Float>.allocate(capacity: 24)
    private let uiLen = UnsafeMutablePointer<Float>.allocate(capacity: 24)
    private var uiNext = 0

    // One-shots
    private var chimeT: Float = 10, chimePhase: (Float, Float, Float) = (0, 0, 0)
    private var beepT: Float = 10, beepFreq: Float = 880, beepPhase: Float = 0, beepLen: Float = 0.16
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

    // Skyline City (and other worlds' ambiences)
    var cityTraffic: Float = 0, cityCrowd: Float = 0, cityTrain: Float = 0, cityTrainPan: Float = 0
    var cityHeli: Float = 0, cityHeliPan: Float = 0, sirenGain: Float = 0, sirenPan: Float = 0
    private var trafficS: Float = 0, crowdS: Float = 0, trainS: Float = 0, heliS: Float = 0, sirenS: Float = 0
    private var trafficF = SVF(), hissF = SVF(), crowdF = SVF(), crowdF2 = SVF(), trainF = SVF(), clackF = SVF(), heliF = SVF()
    private var crowdEnv: Float = 0, crowdTarget: Float = 0, crowdTimer: Float = 0
    private var heliPhase: Float = 0, sirenPhase: Float = 0, sirenSweep: Float = 0, sirenFreq: Float = 700, clackT: Float = 10, clackTimer: Float = 0, clackFlip = false
    private let hornCount = 4
    private let hornT = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let hornG = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let hornP = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let hornPh = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private var hornNext = 0
    private var hornF = SVF()
    private var trainHornT: Float = 10, trainHornPh: (Float, Float, Float) = (0, 0, 0)
    private var flutterT: Float = 10, flutterF = SVF()
    private var shutterT: Float = 10, shutterF = SVF()

    // Creature calls (Dino Valley): a few voices, each a growl, bellow, honk, shriek or footfall.
    private let callCount = 8
    private let callKind = UnsafeMutablePointer<Int>.allocate(capacity: 8)
    private let callT = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let callLen = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let callGain = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let callPan = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let callPitch = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let callPh = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let callF1 = UnsafeMutablePointer<SVF>.allocate(capacity: 8)
    private let callF2 = UnsafeMutablePointer<SVF>.allocate(capacity: 8)
    private var callNext = 0
    // The Wild West: the saloon piano, the steam train, coyotes, the church bell.
    var pianoGain: Float = 0
    private var pianoS: Float = 0, pianoClock: Float = 0, pianoStep = -1
    private let pvCount = 12
    private let pvT = UnsafeMutablePointer<Float>.allocate(capacity: 12)
    private let pvF = UnsafeMutablePointer<Float>.allocate(capacity: 12)
    private let pvG = UnsafeMutablePointer<Float>.allocate(capacity: 12)
    private let pvP = UnsafeMutablePointer<Float>.allocate(capacity: 24)
    private var pvNext = 0
    var westTrain: Float = 0, westTrainPan: Float = 0, westTrainRate: Float = 1
    private var westTrainS: Float = 0, chuffPhase: Float = 0, chuffT: Float = 10
    private var chuffF = SVF(), rumbleWF = SVF(), whistleNoiseF = SVF()
    private var whistleT: Float = 10, whistleG: Float = 0, whistlePh: (Float, Float, Float) = (0, 0, 0)
    private var coyoteT: Float = 10, coyoteG: Float = 0, coyoteP: Float = 0, coyotePh: Float = 0
    private var bellT: Float = 10, bellG: Float = 0, bellPh: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
    // The jungle: insects, birdsong, the river.
    var jungle: Float = 0, jungleWater: Float = 0
    private var jungleS: Float = 0, waterS: Float = 0
    private var insectF = SVF(), insectF2 = SVF(), waterF = SVF()
    private var insectPh: Float = 0, insectPh2: Float = 0, insectSwell: Float = 0.5, insectSwellT: Float = 0.5
    private var chirpT: Float = 10, chirpTimer: Float = 1.5, chirpF: Float = 2500, chirpPh: Float = 0, chirpPan: Float = 0, chirpGlide: Float = 1

    // 1.0: the jetpack, The Finale's march, crowds and fireworks, the crowning choir, the title theme.
    var jetGain: Float = 0, jetSpeed: Float = 0
    private var jetS: Float = 0, jetSp: Float = 0, jetF = SVF(), jetLowF = SVF(), jetWhinePh: Float = 0, igniteT: Float = 10, igniteF = SVF()
    var finaleMusic: Float = 0, titleMusic: Float = 0, crowdCheer: Float = 0
    private var musicS: Float = 0, musicClock: Float = 0, musicStep = -1
    private var titleS: Float = 0, titleClock: Float = 0, titleStep = -1
    // Enough voices for the march and a fanfare at once (a stolen voice cuts its note off with a click).
    private let brCount = 32
    private let brT = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    private let brF = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    private let brG = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    private let brLen = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    private let brP = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    private var brNext = 0
    private var brassF = SVF(), brassF2 = SVF()
    private var timpT: Float = 10, timpF: Float = 65, timpPh: Float = 0, timpG: Float = 0
    private var cheerS: Float = 0, cheerF = SVF(), cheerF2 = SVF(), cheerEnv: Float = 0, cheerTarget: Float = 0, cheerTimer: Float = 0
    // Applause: a handful of clappers, each on its own loose rhythm (one clap retriggered fast just buzzes).
    private let clapCount = 10
    private let clapTs = UnsafeMutablePointer<Float>.allocate(capacity: 10)
    private let clapTimers = UnsafeMutablePointer<Float>.allocate(capacity: 10)
    private let clapGs = UnsafeMutablePointer<Float>.allocate(capacity: 10)
    private var clapF = SVF()
    private let fwCount = 8
    private let fwT = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let fwG = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private let fwP = UnsafeMutablePointer<Float>.allocate(capacity: 8)
    private var fwNext = 0
    private var fwF = SVF(), fwCrackleF = SVF()
    private var choirT: Float = 10, choirG: Float = 0, choirPh: (Float, Float, Float, Float) = (0, 0, 0, 0), choirF1 = SVF(), choirF2 = SVF()

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
        for i in 0..<4 { hornT[i] = 10; hornG[i] = 0; hornP[i] = 0 }
        for i in 0..<8 { hornPh[i] = 0 }
        trafficF.set(140, q: 0.7, sr: sampleRate); hissF.set(1200, q: 0.8, sr: sampleRate)
        crowdF.set(420, q: 1.6, sr: sampleRate); crowdF2.set(900, q: 2.2, sr: sampleRate)
        trainF.set(70, q: 0.8, sr: sampleRate); clackF.set(1800, q: 1.2, sr: sampleRate)
        heliF.set(320, q: 0.9, sr: sampleRate); hornF.set(1100, q: 0.9, sr: sampleRate)
        flutterF.set(2200, q: 1.4, sr: sampleRate); shutterF.set(4500, q: 1.0, sr: sampleRate)
        for i in 0..<8 {
            callKind[i] = 0; callT[i] = 10; callLen[i] = 0; callGain[i] = 0; callPan[i] = 0; callPitch[i] = 1; callPh[i] = 0
            callF1[i] = SVF(); callF2[i] = SVF()
        }
        insectF.set(4600, q: 6, sr: sampleRate); insectF2.set(6900, q: 8, sr: sampleRate); waterF.set(700, q: 0.7, sr: sampleRate)
        for i in 0..<12 { pvT[i] = 10; pvF[i] = 220; pvG[i] = 0 }
        for i in 0..<brCount { brT[i] = 10; brF[i] = 220; brG[i] = 0; brLen[i] = 0; brP[i] = 0 }
        for i in 0..<clapCount { clapTs[i] = 1; clapTimers[i] = Float(i) * 0.07; clapGs[i] = 1 }
        for i in 0..<8 { fwT[i] = 10; fwG[i] = 0; fwP[i] = 0 }
        jetF.set(500, q: 0.8, sr: sampleRate); jetLowF.set(90, q: 0.7, sr: sampleRate); igniteF.set(220, q: 0.7, sr: sampleRate)
        brassF.set(2300, q: 1.1, sr: sampleRate); brassF2.set(1100, q: 1.8, sr: sampleRate)
        cheerF.set(1100, q: 1.4, sr: sampleRate); cheerF2.set(2300, q: 2.0, sr: sampleRate); clapF.set(2600, q: 0.9, sr: sampleRate)
        fwF.set(70, q: 0.8, sr: sampleRate); fwCrackleF.set(3800, q: 1.2, sr: sampleRate)
        choirF1.set(720, q: 4, sr: sampleRate); choirF2.set(1150, q: 5, sr: sampleRate)
        for i in 0..<24 { pvP[i] = 0 }
        chuffF.set(620, q: 1.1, sr: sampleRate); rumbleWF.set(85, q: 0.7, sr: sampleRate); whistleNoiseF.set(1300, q: 2, sr: sampleRate)
        for i in 0..<24 { uiT[i] = 10; uiF[i] = 440; uiG[i] = 0; uiLen[i] = 0 }
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

    /// A soft bell note for the menus (`delay` seconds from now).
    func uiNote(_ freq: Float, delay: Float = 0, length: Float = 0.4, gain: Float = 0.1) {
        let i = uiNext % uiCount
        uiF[i] = freq; uiG[i] = gain; uiLen[i] = length; uiT[i] = -delay
        uiNext = i + 1
    }
    /// Bought something: a quick rising arpeggio.
    func purchase() {
        for (k, f) in [523.25, 659.25, 783.99, 1046.5].enumerated() { uiNote(Float(f), delay: Float(k) * 0.065, length: 0.45, gain: 0.1) }
    }
    /// Finished a goal: a little fanfare with a sparkle on top.
    func fanfare() {
        for (k, f) in [392.0, 523.25, 659.25].enumerated() { uiNote(Float(f), delay: Float(k) * 0.11, length: 0.3, gain: 0.1) }
        uiNote(783.99, delay: 0.33, length: 0.9, gain: 0.12)
        uiNote(1046.5, delay: 0.33, length: 0.9, gain: 0.07)
        for k in 0..<4 { uiNote(2093 + Float(k) * 330, delay: 0.45 + Float(k) * 0.06, length: 0.25, gain: 0.03) }
    }
    /// A tutorial step done: two bright notes.
    func success() {
        uiNote(783.99, delay: 0, length: 0.3, gain: 0.09)
        uiNote(1174.66, delay: 0.09, length: 0.5, gain: 0.09)
    }
    func click() { uiNote(1567.98, length: 0.07, gain: 0.05) }
    /// Countdown blip (a longer, higher one for GO).
    func beep(go: Bool) { beepT = 0; beepPhase = 0; beepFreq = go ? 1318.5 : 659.3; beepLen = go ? 0.45 : 0.16 }
    func eruption(_ strength: Float) { boom = max(boom, strength); blast = max(blast, strength); boomPhase = 0 }
    func gunshot(gain: Float, pan: Float) {
        let i = shotNext % shotCount
        shotGain[i] = gain; shotPan[i] = pan; shotT[i] = 0
        shotNext = i + 1
    }
    func whiz(gain: Float) { whizT = 0; whizGain = gain }
    /// A car horn: two notes, a little out of tune, for a third of a second.
    func horn(gain: Float, pan: Float) {
        let i = hornNext % hornCount
        hornT[i] = 0; hornG[i] = gain; hornP[i] = pan
        hornNext = i + 1
    }
    func trainHorn() { if trainHornT > 2.2 { trainHornT = 0 } }
    func flutter() { flutterT = 0 }

    func steamWhistle(gain: Float) { if whistleT > 1.6 { whistleT = 0; whistleG = gain } }

    /// The jetpack lighting: a deep whoomp.
    func jetIgnite() { igniteT = 0 }
    /// A firework going off `delay` seconds from now (sound takes its time to arrive).
    func firework(gain: Float, pan: Float, delay: Float) {
        let k = fwNext % fwCount
        fwT[k] = -delay; fwG[k] = gain; fwP[k] = pan
        fwNext = k + 1
    }
    /// The crowning: a choir holds a big bright chord for a few seconds.
    func choir(gain: Float) { choirT = 0; choirG = gain }

    /// One brass note (the march, and the heralds' fanfare).
    private func brass(_ midi: Int, gain: Float, length: Float) {
        let k = brNext % brCount
        brNext += 1
        brT[k] = 0; brF[k] = 440 * pow(2, Float(midi - 69) / 12); brG[k] = gain; brLen[k] = length; brP[k] = 0
    }
    /// The heralds' fanfare: a rising call and a held chord. (Set from the game; the audio thread plays it.)
    func heraldFanfare() { fanfareGo = true }
    private var fanfareGo = false
    private var fanfareClock: Float = 10, fanfareNext = 99
    private static let fanfare: [(Float, Int, Float)] = [(0, 67, 0.18), (0.2, 72, 0.18), (0.4, 76, 0.18), (0.6, 79, 0.5), (1.15, 76, 0.18), (1.35, 79, 1.4)]

    /// "The Champion's March" (original): eight bars in C, eighth notes; (step, midi, length in steps) per bar.
    private static let march: [[(Int, Int, Int)]] = [
        [(0, 72, 3), (3, 72, 1), (4, 76, 2), (6, 79, 2)], [(0, 84, 4), (4, 79, 2), (6, 76, 2)],
        [(0, 77, 2), (2, 76, 2), (4, 74, 2), (6, 72, 2)], [(0, 74, 4), (4, 67, 4)],
        [(0, 72, 3), (3, 72, 1), (4, 76, 2), (6, 79, 2)], [(0, 81, 4), (4, 79, 2), (6, 77, 2)],
        [(0, 76, 2), (2, 79, 2), (4, 74, 2), (6, 71, 2)], [(0, 72, 8)],
    ]
    private static let marchChords: [[Int]] = [[48, 60, 64, 67], [48, 60, 64, 67], [53, 60, 65, 69], [55, 59, 62, 67],
                                               [48, 60, 64, 67], [53, 60, 65, 69], [55, 59, 62, 67], [48, 60, 64, 67]]
    /// The title theme (original): a lilting tune in G, six eighths a bar.
    private static let titleTune: [[(Int, Int)]] = [
        [(0, 67), (1, 71), (2, 74), (3, 79), (5, 74)], [(0, 76), (2, 72), (3, 71), (5, 69)],
        [(0, 67), (1, 71), (2, 74), (3, 81), (5, 79)], [(0, 78), (2, 74), (3, 76)],
        [(0, 72), (1, 76), (2, 79), (3, 83), (5, 81)], [(0, 79), (2, 76), (3, 74), (5, 71)],
        [(0, 72), (2, 69), (3, 74), (5, 66)], [(0, 67)],
    ]
    private static let titleBass = [43, 48, 43, 50, 48, 43, 50, 43]
    func coyote(gain: Float, pan: Float) { if coyoteT > 2.5 { coyoteT = 0; coyoteG = gain; coyoteP = pan; coyotePh = 0 } }
    func churchBell(gain: Float) { if bellT > 4 { bellT = 0; bellG = gain } }

    /// An original little rag in C: stride left hand, syncopated tune on top. (step, midi note) per bar, eight steps a bar.
    private static let ragBars: [[(Int, Int)]] = {
        let bass: [(Int, Int, [Int])] = [(36, 43, [60, 64, 67]), (36, 43, [60, 64, 67]), (41, 48, [60, 65, 69]), (41, 48, [60, 65, 69]),
                                         (36, 43, [60, 64, 67]), (43, 38, [59, 62, 65, 67]), (36, 43, [60, 64, 67]), (43, 38, [59, 62, 65, 67])]
        let tune: [[(Int, Int)]] = [[(1, 76), (3, 79), (4, 84), (6, 79)], [(0, 76), (2, 74), (3, 72), (6, 76)],
                                    [(1, 77), (3, 81), (4, 84), (6, 81)], [(0, 77), (2, 79), (3, 81), (5, 77)],
                                    [(1, 79), (2, 76), (4, 72), (6, 76)], [(0, 74), (2, 77), (3, 71), (5, 74)],
                                    [(0, 72), (1, 76), (3, 79), (4, 84)], [(0, 83), (2, 79), (4, 77), (6, 74)]]
        var out: [[(Int, Int)]] = []
        for (b, (root, fifth, chord)) in bass.enumerated() {
            var bar: [(Int, Int)] = [(0, root), (4, fifth)]
            for n in chord { bar.append((2, n)); bar.append((6, n)) }
            bar += tune[b]
            out.append(bar)
        }
        return out
    }()

    private func pianoNote(_ midi: Int, gain: Float) {
        let k = pvNext % pvCount
        pvNext += 1
        pvT[k] = 0; pvF[k] = 440 * pow(2, Float(midi - 69) / 12); pvG[k] = gain; pvP[k * 2] = 0; pvP[k * 2 + 1] = 0
    }

    /// A creature call: 0 roar, 1 bellow, 2 honk, 3 grunt, 4 shriek, 5 screech, 6 thud, 7 stomp.
    func creature(_ kind: Int, gain: Float, pan: Float, pitch: Float) {
        // Take a free voice, or the quietest one.
        var k = -1
        for i in 0..<callCount where callT[i] >= callLen[i] { k = i; break }
        if k < 0 { k = callNext % callCount; callNext += 1 }
        let lens: [Float] = [2.3, 2.5, 1.4, 0.45, 0.55, 0.95, 0.4, 0.75]
        callKind[k] = kind; callGain[k] = gain; callPan[k] = pan; callPitch[k] = pitch; callPh[k] = 0
        callLen[k] = lens[min(max(kind, 0), 7)] * (kind < 3 ? (0.85 + 0.3 / max(pitch, 0.5)) : 1)
        callT[k] = 0
    }
    func shutter() { if shutterT > 0.25 { shutterT = 0 } }
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
        trafficS = ease(trafficS, cityTraffic, 2, dt)
        crowdS = ease(crowdS, cityCrowd, 2, dt)
        trainS = ease(trainS, cityTrain, 3, dt)
        heliS = ease(heliS, cityHeli, 3, dt)
        sirenS = ease(sirenS, sirenGain, 3, dt)
        if crowdS > 0.002 {
            crowdTimer -= dt
            if crowdTimer <= 0 { crowdTarget = 0.3 + 0.7 * (white() * 0.5 + 0.5); crowdTimer = 0.08 + 0.25 * (white() * 0.5 + 0.5) }
            crowdEnv = ease(crowdEnv, crowdTarget, 18, dt)
            crowdF.set(380 + 160 * crowdEnv, q: 1.6, sr: sr)
        }
        if sirenS > 0.002 {
            // A slow wail up and down.
            sirenSweep += dt / 3.2
            if sirenSweep > 1 { sirenSweep -= 1 }
            let tri = sirenSweep < 0.5 ? sirenSweep * 2 : 2 - sirenSweep * 2
            sirenFreq = 700 + 750 * tri
        }
        if trainS > 0.002 {
            clackTimer -= dt
            if clackTimer <= 0 { clackT = 0; clackFlip.toggle(); clackTimer = clackFlip ? 0.11 : 0.62 }
        }
        // Creature voices: formants follow each call's shape.
        for k in 0..<callCount where callT[k] < callLen[k] {
            let u = callT[k] / max(callLen[k], 0.01), p = callPitch[k]
            switch callKind[k] {
            case 0: callF1[k].set((380 + 160 * sin(u * .pi)) * p, q: 3, sr: sr); callF2[k].set((920 + 260 * sin(u * .pi)) * p, q: 4, sr: sr)
            case 1: callF1[k].set(260 * p, q: 4, sr: sr); callF2[k].set(610 * p, q: 5, sr: sr)
            case 2: callF1[k].set(560 * p, q: 6, sr: sr); callF2[k].set(1260 * p, q: 6, sr: sr)
            case 3: callF1[k].set(300 * p, q: 2, sr: sr); callF2[k].set(700 * p, q: 3, sr: sr)
            case 4, 5: callF1[k].set(2200 * p, q: 3, sr: sr); callF2[k].set(3400 * p, q: 4, sr: sr)
            default: callF1[k].set(110 * p, q: 0.8, sr: sr); callF2[k].set(260, q: 0.9, sr: sr)
            }
        }
        // 1.0: the march, the title theme, the heralds, the crowd.
        musicS = ease(musicS, finaleMusic, 1.5, dt)
        if musicS > 0.003 {
            musicClock += dt
            let step = Int(musicClock / 0.3)
            if step != musicStep {
                musicStep = step
                let bar = (step / 8) % 8, s8 = step % 8
                for (st, n, len) in BirdSynth.march[bar] where st == s8 { brass(n, gain: 0.07 * musicS, length: Float(len) * 0.3 * 0.92) }
                if s8 == 0 || s8 == 4 {
                    for (i, n) in BirdSynth.marchChords[bar].enumerated() { brass(n - (i == 0 ? 12 : 0), gain: (i == 0 ? 0.07 : 0.028) * musicS, length: 1.1) }
                    if bar == 0 || bar == 3 || bar == 7 || s8 == 0 { timpT = 0; timpF = s8 == 0 ? 65 : 98; timpG = 0.5 * musicS }
                }
            }
        } else { musicClock = 0; musicStep = -1 }
        titleS = ease(titleS, titleMusic, 1.2, dt)
        if titleS > 0.003 {
            titleClock += dt
            let step = Int(titleClock / 0.32)
            if step != titleStep {
                titleStep = step
                let bar = (step / 6) % 8, s6 = step % 6
                for (st, n) in BirdSynth.titleTune[bar] where st == s6 { uiNote(440 * pow(2, Float(n - 69) / 12), length: 0.9, gain: 0.05 * titleS) }
                if s6 == 0 { brass(BirdSynth.titleBass[bar] - 12, gain: 0.05 * titleS, length: 1.6) }
                if s6 == 3 { brass(BirdSynth.titleBass[bar], gain: 0.025 * titleS, length: 0.8) }
            }
        } else { titleClock = 0; titleStep = -1 }
        if fanfareGo { fanfareGo = false; fanfareClock = 0; fanfareNext = 0 }
        if fanfareNext < BirdSynth.fanfare.count {
            fanfareClock += dt
            while fanfareNext < BirdSynth.fanfare.count && fanfareClock >= BirdSynth.fanfare[fanfareNext].0 {
                let f = BirdSynth.fanfare[fanfareNext]
                fanfareNext += 1
                brass(f.1, gain: 0.11, length: f.2)
                brass(f.1 - 12, gain: 0.05, length: f.2)
            }
        }
        cheerS = ease(cheerS, crowdCheer, 2.5, dt)
        if cheerS > 0.003 {
            cheerTimer -= dt
            if cheerTimer <= 0 { cheerTimer = 0.08 + 0.2 * (white() * 0.5 + 0.5); cheerTarget = 0.55 + 0.45 * (white() * 0.5 + 0.5) }
            // More clappers join in as the cheer grows, each clapping 3–5 times a second, not in time with the others.
            let joined = Int(2 + Float(clapCount - 2) * min(1, cheerS))
            for k in 0..<joined {
                clapTimers[k] -= dt
                if clapTimers[k] <= 0 {
                    clapTimers[k] = 0.2 + 0.13 * (white() * 0.5 + 0.5)
                    clapTs[k] = 0
                    clapGs[k] = 0.5 + 0.5 * (white() * 0.5 + 0.5)
                }
            }
        }
        jetS = ease(jetS, jetGain, 6, dt)
        jetSp = ease(jetSp, min(jetSpeed, 900), 2, dt)
        if jetS > 0.002 { jetF.set(380 + jetSp * 1.4, q: 0.85, sr: sr) }
        pianoS = ease(pianoS, pianoGain, 2, dt)
        if pianoS > 0.003 {
            // An eighth note every 0.27 s (about 112 beats a minute), round and round the eight bars.
            pianoClock += dt
            let step = Int(pianoClock / 0.27)
            if step != pianoStep {
                pianoStep = step
                let bar = WestRag.bar(step / 8)
                for (s, n) in bar where s == step % 8 { pianoNote(n, gain: n < 50 ? 0.06 : (n < 70 ? 0.035 : 0.055)) }
            }
        }
        westTrainS = ease(westTrainS, westTrain, 2, dt)
        if westTrainS > 0.002 {
            chuffPhase += westTrainRate * dt
            if chuffPhase >= 1 { chuffPhase -= 1; chuffT = 0 }
        }
        jungleS = ease(jungleS, jungle, 1.5, dt)
        waterS = ease(waterS, jungleWater, 1.5, dt)
        if jungleS > 0.002 {
            insectSwellT -= dt
            if insectSwellT <= 0 { insectSwellT = 1.5 + 3 * (white() * 0.5 + 0.5); insectSwell = 0.3 + 0.7 * (white() * 0.5 + 0.5) }
            chirpTimer -= dt
            if chirpTimer <= 0 {
                chirpT = 0; chirpPh = 0
                chirpF = 1900 + 1700 * (white() * 0.5 + 0.5)
                chirpGlide = white() > 0 ? 1.6 : 0.6
                chirpPan = white() * 0.8
                chirpTimer = 0.6 + 3.2 * (white() * 0.5 + 0.5)
            }
        }
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
                if beepT < beepLen {
                    beepT += dtS
                    beepPhase += 2 * .pi * beepFreq * dtS
                    let env = min(1, beepT * 400) * min(1, (beepLen - beepT) * 40)
                    let c = (sin(beepPhase) * 0.12 + sin(beepPhase * 2) * 0.03) * env
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

                // Skyline City: traffic, voices, the el, the chopper, sirens, horns, pigeons, cameras.
                if trafficS > 0.002 {
                    let v = trafficF.tick(pl).lp * trafficS * 0.42 + hissF.tick(w2).bp * trafficS * 0.03
                    l += v; r += v
                }
                if crowdS > 0.002 {
                    let v = (crowdF.tick(w1).bp * 0.5 + crowdF2.tick(w3).bp * 0.25) * crowdS * crowdEnv * 0.3
                    l += v * 0.9; r += v
                }
                if trainS > 0.002 {
                    var v = trainF.tick(w4).lp * trainS * 0.8
                    if clackT < 0.05 { clackT += dtS; v += clackF.tick(w2).bp * exp(-clackT * 90) * trainS * 1.0 }
                    l += v * (1 - cityTrainPan * 0.6); r += v * (1 + cityTrainPan * 0.6)
                }
                if heliS > 0.002 {
                    heliPhase += 13.5 * dtS
                    if heliPhase > 1 { heliPhase -= 1 }
                    let chop = pow(max(0, sin(heliPhase * 2 * .pi)), 6)
                    let v = heliF.tick(w3).lp * heliS * (0.1 + 0.75 * chop)
                    l += v * (1 - cityHeliPan * 0.6); r += v * (1 + cityHeliPan * 0.6)
                }
                if sirenS > 0.002 {
                    sirenPhase += 2 * .pi * sirenFreq * dtS
                    if sirenPhase > 2 * .pi { sirenPhase -= 2 * .pi }
                    let v = (sin(sirenPhase) + 0.35 * sin(sirenPhase * 2) + 0.15 * sin(sirenPhase * 3)) * sirenS * 0.11
                    l += v * (1 - sirenPan * 0.6); r += v * (1 + sirenPan * 0.6)
                }
                for k in 0..<hornCount where hornT[k] < 0.4 {
                    hornT[k] += dtS
                    hornPh[k * 2] += 415 * dtS; hornPh[k * 2 + 1] += 523 * dtS
                    if hornPh[k * 2] > 1 { hornPh[k * 2] -= 1 }
                    if hornPh[k * 2 + 1] > 1 { hornPh[k * 2 + 1] -= 1 }
                    let sq = (hornPh[k * 2] < 0.5 ? 1 : -1) + (hornPh[k * 2 + 1] < 0.5 ? 1 : -1) as Float
                    let env = min(1, hornT[k] * 60) * min(1, (0.4 - hornT[k]) * 20)
                    let v = hornF.tick(sq).lp * env * hornG[k] * 0.22
                    l += v * (1 - hornP[k] * 0.7); r += v * (1 + hornP[k] * 0.7)
                }
                if trainHornT < 2.0 {
                    trainHornT += dtS
                    trainHornPh.0 += 2 * .pi * 277 * dtS; trainHornPh.1 += 2 * .pi * 349 * dtS; trainHornPh.2 += 2 * .pi * 415 * dtS
                    let env = min(1, trainHornT * 12) * min(1, (2.0 - trainHornT) * 6)
                    let v = (sin(trainHornPh.0) + sin(trainHornPh.1) * 0.8 + sin(trainHornPh.2) * 0.6 + sin(trainHornPh.0 * 2) * 0.3) * env * 0.09
                    l += v; r += v
                }
                if flutterT < 0.9 {
                    flutterT += dtS
                    let am = pow(max(0, sin(flutterT * 2 * .pi * 11)), 2) * exp(-flutterT * 2.5)
                    let v = flutterF.tick(w2).bp * am * 0.7
                    l += v; r += v * 0.85
                }
                if shutterT < 0.05 {
                    shutterT += dtS
                    let v = shutterF.tick(w4).bp * exp(-shutterT * 160) * 0.35
                    l += v; r += v
                }

                // Dino Valley: creature calls and the jungle.
                for k in 0..<callCount where callT[k] < callLen[k] {
                    let t = callT[k]
                    callT[k] = t + dtS
                    let len = callLen[k], p = callPitch[k], u = t / len
                    var v: Float = 0
                    switch callKind[k] {
                    case 0, 1, 3:
                        // Growls and bellows: a buzzing saw with a rough edge through two formants.
                        let base: Float = callKind[k] == 0 ? 58 : (callKind[k] == 1 ? 44 : 70)
                        let f0 = base * p * (1 + 0.22 * sin(min(u, 1) * .pi) + 0.03 * sin(t * 2 * .pi * 5.5))
                        callPh[k] += f0 * dtS
                        if callPh[k] > 1 { callPh[k] -= 1 }
                        let saw = callPh[k] * 2 - 1
                        let rough: Float = callKind[k] == 0 ? 0.55 + 0.45 * sin(t * 2 * .pi * 29) : 0.85
                        let src = saw * rough + w1 * (callKind[k] == 1 ? 0.15 : 0.55)
                        let env = min(1, t / (callKind[k] == 1 ? 0.35 : 0.1)) * min(1, (len - t) / (callKind[k] == 3 ? 0.2 : 0.7))
                        v = (callF1[k].tick(src).bp * 0.9 + callF2[k].tick(src).bp * 0.5) * env * (callKind[k] == 1 ? 1.4 : 1.1)
                    case 2:
                        // A honk: a reedy note that bends up, through a hollow crest.
                        let f0 = 128 * p * (1 + 0.12 * smoothstep(0, 0.2, u) - 0.1 * smoothstep(0.6, 1, u))
                        callPh[k] += f0 * dtS
                        if callPh[k] > 1 { callPh[k] -= 1 }
                        let sq: Float = callPh[k] < 0.5 ? 1 : -1
                        let env = min(1, t / 0.06) * min(1, (len - t) / 0.3)
                        v = (callF1[k].tick(sq).bp * 0.7 + callF2[k].tick(sq).bp * 0.35) * env * 0.8
                    case 4, 5:
                        // Shrieks and screeches: a squealing chirp with grit.
                        let sweep: Float = callKind[k] == 4 ? 1.2 - 0.45 * u : 0.95 + 0.5 * sin(u * .pi) - 0.3 * u
                        let f0 = 900 * p * sweep
                        callPh[k] += f0 * dtS
                        if callPh[k] > 1 { callPh[k] -= 1 }
                        let tone = sin(callPh[k] * 2 * .pi) + 0.4 * sin(callPh[k] * 4 * .pi)
                        let env = min(1, t / 0.03) * min(1, (len - t) / 0.2)
                        v = (tone * 0.35 + callF1[k].tick(w2).bp * 0.6) * env * 0.6
                    default:
                        // Footfalls: a deep thump.
                        let f0 = (48 - 18 * min(u, 1)) * p
                        callPh[k] += f0 * dtS
                        if callPh[k] > 1 { callPh[k] -= 1 }
                        let env = exp(-t * (callKind[k] == 7 ? 6 : 10)) * min(1, t * 400)
                        v = (sin(callPh[k] * 2 * .pi) * 1.1 + callF1[k].tick(w3).lp * 1.2) * env * (callKind[k] == 7 ? 1.5 : 1)
                    }
                    let g = callGain[k], pn = callPan[k]
                    l += v * g * (1 - pn * 0.65); r += v * g * (1 + pn * 0.65)
                }
                if jungleS > 0.002 {
                    insectPh += 19 * dtS; if insectPh > 1 { insectPh -= 1 }
                    insectPh2 += 27 * dtS; if insectPh2 > 1 { insectPh2 -= 1 }
                    let am1 = pow(max(0, sin(insectPh * 2 * .pi)), 2), am2 = pow(max(0, sin(insectPh2 * 2 * .pi)), 3)
                    let bug = (insectF.tick(w4).bp * am1 * insectSwell + insectF2.tick(w1).bp * am2 * (1.2 - insectSwell) * 0.7) * jungleS * 0.07
                    l += bug; r += bug * 0.85
                    if chirpT < 0.22 {
                        chirpT += dtS
                        chirpPh += 2 * .pi * chirpF * (1 + (chirpGlide - 1) * chirpT / 0.22) * dtS
                        let env = sin(Float.pi * chirpT / 0.22) * (0.6 + 0.4 * sin(chirpT * 2 * .pi * 38))
                        let c = sin(chirpPh) * env * jungleS * 0.022
                        l += c * (1 - chirpPan * 0.7); r += c * (1 + chirpPan * 0.7)
                    }
                }
                if waterS > 0.002 {
                    let wv = waterF.tick(pl + pr).lp * waterS * 0.22
                    l += wv; r += wv
                }

                // Wild West: honky-tonk piano (two slightly detuned strings per note), the train, coyotes, the bell.
                if pianoS > 0.003 {
                    var pv: Float = 0
                    for k in 0..<pvCount where pvT[k] < 1.6 {
                        let t = pvT[k]
                        pvT[k] = t + dtS
                        let f = pvF[k]
                        pvP[k * 2] += 2 * .pi * f * dtS
                        pvP[k * 2 + 1] += 2 * .pi * f * 1.0045 * dtS
                        if pvP[k * 2] > 2 * .pi { pvP[k * 2] -= 2 * .pi }
                        if pvP[k * 2 + 1] > 2 * .pi { pvP[k * 2 + 1] -= 2 * .pi }
                        let a = pvP[k * 2], b = pvP[k * 2 + 1]
                        let tone = sin(a) + sin(b) + (sin(2 * a) + sin(2 * b)) * 0.4 * exp(-t * 6) + sin(3 * a) * 0.2 * exp(-t * 10)
                        pv += tone * pvG[k] * min(1, t * 600) * exp(-t * (f > 400 ? 3.2 : 2.2))
                    }
                    let v = pv * pianoS
                    l += v * 0.9; r += v
                }
                if westTrainS > 0.002 {
                    var v = rumbleWF.tick(w3).lp * 0.9
                    if chuffT < 0.25 { chuffT += dtS; v += chuffF.tick(w4).bp * exp(-chuffT * 16) * 2.2 }
                    v *= westTrainS
                    l += v * (1 - westTrainPan * 0.6); r += v * (1 + westTrainPan * 0.6)
                }
                if whistleT < 1.8 {
                    whistleT += dtS
                    let droop: Float = 1 - 0.03 * smoothstep(1.3, 1.8, whistleT)
                    whistlePh.0 += 2 * .pi * 349 * droop * dtS; whistlePh.1 += 2 * .pi * 440 * droop * dtS; whistlePh.2 += 2 * .pi * 523 * droop * dtS
                    let env = min(1, whistleT * 10) * min(1, (1.8 - whistleT) * 5)
                    let v = ((sin(whistlePh.0) + sin(whistlePh.1) * 0.85 + sin(whistlePh.2) * 0.7) * 0.06 + whistleNoiseF.tick(w1).bp * 0.08) * env * whistleG
                    l += v; r += v
                }
                if coyoteT < 2.3 {
                    coyoteT += dtS
                    let u = coyoteT / 2.3
                    let f = 520 + 360 * smoothstep(0, 0.3, u) - 230 * smoothstep(0.55, 1, u) + 18 * sin(coyoteT * 2 * .pi * 6)
                    coyotePh += 2 * .pi * f * dtS
                    if coyotePh > 2 * .pi { coyotePh -= 2 * .pi }
                    let env = min(1, coyoteT * 4) * min(1, (2.3 - coyoteT) * 3)
                    let v = (sin(coyotePh) + 0.3 * sin(2 * coyotePh)) * env * coyoteG * 0.07
                    l += v * (1 - coyoteP * 0.7); r += v * (1 + coyoteP * 0.7)
                }
                if bellT < 4.5 {
                    bellT += dtS
                    // Two strikes, a bell's uneven partials ringing down.
                    let t = bellT < 1.7 ? bellT : bellT - 1.7
                    let f0: Float = 262
                    bellPh.0 += 2 * .pi * f0 * 0.5 * dtS; bellPh.1 += 2 * .pi * f0 * dtS; bellPh.2 += 2 * .pi * f0 * 1.19 * dtS
                    bellPh.3 += 2 * .pi * f0 * 1.56 * dtS; bellPh.4 += 2 * .pi * f0 * 2.0 * dtS
                    let ring = sin(bellPh.0) * 0.5 * exp(-t * 0.8) + sin(bellPh.1) * exp(-t * 1.1) + sin(bellPh.2) * 0.6 * exp(-t * 1.6) +
                        sin(bellPh.3) * 0.4 * exp(-t * 2.2) + sin(bellPh.4) * 0.3 * exp(-t * 3)
                    let v = ring * min(1, t * 400) * bellG * 0.05
                    l += v; r += v
                }

                // 1.0: brass (the march, the fanfares, the title bass), timpani, the crowd, fireworks, the choir, the jetpack.
                var br: Float = 0
                for k in 0..<brCount where brT[k] < brLen[k] + 0.25 {
                    let t = brT[k]
                    brT[k] = t + dtS
                    let vib: Float = 1 + 0.004 * sin(t * 2 * .pi * 5.2) * smoothstep(0.12, 0.3, t)
                    let inc = brF[k] * vib * dtS
                    var ph = brP[k] + inc
                    if ph >= 1 { ph -= 1 }
                    brP[k] = ph
                    // A band-limited saw (polyBLEP) through the brass filter below.
                    var saw = 2 * ph - 1
                    if ph < inc { let x = ph / inc; saw -= x + x - x * x - 1 } else if ph > 1 - inc { let x = (ph - 1) / inc; saw -= x * x + x + x + 1 }
                    let env = min(1, t / 0.035) * (t < brLen[k] ? 0.75 + 0.25 * exp(-t * 6) : exp(-(t - brLen[k]) * 14))
                    br += saw * env * brG[k]
                }
                if br != 0 {
                    let v = brassF.tick(br).lp * 0.9 + brassF2.tick(br).bp * 0.35
                    l += v * 0.95; r += v
                }
                if timpT < 1.2 {
                    timpT += dtS
                    timpPh += 2 * .pi * timpF * (1 - 0.06 * min(timpT * 4, 1)) * dtS
                    let v = (sin(timpPh) + w2 * 0.15 * exp(-timpT * 30)) * exp(-timpT * 4.5) * timpG * 0.5
                    l += v; r += v
                }
                if cheerS > 0.003 {
                    cheerEnv += (cheerTarget - cheerEnv) * 0.0015
                    var v = (cheerF.tick(w3).bp * 0.6 + cheerF2.tick(w4).bp * 0.35) * cheerEnv * cheerS * 0.5
                    var claps: Float = 0
                    for k in 0..<clapCount where clapTs[k] < 0.04 {
                        let t = clapTs[k]
                        clapTs[k] = t + dtS
                        claps += exp(-t * 140) * clapGs[k] * min(1, t * 4000)
                    }
                    v += clapF.tick(w1 * claps).bp * cheerS * 0.22
                    l += v; r += v * 0.94
                }
                // Every burst's boom and crackle are summed first, then filtered once (a filter must run once a sample).
                var boomL: Float = 0, boomR: Float = 0, gL: Float = 0, gR: Float = 0, crackIn: Float = 0
                for k in 0..<fwCount where fwT[k] < 1.6 {
                    let t = fwT[k]
                    fwT[k] = t + dtS
                    guard t >= 0 else { continue }
                    let g = fwG[k] * 0.5, pl = 1 - fwP[k] * 0.6, pr = 1 + fwP[k] * 0.6
                    // A distant thump and a sparkle of crackle: background to the music, not over it.
                    let boom = exp(-t * 7) * 0.85 * g
                    boomL += boom * pl; boomR += boom * pr
                    gL += g * pl; gR += g * pr
                    if t > 0.08 && t < 1.4 && white() > 0.9935 - 0.004 * (1 - t) { crackIn = 1.1 }
                }
                if gL + gR > 0 {
                    // Several bursts at once (the liftoff volley) mustn't stack up into a roar.
                    let cap: Float = 1 / max(1, (gL + gR) * 0.5)
                    let b = fwF.tick(w2).lp, c = fwCrackleF.tick(w4 * crackIn).bp
                    l += (b * boomL + c * gL) * cap
                    r += (b * boomR + c * gR) * cap
                }
                if choirT < 5.5 {
                    choirT += dtS
                    let env = smoothstep(0, 0.7, choirT) * (1 - smoothstep(3.6, 5.4, choirT))
                    let f: (Float, Float, Float, Float) = (261.63, 329.63, 392.0, 523.25)
                    choirPh.0 += f.0 * dtS; choirPh.1 += f.1 * 1.002 * dtS; choirPh.2 += f.2 * 0.998 * dtS; choirPh.3 += f.3 * 1.003 * dtS
                    if choirPh.0 > 1 { choirPh.0 -= 1 }; if choirPh.1 > 1 { choirPh.1 -= 1 }
                    if choirPh.2 > 1 { choirPh.2 -= 1 }; if choirPh.3 > 1 { choirPh.3 -= 1 }
                    let src = (choirPh.0 + choirPh.1 + choirPh.2 + choirPh.3 - 2) * 0.5
                    let v = (choirF1.tick(src).bp + choirF2.tick(src).bp * 0.7) * env * choirG * 0.35
                    l += v; r += v
                }
                if jetS > 0.002 {
                    jetWhinePh += 2 * .pi * (420 + min(jetSp, 1500) * 0.9) * dtS
                    if jetWhinePh > 2 * .pi { jetWhinePh -= 2 * .pi }
                    let roar = jetF.tick(w1 + w3 * 0.5).bp * 1.6 + jetLowF.tick(pl).lp * 1.4
                    let v = (roar + sin(jetWhinePh) * 0.05) * jetS * 0.55
                    l += v; r += v
                }
                if igniteT < 0.5 {
                    igniteT += dtS
                    let v = igniteF.tick(w2).lp * exp(-igniteT * 7) * min(1, igniteT * 200) * 2.4
                    l += v; r += v
                }

                // Menu sounds
                var ui: Float = 0
                for k in 0..<uiCount where uiT[k] < uiLen[k] {
                    let t = uiT[k]
                    uiT[k] = t + dtS
                    guard t >= 0 else { continue }
                    let env = min(1, t * 300) * exp(-t * 5.5)
                    let ph = 2 * Float.pi * uiF[k] * t
                    ui += (sin(ph) + 0.25 * sin(ph * 2) + 0.08 * sin(ph * 3)) * env * uiG[k]
                }
                let uiOut = tanh(ui * 0.9) * uiVolume
                L[j] = tanh(l * 0.9) * vol + uiOut
                R[j] = tanh(r * 0.9) * vol + uiOut
            }
            i += m
        }
    }
}

/// The saloon rag, bar by bar.
enum WestRag {
    static func bar(_ i: Int) -> [(Int, Int)] { BirdSynth.ragBar(i) }
}

extension BirdSynth {
    static func ragBar(_ i: Int) -> [(Int, Int)] { ragBars[((i % ragBars.count) + ragBars.count) % ragBars.count] }
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

    /// Tests: the same synth, never connected to the speakers (render it by hand with `synth.render`).
    init(offline sampleRate: Float) {
        synth = BirdSynth(sampleRate: sampleRate)
    }

    func setFlight(speed: Float, tuck: Float, stall: Float, roll: Float, ground: Float) {
        synth.airspeed = speed; synth.tuck = tuck; synth.stall = stall; synth.roll = roll; synth.ground = ground
    }
    func setWings(downL: Float, downR: Float, upL: Float, upR: Float) {
        synth.wingDown = (downL, downR); synth.wingUp = (upL, upR)
    }
    func chime() { synth.chime() }
    func beep(go: Bool) { synth.beep(go: go) }
    func impact(_ strength: Float, water: Bool) { synth.impact(strength, water: water) }
    func setMuted(_ m: Bool) { muted = m; synth.volume = m ? 0 : 0.85 }
    /// Menu and reward sounds (only silenced by the player's own mute, not by pausing).
    func setUIMuted(_ m: Bool) { synth.uiVolume = m ? 0 : 0.85 }
    func purchase() { synth.purchase() }
    func fanfare() { synth.fanfare() }
    func success() { synth.success() }
    func click() { synth.click() }
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
    // Skyline City
    func setCity(traffic: Float, crowd: Float, train: Float, trainPan: Float, heli: Float, heliPan: Float) {
        synth.cityTraffic = traffic; synth.cityCrowd = crowd; synth.cityTrain = train; synth.cityTrainPan = trainPan
        synth.cityHeli = heli; synth.cityHeliPan = heliPan
    }
    func horn(gain: Float, pan: Float) { synth.horn(gain: gain, pan: pan) }
    func setSiren(gain: Float, pan: Float) { synth.sirenGain = gain; synth.sirenPan = pan }
    func trainHorn() { synth.trainHorn() }
    func flutter() { synth.flutter() }
    func shutter() { synth.shutter() }
    // Dino Valley
    func dinoCall(_ kind: DinoCall.Kind, gain: Float, pan: Float, pitch: Float) {
        let k: Int
        switch kind {
        case .roar: k = 0
        case .bellow: k = 1
        case .honk: k = 2
        case .grunt: k = 3
        case .shriek: k = 4
        case .screech: k = 5
        case .thud: k = 6
        case .stomp: k = 7
        }
        synth.creature(k, gain: min(gain, 1.2), pan: pan, pitch: pitch)
    }
    func setJungle(_ g: Float, water: Float) { synth.jungle = g; synth.jungleWater = water }
    // Wild West
    func setPiano(_ g: Float) { synth.pianoGain = g }
    func setTrain(gain: Float, pan: Float, rate: Float) { synth.westTrain = gain; synth.westTrainPan = pan; synth.westTrainRate = rate }
    func steamWhistle(gain: Float) { synth.steamWhistle(gain: gain) }
    func coyote(gain: Float, pan: Float) { synth.coyote(gain: gain, pan: pan) }
    func churchBell(gain: Float) { synth.churchBell(gain: gain) }
    /// Silence all world-specific loops (used when switching worlds).
    // 1.0
    func setJet(gain: Float, speed: Float) { synth.jetGain = gain; synth.jetSpeed = speed }
    func jetIgnite() { synth.jetIgnite() }
    func setFinaleMusic(_ g: Float) { synth.finaleMusic = g }
    func setTitleMusic(_ g: Float) { synth.titleMusic = g }
    func setCrowd(cheer: Float) { synth.crowdCheer = cheer }
    func firework(gain: Float, pan: Float, delay: Float) { synth.firework(gain: gain, pan: pan, delay: delay) }
    func choir(gain: Float) { synth.choir(gain: gain) }
    func heraldFanfare() { synth.heraldFanfare() }
    func sonicBoom(_ g: Float) { synth.eruption(g) }

    func resetWorld() {
        setFinaleMusic(0); setCrowd(cheer: 0); setJet(gain: 0, speed: 0)
        synth.volcanoRumble = 0; synth.engGainT = .zero; synth.caveAmbience = false
        setCity(traffic: 0, crowd: 0, train: 0, trainPan: 0, heli: 0, heliPan: 0)
        synth.sirenGain = 0
        setJungle(0, water: 0)
        setPiano(0)
        setTrain(gain: 0, pan: 0, rate: 1)
    }
}

/// The app's sound engine, for menus that play a sound of their own.
enum Sounds {
    static weak var shared: SoundEngine?
}
