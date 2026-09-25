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
}

/// A game someone is hosting on the local network.
struct DiscoveredGame: Equatable {
    /// The host's instance id (stable, unlike the Bonjour service name).
    var service: String
    var hostName: String
    var color: Int
    var mode: GameMode
    var world: String
    var players: Int
    var endpoint: NWEndpoint
}

/// Another Bird Game on the network (for invites).
struct DiscoveredPeer: Equatable {
    /// Instance id.
    var service: String
    var name: String
    var color: Int
    var inGame: Bool
    var endpoint: NWEndpoint
}

struct Invite: Equatable {
    var from: String
    var color: Int
    var service: String
}

// MARK: - Connection

/// One TCP connection carrying length-prefixed JSON messages.
private final class Conn {
    let c: NWConnection
    var id = 0
    var info: PeerInfo?
    var onMessage: ((Wire) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    init(_ c: NWConnection) { self.c = c }

    func start(on q: DispatchQueue) {
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        c.start(queue: q)
        receive()
    }

    func send(_ w: Wire, then: (() -> Void)? = nil) {
        guard !closed, let body = try? Conn.encoder.encode(w) else { return }
        var len = UInt32(body.count).bigEndian
        var d = Data(bytes: &len, count: 4)
        d.append(body)
        c.send(content: d, completion: .contentProcessed { _ in then?() })
    }

    private func receive() {
        c.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] head, _, _, err in
            guard let self else { return }
            guard err == nil, let head, head.count == 4 else { self.finish(); return }
            let len = Int(UInt32(bigEndian: head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard len > 0, len < 4_000_000 else { self.finish(); return }
            self.c.receive(minimumIncompleteLength: len, maximumLength: len) { body, _, done2, err2 in
                guard err2 == nil, let body, body.count == len else { self.finish(); return }
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
    static let protocolVersion = 3
    static let maxPlayers = 8

    enum Role: Equatable { case offline, idle, hosting, joined }

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

    // Network-queue state
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var serviceName = ""
    private var clients: [Int: Conn] = [:]
    private var pending: [ObjectIdentifier: Conn] = [:]
    private var nextId = 2
    private var server: Conn?
    private var latest: [Int: NetState] = [:]
    private var relayTimer: DispatchSourceTimer?
    private var hostingQ = false
    private var lobbyQ = Lobby()

    // NetLink (any thread, under `lock`)
    private var _localId = 1
    private var box = NetInbox()
    var localId: Int { lock.lock(); defer { lock.unlock() }; return _localId }

    private static func params() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let p = NWParameters(tls: nil, tcp: tcp)
        p.includePeerToPeer = true
        // Tests on one Mac: stay on loopback (no Local Network permission needed).
        if ProcessInfo.processInfo.environment["BIRD_LOOPBACK"] != nil { p.requiredInterfaceType = .loopback }
        return p
    }

    // MARK: Presence

    /// Start advertising this copy of the game and looking for others.
    func goOnline() {
        guard role == .offline else { return }
        role = .idle
        status = "Looking for games on your network…"
        q.async { [self] in
            serviceName = "\(name) · \(instance)"
            startListener()
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: LANSession.serviceType, domain: nil), using: LANSession.params())
            b.browseResultsChangedHandler = { [weak self] results, _ in self?.discovered(results) }
            b.start(queue: q)
            browser = b
        }
        onChange?()
    }

    /// TXT record: who we are and what we're hosting.
    private func txt() -> NWTXTRecord {
        var t = NWTXTRecord()
        t["n"] = name
        t["c"] = String(color)
        t["i"] = instance
        t["v"] = String(LANSession.protocolVersion)
        t["h"] = hostingQ ? "1" : "0"
        t["g"] = hostingQ || server != nil ? "1" : "0"
        t["m"] = lobbyQ.mode.rawValue
        t["w"] = lobbyQ.world
        t["p"] = String(lobbyQ.players.count)
        return t
    }

    /// One listener takes joins and invites and advertises us with Bonjour.
    private func startListener() {
        do {
            let l = try NWListener(using: LANSession.params())
            l.service = NWListener.Service(name: serviceName, type: LANSession.serviceType, domain: nil, txtRecord: txt())
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st { self?.main { $0.status = "Network error: \(e.localizedDescription)" } }
            }
            l.start(queue: q)
            listener = l
        } catch {
            main { $0.status = "Couldn't start networking: \(error.localizedDescription)" }
        }
    }

    private var readvertiseQueued = false

    /// Publish a new TXT record. A running listener can't change its record, so it's replaced (connections it
    /// already accepted stay open). Batched so a burst of lobby changes re-registers once.
    private func readvertise() {
        guard listener != nil, !readvertiseQueued else { return }
        readvertiseQueued = true
        q.asyncAfter(deadline: .now() + 0.25) { [self] in
            readvertiseQueued = false
            guard let old = listener else { return }
            old.newConnectionHandler = nil
            old.stateUpdateHandler = nil
            old.cancel()
            startListener()
        }
    }

    /// Name or color changed.
    func updateProfile() {
        let (n, c, b) = (name, color, bird)
        q.async { [self] in
            readvertise()
            if hostingQ, let i = lobbyQ.players.firstIndex(where: { $0.id == 1 }) {
                lobbyQ.players[i].name = n; lobbyQ.players[i].color = c; lobbyQ.players[i].bird = b
                lobbyQ.hostName = n
                pushLobby()
            }
        }
    }

    private func discovered(_ results: Set<NWBrowser.Result>) {
        var g: [DiscoveredGame] = [], p: [DiscoveredPeer] = []
        for r in results {
            guard case .service = r.endpoint, case .bonjour(let t) = r.metadata, let svc = t["i"] else { continue }
            guard svc != instance, t["v"] == String(LANSession.protocolVersion) else { continue }
            let n = t["n"] ?? "Player", c = Int(t["c"] ?? "0") ?? 0
            if t["h"] == "1" {
                g.append(DiscoveredGame(service: svc, hostName: n, color: c, mode: GameMode(rawValue: t["m"] ?? "") ?? .freeRoam,
                                        world: t["w"] ?? "meadow", players: Int(t["p"] ?? "1") ?? 1, endpoint: r.endpoint))
            }
            p.append(DiscoveredPeer(service: svc, name: n, color: c, inGame: t["g"] == "1", endpoint: r.endpoint))
        }
        g.sort { $0.hostName < $1.hostName }
        p.sort { $0.name < $1.name }
        main { s in
            s.games = g
            s.nearby = p
            s.invites.removeAll { inv in !p.contains { $0.service == inv.service } }
            s.onChange?()
        }
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
                let inv = Invite(from: from, color: color, service: service)
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
        guard hostingQ else { conn.send(.reject("That game has ended.")) { conn.close() }; return }
        guard h.version == LANSession.protocolVersion else { conn.send(.reject("Different game version — update Bird Game.")) { conn.close() }; return }
        guard clients.count + 1 < LANSession.maxPlayers else { conn.send(.reject("That game is full.")) { conn.close() }; return }
        let id = nextId
        nextId += 1
        conn.id = id
        conn.info = PeerInfo(id: id, name: String(h.name.prefix(20)), color: h.color, bird: h.bird)
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
            lock.lock(); box.states.append(s); lock.unlock()
            if let i = lobbyQ.players.firstIndex(where: { $0.id == id }), lobbyQ.players[i].bird != s.bird {
                lobbyQ.players[i].bird = s.bird
                pushLobby()
            }
        case .event(let e):
            for (cid, c) in clients where cid != id { c.send(.event(e)) }
            lock.lock(); box.events.append(e); lock.unlock()
            main { $0.onEvent?(id, e) }
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
        for c in clients.values { c.send(.lobby(l)) }
        lock.lock(); box.peers = l.players; box.rules = l.rules; lock.unlock()
        readvertise()
        main { s in s.lobby = l; s.onLobby?(l); s.onChange?() }
    }

    // MARK: Hosting

    func host(mode: GameMode, world: String, rules: MatchRules) {
        guard role == .idle else { return }
        role = .hosting
        status = "Hosting"
        let me = PeerInfo(id: 1, name: name, color: color, bird: bird)
        lock.lock(); _localId = 1; box = NetInbox(); lock.unlock()
        q.async { [self] in
            hostingQ = true
            nextId = 2
            latest = [:]
            lobbyQ = Lobby(hostName: me.name, players: [me], rules: rules, mode: mode, world: world, running: false)
            startRelay()
            pushLobby()
        }
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
        q.async { [self] in for c in clients.values { c.send(.match(m)) } }
    }

    func kick(_ id: Int) {
        q.async { [self] in
            guard let c = clients[id] else { return }
            c.send(.kicked) { c.close() }
            q.asyncAfter(deadline: .now() + 0.5) { c.close() }
        }
    }

    /// Latest reported state per player (host), for standings.
    func latestState(of id: Int) -> NetState? {
        var v: NetState?
        q.sync { v = latest[id] }
        return v
    }

    private func startRelay() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in
            guard let self, self.hostingQ else { return }
            let all = Array(self.latest.values)
            for (id, c) in self.clients {
                let others = all.filter { $0.id != id }
                if !others.isEmpty { c.send(.states(others)) }
            }
        }
        t.resume()
        relayTimer = t
    }

    // MARK: Joining

    func join(_ g: DiscoveredGame) {
        guard role == .idle else { return }
        role = .joined
        status = "Joining \(g.hostName)…"
        invites.removeAll { $0.service == g.service }
        onChange?()
        let hello = Hello(name: name, color: color, bird: bird, version: LANSession.protocolVersion, instance: instance)
        let deadline = Date().addingTimeInterval(8)
        q.async { [self] in connect(g, hello: hello, deadline: deadline) }
    }

    /// One attempt at reaching the host; retried for a few seconds (the host may be re-advertising).
    private func connect(_ g: DiscoveredGame, hello: Hello, deadline: Date) {
        do {
            let conn = Conn(NWConnection(to: g.endpoint, using: LANSession.params()))
            server = conn
            var welcomed = false
            conn.onMessage = { [weak self] w in
                guard let self else { return }
                switch w {
                case .welcome(let id, let l):
                    welcomed = true
                    self.lock.lock(); self._localId = id; self.box = NetInbox(); self.box.peers = l.players; self.box.rules = l.rules
                    self.lock.unlock()
                    self.lobbyQ = l
                    self.readvertise()
                    self.main { s in s.lobby = l; s.status = "In \(l.hostName)'s game"; s.onLobby?(l); s.onChange?() }
                case .reject(let why):
                    welcomed = true
                    self.endJoined(why)
                default:
                    self.fromHost(w)
                }
            }
            conn.onClose = { [weak self] in
                guard let self, self.server === conn else { return }
                if !welcomed && Date() < deadline {
                    self.q.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        guard let self, self.server === conn else { return }
                        self.connect(g, hello: hello, deadline: deadline)
                    }
                    return
                }
                self.endJoined(welcomed ? "Lost connection to the host."
                               : "Couldn't reach that game. Check that Bird Game is allowed in System Settings › Privacy & Security › Local Network.")
            }
            conn.start(on: q)
            conn.send(.hello(hello))
            q.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !welcomed, self.server === conn else { return }
                if Date() < deadline { conn.close() } else { self.endJoined("That game didn't answer.") }
            }
        }
    }

    /// Accept an invite: join the inviting host's game once it's been found on the network.
    func accept(_ inv: Invite) {
        invites.removeAll { $0 == inv }
        if let g = games.first(where: { $0.service == inv.service }) { join(g); return }
        status = "Looking for \(inv.from)'s game…"
        onChange?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.role == .idle else { return }
            if let g = self.games.first(where: { $0.service == inv.service }) { self.join(g) } else {
                self.status = "Couldn't find \(inv.from)'s game."
                self.onChange?()
            }
        }
    }

    func dismiss(_ inv: Invite) { invites.removeAll { $0 == inv }; onChange?() }

    private func fromHost(_ w: Wire) {
        switch w {
        case .states(let ss):
            lock.lock(); box.states += ss; lock.unlock()
        case .event(let e):
            lock.lock(); box.events.append(e); lock.unlock()
        case .lobby(let l):
            lobbyQ = l
            lock.lock(); box.peers = l.players; box.rules = l.rules; lock.unlock()
            readvertise()
            main { s in s.lobby = l; s.onLobby?(l); s.onChange?() }
        case .match(let m):
            main { $0.onMatch?(m) }
        case .kicked:
            endJoined("The host removed you from the game.")
        case .bye:
            endJoined("The host ended the game.")
        default: break
        }
    }

    private func endJoined(_ why: String) {
        guard let s = server else { return }
        server = nil
        s.onClose = nil
        s.close()
        lobbyQ = Lobby()
        readvertise()
        main { m in
            guard m.role == .joined else { return }
            m.role = .idle
            m.lobby = Lobby()
            m.status = why
            m.onEnded?(why)
            m.onChange?()
        }
    }

    // MARK: Leaving

    /// Leave the game (client) or end it for everyone (host).
    func leave() {
        switch role {
        case .joined:
            q.async { [self] in
                guard let s = server else { return }
                server = nil
                s.onClose = nil
                s.send(.bye) { s.close() }
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
                    c.send(.bye) { c.close() }
                }
                clients.removeAll()
                latest.removeAll()
                lobbyQ = Lobby()
                readvertise()
            }
        default: return
        }
        let was = role
        role = .idle
        lobby = Lobby()
        status = ""
        lock.lock(); _localId = 1; box = NetInbox(); lock.unlock()
        onEnded?(was == .hosting ? "You stopped hosting." : "You left the game.")
        onChange?()
    }

    func invite(_ p: DiscoveredPeer) {
        guard role == .hosting else { return }
        invited.insert(p.service)
        onChange?()
        let msg = Wire.invite(from: name, color: color, service: instance)
        q.async {
            let c = Conn(NWConnection(to: p.endpoint, using: LANSession.params()))
            c.start(on: self.q)
            c.send(msg) { self.q.asyncAfter(deadline: .now() + 1) { c.close() } }
        }
    }

    // MARK: NetLink

    func send(state: NetState) {
        q.async { [self] in
            if hostingQ {
                latest[1] = state
            } else {
                server?.send(.state(state))
            }
        }
    }

    func send(event: GameEvent) {
        q.async { [self] in
            if hostingQ {
                for c in clients.values { c.send(.event(event)) }
            } else {
                server?.send(.event(event))
            }
        }
    }

    func drain() -> NetInbox {
        lock.lock(); defer { lock.unlock() }
        let b = box
        box = NetInbox()
        return b
    }

    /// Test hook: pretend to be hosting a game with a few players and people nearby (UI snapshots).
    func debugFill(hosting: Bool) {
        role = hosting ? .hosting : .idle
        status = hosting ? "Hosting" : "Looking for games on your network…"
        lobby = Lobby(hostName: name, players: [PeerInfo(id: 1, name: name, color: color, bird: "eagle"),
                                                 PeerInfo(id: 2, name: "Alex", color: 5, bird: "falcon"),
                                                 PeerInfo(id: 3, name: "Sam", color: 2, bird: "sparrow")],
                      rules: MatchRules(collisions: true, pvp: false, showLocation: true), mode: .ringRace, world: "volcano")
        if !hosting { lobby = Lobby() }
        let ep = NWEndpoint.hostPort(host: "127.0.0.1", port: 1)
        nearby = [DiscoveredPeer(service: "a", name: "Riley", color: 7, inGame: false, endpoint: ep),
                  DiscoveredPeer(service: "b", name: "Jordan", color: 3, inGame: false, endpoint: ep)]
        invited = ["b"]
        games = hosting ? [] : [DiscoveredGame(service: "g", hostName: "Alex", color: 5, mode: .pvp, world: "caves", players: 3, endpoint: ep)]
        invites = hosting ? [] : [Invite(from: "Sam", color: 2, service: "s")]
    }

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
            guard finished[id] == nil else { return nil }
            finished[id] = time
            if firstFinish == nil { firstFinish = Date() }
        case .died(_, let killer):
            if mode == .pvp && killer != 0 { kos[killer, default: 0] += 1 }
            return nil
        case .eliminated(let id):
            guard mode == .pvp, !out.contains(id) else { return nil }
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
