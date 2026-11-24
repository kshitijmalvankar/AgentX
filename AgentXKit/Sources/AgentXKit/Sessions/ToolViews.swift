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
                .background(hovering ? Color.secondary.opacity(0.08) : .clear, in: .rect(cornerRadius: Radius.inset))
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
        case "ExitPlanMode":
            PlanDocument(plan: input["plan"]?.string ?? "", path: input["planFilePath"]?.string)
        case "AskUserQuestion":
            QuestionsAnswered(input: input)
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
        .background(.background.opacity(0.6), in: .rect(cornerRadius: Radius.inset))
    }
}

/// Shown on a conversation that has read untrusted content.
struct TaintBadge: View {
    let reason: String

    var body: some View {
        Label("Untrusted content", systemImage: "checkmark.shield")
            .labelStyle(.iconOnly)
            .foregroundStyle(.orange)
            .help("This conversation read \(reason). Anything that could send your data out now asks first.")
            .accessibilityLabel("Read untrusted content: \(reason)")
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
        switch approval.toolName {
        // A plan to approve, and questions to answer, aren't permissions: they get their own cards.
        case "ExitPlanMode": PlanApprovalCard(approval: approval, answer: answer)
        case "AskUserQuestion": QuestionCard(approval: approval, answer: answer)
        default: permissionCard
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.headline).fontWeight(.semibold)
                    if let detail = approval.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    if let reason = approval.decisionReason, reason != approval.policyReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                    }
                    if let path = approval.blockedPath { Text(path.abbreviatingHome).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }

            if let origin = approval.automationName {
                Label("From \(origin), which runs on its own", systemImage: "clock.arrow.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = approval.policyReason {
                Label(reason, systemImage: "checkmark.shield")
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: .rect(cornerRadius: Radius.inset))
                    .help("AgentX's security policy: once a conversation has read content other people wrote, anything that could send data out asks first. See Settings → Security.")
            }
            if approval.recentRiskyActions > 3 {
                Label("This is request \(approval.recentRiskyActions) in the last 10 minutes. Check it's what you expect.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
                .secondaryButton()
                .keyboardShortcut(approval.defaultToNo ? .defaultAction : .cancelAction)
                Spacer()
                if approval.canAlwaysAllow || approval.canTrustTool {
                    Button(approval.canAlwaysAllow ? approval.alwaysAllowLabel ?? "Always Allow" : "Always Allow") { answer(.allowAlways) }
                        .secondaryButton()
                        .help(approval.canTrustTool && !approval.canAlwaysAllow
                              ? "Let \(SecuritySettings.displayName(ofTool: approval.toolName)) run without asking, even after untrusted content. It only reads. Undo in Settings → Security."
                              : approval.alwaysAllowDetail ?? "Don't ask again for this kind of action")
                }
                Button("Allow") { answer(.allow) }
                    .primaryButton()
                    .keyboardShortcut(approval.defaultToNo ? .init("y", modifiers: .command) : .defaultAction)
            }
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .agentCard)
    }
}


// MARK: - Plans

/// A plan Claude wrote, rendered as a document (not the raw text), with its file.
struct PlanDocument: View {
    let plan: String
    let path: String?
    var maxHeight: CGFloat? = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if plan.isEmpty {
                Text("The plan is in the next message.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    MarkdownText(text: plan).padding(14)
                }
                .frame(maxHeight: maxHeight)
                .background(.background.opacity(0.5), in: .rect(cornerRadius: Radius.inset))
            }
            if let path {
                HStack(spacing: 10) {
                    Label(path.abbreviatingHome, systemImage: "doc.text").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan, forType: .string)
                    }
                    .buttonStyle(.link)
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Approving a plan, like the Claude app: edit automatically, approve but keep asking, or keep planning.
private struct PlanApprovalCard: View {
    let approval: ApprovalRequest
    let answer: (ApprovalAnswer) -> Void
    @State private var feedback = ""
    @State private var givingFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Claude has a plan", systemImage: "list.bullet.clipboard")
                .font(.headline)
            PlanDocument(plan: approval.input["plan"]?.string ?? "", path: approval.input["planFilePath"]?.string)
            if givingFeedback {
                TextField("What should change? (optional)", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(keepPlanning)
            }
            HStack {
                Button(givingFeedback ? "Send to Claude" : "Keep Planning…", action: keepPlanning)
                    .secondaryButton()
                    .help("Claude keeps planning, with your notes")
                Spacer()
                Button("Approve, Ask Before Edits") { answer(.allowWith(input: nil, mode: .default)) }
                    .secondaryButton()
                    .help("Start, and ask before each file edit and command")
                Button("Approve and Edit Automatically") { answer(.allowWith(input: nil, mode: .acceptEdits)) }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .help("Start, editing files without asking (commands still ask). Same as Accept edits mode.")
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.blue.opacity(0.12)), in: .agentCard)
    }

    private func keepPlanning() {
        guard givingFeedback else { givingFeedback = true; return }
        let note = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        answer(.deny(note.isEmpty ? "The user wants to keep planning. Don't start yet." : "Keep planning. The user says: \(note)"))
    }
}

// MARK: - Questions

/// One of Claude's questions, as AskUserQuestion sends it.
struct ClaudeQuestion: Identifiable, Equatable {
    struct Option: Equatable { var label: String; var description: String }
    var id: String { question }
    var question: String
    var header: String
    var multiSelect: Bool
    var options: [Option]

    static func all(in input: JSONValue) -> [ClaudeQuestion] {
        (input["questions"]?.array ?? []).compactMap { q in
            guard let text = q["question"]?.string else { return nil }
            return ClaudeQuestion(question: text, header: q["header"]?.string ?? "", multiSelect: q["multiSelect"]?.bool ?? false,
                                  options: (q["options"]?.array ?? []).compactMap { o in
                                      o["label"]?.string.map { Option(label: $0, description: o["description"]?.string ?? "") }
                                  })
        }
    }

    /// The tool's input with the answers added, as Claude Code expects: question → answer
    /// (several picks separated by commas; your own words for "Other").
    static func answered(_ input: JSONValue, picks: [String: [String]], other: [String: String]) -> JSONValue {
        guard case .object(var fields) = input else { return input }
        var answers: [String: JSONValue] = [:]
        for q in all(in: input) {
            var chosen = picks[q.question] ?? []
            if let own = other[q.question]?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty { chosen.append(own) }
            if !chosen.isEmpty { answers[q.question] = .string(chosen.joined(separator: ", ")) }
        }
        fields["answers"] = .object(answers)
        return .object(fields)
    }
}

/// Claude's questions as a card you answer, not a permission to allow.
private struct QuestionCard: View {
    let approval: ApprovalRequest
    let answer: (ApprovalAnswer) -> Void
    @State private var picks: [String: [String]] = [:]
    @State private var other: [String: String] = [:]

    private var questions: [ClaudeQuestion] { ClaudeQuestion.all(in: approval.input) }

    private var complete: Bool {
        questions.allSatisfy { q in
            !(picks[q.question] ?? []).isEmpty || !(other[q.question] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Claude has \(questions.count == 1 ? "a question" : "\(questions.count) questions")", systemImage: "questionmark.bubble")
                .font(.headline)
            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if !q.header.isEmpty {
                            Text(q.header).font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: .capsule)
                        }
                        Text(q.question).fontWeight(.medium)
                    }
                    if q.multiSelect { Text("Pick any").font(.caption).foregroundStyle(.secondary) }
                    ForEach(q.options, id: \.label) { option in
                        optionRow(option, in: q)
                    }
                    TextField("Other…", text: Binding(get: { other[q.question] ?? "" }, set: { other[q.question] = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Button("Skip") { answer(.deny("The user skipped these questions. Carry on with your best judgement, or ask in chat.")) }
                    .secondaryButton()
                Spacer()
                Button("Answer") { answer(.allowWith(input: ClaudeQuestion.answered(approval.input, picks: picks, other: other), mode: nil)) }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!complete)
            }
        }
        .padding(14)
        .glassEffect(.regular.tint(.purple.opacity(0.12)), in: .agentCard)
    }

    private func optionRow(_ option: ClaudeQuestion.Option, in q: ClaudeQuestion) -> some View {
        let chosen = (picks[q.question] ?? []).contains(option.label)
        return Button {
            var list = picks[q.question] ?? []
            if q.multiSelect {
                if chosen { list.removeAll { $0 == option.label } } else { list.append(option.label) }
            } else {
                list = chosen ? [] : [option.label]
            }
            picks[q.question] = list
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: q.multiSelect ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).fontWeight(.medium)
                    if !option.description.isEmpty {
                        Text(option.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(chosen ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: .rect(cornerRadius: Radius.inset))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A finished question in the transcript: what was asked, and what you answered.
private struct QuestionsAnswered: View {
    let input: JSONValue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ClaudeQuestion.all(in: input)) { q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.question).fontWeight(.medium)
                    // Answers given in AgentX are in the input; otherwise they're in the result below.
                    if let answer = input["answers"]?[q.question]?.string { Text(answer).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
