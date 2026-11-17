import AgentXRemote
import SwiftUI

/// What's waiting for your OK on the Mac. Each one opens to the full
/// details; Allow and Deny ask for Face ID first.
struct ApprovalsView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBanner() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                let approvals = model.snapshot?.approvals ?? []
                if approvals.isEmpty {
                    ContentUnavailableView("Nothing waiting", systemImage: "checkmark.circle",
                                           description: Text("When Claude on your Mac needs your OK, it shows up here. Pull to refresh."))
                }
                ForEach(approvals) { approval in
                    NavigationLink(value: approval.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(approval.summary).lineLimit(2)
                            HStack(spacing: 6) {
                                if approval.policyReason != nil { Image(systemName: "checkmark.shield").foregroundStyle(.orange) }
                                Text(approval.origin ?? approval.tool).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                Text(approval.receivedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Approvals")
            .navigationDestination(for: String.self) { id in ApprovalDetail(id: id) }
            .refreshable { await model.request(.refresh) }
        }
    }
}

private struct ApprovalDetail: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var working = false

    var body: some View {
        if let approval = model.snapshot?.approvals.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(approval.headline).font(.title3.bold())
                    if let origin = approval.origin {
                        Label(approval.unattended ? "From \(origin), which runs on its own" : "From \(origin)",
                              systemImage: approval.unattended ? "clock.arrow.2.circlepath" : "bubble.left")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let reason = approval.policyReason {
                        Label(reason, systemImage: "checkmark.shield")
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.12), in: .rect(cornerRadius: 14))
                    }
                    Text(approval.summary).font(.body)
                    Text("Exactly what it will do").font(.caption).foregroundStyle(.secondary)
                    Text(approval.detail)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14))
                    if model.snapshot?.canApprove == false {
                        Label("Approving from iPhone is turned off on your Mac (Settings → iPhone).", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button("Deny", role: .destructive) { act(approval, allow: false) }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                    Button("Allow") { act(approval, allow: true) }
                        .buttonStyle(.glassProminent)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(working || model.snapshot?.canApprove == false || model.connection != .connected)
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Already answered", systemImage: "checkmark.circle",
                                   description: Text("This request isn't waiting any more."))
        }
    }

    private func act(_ approval: RemoteSnapshot.Approval, allow: Bool) {
        working = true
        Task {
            await model.answer(approval, allow: allow)
            working = false
            if model.snapshot?.approvals.contains(where: { $0.id == id }) != true { dismiss() }
        }
    }
}

/// Settings → Activity on the Mac, read-only.
struct ActivityView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section { ConnectionBanner() }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                let items = model.snapshot?.activity ?? []
                if items.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle")
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.action.prefix(1).uppercased() + item.action.dropFirst() + (item.tool.map { " · \($0)" } ?? ""))
                                .fontWeight(.medium)
                            Spacer()
                            Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                        if let origin = item.origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
            }
            .navigationTitle("Activity")
            .refreshable { await model.request(.refresh) }
        }
    }
}
