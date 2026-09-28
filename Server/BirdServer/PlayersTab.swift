import SwiftUI

/// Hosting: who's in the game (remove them), who's nearby (invite them), and who was removed.
struct PlayersTab: View {
    @Environment(ServerModel.self) private var model
    @State private var removing: LANServer.Player?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.players.isEmpty {
                        Text("Nobody has joined yet. On a Mac: Bird Game → Esc → LAN → Go online, then Join “\(model.hostName)'s game”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.players) { p in
                        PlayerRow(player: p, status: p.status(in: model.lobby, place: model.place(of: p))) { removing = p }
                    }
                } header: {
                    Text("In the game · \(model.players.count) of \(LANProtocol.maxPlayers)")
                }
                Section {
                    if model.nearby.isEmpty {
                        Text("Nobody else is online. A Mac shows up here while Bird Game is on its LAN tab.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.nearby) { p in
                        HStack {
                            PeerRow(peer: p)
                            Spacer()
                            if p.canInvite {
                                Button(p.invited ? "Invited" : "Invite") { model.server.invite(p.id) }
                                    .buttonStyle(.bordered)
                                    .disabled(p.invited)
                            }
                        }
                    }
                } header: {
                    Text("Invite")
                } footer: {
                    Text("They get a message to join (“press J” on a Mac). Macs that block incoming connections, like school Macs, need Bird Game 0.3.1 or newer to see it.")
                }
                if !model.removed.isEmpty {
                    Section {
                        ForEach(model.removed) { r in
                            HStack(spacing: 12) {
                                ColorDot(color: r.color, size: 14)
                                Text(r.name)
                                Spacer()
                                Button("Allow back") { model.server.allowBack(r.id) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    } header: {
                        Text("Removed")
                    } footer: {
                        Text("Removed players can't rejoin until you allow them back.")
                    }
                }
            }
            .navigationTitle("Players")
            .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { p in
                Button("Remove \(p.name)", role: .destructive) { model.server.kick(p.id) }
            } message: { p in
                Text("\(p.name) leaves the game and can't rejoin until you allow them back.")
            }
        }
    }
}

struct PlayerRow: View {
    let player: LANServer.Player
    let status: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ColorDot(color: player.color, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.name)
                    .font(.body.weight(.semibold))
                Text("\(Birds.name(player.bird)) · \(status)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from game", systemImage: "person.fill.xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Options for \(player.name)")
        }
        .swipeActions {
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "person.fill.xmark") }
        }
    }
}
