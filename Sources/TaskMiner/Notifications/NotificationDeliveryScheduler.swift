import Foundation
import UserNotifications
import AppKit
import TaskMinerShared

/// Handles the actual delivery of notifications via UNUserNotificationCenter.
/// Implements the delegate to track clicks and dismissals.
final class NotificationDeliveryScheduler: NSObject {

    /// Callback for when a notification is clicked.
    var onClicked: ((String) -> Void)?

    /// Callback for when a notification is dismissed.
    var onDismissed: ((String) -> Void)?

    private let notificationCenter: UNUserNotificationCenter

    override init() {
        self.notificationCenter = UNUserNotificationCenter.current()
        super.init()
        notificationCenter.delegate = self
        requestAuthorization()
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                Logger.warning("Notification authorization error: \(error.localizedDescription)")
            } else if granted {
                Logger.debug("Notification authorization granted")
            } else {
                Logger.debug("Notification authorization denied")
            }
        }
    }

    // MARK: - Delivery

    /// Deliver a notification to the user.
    func deliver(_ record: NotificationRecord) async {
        let content = UNMutableNotificationContent()
        content.title = record.title
        content.body = record.body
        content.sound = .default
        content.categoryIdentifier = "STUBBLE_NOTIFICATION"

        // Store metadata for handling the response
        content.userInfo = [
            "notificationId": record.id,
            "type": record.type.rawValue,
            "category": record.category.rawValue,
            "payload": encodePayload(record.payload)
        ].compactMapValues { $0 }

        // Configure action button based on type
        if record.type == .link, let url = record.payload?.url {
            content.userInfo["actionURL"] = url
        } else if record.type == .chatPrompt, let prompt = record.payload?.chatPrompt {
            content.userInfo["chatPrompt"] = prompt
        }

        // Create the request with a unique identifier
        let request = UNNotificationRequest(
            identifier: record.id,
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await notificationCenter.add(request)
            Logger.info("NotificationDeliveryScheduler: Delivered '\(record.title)'")
        } catch {
            Logger.error("NotificationDeliveryScheduler: Failed to deliver — \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func encodePayload(_ payload: NotificationPayload?) -> String? {
        guard let payload = payload else { return nil }
        guard let data = try? JSONEncoder().encode(payload),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Register notification categories and actions.
    func registerCategories() {
        // Define actions
        let openAction = UNNotificationAction(
            identifier: "OPEN_ACTION",
            title: "Open",
            options: [.foreground]
        )

        let askAction = UNNotificationAction(
            identifier: "ASK_AI_ACTION",
            title: "Ask AI",
            options: [.foreground]
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: [.destructive]
        )

        // Define category
        let category = UNNotificationCategory(
            identifier: "STUBBLE_NOTIFICATION",
            actions: [openAction, askAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        notificationCenter.setNotificationCategories([category])
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationDeliveryScheduler: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show banner even when app is in foreground
        return [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let notificationId = userInfo["notificationId"] as? String ?? response.notification.request.identifier
        let type = userInfo["type"] as? String

        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier, "OPEN_ACTION":
            // User tapped the notification or the "Open" action
            handleNotificationTap(userInfo: userInfo, type: type)
            onClicked?(notificationId)

        case "ASK_AI_ACTION":
            // User tapped "Ask AI" — open chat with prompt
            handleAskAI(userInfo: userInfo)
            onClicked?(notificationId)

        case UNNotificationDismissActionIdentifier, "DISMISS_ACTION":
            // User dismissed the notification
            onDismissed?(notificationId)

        default:
            // Unknown action — treat as click
            handleNotificationTap(userInfo: userInfo, type: type)
            onClicked?(notificationId)
        }
    }

    private func handleNotificationTap(userInfo: [AnyHashable: Any], type: String?) {
        if type == "link", let urlString = userInfo["actionURL"] as? String,
           let url = URL(string: urlString) {
            // Open the URL in the default browser
            NSWorkspace.shared.open(url)
        } else if type == "chatPrompt", let prompt = userInfo["chatPrompt"] as? String {
            // Open Stubble with the chat prompt
            openStubbleWithChatPrompt(prompt)
        } else {
            // Just bring Stubble to foreground
            activateStubble()
        }
    }

    private func handleAskAI(userInfo: [AnyHashable: Any]) {
        if let prompt = userInfo["chatPrompt"] as? String {
            openStubbleWithChatPrompt(prompt)
        } else {
            // Generate a generic prompt from the notification content
            let title = userInfo["title"] as? String ?? "this topic"
            openStubbleWithChatPrompt("Tell me more about \(title)")
        }
    }

    private func openStubbleWithChatPrompt(_ prompt: String) {
        // Construct the deep link URL
        let encodedPrompt = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "com.stubble://chat?prompt=\(encodedPrompt)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func activateStubble() {
        // Find and activate the Stubble app
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.stubble.app").first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
