import SwiftUI

/// Before hosting: the host's name and color, what to play first, and Start.
struct SetupView: View {
    @Environment(ServerModel.self) private var model
    @State private var showHelp = false
    @FocusState private var editingName: Bool

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        AppBadge()
                        Text("Host Bird Game from this iPhone")
                            .font(.title3.bold())
                        Text("Everyone plays on their Macs. This phone just runs the game, so you can host even when your Mac isn't allowed to.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .listRowBackground(Color.clear)
                }
                if let p = model.problem {
                    Section { ProblemRow(problem: p) }
                }
                Section {
                    TextField("Name", text: $model.name)
                        .focused($editingName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { model.commitName() }
                    NametagColorPicker(selection: $model.color)
                } header: {
                    Text("Host")
                } footer: {
                    Text("Players see “\(model.hostName)'s game”.")
                }
                Section("First game") {
                    Picker("Mode", selection: Binding(get: { model.mode }, set: { model.choose(mode: $0) })) {
                        ForEach(GameMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Map", selection: Binding(get: { model.world }, set: { model.choose(world: $0) })) {
                        ForEach(Maps.all) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    Button {
                        editingName = false
                        model.startHosting()
                    } label: {
                        Text("Start hosting")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    if model.nearby.isEmpty {
                        Text("None yet. A Mac shows up here while Bird Game is online (Esc → LAN → Go online).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.nearby) { PeerRow(peer: $0) }
                } header: {
                    Text("Bird Games nearby")
                }
            }
            .navigationTitle("Bird Server")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showHelp = true } label: { Label("How it works", systemImage: "questionmark.circle") }
                }
            }
            .sheet(isPresented: $showHelp) { HelpSheet() }
            .onChange(of: editingName) { _, editing in if !editing { model.commitName() } }
        }
    }
}
