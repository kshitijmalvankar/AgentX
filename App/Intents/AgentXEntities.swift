import AgentXKit
import AppIntents
import Foundation

/// One of your automations, for "Run Automation" in Shortcuts, Siri and Spotlight.
struct AutomationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Automation"
    static let defaultQuery = AutomationQuery()

    let id: UUID
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    init(_ summary: AgentXActions.AutomationSummary) {
        id = summary.id
        name = summary.name
        detail = summary.detail
    }
}

struct AutomationQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [AutomationEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [AutomationEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [AutomationEntity] { await all() }

    private func all() async -> [AutomationEntity] {
        await MainActor.run { AgentXActions.automations().map(AutomationEntity.init) }
    }
}

/// A project folder, for "Start a Coding Session".
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectQuery()

    /// The folder's path.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\((id as NSString).abbreviatingWithTildeInPath)")
    }

    init(_ project: AgentXActions.Project) {
        id = project.path
        name = project.name
    }
}

struct ProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [ProjectEntity] {
        await all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [ProjectEntity] { await all() }

    private func all() async -> [ProjectEntity] {
        await MainActor.run { AgentXActions.projects().map(ProjectEntity.init) }
    }
}

/// A section of AgentX's window.
enum SectionOption: String, AppEnum {
    case dashboard, chats, sessions, github, system, automations

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Section"
    static let caseDisplayRepresentations: [SectionOption: DisplayRepresentation] = [
        .dashboard: DisplayRepresentation(title: "Dashboard", image: .init(systemName: "square.grid.2x2")),
        .chats: DisplayRepresentation(title: "Chats", image: .init(systemName: "bubble.left.and.text.bubble.right")),
        .sessions: DisplayRepresentation(title: "Sessions", image: .init(systemName: "terminal")),
        .github: DisplayRepresentation(title: "GitHub", image: .init(systemName: "chevron.left.forwardslash.chevron.right")),
        .system: DisplayRepresentation(title: "System", image: .init(systemName: "gauge.with.dots.needle.50percent")),
        .automations: DisplayRepresentation(title: "Automations", image: .init(systemName: "clock.arrow.2.circlepath")),
    ]

    var item: SidebarItem { SidebarItem(rawValue: rawValue) ?? .dashboard }
}
