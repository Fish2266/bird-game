import SwiftUI

/// Hosting: the game's chat. Messages sent from here come from the host's name.
struct ChatTab: View {
    @Environment(ServerModel.self) private var model
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.chat.isEmpty {
                            ContentUnavailableView("No messages yet", systemImage: "bubble.left.and.bubble.right",
                                                   description: Text("Players chat by pressing T in the game. Say hi from here."))
                        }
                        ForEach(Array(model.chat.enumerated()), id: \.offset) { i, line in
                            ChatBubble(line: line).id(i)
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: model.chat.count) { _, _ in withAnimation { scrollToEnd(proxy) } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    TextField("Message everyone", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .focused($typing)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .disabled(ChatLine.clean(draft) == nil)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("Chat")
        }
    }

    private func send() {
        guard model.server.say(draft) else { return }
        draft = ""
        typing = true
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard !model.chat.isEmpty else { return }
        proxy.scrollTo(model.chat.count - 1, anchor: .bottom)
    }
}

struct ChatBubble: View {
    let line: ChatLine

    var body: some View {
        if line.system {
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else if line.id == 1 {
            // Sent from this phone.
            HStack {
                Spacer(minLength: 48)
                Text(line.text)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ColorDot(color: line.color, size: 8)
                    Text(line.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(line.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.trailing, 48)
        }
    }
}
