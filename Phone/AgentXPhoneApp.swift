import AgentXRemote
import SwiftUI

/// The AgentX companion for iPhone: watch your Mac, answer approvals with
/// Face ID, stop everything, and message Claude on your Mac.
@main
struct AgentXPhoneApp: App {
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Root()
                .environment(model)
                .onChange(of: phase) { _, phase in
                    switch phase {
                    case .active: Task { await model.didBecomeActive() }
                    case .background: model.didEnterBackground()
                    default: break
                    }
                }
        }
    }
}

private struct Root: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        Group {
            if model.pairing == nil {
                PairView()
            } else if model.isLocked {
                LockView()
            } else {
                MainTabs()
            }
        }
        .alert("AgentX", isPresented: .constant(model.notice != nil)) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

/// Face ID before anything is shown.
private struct LockView: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.shield").font(.system(size: 56)).foregroundStyle(.tint)
            Text("AgentX is locked").font(.title2.bold())
            Text("Unlock with Face ID to see and control \(model.pairing?.macName ?? "your Mac").")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Unlock") { Task { await model.unlock() } }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            Spacer()
        }
        .padding(32)
        .task { await model.unlock() }
    }
}

struct MainTabs: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        TabView {
            Tab("Mac", systemImage: "desktopcomputer") { OverviewView() }
            Tab("Approvals", systemImage: "hand.raised") { ApprovalsView() }
                .badge(model.snapshot?.approvals.count ?? 0)
            Tab("Claude", systemImage: "bubble.left.and.text.bubble.right") { ConversationsView() }
            Tab("Activity", systemImage: "list.bullet.rectangle") { ActivityView() }
        }
    }
}

/// Shown above content when not connected.
struct ConnectionBanner: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        switch model.connection {
        case .connected, .unpaired:
            EmptyView()
        case .connecting:
            banner("Connecting to \(model.pairing?.macName ?? "your Mac")…", symbol: "arrow.triangle.2.circlepath", tint: .secondary, retry: false)
        case .awaitingConfirmation:
            banner("Waiting for you to allow this iPhone on your Mac (Settings → iPhone).", symbol: "hand.raised", tint: .orange, retry: false)
        case .offline(let why):
            banner(why, symbol: "wifi.exclamationmark", tint: .orange, retry: true)
        case .refused:
            VStack(alignment: .leading, spacing: 8) {
                Label("Your Mac no longer accepts this iPhone. Pair it again with a new code.", systemImage: "xmark.shield")
                    .foregroundStyle(.red)
                Button("Pair Again") { model.unpair() }.buttonStyle(.glass)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    private func banner(_ text: String, symbol: String, tint: Color, retry: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.callout)
            Spacer(minLength: 0)
            if retry {
                Button("Retry") { Task { await model.connect() } }.buttonStyle(.glass)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

enum Format {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    static func bytes(_ v: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .memory)
    }
}
