import Foundation
import FoundationModels

/// Short titles for Mac conversations, written on this Mac (Apple's on-device
/// model) instead of using the first 80 characters of your message. Kept in
/// titles.json in AgentX's data folder, by session.
@MainActor
final class LocalTitles {
    static let shared = LocalTitles()

    private var titles: [String: String]
    private let file = AppChannel.current.dataFile("titles.json")

    init() {
        titles = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))) ?? [:]
    }

    subscript(sessionId: String) -> String? { titles[sessionId] }

    /// Title a new conversation from its first message (once).
    func make(for c: Conversation) {
        guard let sessionId = c.sessionId, titles[sessionId] == nil, LocalCommands.shared.isAvailable,
              let first = c.items.first(where: { if case .user = $0.kind { true } else { false } }),
              case .user(let shown) = first.kind else { return }
        let text = ScreenContext.notes(in: shown).text
        guard text.count > 3 else { return }
        Task {
            guard let title = await Self.title(for: text) else { return }
            titles[sessionId] = title
            c.title = title
            try? SecureFile.write(JSONEncoder().encode(titles), to: file)
        }
    }

    /// "Can you check whether I have anything on Friday afternoon?" → "Friday afternoon plans".
    static func title(for text: String) async -> String? {
        let session = LanguageModelSession(instructions: "You write short titles for conversations. Reply with only the title: 2 to 6 words, no quotes, no full stop.")
        guard let reply = try? await session.respond(to: "Title for a conversation that starts with:\n\(text.prefix(600))",
                                                     options: GenerationOptions(temperature: 0.2)).content else { return nil }
        return clean(reply)
    }

    nonisolated static func clean(_ reply: String) -> String? {
        var t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’.*#"))
        if t.lowercased().hasPrefix("title:") { t = String(t.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        guard !t.isEmpty, t.count <= 60, !t.contains("\n") else { return nil }
        return t
    }
}
