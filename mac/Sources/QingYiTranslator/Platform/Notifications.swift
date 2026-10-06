import AppKit
import QingYiCore
import UserNotifications

/// System notifications (used for the "still running" tip and new versions). They only work from a .app bundle.
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    private var actions: [String: () -> Void] = [:]
    private var configured = false

    private func configure() {
        guard !configured, AppInfo.isBundled else { return }
        configured = true
        UNUserNotificationCenter.current().delegate = self
    }

    /// Shows a notification; `onClick` runs if the user clicks it.
    func show(title: String, body: String, onClick: (() -> Void)? = nil) {
        guard AppInfo.isBundled else { return }
        configure()
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.error("请求通知权限失败", error)
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let id = UUID().uuidString
            if let onClick {
                DispatchQueue.main.async { self.actions[id] = onClick }
            }
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                if let error {
                    Log.error("显示通知失败", error)
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async {
            let action = self.actions.removeValue(forKey: id)
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                action?()
            }
            completionHandler()
        }
    }
}
