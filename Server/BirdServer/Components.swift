import SwiftUI

extension Color {
    /// A player's nametag color (the same eight as in the game).
    static func nametag(_ i: Int) -> Color {
        let c = NameColors.color(i)
        return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }
}

/// The maps a game can be played on (the same ids and names as the game's world catalog).
enum Maps {
    struct Info: Identifiable {
        let id: String
        let name: String
    }

    static let all = [Info(id: "meadow", name: "Home Isles"), Info(id: "volcano", name: "Volcano"),
                      Info(id: "caves", name: "Glow Caves"), Info(id: "dogfight", name: "Dogfight"),
                      Info(id: "city", name: "Skyline City"), Info(id: "dino", name: "Dino Valley"), Info(id: "west", name: "Wild West")]

    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id.capitalized }

    static func valid(_ id: String?) -> String {
        if let id, all.contains(where: { $0.id == id }) { return id }
        return all[0].id
    }
}

/// Bird names (the ids come from the game's catalog).
enum Birds {
    private static let names = ["gull": "Seagull", "sparrow": "Sparrow", "albatross": "Albatross", "hummingbird": "Hummingbird",
                                "falcon": "Peregrine Falcon", "owl": "Snowy Owl", "eagle": "Golden Eagle", "phoenix": "Phoenix"]
    static func name(_ id: String) -> String { names[id] ?? id.capitalized }
}

struct ColorDot: View {
    let color: Int
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color.nametag(color))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The app's icon in miniature: a white bird on sky blue.
struct AppBadge: View {
    var body: some View {
        Image(systemName: "bird.fill")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 72, height: 72)
            .background(LinearGradient(colors: [Color(red: 0.52, green: 0.88, blue: 1), Color(red: 0.10, green: 0.52, blue: 0.90)],
                                       startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Eight nametag colors to pick from.
struct NametagColorPicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<NameColors.all.count, id: \.self) { i in
                Button { selection = i } label: {
                    ZStack {
                        Circle().fill(Color.nametag(i)).frame(width: 26, height: 26)
                        if selection == i {
                            Circle().strokeBorder(Color.nametag(i), lineWidth: 2.5).frame(width: 36, height: 36)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NameColors.names[i])
                .accessibilityAddTraits(selection == i ? .isSelected : [])
            }
        }
    }
}

/// Another Bird Game on the network.
struct PeerRow: View {
    let peer: LANServer.Peer

    var body: some View {
        HStack(spacing: 12) {
            ColorDot(color: peer.color, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.name)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detail: String {
        if let v = peer.otherVersion { return "Has Bird Game \(v), so it can't join" }
        return peer.inGame ? "In another game" : "Online"
    }
}

/// Something that stops Macs from reaching the game.
struct ProblemRow: View {
    let problem: LANServer.Problem

    var body: some View {
        switch problem {
        case .localNetwork:
            VStack(alignment: .leading, spacing: 8) {
                Label("Local Network is off", systemImage: "wifi.exclamationmark")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("Bird Server can't see the Macs on your network, and they can't see it. Turn on Local Network for Bird Server in Settings.")
                    .font(.subheadline)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        case .network(let why):
            Label("Network trouble: \(why). Trying again…", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }
}

/// A switch with a line explaining it.
struct RuleToggle: View {
    let title: String
    let note: String
    @Binding var on: Bool

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One line of a round's results.
struct ResultRow: View {
    let standing: Standing
    let race: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(ordinal(standing.place))
                .font(.subheadline.weight(.bold).monospacedDigit())
                .frame(width: 38, alignment: .leading)
            ColorDot(color: standing.color)
            Text(standing.name)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if race { return standing.time.map(raceClock) ?? "Did not finish" }
        return standing.knockouts == 1 ? "1 knock-out" : "\(standing.knockouts) knock-outs"
    }
}
