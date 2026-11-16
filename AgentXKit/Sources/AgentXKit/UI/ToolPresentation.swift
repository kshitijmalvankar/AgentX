import Foundation

/// How to label and summarize Claude Code's tools in the UI.
enum ToolPresentation {
    static func symbol(for name: String) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell", "PowerShell": "terminal"
        case "Read", "NotebookRead": "doc.text"
        case "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Grep", "Glob", "ToolSearch": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList": "checklist"
        case "Skill": "wand.and.stars"
        case "AskUserQuestion": "questionmark.bubble"
        case "ExitPlanMode", "EnterPlanMode": "list.bullet.clipboard"
        default: name.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    /// "mcp__agentx__calendar_list" → "agentx · calendar_list"
    static func displayName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).split(separator: "__", maxSplits: 1)
        return parts.count == 2 ? "\(parts[0]) · \(parts[1])" : name
    }

    /// What a Mac tool did, in plain words ("Changed appearance").
    static let agentxActivity: [String: String] = [
        "calendar_events": "Checked your calendar",
        "calendar_create_event": "Added an event",
        "reminders_list": "Checked reminders",
        "reminders_create": "Added a reminder",
        "reminders_complete": "Completed a reminder",
        "files_search": "Searched files",
        "files_reveal": "Showed in Finder",
        "files_move": "Moved",
        "files_trash": "Moved to Trash",
        "apps_running": "Checked open apps",
        "apps_open": "Opened",
        "apps_quit": "Quit",
        "shortcuts_list": "Checked your Shortcuts",
        "shortcuts_run": "Ran the Shortcut",
        "system_appearance": "Changed appearance",
        "system_volume": "Set the volume",
        "clipboard_read": "Read the clipboard",
        "clipboard_write": "Copied to the clipboard",
        "mail_recent": "Checked mail",
        "mail_draft": "Drafted an email",
        "mail_send": "Sent an email",
        "notes_search": "Searched notes",
        "notes_create": "Created a note",
        "messages_send": "Sent a message",
        "repos_status": "Checked your repositories",
    ]

    /// A tool call as a short sentence: what Claude did, and to what.
    static func activity(name: String, input: JSONValue, cwd: String?) -> (title: String, detail: String) {
        if name.hasPrefix("mcp__agentx__") {
            let tool = String(name.dropFirst("mcp__agentx__".count))
            return (agentxActivity[tool] ?? tool.replacingOccurrences(of: "_", with: " ").capitalized, agentxDetail(tool, input))
        }
        let summary = summary(name: name, input: input, cwd: cwd)
        switch name {
        case "Bash": return ("Ran a command", summary)
        case "Read", "NotebookRead": return ("Read", summary)
        case "Edit", "MultiEdit", "NotebookEdit": return ("Edited", summary)
        case "Write": return ("Wrote", summary)
        case "Grep": return ("Searched for", summary)
        case "Glob": return ("Looked for files", summary)
        case "WebSearch": return ("Searched the web for", summary)
        case "WebFetch": return ("Read", URL(string: summary)?.host ?? summary)
        case "Agent", "Task": return ("Asked a helper agent to", summary.lowercasedFirst)
        case "TodoWrite": return ("Updated the to-do list", summary)
        case "Skill": return ("Used the skill", summary)
        case "ToolSearch": return ("Looked up tools", "")
        case "AskUserQuestion": return ("Asked you a question", "")
        case "ExitPlanMode": return ("Proposed a plan", "")
        default: return (displayName(name), summary)
        }
    }

    private static func agentxDetail(_ tool: String, _ input: JSONValue) -> String {
        func s(_ key: String) -> String? { input[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        func day(_ key: String) -> String? {
            s(key).map { raw in ToolDates.parse(raw).map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) } ?? raw }
        }
        func when(_ key: String) -> String? {
            s(key).map { raw in ToolDates.parse(raw).map { ToolDates.describe($0) } ?? raw }
        }
        let recipients = (input["to"]?.array?.compactMap(\.string) ?? s("to").map { [$0] } ?? []).joined(separator: ", ")
        switch tool {
        case "calendar_events":
            switch (day("start"), day("end")) {
            case let (start?, end?) where start != end: return "\(start) – \(end)"
            case let (start?, _): return start
            default: return "today"
            }
        case "calendar_create_event": return [s("title"), when("start")].compactMap { $0 }.joined(separator: " · ")
        case "reminders_create": return [s("title"), when("due")].compactMap { $0 }.joined(separator: " · ")
        case "system_appearance": return s("mode")?.capitalized ?? ""
        case "system_volume": return input["level"]?.int.map { "\($0)%" } ?? ""
        case "mail_draft", "mail_send": return [s("subject"), recipients.isEmpty ? nil : "to \(recipients)"].compactMap { $0 }.joined(separator: " ")
        case "messages_send": return recipients.isEmpty ? "" : "to \(recipients)"
        case "files_move":
            let from = s("from").map { ($0 as NSString).lastPathComponent } ?? ""
            let to = s("to").map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
            return "\(from) → \(to)"
        default:
            for key in ["title", "query", "name", "target", "path", "list"] {
                if let v = s(key) { return key == "path" ? (v as NSString).abbreviatingWithTildeInPath : v }
            }
            return ""
        }
    }

    /// One-line description of what the call does.
    static func summary(name: String, input: JSONValue, cwd: String?) -> String {
        func path(_ key: String) -> String? {
            guard let p = input[key]?.string else { return nil }
            if let cwd, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
            return (p as NSString).abbreviatingWithTildeInPath
        }
        switch name {
        case "Bash": return input["description"]?.string ?? input["command"]?.string ?? ""
        case "Read", "Edit", "MultiEdit", "Write", "NotebookEdit": return path("file_path") ?? path("notebook_path") ?? ""
        case "Grep": return [input["pattern"]?.string, path("path")].compactMap { $0 }.joined(separator: " in ")
        case "Glob": return input["pattern"]?.string ?? ""
        case "WebFetch": return input["url"]?.string ?? ""
        case "WebSearch": return input["query"]?.string ?? ""
        case "Agent", "Task": return input["description"]?.string ?? ""
        case "TodoWrite": return "\(input["todos"]?.array?.count ?? 0) items"
        case "Skill": return input["skill"]?.string ?? ""
        default:
            // First short string value is usually the most descriptive.
            let values = input.object?.sorted(by: { $0.key < $1.key }).compactMap { $0.value.string } ?? []
            return values.first { $0.count < 120 } ?? ""
        }
    }
}


extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
