import AgentXRemote
import SwiftUI

/// The Mac tab: vitals, plan usage, today, automations, what's running, and Stop Everything.
struct OverviewView: View {
    @Environment(PhoneModel.self) private var model
    @State private var confirmStop = false
    @State private var confirmUnpair = false
    @State private var details: RemoteSnapshot.AgendaItem?

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBanner() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                if let s = model.snapshot {
                    if let v = s.vitals { vitals(v) }
                    if !s.usage.isEmpty { usage(s) }
                    running(s)
                    today(s)
                    automations(s)
                } else if model.connection == .connected || model.connection == .connecting {
                    Section { ProgressView("Loading…") }
                }
                Section {
                    Button("Stop Everything", systemImage: "stop.circle", role: .destructive) { confirmStop = true }
                        .disabled(model.connection != .connected)
                } footer: {
                    Text("Interrupts every Claude session on your Mac, denies what's waiting for approval, and pauses automations.")
                }
            }
            .navigationTitle(model.snapshot?.macName ?? model.pairing?.macName ?? "Mac")
            .refreshable { await model.request(.refresh) }
            .toolbar {
                Menu("More", systemImage: "ellipsis.circle") {
                    if let s = model.snapshot { Text("\(s.appName) · \(s.planLabel ?? "")") }
                    Button("Unpair This iPhone", role: .destructive) { confirmUnpair = true }
                }
            }
            .confirmationDialog("Stop everything on your Mac?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Everything", role: .destructive) { Task { await model.stopEverything() } }
            } message: {
                Text("You'll confirm with Face ID.")
            }
            .sheet(item: $details) { item in AgendaDetails(item: item).presentationDetents([.medium]) }
            .confirmationDialog("Unpair this iPhone?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair() }
            } message: {
                Text("This iPhone forgets your Mac. Also remove it on the Mac in Settings → iPhone.")
            }
        }
    }

    private func vitals(_ v: RemoteSnapshot.Vitals) -> some View {
        Section("Vitals") {
            meter("CPU", Format.percent(v.cpu), v.cpu)
            meter("Memory", "\(Format.bytes(v.memoryUsed)) of \(Format.bytes(v.memoryTotal))", Double(v.memoryUsed) / Double(max(v.memoryTotal, 1)))
            meter("Disk", "\(Format.bytes(v.diskFree)) free", 1 - Double(v.diskFree) / Double(max(v.diskTotal, 1)))
            if let level = v.batteryLevel {
                meter("Battery", Format.percent(level) + (v.charging == true ? ", charging" : ""), level)
            }
            LabeledContent("Memory pressure", value: v.memoryPressure)
            LabeledContent("Temperature", value: v.thermal)
        }
    }

    private func meter(_ name: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(max(fraction, 0), 1))
        }
    }

    private func usage(_ s: RemoteSnapshot) -> some View {
        Section(s.planLabel ?? "Claude plan") {
            ForEach(s.usage, id: \.label) { u in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(u.label)
                        Spacer()
                        Text(Format.percent(u.fraction)).monospacedDigit().foregroundStyle(u.fraction >= 0.9 ? .red : .secondary)
                    }
                    ProgressView(value: min(u.fraction, 1)).tint(u.fraction >= 0.9 ? .red : .accentColor)
                    if let reset = u.resetsAt {
                        Text("Resets \(reset.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func running(_ s: RemoteSnapshot) -> some View {
        let live = s.conversations.filter { $0.state != nil }
        if !live.isEmpty || !s.approvals.isEmpty {
            Section("Running") {
                if !s.approvals.isEmpty {
                    Label("\(s.approvals.count) waiting for your OK", systemImage: "hand.raised.fill").foregroundStyle(.orange)
                }
                ForEach(live) { c in
                    HStack {
                        Image(systemName: c.isMac ? "desktopcomputer" : "terminal").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(c.title).lineLimit(1)
                            if let project = c.project { Text(project).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text(c.state ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func today(_ s: RemoteSnapshot) -> some View {
        let canEdit = s.canEditReminders == true && model.connection == .connected
        return Section {
            if s.today.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(.secondary)
            }
            ForEach(s.today) { item in
                HStack(spacing: 12) {
                    if item.isReminder {
                        Button {
                            Task { await model.setReminder(item, completed: !item.isDone) }
                        } label: {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(item.isOverdue ? .red : .accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canEdit)
                        .accessibilityLabel(item.isDone ? "Mark \(item.title) as not done" : "Mark \(item.title) as done")
                    } else {
                        Image(systemName: "calendar").foregroundStyle(.secondary).frame(width: 22)
                    }
                    Button { details = item } label: {
                        HStack {
                            Text(item.title)
                                .lineLimit(1)
                                .strikethrough(item.isDone)
                                .foregroundStyle(item.isDone ? .secondary : .primary)
                            Spacer()
                            Text(item.when).font(.caption).foregroundStyle(item.isOverdue ? .red : .secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .swipeActions(edge: .trailing) {
                    if item.isReminder, canEdit {
                        Button(item.isDone ? "Undo" : "Done", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                            Task { await model.setReminder(item, completed: !item.isDone) }
                        }
                        .tint(item.isDone ? .gray : .green)
                    }
                }
            }
        } header: {
            Text("Today")
        } footer: {
            if s.today.contains(where: \.isReminder) {
                Text(s.canEditReminders == true
                     ? "Tap the circle (or swipe) to tick a reminder off. Calendar invitations can only be answered in Calendar."
                     : "Ticking off reminders from iPhone is turned off on your Mac.")
            }
        }
    }

    @ViewBuilder private func automations(_ s: RemoteSnapshot) -> some View {
        if !s.automations.isEmpty {
            Section {
                ForEach(s.automations) { a in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(a.name)
                            Spacer()
                            if let status = a.lastStatus {
                                Text(status.capitalized).font(.caption)
                                    .foregroundStyle(status == "failed" ? .red : status == "succeeded" ? .green : .secondary)
                            }
                        }
                        if let next = a.next {
                            Text("Next: \(next.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Automations")
            } footer: {
                if s.automationsPaused { Text("Automations are paused on your Mac.") }
            }
        }
    }
}

/// A reminder's or event's details, with Done / Undo for reminders.
private struct AgendaDetails: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: RemoteSnapshot.AgendaItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.title).font(.title3.bold()).strikethrough(item.isDone)
                    Label(item.when, systemImage: item.isReminder ? "calendar.badge.clock" : "clock")
                        .foregroundStyle(item.isOverdue ? .red : .primary)
                    if let source = item.source {
                        Label(source, systemImage: item.isReminder ? "list.bullet" : "calendar")
                    }
                    if let location = item.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                    }
                }
                if let notes = item.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Section("Notes") { Text(notes).textSelection(.enabled) }
                }
                if item.isReminder, model.snapshot?.canEditReminders == true {
                    Section {
                        Button(item.isDone ? "Mark as Not Done" : "Mark as Done", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                            Task {
                                await model.setReminder(item, completed: !item.isDone)
                                dismiss()
                            }
                        }
                        .disabled(model.connection != .connected)
                    }
                } else if !item.isReminder {
                    Section {
                        Text("Calendar invitations can only be accepted or declined in the Calendar app.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(item.isReminder ? "Reminder" : "Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
