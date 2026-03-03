import SwiftUI
import UserNotifications
import TaskMinerShared

/// Notification settings pane for the Settings window.
/// Simplified controls for frequency and notification type.
struct NotificationSettingsView: View {
    @State private var dailyMax: Int = 3
    @State private var preferChatPrompts: Bool = false

    /// Suppresses `.onChange` persistence during initial load.
    @State private var isLoading = true

    // Debug section (Option-key reveal)
    @State private var optionKeyHeld = false
    @State private var showDebugSection = false
    @State private var flagsMonitor: Any?
    @State private var testNotificationStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Frequency section
            frequencySection

            // Notification type section
            notificationTypeSection

            // Debug section (Option-key reveal)
            if showDebugSection {
                debugSection
            }
        }
        .onAppear {
            loadSettings()
            setupOptionKeyMonitor()
        }
        .onDisappear {
            if let monitor = flagsMonitor {
                NSEvent.removeMonitor(monitor)
                flagsMonitor = nil
            }
        }
        .onChange(of: dailyMax) { _, _ in saveIfNotLoading() }
        .onChange(of: preferChatPrompts) { _, _ in saveIfNotLoading() }
    }

    // MARK: - Option Key Monitor

    private func setupOptionKeyMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let isOption = event.modifierFlags.contains(.option)
            if isOption != optionKeyHeld {
                optionKeyHeld = isOption
                withAnimation(.easeInOut(duration: 0.15)) {
                    showDebugSection = isOption
                }
            }
            return event
        }
    }

    // MARK: - Frequency Section

    private var frequencySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Frequency")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Daily Maximum")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text("\(dailyMax)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    HStack(spacing: 8) {
                        Text("1")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                        Slider(value: Binding(
                            get: { Double(dailyMax) },
                            set: { dailyMax = Int($0) }
                        ), in: 1...5, step: 1)
                        .tint(Theme.accent)
                        Text("5")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                    }
                }

                Text("To disable notifications entirely, use macOS System Settings.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Notification Type Section

    private var notificationTypeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Notification Type")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Prefer \"Ask AI\" over links", isOn: $preferChatPrompts)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                Text("Opens chat with a prompt instead of opening the browser")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(12)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Debug Section

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "ant.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.statusError)
                Text("Debug")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.statusError)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Send test notifications to verify the system is working.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 12) {
                    Button {
                        sendTestNotification(type: .link)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .font(.system(size: 11))
                            Text("Test Link")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        sendTestNotification(type: .chatPrompt)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 11))
                            Text("Test Chat Prompt")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if let status = testNotificationStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.contains("Error") ? Theme.statusError : Theme.statusActive)
                }
            }
            .padding(12)
            .background(Theme.statusError.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.statusError.opacity(0.3), lineWidth: 1)
            )
        }
    }

    private func sendTestNotification(type: NotificationType) {
        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                if let error = error {
                    testNotificationStatus = "Error: \(error.localizedDescription)"
                    return
                }
                guard granted else {
                    testNotificationStatus = "Error: Notification permission denied. Enable in System Settings."
                    return
                }
                deliverTestNotification(type: type, center: center)
            }
        }
    }

    private func deliverTestNotification(type: NotificationType, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        let notificationId = UUID().uuidString

        switch type {
        case .link:
            content.title = "Test: New Article Recommendation"
            content.body = "SwiftUI Performance Tips: Optimizing your views for smoother scrolling"
            content.categoryIdentifier = "notification.link"
            content.userInfo = [
                "notificationId": notificationId,
                "type": "link",
                "url": "https://developer.apple.com/documentation/swiftui"
            ]

        case .chatPrompt:
            content.title = "Test: Ask AI About Your Work"
            content.body = "Want to explore best practices for the code you were working on?"
            content.categoryIdentifier = "notification.chatPrompt"
            let prompt = "What are the best practices for SwiftUI performance optimization?"
            content.userInfo = [
                "notificationId": notificationId,
                "type": "chatPrompt",
                "chatPrompt": prompt
            ]
        }

        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            DispatchQueue.main.async {
                if let error = error {
                    testNotificationStatus = "Error: \(error.localizedDescription)"
                } else {
                    testNotificationStatus = "Notification sent! Check your notification center."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if testNotificationStatus?.contains("sent") == true {
                            testNotificationStatus = nil
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadSettings() {
        isLoading = true
        dailyMax = SettingsManager.shared.notificationsDailyMax
        preferChatPrompts = SettingsManager.shared.notificationsPreferChatPrompts
        isLoading = false
    }

    private func saveIfNotLoading() {
        guard !isLoading else { return }
        SettingsManager.shared.notificationsDailyMax = dailyMax
        SettingsManager.shared.notificationsPreferChatPrompts = preferChatPrompts
    }
}
