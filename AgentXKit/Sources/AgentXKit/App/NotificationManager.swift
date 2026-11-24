import AppKit
import Foundation
import UserNotifications

/// macOS notifications for approvals, with Allow / Deny buttons right in the
/// banner. Only works when AgentX runs as a real .app bundle.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private static let approvalCategory = "agentx.approval"
    private static let allowAction = "agentx.allow"
    private static let denyAction = "agentx.deny"

    private weak var store: SessionStore?
    private var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func configure(store: SessionStore) {
        self.store = store
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Allowing from a banner needs the Mac unlocked, so nobody can approve from the lock screen.
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [.authenticationRequired])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Approval requests: always for unattended automation runs, otherwise only when AgentX isn't in front.
    func postApproval(_ request: ApprovalRequest) {
        guard isAvailable, request.automationName != nil || !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = request.automationName.map { "\($0) needs your OK" } ?? request.headline
        let project = request.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude"
        content.subtitle = project
        let summary = ToolPresentation.summary(name: request.toolName, input: request.input, cwd: request.cwd)
        content.body = request.policyReason.map { "\(summary)\n\($0)" } ?? summary
        // A burst of requests: make them open AgentX and look, rather than allow from the banner.
        // A question is answered in AgentX, so no Allow/Deny buttons on the banner.
        content.categoryIdentifier = request.recentRiskyActions > 3 || request.isQuestion ? "" : Self.approvalCategory
        content.sound = .default
        content.userInfo = ["approvalID": request.id]
        let req = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// A plain heads-up (e.g. after Stop everything).
    func postNotice(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// "Morning brief: …" when an automation run finishes. Clicking it opens the run.
    func postAutomationResult(_ run: AutomationRun) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        switch run.status {
        case .succeeded: content.title = run.automationName
        case .failed: content.title = "\(run.automationName) didn't finish"
        case .skipped: content.title = "\(run.automationName) was skipped"
        case .running: return
        }
        content.body = String((run.summary ?? "").prefix(300))
        content.sound = .default
        if let sessionId = run.sessionId { content.userInfo = ["openKey": sessionId] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["approvalID"] as? String
        let openKey = response.notification.request.content.userInfo["openKey"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if let openKey {
                AppModel.shared.openSession(openKey)
                AppModel.shared.showMainWindow()
                return
            }
            guard let id else { return }
            switch action {
            case Self.allowAction: store?.answer(approvalID: id, .allow)
            case Self.denyAction: store?.answer(approvalID: id, .deny())
            default:
                NSApp.activate()
                AppModel.shared.sidebar = .sessions
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
