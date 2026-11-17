import AgentXRemote
import SwiftUI

/// Claude on your Mac: conversations (with Mac tools) and running coding
/// sessions. Mac conversations take messages from here.
struct ConversationsView: View {
    @Environment(PhoneModel.self) private var model
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section { ConnectionBanner() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                let conversations = model.snapshot?.conversations ?? []
                let mac = conversations.filter(\.isMac), coding = conversations.filter { !$0.isMac }
                Section("On your Mac") {
                    if mac.isEmpty { Text("No conversations yet.").foregroundStyle(.secondary) }
                    ForEach(mac) { row($0) }
                }
                if !coding.isEmpty {
                    Section("Coding sessions running") { ForEach(coding) { row($0) } }
                }
            }
            .navigationTitle("Claude")
            .navigationDestination(for: String.self) { id in ChatView(conversationID: id, path: $path) }
            .refreshable { await model.request(.refresh) }
            .toolbar {
                if model.snapshot?.canMessage == true {
                    Button("New", systemImage: "square.and.pencil") { path.append(ChatView.newID) }
                        .disabled(model.connection != .connected)
                }
            }
        }
    }

    private func row(_ c: RemoteSnapshot.Conversation) -> some View {
        NavigationLink(value: c.id) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).lineLimit(2)
                    if let project = c.project { Text(project).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if let state = c.state {
                    Text(state).font(.caption).foregroundStyle(state == "Needs approval" ? .orange : .secondary)
                } else if let updated = c.updated {
                    Text(updated, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One conversation: messages, Claude's reply as it streams, and a composer.
struct ChatView: View {
    static let newID = "new"
    @Environment(PhoneModel.self) private var model
    let conversationID: String
    @Binding var path: [String]
    @State private var draft = ""
    @State private var sending = false

    private var transcript: RemoteTranscript? { model.transcripts[conversationID] }
    private var summary: RemoteSnapshot.Conversation? { model.snapshot?.conversations.first { $0.id == conversationID } }
    private var isNew: Bool { conversationID == Self.newID }
    private var canSend: Bool {
        // Unknown (not in the list right now): offer it; the Mac turns away coding sessions.
        model.snapshot?.canMessage == true && model.connection == .connected && (isNew || summary?.isMac ?? true)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if isNew {
                        Text("Ask Claude to do something on your Mac: check your calendar, find a file, draft an email…")
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    }
                    ForEach(transcript?.items ?? []) { item in Bubble(item: item) }
                    if let draft = transcript?.draft {
                        Text(draft).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if transcript?.isWorking == true {
                        ProgressView().padding(.vertical, 4)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding()
            }
            .onChange(of: transcript?.items.count) { proxy.scrollTo("end") }
            .onChange(of: transcript?.draft?.count) { proxy.scrollTo("end") }
        }
        .safeAreaInset(edge: .bottom) {
            if canSend {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Claude on your Mac", text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    Button("Send", systemImage: "arrow.up") { send() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glassProminent)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            } else if summary?.isMac == false {
                Text("Coding sessions are view-only here. Continue them on your Mac, or in the Claude app with Continue on phone.")
                    .font(.footnote).foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle(transcript?.title ?? summary?.title ?? "New conversation")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: conversationID) {
            if !isNew { await model.openTranscript(conversationID) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sending = true
        Task {
            let id = await model.send(text, to: isNew ? nil : conversationID)
            sending = false
            // A new conversation gets its id from the Mac: show that one instead.
            if isNew, let id, !path.isEmpty {
                path[path.count - 1] = id
            }
        }
    }
}

private struct Bubble: View {
    let item: RemoteTranscript.Item

    var body: some View {
        switch item.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.tint.opacity(0.15), in: .rect(cornerRadius: 18))
            }
        case .assistant:
            Text(markdown(item.text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        case .tool:
            Label(item.text, systemImage: "wrench.and.screwdriver")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .notice:
            Label(item.text, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
