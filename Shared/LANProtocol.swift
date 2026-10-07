import Foundation
import Network
import simd

// Everything a LAN game sends over the network, shared by the game (Sources/) and Bird Server, the iPhone app
// that hosts games without playing (Server/). Both compile this file, so they always agree on the wire format.
// Foundation, Network and simd only: no AppKit, UIKit or SceneKit here.

/// LAN play constants and helpers.
///
/// Every copy of the game advertises itself with Bonjour (`serviceType`) and a TXT record:
/// `n` name, `c` nametag color, `i` instance id, `v` protocol version, `a` app version, `h` hosting (1/0),
/// `g` in a game (1/0), and while hosting `m` mode, `w` map, `p` players. Since 0.3.1 also `s` = 1 for a
/// dedicated server (Bird Server: it hosts but doesn't play) and `iv` = the instance ids the host has invited.
enum LANProtocol {
    static let serviceType = "_birdgame._tcp"
    /// Everyone in a LAN game needs the same number (0.3 and 0.3.1 are 5; 1.0, with its new maps, is 6).
    static let version = 6
    /// The Bird Game version that speaks `version` (what Bird Server says it runs).
    static let gameVersion = "1.0"
    static let maxPlayers = 8
    /// Fixed port, so friends can also join by typing the host's address (falls back to any free port).
    static let port: UInt16 = 47474
    /// Silence for this long means the other side is gone.
    static let timeout: Double = 8
    /// How long a host keeps listing an invite in its TXT record.
    static let inviteLife: Double = 60

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let p = NWParameters(tls: nil, tcp: tcp)
        // Also finds devices nearby over Apple's peer-to-peer Wi-Fi (helps on networks that keep devices apart).
        p.includePeerToPeer = true
        // Tests on one Mac: stay on loopback (no Local Network permission needed).
        if ProcessInfo.processInfo.environment["BIRD_LOOPBACK"] != nil { p.requiredInterfaceType = .loopback }
        return p
    }

    /// The system said no to local network access.
    static func isPolicyDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }   // kDNSServiceErr_PolicyDenied
        return false
    }

    /// The `iv` TXT value: invited instance ids, newest last, kept short enough for one TXT entry.
    static func inviteList(_ ids: [String]) -> String {
        var out: [String] = []
        var length = 3   // "iv="
        for id in ids.reversed() where !id.isEmpty && !id.contains(",") {
            guard length + id.count + 1 <= 250 else { break }
            length += id.count + 1
            out.insert(id, at: 0)
        }
        return out.joined(separator: ",")
    }

    /// Instance ids in an `iv` TXT value.
    static func invited(in value: String?) -> Set<String> {
        guard let value, !value.isEmpty else { return [] }
        return Set(value.split(separator: ",").map { String($0) })
    }

    /// IPv4 addresses on active network interfaces (Wi-Fi / Ethernet / Personal Hotspot), most likely first.
    static func localAddresses() -> [String] {
        var list: [(String, String)] = []
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return [] }
        defer { freeifaddrs(ifa) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let ifName = String(cString: cur.pointee.ifa_name)
            guard ifName.hasPrefix("en") || ifName.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue }
            list.append((ifName, ip))
        }
        return list.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/// Fight rules the host needs to know too.
enum FightRules {
    /// Lives each bird starts a fight with.
    static let lives = 3
    /// Fights end after this long, most lives (then health) winning.
    static let timeLimit: Float = 300
}

// MARK: - Game modes

enum GameMode: String, Codable, CaseIterable {
    case freeRoam, ringRace, speedRace, pvp

    var title: String {
        switch self {
        case .freeRoam: return "Free Roam"
        case .ringRace: return "Ring Race"
        case .speedRace: return "Speed Race"
        case .pvp: return "PvP Fight"
        }
    }

    var blurb: String {
        switch self {
        case .freeRoam: return "Fly anywhere and chase the endless rings. The original game."
        case .ringRace: return "Fly a fixed course of rings as fast as you can. Every ring you miss adds 5 seconds."
        case .speedRace: return "Follow the glowing sky road through checkpoints, past spinning blades and other obstacles."
        case .pvp: return "Three lives each; the last bird flying wins. Lock on and open your mouth wide to attack."
        }
    }

    var isRace: Bool { self == .ringRace || self == .speedRace }
}

/// Host settings for a LAN game (single player uses the defaults, with PvP only in the fight mode).
struct MatchRules: Codable, Equatable {
    var collisions = true
    var pvp = true
    var showLocation = true
}

/// One line of a race / fight result.
struct Standing: Codable, Equatable {
    var id: Int
    var name: String
    var color: Int
    var place: Int
    /// Race time in seconds (nil = did not finish).
    var time: Double?
    var knockouts = 0
    var note = ""
}

// MARK: - Nametag colors

enum NameColors {
    static let all: [SIMD3<Float>] = [
        SIMD3(0.93, 0.26, 0.24),  // red
        SIMD3(0.98, 0.58, 0.15),  // orange
        SIMD3(0.97, 0.83, 0.20),  // yellow
        SIMD3(0.35, 0.80, 0.30),  // green
        SIMD3(0.20, 0.80, 0.78),  // teal
        SIMD3(0.25, 0.55, 0.98),  // blue
        SIMD3(0.62, 0.40, 0.95),  // purple
        SIMD3(0.97, 0.45, 0.75),  // pink
    ]
    static let names = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
    static func color(_ i: Int) -> SIMD3<Float> { all[((i % all.count) + all.count) % all.count] }
}

// MARK: - Wire types shared by the game and the network

/// A bird's flight state as sent ~30 times a second.
struct NetState: Codable {
    var id: Int
    var p: SIMD3<Float>
    /// Orientation quaternion (ix, iy, iz, r).
    var q: SIMD4<Float>
    var v: SIMD3<Float>
    /// Wing elevation L/R, wing bend, fold.
    var w: SIMD4<Float>
    var hp: Float
    var flags: Int
    var bird: String
    /// Race progress (gates passed + fraction) for live standings.
    var progress: Float = 0
    var lives = FightRules.lives
    /// The sender's clock (seconds) when this state was taken, so others can replay it at an even pace.
    var t: Double = 0
    /// Outfit code (so a change of hat shows up straight away).
    var fit = ""

    static let alive = 1, paused = 2, finished = 4, spectator = 8, burning = 16
    /// 1.0: wearing the jetpack, and it's burning.
    static let jetpack = 32, jetFiring = 64
}

enum WeaponKind: String, Codable, CaseIterable {
    case pebble, seeds, gust, feathers, missiles, fire

    var name: String {
        switch self {
        case .pebble: return "Pebble Shot"
        case .seeds: return "Seed Spray"
        case .gust: return "Gale Gust"
        case .feathers: return "Razor Feathers"
        case .missiles: return "Homing Missiles"
        case .fire: return "Phoenix Fire"
        }
    }

    var blurb: String {
        switch self {
        case .pebble: return "One pebble that curves toward its target."
        case .seeds: return "A shotgun burst of seeds. Deadly up close."
        case .gust: return "A huge blast of wind: little damage, massive knockback."
        case .feathers: return "A fast burst of three razor feathers."
        case .missiles: return "Two heat-seeking missiles that explode on impact."
        case .fire: return "Homing fireballs that explode and set birds alight."
        }
    }
}

/// One attack as broadcast to other players (they replay it for looks; the shooter decides hits).
struct Shot: Codable {
    var owner: Int
    var weapon: WeaponKind
    var attack: Int
    var origin: SIMD3<Float>
    var dir: SIMD3<Float>
    var ownerVel: SIMD3<Float>
    var target: Int?
    /// Fired by a person (stronger homing, bigger hit radius) rather than a bot.
    var assist = false
}

enum HitSource: String, Codable { case shot, ram, border, hazard }

struct HitReport: Codable {
    var from: Int
    var to: Int
    var damage: Float
    var impulse: SIMD3<Float>
    var burn: Float = 0
    var source: HitSource
    var weapon: WeaponKind?
}

enum GameEvent: Codable {
    case fire(Shot)
    case hit(HitReport)
    /// `killer` 0 = nobody (border, crash).
    case died(victim: Int, killer: Int)
    case finished(id: Int, time: Double)
    case respawned(id: Int)
    /// Out of lives (fights).
    case eliminated(id: Int)
    /// Someone took a health orb; everyone hides it.
    case pickup(orb: Int, by: Int)
}

/// Host → everyone: match flow.
enum MatchCommand: Codable {
    /// Put everyone on the start grid and count down.
    case start(matchId: Int, countdown: Double, slots: [Int: Int])
    case results(matchId: Int, standings: [Standing])
    case warmup
}

struct PeerInfo: Codable, Equatable {
    var id: Int
    var name: String
    var color: Int
    var bird: String
    /// Outfit code (hat, glasses, trail…).
    var fit = ""
}

struct Hello: Codable {
    var name: String
    var color: Int
    var bird: String
    var version: Int
    var instance: String
    /// Outfit code (see `Outfit.code`).
    var fit = ""
}

/// What the host tells everyone about the game.
struct Lobby: Codable, Equatable {
    var hostName = ""
    var players: [PeerInfo] = []
    var rules = MatchRules()
    var mode = GameMode.freeRoam
    var world = "meadow"
    /// A round (race / fight) is under way.
    var running = false
}

enum Wire: Codable {
    case hello(Hello)
    case welcome(id: Int, lobby: Lobby)
    case reject(String)
    case invite(from: String, color: Int, service: String)
    case lobby(Lobby)
    case kicked
    case state(NetState)
    case states([NetState])
    case event(GameEvent)
    case match(MatchCommand)
    case bye
    /// Heartbeat, so a vanished player (Mac asleep, Wi-Fi gone) is noticed within seconds.
    case ping
    case chat(ChatLine)
}

/// One chat message (or a "joined" / "left" note when `system`).
struct ChatLine: Codable, Equatable {
    var id: Int
    var name: String
    var color: Int
    var text: String
    var system = false

    static let maxLength = 140
    /// One line, trimmed, not too long; nil when there's nothing to say.
    static func clean(_ raw: String) -> String? {
        let one = raw.components(separatedBy: .newlines).joined(separator: " ")
            .filter { !$0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
            .trimmingCharacters(in: .whitespaces)
        return one.isEmpty ? nil : String(one.prefix(maxLength))
    }
}

extension GameEvent {
    /// The same event with its player ids forced to the sender's (a client can only speak for itself).
    func from(_ id: Int) -> GameEvent {
        switch self {
        case .fire(var s): s.owner = id; return .fire(s)
        case .hit(var h): h.from = id; return .hit(h)
        case .died(_, let killer): return .died(victim: id, killer: killer)
        case .finished(_, let time): return .finished(id: id, time: time)
        case .respawned: return .respawned(id: id)
        case .eliminated: return .eliminated(id: id)
        case .pickup(let orb, _): return .pickup(orb: orb, by: id)
        }
    }
}

func ordinal(_ n: Int) -> String {
    let s: String
    switch (n % 10, n % 100) {
    case (1, let t) where t != 11: s = "st"
    case (2, let t) where t != 12: s = "nd"
    case (3, let t) where t != 13: s = "rd"
    default: s = "th"
    }
    return "\(n)\(s)"
}

func raceClock(_ t: Double) -> String {
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Connection

/// One TCP connection carrying length-prefixed JSON messages.
final class Conn {
    let c: NWConnection
    var id = 0
    var info: PeerInfo?
    /// The other game's instance id (from its hello).
    var instance = ""
    var onMessage: ((Wire) -> Void)?
    var onClose: (() -> Void)?
    /// Network queue: when we last heard anything, and when the connection was made.
    private(set) var lastHeard = uptime()
    let opened = uptime()
    private var ready = false
    private var closed = false
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    init(_ c: NWConnection) { self.c = c }

    func start(on q: DispatchQueue) {
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.ready = true
            // Before it connects, "waiting" means the other side can't be reached right now: give up and let the caller retry.
            case .waiting: if self?.ready == false { self?.finish() }
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        c.start(queue: q)
        receive()
    }

    /// A message framed for sending (encode once, send to many).
    static func frame(_ w: Wire) -> Data? {
        guard let body = try? encoder.encode(w) else { return nil }
        var len = UInt32(body.count).bigEndian
        var d = Data(bytes: &len, count: 4)
        d.append(body)
        return d
    }

    func send(_ w: Wire, then: ((Bool) -> Void)? = nil) {
        guard let d = Conn.frame(w) else { return }
        send(frame: d, then: then)
    }

    func send(frame d: Data, then: ((Bool) -> Void)? = nil) {
        guard !closed else { then?(false); return }
        c.send(content: d, completion: .contentProcessed { err in then?(err == nil) })
    }

    private func receive() {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, err in
            guard let self else { return }
            guard err == nil, let head, head.count == 4 else { self.finish(); return }
            let len = Int(UInt32(bigEndian: head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 4_000_000 else { self.finish(); return }
            self.c.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, done2, err2 in
                guard err2 == nil, let body, body.count == len else { self.finish(); return }
                self.lastHeard = uptime()
                if let w = try? Conn.decoder.decode(Wire.self, from: body) { self.onMessage?(w) }
                if done2 { self.finish() } else { self.receive() }
            }
        }
    }

    func close() {
        c.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        c.cancel()
        onClose?()
    }
}

// MARK: - Match director (host only)

/// Runs rounds for a LAN game: who's racing / fighting, finish times, knock-outs, and when it's over.
/// Not thread-safe: the game drives it from the main thread, Bird Server from its network queue.
final class MatchDirector {
    private(set) var round = 0
    private(set) var running = false
    private(set) var mode = GameMode.freeRoam
    /// Who's in the current (or last) round.
    private(set) var players: [PeerInfo] = []
    private var finished: [Int: Double] = [:]
    private var out: [Int] = []
    private var kos: [Int: Int] = [:]
    private(set) var started = Date()
    private var firstFinish: Date?
    /// Latest state per player (race progress, lives, health) for standings.
    var state: ((Int) -> NetState?)?

    /// Start a round: everyone gets a grid slot.
    func start(mode: GameMode, players: [PeerInfo]) -> MatchCommand {
        round += 1
        running = true
        self.mode = mode
        self.players = players
        finished = [:]
        out = []
        kos = [:]
        started = Date()
        firstFinish = nil
        var slots: [Int: Int] = [:]
        for (i, p) in players.shuffled().enumerated() { slots[p.id] = i }
        return .start(matchId: round, countdown: 3, slots: slots)
    }

    func stop() { running = false }

    /// End the round now, with things as they stand (Bird Server's "End round").
    func finishNow() -> MatchCommand? { running ? results() : nil }

    /// A player's race time this round.
    func finishTime(of id: Int) -> Double? { finished[id] }
    /// Out of lives this round (fights).
    func isOut(_ id: Int) -> Bool { out.contains(id) }
    /// Knock-outs this round (fights).
    func knockouts(of id: Int) -> Int { kos[id] ?? 0 }

    func handle(_ e: GameEvent) -> MatchCommand? {
        guard running else { return nil }
        switch e {
        case .finished(let id, let time):
            guard mode.isRace, finished[id] == nil, players.contains(where: { $0.id == id }) else { return nil }
            finished[id] = time
            if firstFinish == nil { firstFinish = Date() }
        case .died(_, let killer):
            if mode == .pvp && killer != 0 { kos[killer, default: 0] += 1 }
            return nil
        case .eliminated(let id):
            guard mode == .pvp, !out.contains(id), players.contains(where: { $0.id == id }) else { return nil }
            out.append(id)
        default: return nil
        }
        return check()
    }

    func playerLeft(_ id: Int) -> MatchCommand? {
        players.removeAll { $0.id == id }
        return running ? check() : nil
    }

    /// Timeouts: 45 s after the first finisher, or 6 minutes in all.
    func tick() -> MatchCommand? {
        guard running else { return nil }
        if let f = firstFinish, Date().timeIntervalSince(f) > 45 { return results() }
        let limit = mode == .pvp ? Double(FightRules.timeLimit) + 3 : 360
        if Date().timeIntervalSince(started) > limit { return results() }
        return nil
    }

    private func check() -> MatchCommand? {
        if mode.isRace {
            return players.allSatisfy({ finished[$0.id] != nil }) ? results() : nil
        }
        let alive = players.filter { !out.contains($0.id) }
        return alive.count <= 1 ? results() : nil
    }

    private func results() -> MatchCommand {
        running = false
        var st: [Standing] = []
        if mode.isRace {
            let done = players.filter { finished[$0.id] != nil }.sorted { finished[$0.id]! < finished[$1.id]! }
            let dnf = players.filter { finished[$0.id] == nil }.sorted { (state?($0.id)?.progress ?? 0) > (state?($1.id)?.progress ?? 0) }
            for (i, p) in (done + dnf).enumerated() {
                st.append(Standing(id: p.id, name: p.name, color: p.color, place: i + 1, time: finished[p.id],
                                   note: finished[p.id] == nil ? "Did not finish" : ""))
            }
        } else {
            // Still in: most lives, then most health.
            let alive = players.filter { !out.contains($0.id) }.sorted { a, b in
                let sa = state?(a.id), sb = state?(b.id)
                if (sa?.lives ?? 0) != (sb?.lives ?? 0) { return (sa?.lives ?? 0) > (sb?.lives ?? 0) }
                return (sa?.hp ?? 0) > (sb?.hp ?? 0)
            }
            let order = alive.map(\.id) + out.reversed()
            for (i, id) in order.enumerated() {
                guard let p = players.first(where: { $0.id == id }) else { continue }
                st.append(Standing(id: id, name: p.name, color: p.color, place: i + 1, knockouts: kos[id] ?? 0))
            }
        }
        // Players who left mid-round don't get listed.
        for (i, _) in st.enumerated() { st[i].place = i + 1 }
        return .results(matchId: round, standings: st)
    }
}
