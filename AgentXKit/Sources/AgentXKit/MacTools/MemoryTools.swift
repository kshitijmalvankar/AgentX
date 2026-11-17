import Foundation

/// Claude's side of AgentX's memory (see MemoryStore). Saving is "create"
/// tier, so it runs on its own, except in a conversation that has read
/// untrusted content, where agent-core's policy makes it ask. Forgetting asks.
enum MemoryTools {
    static let kinds = MemoryItem.Kind.allCases.map(\.rawValue)

    static var all: [MacTool] {[
        MacTool("memory_save", area: "Memory", summary: "Remember something", risk: .create,
                description: "Save one lasting fact about the user: about them, a person, a project, a preference or a decision. A title that matches an existing memory updates it. Never passwords, keys, card or ID numbers.",
                parameters: [
                    .init("title", .string, "Short title, e.g. \"Prefers short replies\" or \"Enda Fallon\"."),
                    .init("text", .string, "The fact, in a sentence or two."),
                    .init("kind", .choice(kinds), "me, person, project, preference, decision or other."),
                ]) { args in
            let title = try args.string("title"), text = try args.string("text")
            let kind = MemoryItem.Kind(rawValue: args.optionalString("kind") ?? "") ?? .other
            let source = args.origin.map { "Conversation “\($0)”" }
            let isNew = try await MainActor.run {
                try MemoryStore.shared.save(title: title, body: text, kind: kind, source: source, reviewed: false)
            }
            return isNew ? "Saved “\(title)”." : "Updated “\(title)”."
        },
        MacTool("memory_search", area: "Memory", summary: "Search memory", risk: .read,
                description: "Find memories whose title or text contains these words (all of them). Empty query lists everything.",
                parameters: [.init("query", .string, "Words to look for.", required: false)]) { args in
            let query = args.optionalString("query") ?? ""
            let found = await MainActor.run { () -> [MemoryItem]? in
                MemoryStore.shared.isPaused ? nil : MemoryStore.shared.search(query)
            }
            guard let found else { return "Memory is paused (Settings → Memory)." }
            guard !found.isEmpty else { return "No memories match." }
            return found.prefix(40).map { "• \($0.title) [\($0.kind.rawValue)]: \($0.body.prefix(300))" }.joined(separator: "\n")
        },
        MacTool("memory_read", area: "Memory", summary: "Read a memory", risk: .read,
                description: "The full text of one memory, by its title.",
                parameters: [.init("title", .string, "The memory's title.")]) { args in
            let title = try args.string("title")
            let item = await MainActor.run { MemoryStore.shared.isPaused ? nil : MemoryStore.shared.item(titled: title) }
            guard let item else { throw ToolError("No memory titled “\(title)”.") }
            return "\(item.title) [\(item.kind.rawValue)], updated \(ToolDates.describe(item.updated))\n\(item.body)"
        },
        MacTool("memory_forget", area: "Memory", summary: "Forget something", risk: .ask,
                description: "Delete a memory that's no longer true (it moves to Memory/.trash).",
                parameters: [.init("title", .string, "The memory's title.")]) { args in
            let title = try args.string("title")
            try await MainActor.run {
                guard let item = MemoryStore.shared.item(titled: title) else { throw ToolError("No memory titled “\(title)”.") }
                try MemoryStore.shared.forget(item.id)
            }
            return "Forgot “\(title)”."
        },
    ]}
}
