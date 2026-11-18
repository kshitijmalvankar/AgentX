import AppKit
import ServiceManagement
import SwiftUI

/// Opens AgentX when you log in, so automations can run (macOS login item).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension Date {
    /// "Today 18:00", "Tomorrow 08:00", "Sun 10:00".
    var scheduleLabel: String {
        let time = formatted(.dateTime.hour().minute())
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today \(time)" }
        if cal.isDateInTomorrow(self) { return "Tomorrow \(time)" }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

struct AutomationsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Automation?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    private var center: AutomationCenter { model.automations }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if center.isPaused {
                    HStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                        Text(AppChannel.current.isDev
                             ? "Paused in AgentX Dev, so your installed AgentX is the only one running automations. \"Run now\" still works."
                             : "Automations are paused (Stop everything, or you paused them). \"Run now\" still works.")
                            .font(.callout)
                        Spacer()
                        Button("Resume") { center.isPaused = false }.secondaryButton()
                    }
                    .padding(12)
                    .glassEffect(.regular.tint(.orange.opacity(0.12)), in: .agentCard)
                }
                if let error = center.storageError {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                }
                VStack(spacing: 12) {
                    ForEach(center.automations) { automation in
                        AutomationCard(automation: automation, edit: { editing = automation })
                    }
                }
                if !center.runs.isEmpty {
                    Text("Recent runs").font(.headline).padding(.top, 8)
                    VStack(spacing: 0) {
                        ForEach(center.runs.prefix(30)) { run in
                            RunRow(run: run)
                            Divider()
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Automations")
        .sheet(item: $editing) { automation in
            AutomationEditor(original: automation)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automations").font(.largeTitle.bold())
                    Text("Claude tasks that run on a schedule, with the same tools and approvals as the Assistant.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("New Automation", systemImage: "plus") {
                    editing = Automation(name: "", prompt: "", kind: .assistant, folder: nil,
                                         schedule: .daily(hour: 9, minute: 0, weekdays: []), enabled: true)
                }
                .primaryButton()
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Automations run only while AgentX is open (it can stay in the menu bar). Anything that needs your OK is sent as a notification and skipped after 10 minutes without an answer. Each run uses your Claude plan.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle("Open AgentX at login", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .disabled(AppChannel.current.isDev)
                        .help(AppChannel.current.isDev ? "Only the installed AgentX opens at login." : "")
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                try LaunchAtLogin.set(on)
                                loginError = nil
                            } catch {
                                loginError = error.localizedDescription
                                launchAtLogin = LaunchAtLogin.isEnabled
                            }
                        }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: .agentCard)
        }
    }
}

private struct AutomationCard: View {
    @Environment(AppModel.self) private var model
    let automation: Automation
    let edit: () -> Void
    @State private var confirmDelete = false

    private var center: AutomationCenter { model.automations }

    var body: some View {
        let running = center.isRunning(automation.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(automation.name.isEmpty ? "Untitled" : automation.name).font(.headline)
                    HStack(spacing: 6) {
                        Label(automation.schedule.label, systemImage: "clock")
                        Text("·")
                        Text(automation.kind == .assistant ? "Assistant"
                             : automation.kind == .onDevice ? "On this Mac"
                             : "Coding in \(((automation.folder ?? "~") as NSString).lastPathComponent)")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Text(automation.prompt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("On", isOn: Binding(get: { automation.enabled }, set: { center.setEnabled(automation.id, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(automation.enabled ? "Turn off" : "Turn on")
            }
            HStack(spacing: 12) {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Running now…").font(.callout).foregroundStyle(.secondary)
                } else if let next = center.nextRun(of: automation) {
                    Label("Next: \(next.scheduleLabel)", systemImage: "calendar").font(.callout)
                } else {
                    Text("Off").font(.callout).foregroundStyle(.tertiary)
                }
                if let last = center.lastRun(of: automation), last.status != .running {
                    RunStatusIcon(status: last.status)
                    Text("Last run \(last.startedAt.relative)").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run Now", systemImage: "play.fill") { center.runNow(automation) }
                    .disabled(running)
                    .help("Run it once now (uses your plan)")
                Button("Edit", action: edit)
                Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    .labelStyle(.iconOnly)
            }
            .secondaryButton()
            .controlSize(.small)
        }
        .padding(16)
        .glassEffect(.regular, in: .agentCard)
        .confirmationDialog("Delete \"\(automation.name)\"?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { center.delete(automation.id) }
        } message: {
            Text("Its past runs stay in the history.")
        }
    }
}

struct RunStatusIcon: View {
    let status: AutomationRun.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(Viz.good).help("Finished")
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Viz.critical).help("Didn't finish")
        case .skipped: Image(systemName: "forward.circle.fill").foregroundStyle(Viz.warning).help("Skipped")
        }
    }
}

private struct RunRow: View {
    @Environment(AppModel.self) private var model
    let run: AutomationRun
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunStatusIcon(status: run.status).frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(run.automationName).fontWeight(.medium)
                    Text(run.startedAt.scheduleLabel).foregroundStyle(.secondary)
                    if run.trigger != .scheduled {
                        Text(run.trigger == .manual ? "run by you" : "caught up after wake")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                if let summary = run.summary, !summary.isEmpty {
                    if expanded {
                        MarkdownText(text: summary)
                    } else {
                        Text(summary).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                if run.unansweredApprovals > 0 {
                    Label("\(run.unansweredApprovals) step\(run.unansweredApprovals == 1 ? "" : "s") skipped: no answer within 10 minutes",
                          systemImage: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            Spacer()
            if let summary = run.summary, summary.count > 160 {
                Button(expanded ? "Less" : "More") { expanded.toggle() }.buttonStyle(.link).font(.caption)
            }
            if let sessionId = run.sessionId {
                Button("Open") { model.openSession(sessionId) }
                    .secondaryButton()
                    .controlSize(.small)
                    .help("Open the full conversation")
            }
        }
        .padding(.vertical, 10)
    }
}

/// Create or edit an automation.
private struct AutomationEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Automation
    @State private var draft: Automation
    @State private var everyHours = false
    @State private var time = Date()
    @State private var weekdays: Set<Int> = []
    @State private var hours = 3
    @State private var allowedText = ""

    init(original: Automation) {
        self.original = original
        _draft = State(initialValue: original)
        switch original.schedule {
        case .daily(let hour, let minute, let days):
            _time = State(initialValue: Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
            _weekdays = State(initialValue: days)
        case .interval(let h):
            _everyHours = State(initialValue: true)
            _hours = State(initialValue: h)
        }
        _allowedText = State(initialValue: original.allowedTools.joined(separator: ", "))
    }

    private var isNew: Bool { !model.automations.automations.contains { $0.id == original.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Automation" : "Edit Automation").font(.title2.bold())
            Form {
                TextField("Name", text: $draft.name, prompt: Text("Morning brief"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("What should Claude do?")
                    TextEditor(text: $draft.prompt)
                        .font(.body)
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: Radius.field))
                }
                Picker("Runs as", selection: $draft.kind) {
                    Text("Assistant (Calendar, Files, Mail, …)").tag(Automation.Kind.assistant)
                    Text("Coding session in a folder").tag(Automation.Kind.coding)
                    Text("Briefing on this Mac (no Claude)").tag(Automation.Kind.onDevice)
                }
                if draft.kind == .onDevice {
                    Text("Written on this Mac by Apple Intelligence from your calendar, reminders and unread mail, and shown as a notification. It doesn't use your Claude plan. Below, say what to focus on (or leave it empty).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.kind == .coding {
                    Picker("Folder", selection: Binding(get: { draft.folder ?? "" }, set: { draft.folder = $0.isEmpty ? nil : $0 })) {
                        Text("Choose…").tag("")
                        ForEach(model.sessions.recentProjects.prefix(15), id: \.self) { Text($0.abbreviatingHome).tag($0) }
                    }
                    TextField("Commands it may run unattended", text: $allowedText,
                              prompt: Text("Bash(git status:*), Bash(npm test:*)"))
                    Text("Anything else that needs approval is sent to you and skipped after 10 minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Schedule", selection: $everyHours) {
                    Text("At a time").tag(false)
                    Text("Every few hours").tag(true)
                }
                .pickerStyle(.segmented)
                if everyHours {
                    Stepper("Every \(hours) hour\(hours == 1 ? "" : "s")", value: $hours, in: 1...24)
                } else {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    LabeledContent("Days") {
                        HStack(spacing: 4) {
                            ForEach(1...7, id: \.self) { day in
                                let on = weekdays.contains(day)
                                Button(Calendar.current.veryShortWeekdaySymbols[day - 1]) {
                                    if on { weekdays.remove(day) } else { weekdays.insert(day) }
                                }
                                .buttonStyle(.plain)
                                .frame(width: 26, height: 26)
                                .background(on ? Color.accentColor : Color.secondary.opacity(0.15), in: .circle)
                                .foregroundStyle(on ? Color.white : Color.primary)
                            }
                        }
                    }
                    Text(weekdays.isEmpty ? "No days picked: runs every day." : "Runs on the highlighted days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("On", isOn: $draft.enabled)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.secondaryButton().keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (draft.kind != .onDevice && draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                              || (draft.kind == .coding && draft.folder == nil))
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func save() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        draft.schedule = everyHours ? .interval(hours: hours)
            : .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays)
        draft.allowedTools = allowedText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if draft.kind == .assistant || draft.kind == .onDevice { draft.folder = nil; draft.allowedTools = [] }
        if isNew { model.automations.add(draft) } else { model.automations.update(draft) }
        dismiss()
    }
}

/// Dashboard: what runs next and how the last runs went.
struct AutomationsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let center = model.automations
        GlassCard("Automations", symbol: "clock.arrow.2.circlepath", tint: .teal) {
            Button("All") { model.sidebar = .automations }.buttonStyle(.link)
        } content: {
            let upcoming = center.upcoming.prefix(2)
            let recent = center.runs.filter { $0.status != .running }.prefix(2)
            if upcoming.isEmpty && recent.isEmpty {
                Text("Nothing scheduled. Turn on a starter like Morning brief in Automations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(upcoming), id: \.automation.id) { item in
                HStack {
                    Image(systemName: center.isRunning(item.automation.id) ? "hourglass" : "clock").foregroundStyle(.secondary)
                    Text(item.automation.name).lineLimit(1)
                    Spacer()
                    Text(center.isRunning(item.automation.id) ? "Running" : item.date.scheduleLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !recent.isEmpty && !upcoming.isEmpty { Divider() }
            ForEach(Array(recent)) { run in
                Button {
                    if let id = run.sessionId { model.openSession(id) } else { model.sidebar = .automations }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        RunStatusIcon(status: run.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(run.automationName) · \(run.startedAt.relative)").font(.callout)
                            if let summary = run.summary {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minHeight: 140)
    }
}
