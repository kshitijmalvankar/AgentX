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
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow")
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func postApproval(_ request: ApprovalRequest) {
        guard isAvailable, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = request.headline
        let project = request.cwd.map { ($0 as NSString).lastPathComponent } ?? "Claude"
        content.subtitle = project
        content.body = ToolPresentation.summary(name: request.toolName, input: request.input, cwd: request.cwd)
        content.categoryIdentifier = Self.approvalCategory
        content.sound = .default
        content.userInfo = ["approvalID": request.id]
        let req = UNNotificationRequest(identifier: request.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["approvalID"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
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
