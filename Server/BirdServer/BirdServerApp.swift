import SwiftUI

/// Bird Server: hosts Bird Game LAN games from an iPhone. It doesn't play; everyone plays on their Macs.
/// The hosting itself is `LANServer` (Shared/), the same protocol code the game compiles.
@main
struct BirdServerApp: App {
    @State private var model = ServerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
    }
}

struct RootView: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        if model.hosting { HostingView() } else { SetupView() }
    }
}

/// While hosting: the game, the players and the chat.
struct HostingView: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            GameTab()
                .tabItem { Label("Game", systemImage: "gamecontroller.fill") }
                .tag(ServerModel.Tab.game)
            PlayersTab()
                .tabItem { Label("Players", systemImage: "person.3.fill") }
                .tag(ServerModel.Tab.players)
            ChatTab()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }
                .badge(model.unread)
                .tag(ServerModel.Tab.chat)
        }
    }
}
