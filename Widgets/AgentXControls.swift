// Control Center (and menu bar) buttons. Each opens an agentx:// link in
// AgentX; the ones that do something carry AgentX's route token, which they
// read from AgentX's data folder, so a web page can't fake them.
import AgentXShared
import AppIntents
import SwiftUI
import WidgetKit

/// Opens the launcher over the app you're in.
struct AskControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.agentx.control.ask") {
            ControlWidgetButton(action: OpenURLIntent(SharedChannel.url("launcher"))) {
                Label("Ask \(SharedChannel.appName)", systemImage: "sparkle.magnifyingglass")
            }
        }
        .displayName("Ask \(SharedChannel.appName)")
        .description("Opens the launcher, like the keyboard shortcut.")
    }
}

/// Shows how many approvals are waiting; opens them.
struct ApprovalsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.agentx.control.approvals", provider: ApprovalsProvider()) { waiting in
            ControlWidgetButton(action: OpenURLIntent(SharedChannel.url("approvals"))) {
                Label(waiting == 0 ? "Nothing waiting" : "\(waiting) waiting for you",
                      systemImage: waiting == 0 ? "checkmark.shield" : "exclamationmark.shield")
            }
        }
        .displayName("Approvals")
        .description("How many of Claude's actions are waiting for your OK.")
    }
}

struct ApprovalsProvider: ControlValueProvider {
    var previewValue: Int { 1 }
    func currentValue() async throws -> Int { WidgetSnapshot.load()?.waitingApprovals ?? 0 }
}

/// The kill switch.
struct StopEverythingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.agentx.control.stop") {
            ControlWidgetButton(action: OpenURLIntent(SharedChannel.url("stop", secured: true))) {
                Label("Stop Everything", systemImage: "stop.circle")
            }
        }
        .displayName("Stop Everything")
        .description("Stops every running Claude session, turns down waiting approvals and pauses automations.")
    }
}

// MARK: - Run an automation

/// Runs the automation you picked when adding the control.
struct RunAutomationControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "dev.agentx.control.run", provider: RunAutomationProvider()) { value in
            ControlWidgetButton(action: OpenURLIntent(value.url)) {
                Label(value.name, systemImage: "clock.arrow.2.circlepath")
            }
        }
        .displayName("Run Automation")
        .description("Runs one of your AgentX automations.")
        .promptsForUserConfiguration()
    }
}

struct RunAutomationValue: Sendable {
    var name: String
    var url: URL
}

struct RunAutomationProvider: AppIntentControlValueProvider {
    func previewValue(configuration: ChooseAutomationIntent) -> RunAutomationValue {
        RunAutomationValue(name: configuration.automation?.name ?? "Run Automation", url: SharedChannel.url("automations"))
    }

    func currentValue(configuration: ChooseAutomationIntent) async throws -> RunAutomationValue {
        // Not picked yet, or since deleted: open Automations instead.
        guard let picked = configuration.automation,
              WidgetSnapshot.load()?.automations?.contains(where: { $0.id == picked.id }) ?? true else {
            return RunAutomationValue(name: "Choose an Automation", url: SharedChannel.url("automations"))
        }
        return RunAutomationValue(name: picked.name, url: SharedChannel.url("run/\(picked.id)", secured: true))
    }
}

struct ChooseAutomationIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose an Automation"

    @Parameter(title: "Automation")
    var automation: ControlAutomation?
}

/// An automation as the controls know it (from AgentX's snapshot).
struct ControlAutomation: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Automation"
    static let defaultQuery = ControlAutomationQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ControlAutomationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ControlAutomation] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ControlAutomation] { all() }

    private func all() -> [ControlAutomation] {
        (WidgetSnapshot.load()?.automations ?? []).map { ControlAutomation(id: $0.id, name: $0.name) }
    }
}
