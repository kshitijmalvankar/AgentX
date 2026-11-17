import AppKit
import Foundation

/// Files (Spotlight, Finder), apps, Shortcuts, appearance, volume, clipboard.
enum SystemTools {
    static var all: [MacTool] { files + apps }

    // MARK: Files

    static var files: [MacTool] {[
        MacTool("files_search", area: "Files", summary: "Search with Spotlight", risk: .read,
                description: "Find files with Spotlight by name or content. Returns paths, newest first. Use Claude's Read tool to open one.",
                parameters: [
                    .init("query", .string, "What to search for: words in the name or contents."),
                    .init("folder", .string, "Only search inside this folder (e.g. ~/Downloads).", required: false),
                    .init("nameOnly", .boolean, "Match file names only, not contents.", required: false),
                    .init("limit", .integer, "Maximum results (default 20, max 100).", required: false),
                ]) { args in
            let query = try args.string("query")
            var arguments: [String] = []
            if let folder = args.optionalString("folder") {
                arguments += ["-onlyin", (folder as NSString).expandingTildeInPath]
            }
            arguments += args.bool("nameOnly", default: false) ? ["-name", query] : [query]
            let result = try await ProcessRunner.run("/usr/bin/mdfind", arguments, timeout: 20)
            let paths = result.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            guard !paths.isEmpty else { return "No files found for \"\(query)\"." }
            let limit = min(100, max(1, args.int("limit", default: 20)))
            let dated = paths.prefix(500).map { path -> (String, Date) in
                let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                return (path, date)
            }.sorted { $0.1 > $1.1 }
            return dated.prefix(limit).map { "• \(($0.0 as NSString).abbreviatingWithTildeInPath)  (modified \(ToolDates.describe($0.1)))" }
                .joined(separator: "\n") + (paths.count > limit ? "\n…and \(paths.count - limit) more." : "")
        },
        MacTool("files_reveal", area: "Files", summary: "Show in Finder", risk: .create,
                description: "Open a Finder window with the file or folder selected.",
                parameters: [.init("path", .string, "File or folder path (absolute or starting with ~).")]) { args in
            let url = try args.path("path")
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("Nothing exists at \(url.path).") }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return "Showing \(url.lastPathComponent) in Finder."
        },
        MacTool("files_move", area: "Files", summary: "Move or rename", risk: .ask,
                description: "Move or rename a file or folder. If the destination is an existing folder, the item goes inside it. Never overwrites.",
                parameters: [
                    .init("from", .string, "Current path."),
                    .init("to", .string, "New path, or an existing folder to move into."),
                ]) { args in
            let from = try args.path("from")
            var to = try args.path("to")
            let fm = FileManager.default
            guard fm.fileExists(atPath: from.path) else { throw ToolError("Nothing exists at \(from.path).") }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: to.path, isDirectory: &isDir), isDir.boolValue { to.appendPathComponent(from.lastPathComponent) }
            guard !fm.fileExists(atPath: to.path) else { throw ToolError("\(to.path) already exists; not overwriting it.") }
            try fm.moveItem(at: from, to: to)
            return "Moved \((from.path as NSString).abbreviatingWithTildeInPath) to \((to.path as NSString).abbreviatingWithTildeInPath)."
        },
        MacTool("files_trash", area: "Files", summary: "Move to Trash", risk: .ask,
                description: "Move a file or folder to the Trash (recoverable from the Trash).",
                parameters: [.init("path", .string, "Path to move to the Trash.")]) { args in
            let url = try args.path("path")
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            guard url != home, url.path != "/" else { throw ToolError("Refusing to trash \(url.path).") }
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return "Moved \(url.lastPathComponent) to the Trash."
        },
    ]}

    // MARK: Apps, Shortcuts, settings, clipboard

    static var apps: [MacTool] {[
        MacTool("apps_running", area: "Apps", summary: "List open apps", risk: .read,
                description: "List the apps currently open (with a Dock icon).") { _ in
            await MainActor.run {
                NSWorkspace.shared.runningApplications
                    .filter { $0.activationPolicy == .regular }
                    .compactMap { app in app.localizedName.map { "• \($0)\(app.isActive ? " (frontmost)" : app.isHidden ? " (hidden)" : "")" } }
                    .sorted()
                    .joined(separator: "\n")
            }
        },
        MacTool("apps_open", area: "Apps", summary: "Open an app, file or URL", risk: .create,
                description: "Open an app by name (e.g. \"Safari\"), a file path, or a URL (https://, mailto:, …).",
                parameters: [.init("target", .string, "App name, path, or URL.")]) { args in
            let target = try args.string("target")
            if let url = URL(string: target), let scheme = url.scheme, !scheme.isEmpty, target.contains(":") {
                let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                guard opened else { throw ToolError("Couldn't open \(target).") }
                return "Opened \(target)."
            }
            let expanded = (target as NSString).expandingTildeInPath
            let arguments = expanded.hasPrefix("/") ? [expanded] : ["-a", target]
            let result = try await ProcessRunner.run("/usr/bin/open", arguments, timeout: 15)
            guard result.status == 0 else { throw ToolError(result.stderr.isEmpty ? "Couldn't open \(target)." : result.stderr) }
            return "Opened \(target)."
        },
        MacTool("apps_quit", area: "Apps", summary: "Quit an app", risk: .ask,
                description: "Ask an open app to quit (it can still prompt to save documents).",
                parameters: [.init("name", .string, "The app's name, as shown in the Dock.")]) { args in
            let name = try args.string("name")
            let quit = await MainActor.run { () -> String? in
                let matches = NSWorkspace.shared.runningApplications.filter {
                    $0.activationPolicy == .regular && ($0.localizedName ?? "").caseInsensitiveCompare(name) == .orderedSame
                }
                guard !matches.isEmpty else { return nil }
                matches.forEach { $0.terminate() }
                return matches.first?.localizedName
            }
            guard let quit else { throw ToolError("No open app is named \"\(name)\".") }
            return "Asked \(quit) to quit."
        },
        MacTool("shortcuts_list", area: "Shortcuts", summary: "List Shortcuts", risk: .read,
                description: "List the Shortcuts (from the Shortcuts app) that can be run.") { _ in
            let result = try await ProcessRunner.run("/usr/bin/shortcuts", ["list"])
            let names = result.stdout.split(separator: "\n").map { "• \($0)" }
            return names.isEmpty ? "No Shortcuts found." : names.joined(separator: "\n")
        },
        MacTool("shortcuts_run", area: "Shortcuts", summary: "Run a Shortcut", risk: .ask,
                description: "Run one of your Shortcuts by its exact name, optionally passing text as input. Returns its text output, if any.",
                parameters: [
                    .init("name", .string, "The Shortcut's exact name (see shortcuts_list)."),
                    .init("input", .string, "Text to pass as the Shortcut's input.", required: false),
                ]) { args in
            let name = try args.string("name")
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentx-shortcut-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let output = temp.appendingPathComponent("output.txt")
            var arguments = ["run", name, "--output-path", output.path, "--output-type", "public.plain-text"]
            if let input = args.optionalString("input") {
                let inputFile = temp.appendingPathComponent("input.txt")
                try input.write(to: inputFile, atomically: true, encoding: .utf8)
                arguments += ["--input-path", inputFile.path]
            }
            let result = try await ProcessRunner.run("/usr/bin/shortcuts", arguments, timeout: 120)
            guard result.status == 0 else { throw ToolError(result.stderr.isEmpty ? "The Shortcut \"\(name)\" failed." : result.stderr) }
            let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "Ran \"\(name)\"." : "Ran \"\(name)\". Output:\n\(text)"
        },
        MacTool("system_appearance", area: "Settings", summary: "Dark or light mode", risk: .create,
                description: "Switch macOS between dark and light mode.",
                parameters: [.init("mode", .choice(["dark", "light"]), "Which appearance to use.")]) { args in
            let dark = try args.string("mode") == "dark"
            _ = try await AppleScript.run("""
                on run argv
                  tell application "System Events" to tell appearance preferences to set dark mode to ((item 1 of argv) is "true")
                end run
                """, arguments: [dark ? "true" : "false"])
            return "Switched to \(dark ? "dark" : "light") mode."
        },
        MacTool("system_volume", area: "Settings", summary: "Set the volume", risk: .create,
                description: "Set the output volume from 0 (muted) to 100.",
                parameters: [.init("level", .integer, "Volume, 0–100.")]) { args in
            let level = min(100, max(0, args.int("level", default: 50)))
            _ = try await AppleScript.run("""
                on run argv
                  set volume output volume ((item 1 of argv) as integer)
                end run
                """, arguments: [String(level)])
            return "Volume set to \(level)%."
        },
        MacTool("clipboard_read", area: "Clipboard", summary: "Read the clipboard", risk: .ask,
                description: "Read the text currently on the clipboard. Asks first, since the clipboard can hold private things.",
                untrustedSource: "the clipboard") { _ in
            let text = await MainActor.run { NSPasteboard.general.string(forType: .string) }
            guard let text, !text.isEmpty else { return "The clipboard has no text." }
            return String(text.prefix(20_000))
        },
        MacTool("clipboard_write", area: "Clipboard", summary: "Copy text", risk: .create,
                description: "Put text on the clipboard, ready to paste.",
                parameters: [.init("text", .string, "Text to copy.")]) { args in
            let text = try args.string("text")
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            return "Copied \(text.count) characters to the clipboard."
        },
    ]}
}
