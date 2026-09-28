import SwiftUI
import UIKit

/// The app's state: mirrors the server for SwiftUI, remembers the settings, and keeps the app running while it hosts.
@MainActor
@Observable
final class ServerModel {
    enum Tab: Hashable { case game, players, chat }

    let server = LANServer()
    private let keepAlive = KeepAlive()
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    // What the server publishes
    private(set) var hosting = false
    private(set) var lobby = Lobby()
    private(set) var players: [LANServer.Player] = []
    private(set) var nearby: [LANServer.Peer] = []
    private(set) var removed: [LANServer.Removed] = []
    private(set) var chat: [ChatLine] = []
    private(set) var results: [Standing]?
    private(set) var roundStarted: Date?
    private(set) var problem: LANServer.Problem?
    private(set) var port: UInt16?
    private(set) var addresses: [String] = []
    /// Silent audio is keeping the app running, so it can host with the phone locked.
    private(set) var keptAlive = false

    var tab = Tab.game {
        didSet { if tab == .chat { unread = 0 } }
    }
    /// Chat messages that arrived while the Chat tab wasn't showing.
    var unread = 0

    // Settings (remembered between launches)
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "name") }
    }
    var color: Int {
        didSet {
            UserDefaults.standard.set(color, forKey: "color")
            pushProfile()
        }
    }
    var keepRunning: Bool {
        didSet {
            UserDefaults.standard.set(keepRunning, forKey: "keepRunning")
            updateKeepAlive()
        }
    }
    /// What's played (while hosting) or what hosting starts with.
    private(set) var mode: GameMode
    private(set) var world: String
    private(set) var rules: MatchRules

    init() {
        let d = UserDefaults.standard
        name = d.string(forKey: "name") ?? "iPhone"
        color = d.object(forKey: "color") as? Int ?? 5
        keepRunning = d.object(forKey: "keepRunning") as? Bool ?? true
        mode = GameMode(rawValue: d.string(forKey: "mode") ?? "") ?? .freeRoam
        world = Maps.valid(d.string(forKey: "world"))
        rules = d.data(forKey: "rules").flatMap { try? JSONDecoder().decode(MatchRules.self, from: $0) } ?? MatchRules()
        server.name = hostName
        server.color = color
        // The server calls back on the main thread.
        server.onChange = { [weak self] in MainActor.assumeIsolated { self?.sync() } }
        server.onChat = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.tab != .chat else { return }
                self.unread += 1
            }
        }
        keepAlive.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.updateKeepAlive() } }
        server.goOnline()
    }

    /// The name players see ("<name>'s game"), tidied up.
    var hostName: String {
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        return n.isEmpty ? "iPhone" : n
    }

    /// Where Macs can type to join, when the game doesn't show up in their list.
    var address: String? {
        guard let a = addresses.first else { return nil }
        if let p = port, p != LANProtocol.port { return "\(a):\(p)" }
        return a
    }

    private func sync() {
        set(\.hosting, server.hosting)
        set(\.lobby, server.lobby)
        set(\.players, server.players)
        set(\.nearby, server.nearby)
        set(\.removed, server.removed)
        set(\.chat, server.chat)
        set(\.results, server.results)
        set(\.roundStarted, server.roundStarted)
        set(\.problem, server.problem)
        set(\.port, server.port)
        set(\.addresses, server.addresses)
    }

    /// Only touch what changed, so SwiftUI redraws only what it must.
    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<ServerModel, T>, _ value: T) {
        if self[keyPath: key] != value { self[keyPath: key] = value }
    }

    // MARK: Hosting

    func startHosting() {
        commitName()
        server.start(mode: mode, world: world, rules: rules)
        unread = 0
        tab = .game
        sync()
        updateKeepAlive()
    }

    func stopHosting() {
        server.stop()
        sync()
        updateKeepAlive()
    }

    func choose(mode m: GameMode) {
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        server.play(m, on: world)
    }

    func choose(world w: String) {
        world = w
        UserDefaults.standard.set(w, forKey: "world")
        server.play(mode, on: w)
    }

    func choose(rules r: MatchRules) {
        rules = r
        UserDefaults.standard.set(try? JSONEncoder().encode(r), forKey: "rules")
        server.setRules(r)
    }

    /// Done editing the name: tidy it and tell the players.
    func commitName() {
        if name != hostName { name = hostName }
        pushProfile()
    }

    private func pushProfile() {
        guard server.name != hostName || server.color != color else { return }
        server.name = hostName
        server.color = color
        server.updateProfile()
    }

    /// Live place in a race (finishers by time, everyone else by how far along they are).
    func place(of p: LANServer.Player) -> Int? {
        guard lobby.running, lobby.mode.isRace, p.inRound else { return nil }
        let ahead = players.filter(\.inRound).filter { o in
            if let a = o.finishTime { return p.finishTime.map { a < $0 } ?? true }
            return p.finishTime == nil && o.progress > p.progress + 0.0005
        }.count
        return ahead + 1
    }

    // MARK: Staying alive

    /// While hosting, keep the server running when the phone locks: with silent audio if that's on,
    /// otherwise by keeping the screen awake.
    private func updateKeepAlive() {
        if hosting && keepRunning {
            keptAlive = keepAlive.start()
        } else {
            keepAlive.stop()
            keptAlive = false
        }
        UIApplication.shared.isIdleTimerDisabled = hosting && !keptAlive
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            server.resume()
            if hosting { updateKeepAlive() }
        case .background:
            // Without the keep-alive iOS gives an app about 30 seconds before pausing it: enough for a quick look elsewhere.
            if hosting && !keepAlive.running { beginBackgroundTask() }
        default:
            break
        }
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Hosting") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

extension LANServer.Player {
    /// What they're doing, in a few words.
    func status(in lobby: Lobby, place: Int?) -> String {
        guard flags != nil else { return "Joining…" }
        if has(NetState.paused) { return "In the menu" }
        let flying = has(NetState.alive)
        if lobby.running {
            if !inRound { return "Watching until the next round" }
            if lobby.mode.isRace {
                if let t = finishTime { return "Finished in \(raceClock(t))" }
                return place.map { "Racing, \(ordinal($0))" } ?? "Racing"
            }
            if out { return "Out of lives" }
            let hearts = String(repeating: "♥", count: max(0, lives)) + String(repeating: "♡", count: max(0, FightRules.lives - lives))
            let kos = knockouts > 0 ? " · \(knockouts) KO" : ""
            return (flying ? "\(hearts) \(Int(hp.rounded())) hp" : "\(hearts) knocked out") + kos
        }
        if !flying { return "Knocked out" }
        return lobby.mode == .freeRoam ? "Flying" : "Warming up"
    }
}
