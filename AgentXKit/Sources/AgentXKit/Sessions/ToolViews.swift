import MarkdownUI
import SwiftUI

/// Claude's reply text, rendered as Markdown.
struct MarkdownText: View {
    let text: String

    var body: some View {
        Markdown(text)
            .markdownTheme(.agentX)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One tool call as a quiet activity line ("Changed appearance · Dark").
/// Click to see the details (diff, command, output).
struct ToolCallCard: View {
    let call: ToolCall
    let cwd: String
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        let activity = ToolPresentation.activity(name: call.name, input: call.input, cwd: cwd)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    status.frame(width: 16)
                    (Text(activity.title).foregroundStyle(call.isError ? Color.red : Color.secondary)
                        + Text(activity.detail.isEmpty ? "" : "  \(activity.detail)").foregroundStyle(Color.secondary.opacity(0.7)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering || expanded ? 1 : 0)
                }
                .font(.callout)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(hovering ? Color.secondary.opacity(0.08) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("\(ToolPresentation.displayName(call.name)): \(activity.title) \(activity.detail)")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ToolInputView(name: call.name, input: call.input)
                    if let result = call.result, !result.isEmpty {
                        OutputBlock(text: result, isError: call.isError)
                    }
                }
                .font(.callout)
                .padding(.leading, 32)
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, -8)   // line the text up with the reply text
    }

    @ViewBuilder private var status: some View {
        if !call.isFinished {
            ProgressView().controlSize(.mini)
        } else if call.isError {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        } else {
            Image(systemName: ToolPresentation.symbol(for: call.name)).foregroundStyle(.tertiary)
        }
    }
}

/// Human-friendly rendering of a tool's input (diffs for edits, the command for Bash, ...).
struct ToolInputView: View {
    let name: String
    let input: JSONValue

    var body: some View {
        switch name {
        case "Edit":
            DiffView(old: input["old_string"]?.string ?? "", new: input["new_string"]?.string ?? "")
        case "MultiEdit":
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array((input["edits"]?.array ?? []).enumerated()), id: \.offset) { _, edit in
                    DiffView(old: edit["old_string"]?.string ?? "", new: edit["new_string"]?.string ?? "")
                }
            }
        case "Write":
            OutputBlock(text: input["content"]?.string ?? "", isError: false, maxLines: 40)
        case "Bash":
            OutputBlock(text: "$ " + (input["command"]?.string ?? ""), isError: false)
        case "TodoWrite":
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array((input["todos"]?.array ?? []).enumerated()), id: \.offset) { _, todo in
                    let status = todo["status"]?.string
                    Label(todo["content"]?.string ?? "", systemImage: status == "completed" ? "checkmark.square" : status == "in_progress" ? "arrow.right.square" : "square")
                }
            }
        default:
            OutputBlock(text: input.prettyPrinted(), isError: false, maxLines: 30)
        }
    }
}

/// Monospaced, scrollable text (tool output, file contents).
struct OutputBlock: View {
    let text: String
    let isError: Bool
    var maxLines = 60

    private var shown: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return String(text.prefix(12_000)) }
        return lines.prefix(maxLines).joined(separator: "\n") + "\n… \(lines.count - maxLines) more lines"
    }

    var body: some View {
        ScrollView(.horizontal) {
            Text(shown)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? .red : .primary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 260)
        .background(.background.opacity(0.6), in: .rect(cornerRadius: 6))
    }
}

/// "Claude wants to run …" with Allow / Always allow / Deny.
struct ApprovalCard: View {
    let approval: ApprovalRequest
    let answer: (ApprovalAnswer) -> Void
    @State private var showDetails = true
    @State private var denyReason = ""
    @State private var showDenyReason = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.headline).fontWeight(.semibold)
                    if let detail = approval.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if let reason = approval.decisionReason { Text(reason).font(.caption).foregroundStyle(.secondary) }
                    if let path = approval.blockedPath { Text(path.abbreviatingHome).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if showDetails {
                ToolInputView(name: approval.toolName, input: approval.input)
            }

            if showDenyReason {
                TextField("Tell Claude what to do instead (optional)", text: $denyReason)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { answer(.deny(denyReason)) }
            }

            HStack {
                Button(showDenyReason ? "Deny" : "Deny…", role: .destructive) {
                    if showDenyReason { answer(.deny(denyReason)) } else { showDenyReason = true }
                }
                .keyboardShortcut(approval.defaultToNo ? .defaultAction : .cancelAction)
                Spacer()
                if approval.canAlwaysAllow {
                    Button("Always allow") { answer(.allowAlways) }
                        .help("Don't ask again for this kind of action in this project")
                }
                Button("Allow") { answer(.allow) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(approval.defaultToNo ? .init("y", modifiers: .command) : .defaultAction)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 14))
    }
}
