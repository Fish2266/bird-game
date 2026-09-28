import SwiftUI

/// The host's name and color, keeping the app running, and help.
struct SettingsView: View {
    @Environment(ServerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { model.commitName() }
                    NametagColorPicker(selection: $model.color)
                } header: {
                    Text("Host")
                } footer: {
                    Text("Players see “\(model.hostName)'s game”, and your chat messages come from this name.")
                }
                Section {
                    Toggle("Keep running when locked", isOn: $model.keepRunning)
                } footer: {
                    Text("iOS pauses apps soon after they leave the screen, which would end the game for everyone. With this on, Bird Server plays silence while it hosts, so it keeps running when you lock the phone or switch apps (your music still plays). With it off, keep Bird Server open: the screen stays on while you host.")
                }
                Section {
                    NavigationLink("How it works") { HelpView() }
                }
                Section {
                    LabeledContent("Bird Server", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("Hosts games for", value: "Bird Game \(LANProtocol.gameVersion)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { model.commitName() }
        }
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HelpView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct HelpView: View {
    @Environment(ServerModel.self) private var model

    var body: some View {
        List {
            Section("Joining from a Mac") {
                step(1, "Put this phone and the Macs on the same Wi-Fi.")
                step(2, "On each Mac, open Bird Game, press Esc, go to LAN and click Go online.")
                step(3, "Click Join next to “\(model.hostName)'s game”.")
            }
            Section("Game not in a Mac's list?") {
                Text("Type this phone's address into “Join by the host's address” on the Mac's LAN tab" + (model.address.map { ": \($0)." } ?? ".")
                     + " Some networks (school, guest and mesh Wi-Fi) hide games from each other.")
            }
            Section("School or guest Wi-Fi") {
                Text("If the Wi-Fi keeps devices apart, nobody can reach the game over it. Turn on Personal Hotspot on this phone and have everyone join that instead. Anything else the Macs do online then uses this phone's data.")
            }
            Section("Running the game") {
                Text("You pick the mode, map and rules, start each race or fight, and can end a round early. Players who join during a round watch until the next one. This phone doesn't play; it only hosts.")
            }
            Section("Invites and removing players") {
                Text("Invite anyone whose Bird Game is online and they get a message to join. Removed players can't rejoin until you allow them back from the Players tab. Invites reach Macs that block incoming connections, like school Macs, from Bird Game 0.3.1 on.")
            }
            Section("Keeping it running") {
                Text("With “Keep running when locked” on (in Settings), you can lock the phone or use other apps while you host. Otherwise keep Bird Server open. Hosting uses some battery, so plug in for long sessions.")
            }
        }
        .navigationTitle("How it works")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)")
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
        }
    }
}
