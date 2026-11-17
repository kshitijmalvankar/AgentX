import AppKit
import KeyboardShortcuts
import SwiftUI

/// Settings → Security: how this copy is signed, the engine check, the kill
/// switch, and the files the assistant may never touch.
struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var exceptions: [String] = PathGuard.exceptions
    @State private var showRules = false
    private let ownTeam = CodeSignature.ownTeam()

    var body: some View {
        Form {
            Section("This copy") {
                LabeledContent("App", value: AppChannel.current.isDev ? "AgentX Dev (built from your working copy)" : "AgentX (installed)")
                LabeledContent("Location", value: Bundle.main.bundlePath.abbreviatingHome)
                LabeledContent("Signed by") {
                    if let ownTeam {
                        Label("Apple Development (team \(ownTeam))", systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else {
                        Label("Ad-hoc", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                if ownTeam == nil {
                    Text("macOS forgets permissions like Accessibility and Screen Recording each time an ad-hoc build changes. Add your Apple ID in Xcode → Settings → Accounts (free), then set your team in Config/Local.xcconfig.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Agent engine") {
                LabeledContent("agent-core", value: model.client.paths?.agentCoreIsEmbedded == true
                               ? "Inside the app (signed)" : (model.client.paths?.agentCore?.abbreviatingHome ?? "Not found"))
                LabeledContent("Claude Code engine") { engineStatus }
            }

            Section("Stop everything") {
                KeyboardShortcuts.Recorder("Shortcut:", name: .stopEverything)
                HStack {
                    Text("Interrupts every running Claude session, denies what's waiting for approval, and pauses automations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop Everything", role: .destructive) { Task { await model.stopEverything(source: "Settings") } }
                        .secondaryButton()
                }
            }

            Section("Untrusted content") {
                Text("Web pages, email, notes, calendar invites, files outside your projects and anything a schedule or trigger brings in can contain instructions written to steer Claude. Once a conversation has read any of it, AgentX asks before anything that could send your data out (fetching a URL, opening a link, the clipboard), and \"Always allow\" isn't offered for sending or deleting. Scheduled runs start this way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Protected files (\(ruleLabels.count) kinds)", isExpanded: $showRules) {
                    ForEach(ruleLabels, id: \.self) { Text($0).font(.callout) }
                }
                if exceptions.isEmpty {
                    Text("No exceptions.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(exceptions, id: \.self) { path in
                        HStack {
                            Image(systemName: "lock.open").foregroundStyle(.orange)
                            Text(path).font(.callout.monospaced())
                            Spacer()
                            Button("Remove", systemImage: "minus.circle") { setExceptions(exceptions.filter { $0 != path }) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Exception…") { addException() }
            } header: {
                Text("Protected files")
            } footer: {
                Text("The assistant, tasks and automations can never read or change credentials, keys, cookies, the Keychain or browser profiles. Coding sessions keep Claude Code's own rules. Add an exception only for a folder you're sure about.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var engineStatus: some View {
        switch model.engineSignature {
        case nil:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .verified(let team)?:
            Label("Signed by Anthropic (\(team))", systemImage: "checkmark.seal").foregroundStyle(.green)
        case .failed(let why)?:
            Label("Signature check failed: \(why)", systemImage: "xmark.seal").foregroundStyle(.red)
        case .missing?:
            Label("Not found", systemImage: "questionmark.circle").foregroundStyle(.orange)
        }
    }

    private var ruleLabels: [String] {
        var seen = Set<String>()
        return PathGuard.rules.map(\.label).filter { seen.insert($0).inserted }
    }

    private func setExceptions(_ list: [String]) {
        exceptions = list
        UserDefaults.standard.set(list, forKey: PathGuard.exceptionsKey)
        Task { await model.sendSecuritySettings() }
        model.activity.record(.policy, "exceptions changed", detail: list.isEmpty ? "No path exceptions." : "Exceptions: " + list.joined(separator: ", "))
    }

    private func addException() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a protected folder or file the assistant may use."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = PathGuard.display(url.standardizedFileURL.path)
        guard !exceptions.contains(path) else { return }
        setExceptions(exceptions + [path])
    }
}

/// Settings → Activity: everything AgentX and Claude did that changed
/// something, plus every security decision, newest first.
struct ActivitySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter: ActivityEntry.Kind?
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("Everything").tag(ActivityEntry.Kind?.none)
                    Text("Tools").tag(ActivityEntry.Kind?.some(.tool))
                    Text("Security").tag(ActivityEntry.Kind?.some(.policy))
                    Text("Approvals").tag(ActivityEntry.Kind?.some(.approval))
                    Text("Automations").tag(ActivityEntry.Kind?.some(.automation))
                }
                .fixedSize()
                Spacer()
                Button("Show Log File") { NSWorkspace.shared.activateFileViewerSelecting([model.activity.fileURL]) }
                    .secondaryButton()
                Button("Clear…") { confirmClear = true }
                    .secondaryButton()
            }
            let entries = model.activity.recent.filter { filter == nil || $0.kind == filter || (filter == .policy && [.killSwitch, .link].contains($0.kind)) }
            if entries.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Actions that change something, approvals and security decisions show up here. Kept for 30 days."))
                    .frame(maxHeight: .infinity)
            } else {
                List(entries) { entry in ActivityRow(entry: entry) }
                    .listStyle(.inset)
                    .clipShape(.rect(cornerRadius: Radius.inset))
            }
        }
        .padding()
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.activity.clear() }
        } message: {
            Text("This deletes the record of what AgentX and Claude did. It can't be undone.")
        }
    }
}

private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(headline).fontWeight(.medium)
                    Spacer()
                    Text(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                if let origin = entry.origin {
                    Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var headline: String {
        let tool = entry.toolLabel.map { " · \($0)" } ?? ""
        return entry.action.prefix(1).uppercased() + entry.action.dropFirst() + tool
    }

    private var symbol: String {
        switch entry.kind {
        case .tool: "wrench.and.screwdriver"
        case .policy: entry.action == "blocked" ? "xmark.shield" : "checkmark.shield"
        case .approval: entry.action == "denied" ? "hand.raised.slash" : "hand.thumbsup"
        case .automation: "clock.arrow.2.circlepath"
        case .killSwitch: "stop.circle"
        case .link: "link"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .policy where entry.action == "blocked", .killSwitch: .red
        case .policy, .link: .orange
        default: .secondary
        }
    }
}
