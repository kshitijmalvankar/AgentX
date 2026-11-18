import AppKit
import EventKit
import SwiftUI

/// Settings → Assistant → Permissions: what macOS lets the assistant use,
/// with a button to ask (or fix) each one.
struct PermissionsSection: View {
    @State private var automation: [AutomationTarget: AutomationAccess.Status] = [:]
    @State private var working: AutomationTarget?
    @State private var calendar = CalendarService.access(to: .event)
    @State private var reminders = CalendarService.access(to: .reminder)
    @State private var confirmReset = false
    /// Files & Folders, once checked (checking shows macOS's prompt the first time, so only on a click).
    @State private var folders: [FolderAccess.Folder: Bool] = [:]
    @State private var message: String?

    var body: some View {
        Section {
            calendarRow("Calendar", status: calendar, pane: "Privacy_Calendars")
            calendarRow("Reminders", status: reminders, pane: "Privacy_Reminders")
            ForEach(AutomationTarget.allCases.filter(\.isInstalled)) { target in automationRow(target) }
            ForEach(FolderAccess.Folder.allCases) { folder in folderRow(folder) }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Permissions")
        } footer: {
            HStack(alignment: .top) {
                Text("macOS asks once for each. If an app says Off but you never saw a prompt, Reset and Ask Again clears AgentX's Automation answers (for all apps) so macOS asks again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset and Ask Again…") { confirmReset = true }
                    .secondaryButton()
                    .controlSize(.small)
            }
        }
        .task { await refresh() }
        .confirmationDialog("Reset AgentX's Automation permissions?", isPresented: $confirmReset) {
            Button("Reset") { Task { await reset() } }
        } message: {
            Text("macOS forgets whether AgentX may control Mail, Notes, Messages, System Events, Finder and your browsers. Each asks again the next time it's needed (or when you click Allow here). Nothing else changes.")
        }
    }

    private func calendarRow(_ name: String, status: CalendarAccess, pane: String) -> some View {
        LabeledContent(name) {
            HStack(spacing: 8) {
                badge(status == .granted ? .allowed : status == .notDetermined ? .notAsked : .denied)
                switch status {
                case .granted: EmptyView()
                case .notDetermined:
                    Button("Allow…") {
                        Task {
                            await CalendarService.shared.requestAccess()
                            calendar = CalendarService.access(to: .event)
                            reminders = CalendarService.access(to: .reminder)
                        }
                    }
                    .controlSize(.small)
                case .denied:
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func automationRow(_ target: AutomationTarget) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if working == target { ProgressView().controlSize(.small) }
                badge(automation[target] ?? .unknown)
                switch automation[target] ?? .unknown {
                case .allowed:
                    EmptyView()
                case .notAsked, .unknown:
                    Button(automation[target] == .notAsked ? "Allow…" : "Check…") { Task { await request(target) } }
                        .controlSize(.small)
                        .disabled(working != nil)
                        .help("Opens \(target.name) in the background if needed, then macOS asks once.")
                case .denied:
                    Button("Open Settings") { AutomationAccess.openSystemSettings() }
                        .controlSize(.small)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(target.name)
                Text(target.purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func folderRow(_ folder: FolderAccess.Folder) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                switch folders[folder] {
                case true?:
                    badge(.allowed)
                case false?:
                    badge(.denied)
                    Button("Open Settings") { FolderAccess.openSettings() }.controlSize(.small)
                case nil:
                    badge(.unknown)
                    Button("Check…") { Task { folders[folder] = await FolderAccess.ensure(folder.url) } }
                        .controlSize(.small)
                        .help("macOS asks once whether AgentX may see this folder.")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(folder.rawValue) folder")
                Text(folder == .desktop ? "Finding files and screenshots there from the launcher" : "Finding files there from the launcher")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func badge(_ status: AutomationAccess.Status) -> some View {
        let (text, symbol, color): (String, String, Color) = switch status {
        case .allowed: ("On", "checkmark.circle.fill", .green)
        case .notAsked: ("Not asked yet", "questionmark.circle", .secondary)
        case .denied: ("Off", "xmark.circle.fill", .red)
        case .unknown: ("Not checked", "circle.dashed", .secondary)
        }
        return Label(text, systemImage: symbol).foregroundStyle(color).font(.callout)
    }

    private func refresh() async {
        calendar = CalendarService.access(to: .event)
        reminders = CalendarService.access(to: .reminder)
        for target in AutomationTarget.allCases where target.isInstalled {
            automation[target] = await AutomationAccess.status(of: target)
        }
    }

    private func request(_ target: AutomationTarget) async {
        working = target
        let status = await AutomationAccess.request(target)
        automation[target] = status
        working = nil
        if status == .denied {
            message = "\(target.name) is off. If you didn't see a prompt, use Reset and Ask Again."
        }
    }

    private func reset() async {
        do {
            try await AutomationAccess.resetAll()
            message = "Reset. Click Allow next to each app (or just ask the assistant) and macOS will ask again."
        } catch {
            message = error.localizedDescription
        }
        await refresh()
    }
}
