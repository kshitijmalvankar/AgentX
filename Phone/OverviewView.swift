import AgentXRemote
import SwiftUI

/// The Mac tab: vitals, plan usage, today, automations, what's running, and Stop Everything.
struct OverviewView: View {
    @Environment(PhoneModel.self) private var model
    @State private var confirmStop = false
    @State private var confirmUnpair = false

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
        Section("Today") {
            if s.today.isEmpty {
                Text("Nothing scheduled.").foregroundStyle(.secondary)
            }
            ForEach(s.today) { item in
                HStack {
                    Image(systemName: item.isReminder ? "circle" : "calendar")
                        .foregroundStyle(item.isOverdue ? .red : .secondary)
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.when).font(.caption).foregroundStyle(item.isOverdue ? .red : .secondary)
                }
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
