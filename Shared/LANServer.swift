import Foundation
import Network

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// Hosts a LAN game without playing in it: Bird Server, the iPhone app (and `--server-test` on a Mac).
///
/// It speaks the same protocol as a Mac hosting a game (`LANSession`), so every Bird Game on
/// `LANProtocol.version` finds it, joins it and plays as usual. Players get ids from 2 up; id 1 is the server
/// itself (its chat messages). It relays flight states and events, runs rounds with a `MatchDirector`,
/// and can invite and remove players. Nothing here needs a screen: the app shows what it publishes.
final class LANServer {
    /// Someone in the game, with what their latest flight state says.
    struct Player: Equatable, Identifiable {
        var id: Int
        var name: String
        var color: Int
        var bird: String
        /// Their game's instance id (removing a player bans it).
        var instance: String
        /// Flags from their latest flight state (`NetState.alive`, `.paused`…); nil until one arrives.
        var flags: Int?
        var hp: Float = 0
        var lives = FightRules.lives
        /// Race progress (gates passed + a fraction).
        var progress: Float = 0
        /// In the round under way (someone who joins mid-round watches until the next one).
        var inRound = false
        /// Race time this round.
        var finishTime: Double?
        /// Out of lives this round.
        var out = false
        var knockouts = 0

        func has(_ flag: Int) -> Bool { (flags ?? 0) & flag != 0 }
    }

    /// Another Bird Game on the network (for invites).
    struct Peer: Equatable, Identifiable {
        /// Instance id.
        var id: String
        var name: String
        var color: Int
        var inGame: Bool
        /// Their app version when it can't play with this server (nil = compatible).
        var otherVersion: String?
        /// Invited in the last minute.
        var invited = false
        var endpoint: NWEndpoint
        var canInvite: Bool { !inGame && otherVersion == nil }
    }

    /// A removed player: their game can't rejoin until allowed back.
    struct Removed: Equatable, Identifiable {
        /// Instance id.
        var id: String
        var name: String
        var color: Int
    }

    enum Problem: Equatable {
        /// Local Network access is turned off for the app, so nobody can find the game.
        case localNetwork
        /// Couldn't take connections (why).
        case network(String)
    }

    let instance = String(UUID().uuidString.prefix(8))
    private let q = DispatchQueue(label: "bird.server")

    // Main-thread state (the app shows these)
    private(set) var hosting = false
    private(set) var lobby = Lobby()
    private(set) var players: [Player] = []
    private(set) var nearby: [Peer] = []
    private(set) var removed: [Removed] = []
    private(set) var chat: [ChatLine] = []
    /// The last round's results (until the next round starts or the game changes).
    private(set) var results: [Standing]?
    /// When the round under way started.
    private(set) var roundStarted: Date?
    private(set) var problem: Problem?
    private(set) var port: UInt16?
    /// This device's address(es), for joining by address.
    private(set) var addresses: [String] = []
    /// Players see "<name>'s game"; the server's chat messages come from this name.
    var name = "iPhone"
    var color = 5

    // Callbacks (main thread)
    var onChange: (() -> Void)?
    /// A player's chat message arrived.
    var onChat: ((ChatLine) -> Void)?
    /// Someone joined (true) or left (false).
    var onPlayer: ((String, Bool) -> Void)?

    /// Test hook: invite only through the TXT record (like a player whose firewall turns away direct invites).
    var debugNoDirectInvites = false

    // Network-queue state
    private var me = (name: "iPhone", color: 5)
    private var online = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var serviceName = ""
    private var advertised: [String: String] = [:]
    private var advertiseQueued = false
    private var endpoints: [String: NWEndpoint] = [:]
    private var peersQ: [Peer] = []
    private var clients: [Int: Conn] = [:]
    private var pending: [ObjectIdentifier: Conn] = [:]
    private var banned: [String: Removed] = [:]
    /// Invited in the last minute (instance id → when the invite lapses), listed in the TXT record.
    private var invitedQ: [String: Double] = [:]
    private var nextId = 2
    private var latest: [Int: NetState] = [:]
    private var outbox: [NetState] = []
    private var relayTimer: DispatchSourceTimer?
    private var ticker: DispatchSourceTimer?
    private var ticks = 0
    private var hostingQ = false
    private var lobbyQ = Lobby()
    private let director = MatchDirector()
    /// When to send everyone back to warm-up after a round's results.
    private var warmupAt: Double?
    /// Recent message times per player (spam guard).
    private var chatTimes: [Int: [Double]] = [:]
    private var shownPlayers: [Player] = []

    init() {
        director.state = { [weak self] id in self?.latest[id] }
    }

    // MARK: Presence

    /// Start looking for Bird Games on the network (for the invite list). Hosting also starts this.
    func goOnline() {
        q.async { [self] in startPresence() }
        refreshAddresses()
    }

    private func startPresence() {
        guard !online else { return }
        online = true
        startBrowser()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    /// Back in the foreground: restart anything the system shut down while the app was away.
    func resume() {
        refreshAddresses()
        q.async { [self] in
            if online, browser == nil { startBrowser() }
            if hostingQ, listener == nil { startListener(fixedPort: true) }
        }
    }

    /// TXT record: the game this server is running.
    private func txt() -> NWTXTRecord {
        var t = NWTXTRecord()
        t["n"] = me.name
        t["c"] = String(me.color)
        t["i"] = instance
        t["v"] = String(LANProtocol.version)
        t["a"] = LANProtocol.gameVersion
        t["h"] = "1"
        t["g"] = "1"
        t["s"] = "1"
        t["m"] = lobbyQ.mode.rawValue
        t["w"] = lobbyQ.world
        t["p"] = String(lobbyQ.players.count)
        if !invitedQ.isEmpty { t["iv"] = LANProtocol.inviteList(invitedQ.sorted { $0.value < $1.value }.map(\.key)) }
        return t
    }

    /// The listener takes joins and advertises the game with Bonjour (only while hosting: a server isn't a player).
    private func startListener(fixedPort: Bool) {
        let l: NWListener
        let params = LANProtocol.parameters()
        // Hosting again right after stopping (or after the app was relaunched) keeps the usual port for joining by address.
        params.allowLocalEndpointReuse = true
        do {
            l = fixedPort ? try NWListener(using: params, on: NWEndpoint.Port(rawValue: LANProtocol.port)!)
                          : try NWListener(using: params)
        } catch {
            if fixedPort { startListener(fixedPort: false) } else { main { $0.flag(.network(error.localizedDescription)) } }
            return
        }
        let t = txt()
        advertised = t.dictionary
        l.service = NWListener.Service(name: serviceName, type: LANProtocol.serviceType, domain: nil, txtRecord: t)
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l, self.listener === l else { return }
            switch st {
            case .ready:
                let p = l.port?.rawValue
                self.main { s in
                    s.port = p
                    if case .network? = s.problem { s.problem = nil }
                    s.onChange?()
                }
            case .waiting(let e):
                if LANProtocol.isPolicyDenied(e) { self.main { $0.flag(.localNetwork) } }
            case .failed(let e):
                l.cancel()
                self.listener = nil
                guard self.hostingQ else { return }
                if fixedPort, case .posix(let code) = e, code == .EADDRINUSE {
                    // Something else has the port: any free one works for Bonjour.
                    self.startListener(fixedPort: false)
                } else {
                    // The network changed, or the system took the socket back while the app was suspended: start again.
                    self.main { $0.flag(.network(e.localizedDescription)) }
                    self.q.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self, self.hostingQ, self.listener == nil else { return }
                        self.startListener(fixedPort: true)
                    }
                }
            default: break
            }
        }
        l.start(queue: q)
        listener = l
    }

    private func startBrowser() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: LANProtocol.serviceType, domain: nil), using: LANProtocol.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.discovered(results) }
        b.stateUpdateHandler = { [weak self, weak b] st in
            guard let self, let b, self.browser === b else { return }
            switch st {
            case .ready:
                self.main { s in
                    guard s.problem == .localNetwork else { return }
                    s.problem = nil
                    s.onChange?()
                }
            case .waiting(let e):
                if LANProtocol.isPolicyDenied(e) { self.main { $0.flag(.localNetwork) } }
            case .failed:
                // Start again (e.g. after the network changed).
                b.cancel()
                self.browser = nil
                self.q.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.online, self.browser == nil else { return }
                    self.startBrowser()
                }
            default: break
            }
        }
        b.start(queue: q)
        browser = b
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
            l.service = NWListener.Service(name: serviceName, type: LANProtocol.serviceType, domain: nil, txtRecord: t)
        }
    }

    private func discovered(_ results: Set<NWBrowser.Result>) {
        var list: [Peer] = []
        var eps: [String: NWEndpoint] = [:]
        for r in results {
            guard case .service = r.endpoint, case .bonjour(let t) = r.metadata, let svc = t["i"], svc != instance else { continue }
            eps[svc] = r.endpoint
            // Other servers aren't players.
            guard t["s"] != "1" else { continue }
            // 0.2 didn't advertise its app version.
            let other: String? = t["v"] == String(LANProtocol.version) ? nil : (t["a"] ?? (t["v"] == "3" ? "0.2" : "another version"))
            list.append(Peer(id: svc, name: t["n"] ?? "Player", color: Int(t["c"] ?? "0") ?? 0, inGame: t["g"] == "1",
                             otherVersion: other, endpoint: r.endpoint))
        }
        endpoints = eps
        peersQ = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        publishPeers()
    }

    /// Nearby players for the invite list (not the ones already in this game).
    private func publishPeers() {
        let here = Set(clients.values.map(\.instance))
        let list = peersQ.filter { !here.contains($0.id) }.map { p -> Peer in
            var p = p
            p.invited = invitedQ[p.id] != nil
            return p
        }
        main { s in
            guard s.nearby != list else { return }
            s.nearby = list
            s.onChange?()
        }
    }

    // MARK: Heartbeat, rounds and the status the app shows (twice a second)

    private func tick() {
        ticks += 1
        let now = uptime()
        if ticks % 2 == 0 {
            // A player whose Mac sleeps or leaves the Wi-Fi goes quiet: drop them after the timeout.
            for c in clients.values {
                if now - c.lastHeard > LANProtocol.timeout { c.close() } else { c.send(.ping) }
            }
            // Connections that never said hello.
            for c in pending.values where now - c.opened > 10 { c.close() }
        }
        // Invites lapse after a minute (and can be sent again).
        let lapsed = invitedQ.filter { $0.value < now }.map(\.key)
        if !lapsed.isEmpty {
            for k in lapsed { invitedQ.removeValue(forKey: k) }
            readvertise()
            publishPeers()
        }
        // Rounds: time limits, and back to warm-up after a look at the results.
        if let c = director.tick() { finishRound(c) }
        if let w = warmupAt, now >= w {
            warmupAt = nil
            if hostingQ && !director.running { broadcast(.warmup) }
        }
        publishPlayers()
    }

    private func publishPlayers() {
        let rows = lobbyQ.players.map { p -> Player in
            let st = latest[p.id]
            return Player(id: p.id, name: p.name, color: p.color, bird: p.bird, instance: clients[p.id]?.instance ?? "",
                          flags: st?.flags, hp: st?.hp ?? 0, lives: st?.lives ?? FightRules.lives, progress: st?.progress ?? 0,
                          inRound: director.running && director.players.contains { $0.id == p.id },
                          finishTime: director.finishTime(of: p.id), out: director.isOut(p.id), knockouts: director.knockouts(of: p.id))
        }
        guard rows != shownPlayers else { return }
        shownPlayers = rows
        main { s in
            s.players = rows
            s.onChange?()
        }
    }

    // MARK: Players joining

    private func accept(_ nc: NWConnection) {
        let conn = Conn(nc)
        let key = ObjectIdentifier(conn)
        pending[key] = conn
        conn.onClose = { [weak self] in self?.pending.removeValue(forKey: key) }
        conn.onMessage = { [weak self, weak conn] w in
            guard let self, let conn else { return }
            switch w {
            case .hello(let h): self.pending.removeValue(forKey: key); self.admit(conn, h)
            // An invite for a server has nobody to show it to.
            case .invite: conn.close()
            default: break
            }
        }
        conn.start(on: q)
    }

    private func admit(_ conn: Conn, _ h: Hello) {
        func reject(_ why: String) { conn.send(.reject(why)) { _ in conn.close() } }
        guard hostingQ else { reject("That game has ended."); return }
        guard h.version == LANProtocol.version else {
            reject("That game is for Bird Game \(LANProtocol.gameVersion). You need the same version to play together.")
            return
        }
        guard banned[h.instance] == nil else { reject("The host removed you from this game."); return }
        // The same game reconnecting (e.g. after a Wi-Fi blip): drop its old connection first.
        if let old = clients.first(where: { $0.value.instance == h.instance }) { old.value.close() }
        guard clients.count < LANProtocol.maxPlayers else { reject("That game is full."); return }
        let id = nextId
        nextId += 1
        conn.id = id
        conn.instance = h.instance
        let n = h.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = PeerInfo(id: id, name: String((n.isEmpty ? "Player" : n).prefix(20)), color: h.color, bird: h.bird, fit: h.fit)
        conn.info = info
        clients[id] = conn
        conn.onMessage = { [weak self] w in self?.fromClient(id, w) }
        conn.onClose = { [weak self] in self?.dropClient(id) }
        lobbyQ.players.append(info)
        conn.send(.welcome(id: id, lobby: lobbyQ))
        if relayTimer == nil { startRelay() }
        pushLobby()
        publishPeers()
        main { s in
            s.note("\(info.name) joined")
            s.onPlayer?(info.name, true)
        }
    }

    private func fromClient(_ id: Int, _ w: Wire) {
        switch w {
        case .state(var s):
            s.id = id
            latest[id] = s
            outbox.append(s)
            if let i = lobbyQ.players.firstIndex(where: { $0.id == id }), lobbyQ.players[i].bird != s.bird || lobbyQ.players[i].fit != s.fit {
                lobbyQ.players[i].bird = s.bird
                lobbyQ.players[i].fit = s.fit
                pushLobby()
            }
        case .event(let raw):
            let e = raw.from(id)
            if let d = Conn.frame(.event(e)) { for (cid, c) in clients where cid != id { c.send(frame: d) } }
            if let c = director.handle(e) { finishRound(c) }
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
            main { s in
                s.received(l)
                s.onChat?(l)
            }
        case .bye:
            clients[id]?.close()
        default: break
        }
    }

    private func dropClient(_ id: Int) {
        guard let c = clients.removeValue(forKey: id) else { return }
        latest.removeValue(forKey: id)
        chatTimes.removeValue(forKey: id)
        lobbyQ.players.removeAll { $0.id == id }
        if clients.isEmpty {
            relayTimer?.cancel()
            relayTimer = nil
            outbox.removeAll()
        }
        pushLobby()
        publishPeers()
        if let cmd = director.playerLeft(id) { finishRound(cmd) }
        let who = c.info?.name ?? "Someone", kicked = banned[c.instance] != nil
        main { s in
            s.note(kicked ? "\(who) was removed" : "\(who) left")
            s.onPlayer?(who, false)
        }
    }

    /// Send the lobby to everyone (and the app).
    private func pushLobby() {
        let l = lobbyQ
        if let d = Conn.frame(.lobby(l)) { for c in clients.values { c.send(frame: d) } }
        readvertise()
        main { s in
            s.lobby = l
            s.onChange?()
        }
        publishPlayers()
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

    // MARK: Hosting

    /// Start hosting: the game shows up on everyone's network as "<name>'s game".
    func start(mode: GameMode, world: String, rules: MatchRules) {
        guard !hosting else { return }
        hosting = true
        chat = []
        results = nil
        roundStarted = nil
        lobby = Lobby(hostName: name, players: [], rules: rules, mode: mode, world: world, running: false)
        let profile = (name, color)
        q.async { [self] in
            startPresence()
            me = profile
            serviceName = "\(profile.0.prefix(30)) · \(instance)"
            hostingQ = true
            nextId = 2
            latest = [:]
            outbox = []
            banned = [:]
            invitedQ = [:]
            chatTimes = [:]
            warmupAt = nil
            director.stop()
            lobbyQ = Lobby(hostName: profile.0, players: [], rules: rules, mode: mode, world: world, running: false)
            startListener(fixedPort: true)
            pushLobby()
            publishRemoved()
        }
        refreshAddresses()
        onChange?()
    }

    /// Stop hosting: everyone is told the game is over.
    func stop() {
        guard hosting else { return }
        hosting = false
        lobby = Lobby()
        players = []
        removed = []
        results = nil
        roundStarted = nil
        port = nil
        q.async { [self] in
            hostingQ = false
            listener?.cancel()
            listener = nil
            relayTimer?.cancel()
            relayTimer = nil
            for c in clients.values {
                c.onClose = nil
                c.send(.bye) { _ in c.close() }
                q.asyncAfter(deadline: .now() + 0.5) { c.close() }
            }
            clients.removeAll()
            for c in pending.values { c.close() }
            latest.removeAll()
            outbox.removeAll()
            invitedQ = [:]
            banned = [:]
            director.stop()
            warmupAt = nil
            lobbyQ = Lobby()
            shownPlayers = []
            publishPeers()
        }
        onChange?()
    }

    /// Change the mode and / or map for everyone (a round under way ends without results).
    func play(_ mode: GameMode, on world: String) {
        guard hosting, mode != lobby.mode || world != lobby.world else { return }
        lobby.mode = mode
        lobby.world = world
        lobby.running = false
        results = nil
        roundStarted = nil
        onChange?()
        q.async { [self] in
            guard hostingQ else { return }
            director.stop()
            warmupAt = nil
            lobbyQ.mode = mode
            lobbyQ.world = world
            lobbyQ.running = false
            pushLobby()
        }
    }

    func setRules(_ r: MatchRules) {
        guard hosting, r != lobby.rules else { return }
        lobby.rules = r
        onChange?()
        q.async { [self] in
            guard hostingQ else { return }
            lobbyQ.rules = r
            pushLobby()
        }
    }

    /// Start a race or fight: everyone lines up and counts down from 3.
    func startRound() {
        q.async { [self] in
            guard hostingQ, lobbyQ.mode != .freeRoam, !director.running, !lobbyQ.players.isEmpty else { return }
            warmupAt = nil
            let cmd = director.start(mode: lobbyQ.mode, players: lobbyQ.players)
            broadcast(cmd)
            lobbyQ.running = true
            pushLobby()
            main { s in
                s.results = nil
                s.roundStarted = Date()
                s.onChange?()
            }
        }
    }

    /// End the round under way now, with results as things stand.
    func endRound() {
        q.async { [self] in
            guard hostingQ, let cmd = director.finishNow() else { return }
            finishRound(cmd)
        }
    }

    private func finishRound(_ c: MatchCommand) {
        broadcast(c)
        lobbyQ.running = false
        pushLobby()
        if case .results(_, let standings) = c {
            main { s in
                s.results = standings
                s.roundStarted = nil
                s.onChange?()
            }
        }
        warmupAt = uptime() + 14
    }

    private func broadcast(_ m: MatchCommand) {
        guard let d = Conn.frame(.match(m)) else { return }
        for c in clients.values { c.send(frame: d) }
    }

    /// Remove a player. Their game can't rejoin until allowed back.
    func kick(_ id: Int) {
        q.async { [self] in
            guard let c = clients[id], let info = c.info else { return }
            if !c.instance.isEmpty { banned[c.instance] = Removed(id: c.instance, name: info.name, color: info.color) }
            publishRemoved()
            c.send(.kicked) { _ in c.close() }
            q.asyncAfter(deadline: .now() + 0.5) { c.close() }
        }
    }

    /// Let a removed player join again.
    func allowBack(_ instance: String) {
        q.async { [self] in
            guard banned.removeValue(forKey: instance) != nil else { return }
            publishRemoved()
        }
    }

    private func publishRemoved() {
        let list = banned.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        main { s in
            s.removed = list
            s.onChange?()
        }
    }

    /// Invite someone on the network: their game offers to join ("press J to join" on a Mac).
    /// The invite is listed in the TXT record, which every Bird Game from 0.3.1 on reads, and also sent directly,
    /// which reaches 0.3 too (unless the player's firewall turns it away, like on a school Mac).
    func invite(_ peer: String) {
        let msg = Wire.invite(from: name, color: color, service: instance)
        let direct = !debugNoDirectInvites
        q.async { [self] in
            guard hostingQ, let p = peersQ.first(where: { $0.id == peer }), p.otherVersion == nil else { return }
            invitedQ[peer] = uptime() + LANProtocol.inviteLife
            readvertise()
            publishPeers()
            if direct { sendInvite(msg, to: peer, fallback: p.endpoint, tries: 3) }
        }
    }

    private func sendInvite(_ msg: Wire, to service: String, fallback: NWEndpoint, tries: Int) {
        let c = Conn(NWConnection(to: endpoints[service] ?? fallback, using: LANProtocol.parameters()))
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

    /// The host's name or color changed.
    func updateProfile() {
        let (n, c) = (name, color)
        if hosting { lobby.hostName = n }
        q.async { [self] in
            me = (n, c)
            guard hostingQ else { return }
            lobbyQ.hostName = n
            pushLobby()
        }
    }

    // MARK: Chat

    /// Send a message to everyone. Returns false when there's no game (or nothing to say).
    @discardableResult
    func say(_ raw: String) -> Bool {
        guard hosting, let text = ChatLine.clean(raw) else { return false }
        let line = ChatLine(id: 1, name: name, color: color, text: text)
        received(line)
        q.async { [self] in
            guard let d = Conn.frame(.chat(line)) else { return }
            for c in clients.values { c.send(frame: d) }
        }
        return true
    }

    /// A note in the chat that only the app shows (e.g. "Alex joined").
    private func note(_ text: String) { received(ChatLine(id: 0, name: "", color: 0, text: text, system: true)) }

    private func received(_ l: ChatLine) {
        chat.append(l)
        if chat.count > 100 { chat.removeFirst(chat.count - 100) }
        onChange?()
    }

    // MARK: This device

    /// Look up this device's addresses (in the background).
    func refreshAddresses() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let a = LANProtocol.localAddresses()
            DispatchQueue.main.async {
                guard let self, a != self.addresses else { return }
                self.addresses = a
                self.onChange?()
            }
        }
    }

    private func flag(_ p: Problem) {
        guard problem != p else { return }
        problem = p
        onChange?()
    }

    private func main(_ f: @escaping (LANServer) -> Void) {
        DispatchQueue.main.async { [weak self] in if let self { f(self) } }
    }
}
