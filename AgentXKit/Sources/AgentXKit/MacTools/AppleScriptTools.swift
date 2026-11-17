import Foundation

/// Mail, Notes and Messages through AppleScript. macOS asks once per app
/// ("AgentX wants to control Mail"). Values always travel as argv.
enum AppleScriptTools {
    static var all: [MacTool] {[
        MacTool("mail_recent", area: "Mail", summary: "Read recent mail", risk: .read,
                description: "List recent messages in Mail's inbox (sender, subject, date, read state, and the start of the text).",
                parameters: [
                    .init("count", .integer, "How many messages (default 10, max 30).", required: false),
                    .init("unreadOnly", .boolean, "Only unread messages.", required: false),
                ], untrustedSource: "your email") { args in
            let count = min(30, max(1, args.int("count", default: 10)))
            let output = try await AppleScript.run("""
                on run argv
                  set maxCount to (item 1 of argv) as integer
                  set unreadOnly to (item 2 of argv) is "true"
                  set out to ""
                  tell application "Mail"
                    if unreadOnly then
                      set msgs to (messages of inbox whose read status is false)
                    else
                      set msgs to messages of inbox
                    end if
                    set n to count of msgs
                    if n > maxCount then set n to maxCount
                    repeat with i from 1 to n
                      set m to item i of msgs
                      set preview to ""
                      try
                        set preview to content of m
                        if (length of preview) > 280 then set preview to (text 1 thru 280 of preview) & "…"
                      end try
                      set state to "read"
                      if read status of m is false then set state to "unread"
                      set out to out & "• " & (date received of m as string) & " | " & (sender of m) & " | " & (subject of m) & " | " & state & linefeed & "  " & preview & linefeed
                    end repeat
                  end tell
                  return out
                end run
                """, arguments: [String(count), args.bool("unreadOnly", default: false) ? "true" : "false"], timeout: 90)
            return output.isEmpty ? "No messages." : output
        },
        MacTool("mail_draft", area: "Mail", summary: "Draft an email", risk: .create,
                description: "Open a new email in Mail with the recipients, subject and body filled in, without sending it.",
                parameters: emailParameters) { args in
            try await composeMail(args, send: false)
        },
        MacTool("mail_send", area: "Mail", summary: "Send an email", risk: .ask,
                description: "Send an email from Mail right away. Prefer mail_draft unless the user clearly asked to send.",
                parameters: emailParameters) { args in
            try await composeMail(args, send: true)
        },
        MacTool("notes_search", area: "Notes", summary: "Search notes", risk: .read,
                description: "Find notes in Apple Notes whose title or text contains the given words.",
                parameters: [.init("query", .string, "Text to look for.")], untrustedSource: "your notes") { args in
            let output = try await AppleScript.run("""
                on run argv
                  set q to item 1 of argv
                  set out to ""
                  tell application "Notes"
                    set found to (notes whose name contains q or plaintext contains q)
                    set n to count of found
                    if n > 15 then set n to 15
                    repeat with i from 1 to n
                      set theNote to item i of found
                      set body to plaintext of theNote
                      if (length of body) > 300 then set body to (text 1 thru 300 of body) & "…"
                      set out to out & "• " & (name of theNote) & " (modified " & (modification date of theNote as string) & ")" & linefeed & "  " & body & linefeed
                    end repeat
                  end tell
                  return out
                end run
                """, arguments: [try args.string("query")], timeout: 60)
            return output.isEmpty ? "No notes match." : output
        },
        MacTool("notes_create", area: "Notes", summary: "Create a note", risk: .create,
                description: "Create a note in Apple Notes.",
                parameters: [
                    .init("title", .string, "Note title."),
                    .init("body", .string, "Note text."),
                    .init("folder", .string, "Folder name. Defaults to Notes' default folder.", required: false),
                ]) { args in
            let title = try args.string("title")
            _ = try await AppleScript.run("""
                on run argv
                  set t to item 1 of argv
                  set b to item 2 of argv
                  set f to item 3 of argv
                  tell application "Notes"
                    if f is "" then
                      make new note with properties {name:t, body:b}
                    else
                      make new note at folder f with properties {name:t, body:b}
                    end if
                  end tell
                end run
                """, arguments: [title, try args.string("body"), args.optionalString("folder") ?? ""])
            return "Created the note \"\(title)\"."
        },
        MacTool("messages_send", area: "Messages", summary: "Send an iMessage", risk: .ask,
                description: "Send an iMessage to a phone number or email address.",
                parameters: [
                    .init("to", .string, "Phone number (with country code) or email address."),
                    .init("text", .string, "Message text."),
                ]) { args in
            let to = try args.string("to")
            _ = try await AppleScript.run("""
                on run argv
                  tell application "Messages"
                    set svc to 1st account whose service type = iMessage
                    send (item 2 of argv) to participant (item 1 of argv) of svc
                  end tell
                end run
                """, arguments: [to, try args.string("text")])
            return "Sent the message to \(to)."
        },
    ]}

    private static var emailParameters: [ToolParameter] {[
        .init("to", .stringList, "Recipient email addresses."),
        .init("subject", .string, "Subject line."),
        .init("body", .string, "Plain-text body."),
        .init("cc", .stringList, "Cc addresses.", required: false),
    ]}

    private static func composeMail(_ args: ToolArguments, send: Bool) async throws -> String {
        let to = args.stringList("to")
        guard !to.isEmpty else { throw ToolError("Add at least one recipient in \"to\".") }
        let subject = try args.string("subject")
        _ = try await AppleScript.run("""
            on run argv
              set theSubject to item 1 of argv
              set theBody to item 2 of argv
              set shouldSend to (item 3 of argv) is "true"
              set toList to paragraphs of (item 4 of argv)
              set ccList to paragraphs of (item 5 of argv)
              tell application "Mail"
                set m to make new outgoing message with properties {subject:theSubject, content:theBody, visible:(not shouldSend)}
                tell m
                  repeat with a in toList
                    if (a as string) is not "" then make new to recipient at end of to recipients with properties {address:(a as string)}
                  end repeat
                  repeat with a in ccList
                    if (a as string) is not "" then make new cc recipient at end of cc recipients with properties {address:(a as string)}
                  end repeat
                end tell
                if shouldSend then
                  send m
                else
                  activate
                end if
              end tell
            end run
            """, arguments: [subject, try args.string("body"), send ? "true" : "false",
                             to.joined(separator: "\n"), args.stringList("cc").joined(separator: "\n")])
        return send ? "Sent \"\(subject)\" to \(to.joined(separator: ", "))."
                    : "Opened a draft \"\(subject)\" to \(to.joined(separator: ", ")) in Mail."
    }
}

/// Every Mac tool, and the one place to run them.
enum MacToolbox {
    static let tools: [MacTool] = CalendarTools.all + SystemTools.all + AppleScriptTools.all + CodeTools.all + MemoryTools.all

    static func tool(named name: String) -> MacTool? { tools.first { $0.name == name } }

    /// Sent to agent-core at startup (`tools.register`).
    static var definitions: JSONValue { .array(tools.map(\.definition)) }

    /// Run a tool for Claude. Failures come back as readable text with isError set.
    static func invoke(name: String, arguments: JSONValue, origin: String? = nil) async -> JSONValue {
        guard let tool = tool(named: name) else {
            return ["text": .string("AgentX has no tool named \(name)."), "isError": true]
        }
        do {
            let output = try await tool.run(ToolArguments(values: arguments, origin: origin))
            var result: [String: JSONValue] = ["text": .string(output.text), "isError": false]
            if let image = output.image {
                result["image"] = ["data": .string(image.data.base64EncodedString()), "mimeType": .string(image.mediaType)]
            }
            return .object(result)
        } catch {
            return ["text": .string(error.localizedDescription), "isError": true]
        }
    }
}
