import AppKit
import Foundation
import Network

// MARK: - Wire format

struct Hello: Codable {
    var name: String
    var color: Int
    var bird: String
    var version: Int
    var instance: String
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

/// A game someone is hosting on the local network.
struct DiscoveredGame: Equatable {
    /// The host's instance id (stable, unlike the Bonjour service name). Empty for a game joined by address.
    var service: String
    var hostName: String
    var color: Int
    var mode: GameMode
    var world: String
    var players: Int
    var endpoint: NWEndpoint
    /// The host's app version when it can't play with ours (nil = compatible).
    var otherVersion: String? = nil
}

/// Another Bird Game on the network (for invites).
struct DiscoveredPeer: Equatable {
    /// Instance id.
    var service: String
    var name: String
    var color: Int
    var inGame: Bool
    var endpoint: NWEndpoint
    var otherVersion: String? = nil
}

struct Invite: Equatable {
    var from: String
    var color: Int
    var service: String
}

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

// MARK: - Connection

/// One TCP connection carrying length-prefixed JSON messages.
private final class Conn {
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

// MARK: - Session

/// LAN play without a server: every copy of the game advertises itself with Bonjour (so it can be invited),
/// one player hosts, the others connect straight to the host, and the host relays flight states and events.
/// Each player flies their own bird; the shooter decides what their attacks hit.
final class LANSession: NetLink {
    static let serviceType = "_birdgame._tcp"
    static let protocolVersion = 4
    static let maxPlayers = 8
    /// Fixed port, so friends can also join by typing the host's address (falls back to any free port).
    static let port: UInt16 = 47474
    /// Silence for this long means the other side is gone.
    static let timeout: Double = 8

    enum Role: Equatable { case offline, idle, joining, hosting, joined }

    /// Something on this Mac that stops friends from reaching us.
    enum Problem: Equatable {
        /// macOS Local Network permission was turned off for Bird Game.
        case localNetwork
        /// The macOS firewall blocks incoming connections to Bird Game (friends can't join our games).
        case firewall
    }

    let instance = String(UUID().uuidString.prefix(8))
    private let q = DispatchQueue(label: "bird.net")
    private let lock = NSLock()

    // Main-thread state (UI reads these)
    private(set) var role = Role.offline
    private(set) var games: [DiscoveredGame] = []
    private(set) var nearby: [DiscoveredPeer] = []
    private(set) var invites: [Invite] = []
    private(set) var invited: Set<String> = []
    private(set) var lobby = Lobby()
    private(set) var status = ""
    private(set) var problems: Set<Problem> = []
    /// This Mac's address(es) on the network, for "join by address".
    private(set) var addresses: [String] = []
    private(set) var listeningPort: UInt16?
    /// This game's chat, oldest first (cleared when you host or join another game).
    private(set) var chat: [ChatLine] = []
    var name = "Player"
    var color = 0
    var bird = "gull"

    // Callbacks (main thread)
    var onChange: (() -> Void)?
    var onLobby: ((Lobby) -> Void)?
    var onMatch: ((MatchCommand) -> Void)?
    /// Host: events from other players, for the match director.
    var onEvent: ((Int, GameEvent) -> Void)?
    var onInvite: ((Invite) -> Void)?
    /// Left a game (kicked, host gone, connection lost).
    var onEnded: ((String) -> Void)?
    var onPeerLeft: ((Int) -> Void)?
    var onChat: ((ChatLine) -> Void)?

    // Network-queue state
    private var me = (name: "Player", color: 0, bird: "gull")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var serviceName = ""
    private var advertised: [String: String] = [:]
    private var advertiseQueued = false
    private var endpoints: [String: NWEndpoint] = [:]
    private var clients: [Int: Conn] = [:]
    private var pending: [ObjectIdentifier: Conn] = [:]
    private var banned: Set<String> = []
    private var nextId = 2
    private var server: Conn?
    private var welcomed = false
    private var latest: [Int: NetState] = [:]
    private var outbox: [NetState] = []
    private var relayTimer: DispatchSourceTimer?
    private var heartbeat: DispatchSourceTimer?
    private var hostingQ = false
    private var lobbyQ = Lobby()
    private var activity: NSObjectProtocol?
    /// Host: recent message times per player (spam guard).
    private var chatTimes: [Int: [Double]] = [:]

    // NetLink (any thread, under `lock`)
    private var _localId = 1
    private var box = NetInbox()
    var localId: Int { lock.lock(); defer { lock.unlock() }; return _localId }

    private static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let p = NWParameters(tls: nil, tcp: tcp)
        // Also finds Macs nearby over Apple's peer-to-peer Wi-Fi (helps on networks that keep devices apart).
        p.includePeerToPeer = true
        // Tests on one Mac: stay on loopback (no Local Network permission needed).
        if ProcessInfo.processInfo.environment["BIRD_LOOPBACK"] != nil { p.requiredInterfaceType = .loopback }
        return p
    }

    private static var appVersion: String { AppVersion.short }

    // MARK: Presence

    /// Start advertising this copy of the game and looking for others.
    func goOnline() {
        guard role == .offline else { return }
        role = .idle
        status = "Looking for games on your network…"
        let profile = (name, color, bird)
        q.async { [self] in
            me = profile
            serviceName = "\(profile.0.prefix(30)) · \(instance)"
            startListener(fixedPort: true)
            startBrowser()
            startHeartbeat()
        }
        refreshDiagnostics()
        onChange?()
    }

    /// TXT record: who we are and what we're hosting.
    private func txt() -> NWTXTRecord {
        var t = NWTXTRecord()
        t["n"] = me.name
        t["c"] = String(me.color)
        t["i"] = instance
        t["v"] = String(LANSession.protocolVersion)
        t["a"] = LANSession.appVersion
        t["h"] = hostingQ ? "1" : "0"
        t["g"] = hostingQ || server != nil ? "1" : "0"
        if hostingQ {
            t["m"] = lobbyQ.mode.rawValue
            t["w"] = lobbyQ.world
            t["p"] = String(lobbyQ.players.count)
        }
        return t
    }

    /// One long-lived listener takes joins and invites and advertises us with Bonjour.
    private func startListener(fixedPort: Bool) {
        let l: NWListener
        do {
            l = fixedPort ? try NWListener(using: LANSession.params(), on: NWEndpoint.Port(rawValue: LANSession.port)!)
                          : try NWListener(using: LANSession.params())
        } catch {
            if fixedPort { startListener(fixedPort: false) } else { main { $0.setStatus("Couldn't start networking: \(error.localizedDescription)") } }
            return
        }
        let t = txt()
        advertised = t.dictionary
        l.service = NWListener.Service(name: serviceName, type: LANSession.serviceType, domain: nil, txtRecord: t)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                let p = l.port?.rawValue
                self.main { $0.listeningPort = p; $0.onChange?() }
            case .waiting(let e):
                if LANSession.isPolicyDenied(e) { self.main { $0.flag(.localNetwork, true) } }
            case .failed(let e):
                l.cancel()
                self.listener = nil
                if fixedPort {
                    // The port is taken (another copy of the game on this Mac): any free port works for Bonjour.
                    self.startListener(fixedPort: false)
                } else {
                    self.main { $0.setStatus("Network error: \(e.localizedDescription)") }
                    self.q.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.listener == nil, self.browser != nil else { return }
                        self.startListener(fixedPort: false)
                    }
                }
            default: break
            }
        }
        l.start(queue: q)
        listener = l
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LANSession.serviceType, domain: nil), using: LANSession.params())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.discovered(results) }
        b.stateUpdateHandler = { [weak self, weak b] st in
            guard let self, let b, self.browser === b else { return }
            switch st {
            case .ready:
                self.main { $0.flag(.localNetwork, false) }
            case .waiting(let e):
                if LANSession.isPolicyDenied(e) { self.main { $0.flag(.localNetwork, true) } }
            case .failed:
                // Restart (e.g. after the network changed).
                b.cancel()
                self.q.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.browser === b else { return }
                    self.startBrowser()
                }
            default: break
            }
        }
        b.start(queue: q)
        browser = b
    }

    /// macOS said no to local network access.
    private static func isPolicyDenied(_ e: NWError) -> Bool {
        if case .dns(let code) = e { return code == -65570 }   // kDNSServiceErr_PolicyDenied
        return false
    }

    /// Publish a new TXT record when what we'd advertise changed (the listener keeps running and keeps its port).
    private func readvertise() {
        guard listener != nil, !advertiseQueued else { return }
        advertiseQueued = true
        q.asyncAfter(deadline: .now() + 0.15) { [self] in
            advertiseQueued = false
            guard let l = listener else { return }
            let t = txt()
            guard t.dictionary != advertised else { return }
            advertised = t.dictionary
            l.service = NWListener.Service(name: serviceName, type: LANSession.serviceType, domain: nil, txtRecord: t)
        }
    }

    /// Name, color or bird changed.
    func updateProfile() {
        let (n, c, b) = (name, color, bird)
        q.async { [self] in
            me = (n, c, b)
            readvertise()
            if hostingQ, let i = lobbyQ.players.firstIndex(where: { $0.id == 1 }) {
                lobbyQ.players[i].name = n; lobbyQ.players[i].color = c; lobbyQ.players[i].bird = b
                lobbyQ.hostName = n
                pushLobby()
            }
        }
    }

    private func discovered(_ results: Set<NWBrowser.Result>) {
        var g: [String: DiscoveredGame] = [:], p: [String: DiscoveredPeer] = [:]
        var eps: [String: NWEndpoint] = [:]
        for r in results {
            guard case .service = r.endpoint, case .bonjour(let t) = r.metadata, let svc = t["i"], svc != instance else { continue }
            eps[svc] = r.endpoint
            // 0.2 didn't advertise its app version.
            let other: String? = t["v"] == String(LANSession.protocolVersion) ? nil : (t["a"] ?? (t["v"] == "3" ? "0.2" : "another version"))
            let n = t["n"] ?? "Player", c = Int(t["c"] ?? "0") ?? 0
            if t["h"] == "1" {
                g[svc] = DiscoveredGame(service: svc, hostName: n, color: c, mode: GameMode(rawValue: t["m"] ?? "") ?? .freeRoam,
                                        world: t["w"] ?? "meadow", players: Int(t["p"] ?? "1") ?? 1, endpoint: r.endpoint, otherVersion: other)
            }
            p[svc] = DiscoveredPeer(service: svc, name: n, color: c, inGame: t["g"] == "1", endpoint: r.endpoint, otherVersion: other)
        }
        endpoints = eps
        let games = g.values.sorted { ($0.otherVersion == nil ? 0 : 1, $0.hostName) < ($1.otherVersion == nil ? 0 : 1, $1.hostName) }
        let peers = p.values.sorted { $0.name < $1.name }
        main { s in
            s.games = games
            s.nearby = peers
            s.invites.removeAll { inv in !peers.contains { $0.service == inv.service } }
            s.onChange?()
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.beat() }
        t.resume()
        heartbeat = t
    }

    private func beat() {
        let now = uptime()
        for c in clients.values {
            if now - c.lastHeard > LANSession.timeout { c.close() } else { c.send(.ping) }
        }
        if let s = server, welcomed {
            if now - s.lastHeard > LANSession.timeout { s.close() } else { s.send(.ping) }
        }
        // Connections that never said hello (or an invite that was never sent).
        for c in pending.values where now - c.opened > 10 { c.close() }
    }

    // MARK: Incoming connections (joins and invites)

    private func accept(_ nc: NWConnection) {
        let conn = Conn(nc)
        let key = ObjectIdentifier(conn)
        pending[key] = conn
        conn.onClose = { [weak self] in self?.pending.removeValue(forKey: key) }
        conn.onMessage = { [weak self, weak conn] w in
            guard let self, let conn else { return }
            switch w {
            case .hello(let h): self.pending.removeValue(forKey: key); self.admit(conn, h)
            case .invite(let from, let color, let service):
                let inv = Invite(from: String(from.prefix(20)), color: color, service: service)
                self.main { s in
                    guard s.role == .idle, !s.invites.contains(inv) else { return }
                    s.invites.append(inv)
                    s.onInvite?(inv)
                    s.onChange?()
                }
                conn.close()
            default: break
            }
        }
        conn.start(on: q)
    }

    private func admit(_ conn: Conn, _ h: Hello) {
        func reject(_ why: String) { conn.send(.reject(why)) { _ in conn.close() } }
        guard hostingQ else { reject("That game has ended."); return }
        guard h.version == LANSession.protocolVersion else {
            reject("That game is on a different version of Bird Game (you both need \(LANSession.appVersion)).")
            return
        }
        guard !banned.contains(h.instance) else { reject("The host removed you from this game."); return }
        guard clients.count + 1 < LANSession.maxPlayers else { reject("That game is full."); return }
        // The same game reconnecting (e.g. after a Wi-Fi blip): drop its old connection first.
        if let old = clients.first(where: { $0.value.instance == h.instance }) { old.value.close() }
        let id = nextId
        nextId += 1
        conn.id = id
        conn.instance = h.instance
        let n = h.name.trimmingCharacters(in: .whitespacesAndNewlines)
        conn.info = PeerInfo(id: id, name: String((n.isEmpty ? "Player" : n).prefix(20)), color: h.color, bird: h.bird)
        clients[id] = conn
        conn.onMessage = { [weak self] w in self?.fromClient(id, w) }
        conn.onClose = { [weak self] in self?.dropClient(id) }
        lobbyQ.players.append(conn.info!)
        conn.send(.welcome(id: id, lobby: lobbyQ))
        pushLobby()
    }

    private func fromClient(_ id: Int, _ w: Wire) {
        switch w {
        case .state(var s):
            s.id = id
            latest[id] = s
            outbox.append(s)
            deliver([s])
            if let i = lobbyQ.players.firstIndex(where: { $0.id == id }), lobbyQ.players[i].bird != s.bird {
                lobbyQ.players[i].bird = s.bird
                pushLobby()
            }
        case .event(let raw):
            let e = raw.from(id)
            if let d = Conn.frame(.event(e)) { for (cid, c) in clients where cid != id { c.send(frame: d) } }
            deliver(e)
            main { $0.onEvent?(id, e) }
        case .chat(var l):
            guard let info = clients[id]?.info, let text = ChatLine.clean(l.text) else { return }
            // At most 6 messages in 5 seconds each.
            let now = uptime()
            var times = (chatTimes[id] ?? []).filter { now - $0 < 5 }
            guard times.count < 6 else { return }
            times.append(now)
            chatTimes[id] = times
            l = ChatLine(id: id, name: info.name, color: info.color, text: text)
            if let d = Conn.frame(.chat(l)) { for (cid, c) in clients where cid != id { c.send(frame: d) } }
            main { $0.received(l) }
        case .bye:
            clients[id]?.close()
        default: break
        }
    }

    private func dropClient(_ id: Int) {
        guard clients.removeValue(forKey: id) != nil else { return }
        latest.removeValue(forKey: id)
        lobbyQ.players.removeAll { $0.id == id }
        pushLobby()
        main { $0.onPeerLeft?(id) }
    }

    /// Host: send the lobby to everyone and to our own game.
    private func pushLobby() {
        let l = lobbyQ
        if let d = Conn.frame(.lobby(l)) { for c in clients.values { c.send(frame: d) } }
        lock.lock(); box.peers = l.players; box.rules = l.rules; lock.unlock()
        readvertise()
        main { s in s.lobby = l; s.onLobby?(l); s.onChange?() }
    }

    // MARK: Hosting

    func host(mode: GameMode, world: String, rules: MatchRules) {
        guard role == .idle else { return }
        role = .hosting
        status = "Hosting"
        chat = []
        let me = PeerInfo(id: 1, name: name, color: color, bird: bird)
        lock.lock(); _localId = 1; box = NetInbox(); lock.unlock()
        q.async { [self] in
            hostingQ = true
            nextId = 2
            latest = [:]
            outbox = []
            banned = []
            lobbyQ = Lobby(hostName: me.name, players: [me], rules: rules, mode: mode, world: world, running: false)
            startRelay()
            pushLobby()
        }
        keepAwake(true)
        refreshDiagnostics()
        onChange?()
    }

    /// Host: change the mode, map or settings for everyone.
    func updateLobby(mode: GameMode? = nil, world: String? = nil, rules: MatchRules? = nil, running: Bool? = nil) {
        q.async { [self] in
            guard hostingQ else { return }
            if let mode { lobbyQ.mode = mode }
            if let world { lobbyQ.world = world }
            if let rules { lobbyQ.rules = rules }
            if let running { lobbyQ.running = running }
            pushLobby()
        }
    }

    /// Host: tell every client (the host applies commands to its own game itself).
    func broadcast(_ m: MatchCommand) {
        q.async { [self] in
            guard let d = Conn.frame(.match(m)) else { return }
            for c in clients.values { c.send(frame: d) }
        }
    }

    /// Host: remove a player. They can't rejoin this game.
    func kick(_ id: Int) {
        q.async { [self] in
            guard let c = clients[id] else { return }
            if !c.instance.isEmpty { banned.insert(c.instance) }
            c.send(.kicked) { _ in c.close() }
            q.asyncAfter(deadline: .now() + 0.5) { c.close() }
        }
    }

    /// Latest reported state per player (host), for standings.
    func latestState(of id: Int) -> NetState? {
        var v: NetState?
        q.sync { v = latest[id] }
        return v
    }

    /// Every state received since the last tick goes out to everyone, 60 times a second, encoded once.
    /// (Each game skips its own.) Nothing is dropped or sent twice, so other birds move smoothly.
    private func startRelay() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 60.0, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in
            guard let self, self.hostingQ, !self.outbox.isEmpty else { return }
            let batch = self.outbox
            self.outbox.removeAll(keepingCapacity: true)
            guard !self.clients.isEmpty, let d = Conn.frame(.states(batch)) else { return }
            for c in self.clients.values { c.send(frame: d) }
        }
        t.resume()
        relayTimer = t
    }

    // MARK: Joining

    func join(_ g: DiscoveredGame) {
        guard role == .idle else { return }
        if let v = g.otherVersion {
            status = "\(g.hostName) has Bird Game \(v) and you have \(LANSession.appVersion). You both need the same version to play together."
            onChange?()
            return
        }
        role = .joining
        status = "Joining \(g.hostName)…"
        invites.removeAll { $0.service == g.service }
        onChange?()
        let hello = Hello(name: name, color: color, bird: bird, version: LANSession.protocolVersion, instance: instance)
        let deadline = uptime() + 9
        q.async { [self] in connect(g, hello: hello, deadline: deadline) }
    }

    /// Join by typing the host's address (for networks where games don't show up by themselves).
    /// Accepts "192.168.1.23", "192.168.1.23:47474" or a name like "Connors-MacBook.local".
    @discardableResult
    func join(address raw: String) -> Bool {
        guard let ep = LANSession.endpoint(raw) else {
            status = "That doesn't look like an address — it should look like 192.168.1.23"
            onChange?()
            return false
        }
        join(DiscoveredGame(service: "", hostName: raw.trimmingCharacters(in: .whitespaces), color: 0, mode: .freeRoam,
                            world: "meadow", players: 1, endpoint: ep))
        return true
    }

    static func endpoint(_ raw: String) -> NWEndpoint? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        var port = LANSession.port
        // "host:port" (but not a bare IPv6 address)
        if s.filter({ $0 == ":" }).count == 1, let i = s.lastIndex(of: ":") {
            guard let p = UInt16(s[s.index(after: i)...]) else { return nil }
            port = p
            s = String(s[..<i])
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || ".-:%".contains($0) }) else { return nil }
        return .hostPort(host: NWEndpoint.Host(s), port: NWEndpoint.Port(rawValue: port)!)
    }

    /// One attempt at reaching the host; retried until the deadline (Wi-Fi hiccups, the host still starting up).
    private func connect(_ g: DiscoveredGame, hello: Hello, deadline: Double) {
        // A Bonjour game may have moved (new address or interface): use the freshest endpoint.
        let ep = g.service.isEmpty ? g.endpoint : (endpoints[g.service] ?? g.endpoint)
        let conn = Conn(NWConnection(to: ep, using: LANSession.params()))
        server = conn
        welcomed = false
        conn.onMessage = { [weak self, weak conn] w in
            guard let self, let conn, self.server === conn else { return }
            switch w {
            case .welcome(let id, let l):
                self.welcomed = true
                self.lock.lock(); self._localId = id; self.box = NetInbox(); self.box.peers = l.players; self.box.rules = l.rules
                self.lock.unlock()
                self.lobbyQ = l
                self.readvertise()
                self.main { s in
                    guard s.role == .joining else { return }
                    s.role = .joined
                    s.chat = []
                    s.lobby = l
                    s.status = "In \(l.hostName)'s game"
                    s.keepAwake(true)
                    s.onLobby?(l)
                    s.onChange?()
                }
            case .reject(let why):
                self.endJoined(why)
            default:
                self.fromHost(w)
            }
        }
        conn.onClose = { [weak self] in
            guard let self, self.server === conn else { return }
            if !self.welcomed && uptime() < deadline {
                self.q.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.server === conn else { return }
                    self.connect(g, hello: hello, deadline: deadline)
                }
                return
            }
            self.endJoined(self.welcomed ? "Lost connection to the host." : LANSession.unreachable(g))
        }
        conn.start(on: q)
        conn.send(.hello(hello))
        q.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, !self.welcomed, self.server === conn else { return }
            if uptime() < deadline { conn.close() } else { self.endJoined(LANSession.unreachable(g)) }
        }
    }

    private static func unreachable(_ g: DiscoveredGame) -> String {
        g.service.isEmpty
            ? "Couldn't reach \(g.hostName). Check the address, and that the host's firewall lets Bird Game in."
            : "Couldn't reach \(g.hostName)'s game. The host's Mac may be blocking it — their LAN tab says how to fix it."
    }

    /// Accept an invite: join the inviting host's game once it's been found on the network.
    func accept(_ inv: Invite) {
        invites.removeAll { $0 == inv }
        status = "Looking for \(inv.from)'s game…"
        onChange?()
        let give = Date().addingTimeInterval(6)
        func attempt() {
            guard role == .idle else { return }
            if let g = games.first(where: { $0.service == inv.service }) { join(g); return }
            guard Date() < give else {
                status = "Couldn't find \(inv.from)'s game. Maybe they stopped hosting."
                onChange?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { attempt() }
        }
        attempt()
    }

    func dismiss(_ inv: Invite) { invites.removeAll { $0 == inv }; onChange?() }

    private func fromHost(_ w: Wire) {
        switch w {
        case .states(let ss):
            let mine = localId
            let others = ss.filter { $0.id != mine }
            guard !others.isEmpty else { return }
            deliver(others)
        case .state(let s):
            deliver([s])
        case .event(let e):
            deliver(e)
        case .lobby(let l):
            lobbyQ = l
            lock.lock(); box.peers = l.players; box.rules = l.rules; lock.unlock()
            main { s in
                guard s.role == .joined else { return }
                s.lobby = l; s.onLobby?(l); s.onChange?()
            }
        case .match(let m):
            main { s in if s.role == .joined { s.onMatch?(m) } }
        case .chat(let l):
            main { s in if s.role == .joined { s.received(l) } }
        case .kicked:
            endJoined("The host removed you from the game.")
        case .bye:
            endJoined("The host ended the game.")
        default: break
        }
    }

    private func endJoined(_ why: String) {
        guard let s = server else { return }
        let wasIn = welcomed
        server = nil
        welcomed = false
        s.onClose = nil
        s.close()
        lobbyQ = Lobby()
        readvertise()
        lock.lock(); _localId = 1; box = NetInbox(); lock.unlock()
        main { m in
            guard m.role == .joined || m.role == .joining else { return }
            m.role = .idle
            m.lobby = Lobby()
            m.status = why
            m.keepAwake(false)
            // A join that never got in leaves your own game alone.
            if wasIn { m.onEnded?(why) }
            m.onChange?()
        }
    }

    // MARK: Leaving

    /// Leave the game (client), stop trying to join, or end the game for everyone (host).
    func leave() {
        switch role {
        case .joined, .joining:
            q.async { [self] in
                guard let s = server else { return }
                server = nil
                welcomed = false
                s.onClose = nil
                s.send(.bye) { _ in s.close() }
                q.asyncAfter(deadline: .now() + 0.5) { s.close() }
                lobbyQ = Lobby()
                readvertise()
            }
        case .hosting:
            q.async { [self] in
                hostingQ = false
                relayTimer?.cancel()
                relayTimer = nil
                for c in clients.values {
                    c.onClose = nil
                    c.send(.bye) { _ in c.close() }
                }
                clients.removeAll()
                latest.removeAll()
                outbox.removeAll()
                lobbyQ = Lobby()
                readvertise()
            }
        default: return
        }
        let was = role
        role = .idle
        lobby = Lobby()
        status = ""
        keepAwake(false)
        lock.lock(); _localId = 1; box = NetInbox(); lock.unlock()
        if was != .joining { onEnded?(was == .hosting ? "You stopped hosting." : "You left the game.") }
        onChange?()
    }

    func invite(_ p: DiscoveredPeer) {
        guard role == .hosting, p.otherVersion == nil else { return }
        invited.insert(p.service)
        onChange?()
        let msg = Wire.invite(from: name, color: color, service: instance)
        q.async { [self] in sendInvite(msg, to: p.service, fallback: p.endpoint, tries: 3) }
    }

    private func sendInvite(_ msg: Wire, to service: String, fallback: NWEndpoint, tries: Int) {
        let c = Conn(NWConnection(to: endpoints[service] ?? fallback, using: LANSession.params()))
        var sent = false
        c.onClose = { [weak self] in
            guard !sent, tries > 1 else { return }
            self?.q.asyncAfter(deadline: .now() + 1) { self?.sendInvite(msg, to: service, fallback: fallback, tries: tries - 1) }
        }
        c.start(on: q)
        c.send(msg) { [weak self] ok in
            sent = ok
            self?.q.asyncAfter(deadline: .now() + 1) { c.close() }
        }
    }

    // MARK: Chat

    /// Send a message to everyone in the game. Returns false when there's no game (or nothing to say).
    @discardableResult
    func say(_ raw: String) -> Bool {
        guard role == .hosting || role == .joined, let text = ChatLine.clean(raw) else { return false }
        let line = ChatLine(id: localId, name: name, color: color, text: text)
        received(line)
        q.async { [self] in
            if hostingQ {
                guard let d = Conn.frame(.chat(line)) else { return }
                for c in clients.values { c.send(frame: d) }
            } else if welcomed {
                server?.send(.chat(line))
            }
        }
        return true
    }

    /// A note in the chat that only this game sees (e.g. "Alex joined").
    func note(_ text: String) {
        guard role == .hosting || role == .joined else { return }
        received(ChatLine(id: 0, name: "", color: 0, text: text, system: true))
    }

    private func received(_ l: ChatLine) {
        chat.append(l)
        if chat.count > 60 { chat.removeFirst(chat.count - 60) }
        onChat?(l)
    }

    // MARK: NetLink

    func send(state: NetState) {
        q.async { [self] in
            if hostingQ {
                latest[1] = state
                outbox.append(state)
            } else if welcomed {
                server?.send(.state(state))
            }
        }
    }

    func send(event: GameEvent) {
        q.async { [self] in
            if hostingQ {
                guard let d = Conn.frame(.event(event)) else { return }
                for c in clients.values { c.send(frame: d) }
            } else if welcomed {
                server?.send(.event(event))
            }
        }
    }

    /// Hand states to the game. If the game isn't picking them up (window hidden and nothing ticking),
    /// keep only the newest so memory stays flat and nothing floods in later.
    private func deliver(_ ss: [NetState]) {
        lock.lock()
        box.states += ss
        if box.states.count > 480 { box.states.removeFirst(box.states.count - 240) }
        lock.unlock()
    }

    private func deliver(_ e: GameEvent) {
        lock.lock()
        box.events.append(e)
        if box.events.count > 300 {
            // Old attack effects don't matter any more; hits, knock-outs and finishes do.
            box.events.removeAll { if case .fire = $0 { return true }; return false }
            if box.events.count > 300 { box.events.removeFirst(box.events.count - 300) }
        }
        lock.unlock()
    }

    func drain() -> NetInbox {
        lock.lock(); defer { lock.unlock() }
        let b = box
        box = NetInbox()
        return b
    }

    // MARK: This Mac

    /// Keep the game running at full speed while others depend on it, even when it's in the background
    /// (otherwise macOS App Nap slows the host down and everyone stutters).
    private func keepAwake(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                             reason: "Playing a LAN game")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }

    private func setStatus(_ s: String) { status = s; onChange?() }

    private func flag(_ p: Problem, _ on: Bool) {
        let had = problems.contains(p)
        guard had != on else { return }
        if on { problems.insert(p) } else { problems.remove(p) }
        onChange?()
    }

    /// Look up this Mac's addresses and whether the firewall lets friends in (runs in the background).
    func refreshDiagnostics() {
        guard role != .offline else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let addrs = LANSession.localAddresses()
            let blocked = LANSession.firewallBlocksUs()
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = addrs != self.addresses || blocked != self.problems.contains(.firewall)
                self.addresses = addrs
                if blocked { self.problems.insert(.firewall) } else { self.problems.remove(.firewall) }
                if changed { self.onChange?() }
            }
        }
    }

    /// IPv4 addresses on active network interfaces (Wi-Fi / Ethernet), most likely first.
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

    /// True when the macOS firewall is on and blocks incoming connections to this app (or everything).
    static func firewallBlocksUs() -> Bool {
        func fw(_ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: d, as: UTF8.self).lowercased()
        }
        guard fw(["--getglobalstate"]).contains("enabled") else { return false }
        if fw(["--getblockall"]).contains("enabled") { return true }
        guard let exe = Bundle.main.executablePath else { return false }
        return fw(["--getappblocked", exe]).contains("is blocked")
    }

    static func openSettings(for p: Problem) {
        let url = p == .firewall ? "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
                                 : "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// Test hook: pretend to be hosting a game with a few players and people nearby (UI snapshots).
    func debugFill(hosting: Bool, problems: Set<Problem> = []) {
        role = hosting ? .hosting : .idle
        status = hosting ? "Hosting" : "Looking for games on your network…"
        self.problems = problems
        addresses = ["192.168.1.23"]
        listeningPort = LANSession.port
        lobby = Lobby(hostName: name, players: [PeerInfo(id: 1, name: name, color: color, bird: "eagle"),
                                                 PeerInfo(id: 2, name: "Alex", color: 5, bird: "falcon"),
                                                 PeerInfo(id: 3, name: "Sam", color: 2, bird: "sparrow")],
                      rules: MatchRules(collisions: true, pvp: false, showLocation: true), mode: .ringRace, world: "volcano")
        if !hosting { lobby = Lobby() }
        let ep = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        nearby = [DiscoveredPeer(service: "a", name: "Riley", color: 7, inGame: false, endpoint: ep),
                  DiscoveredPeer(service: "b", name: "Jordan", color: 3, inGame: false, endpoint: ep)]
        invited = ["b"]
        games = hosting ? [] : [DiscoveredGame(service: "g", hostName: "Alex", color: 5, mode: .pvp, world: "caves", players: 3, endpoint: ep),
                                DiscoveredGame(service: "h", hostName: "Morgan", color: 6, mode: .freeRoam, world: "meadow", players: 1,
                                               endpoint: ep, otherVersion: "0.2")]
        invites = hosting ? [] : [Invite(from: "Sam", color: 2, service: "s")]
        chat = hosting ? [ChatLine(id: 0, name: "", color: 0, text: "Sam joined", system: true),
                          ChatLine(id: 2, name: "Alex", color: 5, text: "ready when you are"),
                          ChatLine(id: 1, name: name, color: color, text: "starting the race in a sec, get to the line!")] : []
    }

    /// Test hook: stop all network activity without saying goodbye (like a Mac going to sleep).
    func debugGoSilent() { q.suspend() }

    private func main(_ f: @escaping (LANSession) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { f(self) } }
    }
}

// MARK: - Match director (host only, main thread)

/// Runs rounds for a LAN game: who's racing / fighting, finish times, knock-outs, and when it's over.
final class MatchDirector {
    private(set) var round = 0
    private(set) var running = false
    private var mode = GameMode.freeRoam
    private var players: [PeerInfo] = []
    private var finished: [Int: Double] = [:]
    private var out: [Int] = []
    private var kos: [Int: Int] = [:]
    private var started = Date()
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
        let limit = mode == .pvp ? Double(Game.fightLimit) + 3 : 360
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
