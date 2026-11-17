import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Account", systemImage: "person.crop.circle") { AccountSettings() }
            Tab("Assistant", systemImage: "sparkles") { AssistantSettings() }
            Tab("iPhone", systemImage: "iphone") { PhoneSettingsView() }
            Tab("Security", systemImage: "lock.shield") { SecuritySettingsView() }
            Tab("Activity", systemImage: "list.bullet.rectangle") { ActivitySettingsView() }
            Tab("Diagnostics", systemImage: "stethoscope") { DiagnosticsSettings() }
        }
        .frame(width: 700, height: 560)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ToolLocator.nodePathOverrideKey) private var nodeOverride = ""
    @AppStorage(ToolLocator.agentCorePathOverrideKey) private var coreOverride = ""

    var body: some View {
        Form {
            Section("Launcher") {
                KeyboardShortcuts.Recorder("Open the launcher:", name: .toggleLauncher)
                Text("Ask the assistant from anywhere, or type /code <project> <task> to start a coding session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Agent engine") {
                LabeledContent("Status", value: model.client.statusMessage)
                LabeledContent("Agent SDK", value: model.client.sdkVersion ?? "—")
                Button("Restart Engine") { Task { await model.restartEngine() } }
            }
            Section("Programs") {
                LabeledContent("Node.js", value: model.client.paths?.node?.abbreviatingHome ?? "Not found")
                LabeledContent("agent-core", value: model.client.paths?.agentCore?.abbreviatingHome ?? "Not found")
                LabeledContent("claude CLI", value: model.client.paths?.claude?.abbreviatingHome ?? "Not found")
                TextField("Node.js path override", text: $nodeOverride, prompt: Text("Automatic"))
                TextField("agent-core path override", text: $coreOverride, prompt: Text("Automatic"))
                Text("Changes apply after Restart Engine.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Claude Code login") {
                if let a = model.account?.account {
                    LabeledContent("Plan", value: a.planLabel)
                    LabeledContent("Email", value: a.email ?? "—")
                    LabeledContent("Organization", value: a.organization ?? "—")
                    LabeledContent("Provider", value: a.apiProvider ?? "—")
                } else {
                    Text(model.accountError ?? "Loading…").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Sign In / Switch Account…") { model.showLogin = true }
                    Button("Reload") { Task { await model.reloadAccount() } }
                }
            }
            Section {
                Text("AgentX uses the Claude Code login on this Mac and never stores credentials itself. Builds shared with other people will need their own Anthropic API key for the native chat, per Anthropic's Agent SDK terms; the Terminal tab always works with their own Claude login.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Every Mac tool the assistant has, and whether it asks first.
private struct AssistantSettings: View {
    private var areas: [(String, [MacTool])] {
        var order: [String] = []
        var byArea: [String: [MacTool]] = [:]
        for tool in MacToolbox.tools {
            if byArea[tool.area] == nil { order.append(tool.area) }
            byArea[tool.area, default: []].append(tool)
        }
        return order.map { ($0, byArea[$0]!) }
    }

    var body: some View {
        Form {
            Section {
                Text("Reading and creating things run on their own and appear as cards in the conversation. Sending, deleting, moving, quitting and running Shortcuts always ask you first. macOS also asks once before AgentX can use Calendar, Reminders, Mail, Notes, Messages or System Events.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(areas, id: \.0) { area, tools in
                Section(area) {
                    ForEach(tools) { tool in
                        LabeledContent(tool.summary) {
                            Label(tool.risk.label, systemImage: tool.risk == .ask ? "hand.raised" : tool.risk == .create ? "plus.circle" : "eye")
                                .foregroundStyle(tool.risk == .ask ? .primary : .secondary)
                        }
                        .help(tool.description)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            Text("agent-core log").font(.headline)
            ScrollView {
                Text(model.client.recentLog.suffix(200).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Radius.inset))
        }
        .padding()
    }
}
