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
