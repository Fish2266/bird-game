import SwiftUI

/// Hosting: where to find the game, the round, the mode, map and rules.
struct GameTab: View {
    @Environment(ServerModel.self) private var model
    @State private var confirmStop = false
    @State private var confirmEnd = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section { StatusCard() }
                if let p = model.problem {
                    Section { ProblemRow(problem: p) }
                }
                if model.lobby.mode != .freeRoam { roundSection }
                Section {
                    Picker("Mode", selection: Binding(get: { model.mode }, set: { model.choose(mode: $0) })) {
                        ForEach(GameMode.allCases, id: \.self) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title)
                                Text(m.blurb)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(m)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Mode")
                } footer: {
                    if model.lobby.running { Text("Changing the mode or map ends the round under way.") }
                }
                Section("Map") {
                    Picker("Map", selection: Binding(get: { model.world }, set: { model.choose(world: $0) })) {
                        ForEach(Maps.all) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Rules") {
                    RuleToggle(title: "Collisions", note: "Flying into a bird knocks it flying.", on: rule(\.collisions))
                    RuleToggle(title: "PvP", note: "Attacks work in every mode, not just PvP Fight.", on: rule(\.pvp))
                    RuleToggle(title: "Show location", note: "Everyone glows through walls, with a compass.", on: rule(\.showLocation))
                }
                Section {
                    Button("Stop hosting", role: .destructive) { confirmStop = true }
                }
            }
            .navigationTitle("Game")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("Stop hosting?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop hosting", role: .destructive) { model.stopHosting() }
            } message: {
                Text(model.players.isEmpty ? "The game closes." : "The game ends for everyone in it.")
            }
            .confirmationDialog("End the round now?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End round", role: .destructive) { model.server.endRound() }
            } message: {
                Text("Everyone gets results as things stand.")
            }
        }
    }

    private func rule(_ key: WritableKeyPath<MatchRules, Bool>) -> Binding<Bool> {
        Binding(get: { model.rules[keyPath: key] }, set: { on in
            var r = model.rules
            r[keyPath: key] = on
            model.choose(rules: r)
        })
    }

    private var roundSection: some View {
        Section {
            if model.lobby.running {
                HStack {
                    Label("Round under way", systemImage: "flag.checkered")
                    Spacer()
                    if let start = model.roundStarted {
                        Text(start, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Button("End round now", role: .destructive) { confirmEnd = true }
            } else {
                Button { model.server.startRound() } label: {
                    Label("Start round", systemImage: "flag.checkered")
                }
                .disabled(model.players.isEmpty)
                if let results = model.results {
                    ForEach(results, id: \.id) { ResultRow(standing: $0, race: model.lobby.mode.isRace) }
                }
            }
        } header: {
            Text(!model.lobby.running && model.results != nil ? "Round · last results" : "Round")
        } footer: {
            if !model.lobby.running {
                Text(model.players.isEmpty ? "You can start a round once someone has joined."
                     : "Everyone lines up and counts down from 3. A round ends when everyone finishes (or one bird is left), after a time limit, or when you end it.")
            }
        }
    }
}

/// Hosting status: the game, how many are in it, and how to reach it.
struct StatusCard: View {
    @Environment(ServerModel.self) private var model
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text("Hosting \(model.hostName)'s game")
                    .font(.headline)
            }
            Text("\(model.lobby.mode.title) on \(Maps.name(model.lobby.world)) · \(model.players.count) of \(LANProtocol.maxPlayers) players")
                .foregroundStyle(.secondary)
            Divider()
            if let address = model.address {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not in a Mac's list? Join by address:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(address)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = address
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy address")
                }
            } else {
                Label("This phone isn't on Wi-Fi. Join the same network as the Macs, or turn on Personal Hotspot and have them join it.",
                      systemImage: "wifi.slash")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            Label(model.keptAlive ? "Keeps hosting when you lock the phone." : "Keep Bird Server open while you host. The screen stays on.",
                  systemImage: model.keptAlive ? "lock.fill" : "iphone")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
