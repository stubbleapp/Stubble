import SwiftUI
import UserNotifications
import TaskMinerShared

/// Notification settings pane for the Settings window.
/// Provides controls for notification frequency, timing, content types, and learning.
struct NotificationSettingsView: View {
    @State private var notificationsEnabled: Bool = true
    @State private var dailyMax: Int = 3
    @State private var requireIdle: Bool = true
    @State private var quietHoursEnabled: Bool = false
    @State private var quietHoursStart: Int = 22
    @State private var quietHoursEnd: Int = 8
    @State private var enabledCategories: Set<String> = Set(NotificationCategory.allCases.map { $0.rawValue })
    @State private var preferChatPrompts: Bool = false
    @State private var minRelevanceScore: Double = 0.6
    @State private var learningEnabled: Bool = true
    @State private var showAdvanced: Bool = false

    /// Suppresses `.onChange` persistence during initial load.
    @State private var isLoading = true

    // Debug section (Option-key reveal)
    @State private var optionKeyHeld = false
    @State private var showDebugSection = false
    @State private var flagsMonitor: Any?
    @State private var testNotificationStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // General section
            generalSection

            // Timing section
            timingSection

            // Content Types section
            contentTypesSection

            // Delivery Style section
            deliveryStyleSection

            // Learning section
            learningSection

            // Advanced section (collapsible)
            advancedSection

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
        .onChange(of: notificationsEnabled) { _, _ in saveIfNotLoading() }
        .onChange(of: dailyMax) { _, _ in saveIfNotLoading() }
        .onChange(of: requireIdle) { _, _ in saveIfNotLoading() }
        .onChange(of: quietHoursEnabled) { _, _ in saveIfNotLoading() }
        .onChange(of: quietHoursStart) { _, _ in saveIfNotLoading() }
        .onChange(of: quietHoursEnd) { _, _ in saveIfNotLoading() }
        .onChange(of: enabledCategories) { _, _ in saveIfNotLoading() }
        .onChange(of: preferChatPrompts) { _, _ in saveIfNotLoading() }
        .onChange(of: minRelevanceScore) { _, _ in saveIfNotLoading() }
        .onChange(of: learningEnabled) { _, _ in saveIfNotLoading() }
    }

    // MARK: - Option Key Monitor

    private func setupOptionKeyMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let isOption = event.modifierFlags.contains(.option)
            if isOption != optionKeyHeld {
                optionKeyHeld = isOption
                if isOption {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDebugSection = true
                    }
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showDebugSection = false
                    }
                }
            }
            return event
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("General")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                // Enable toggle
                HStack {
                    Toggle("Enable Notifications", isOn: $notificationsEnabled)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    Spacer()
                }

                // Daily maximum slider
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
                .opacity(notificationsEnabled ? 1 : 0.5)
                .disabled(!notificationsEnabled)
            }
            .padding(12)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    // MARK: - Timing Section

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timing")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                // Require idle toggle
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Only notify when I'm idle", isOn: $requireIdle)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    Text("Waits for screen lock or inactivity")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                Divider()

                // Quiet hours toggle and time pickers
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Quiet Hours", isOn: $quietHoursEnabled)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)

                    if quietHoursEnabled {
                        HStack(spacing: 12) {
                            Text("From")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)

                            Picker("Start", selection: $quietHoursStart) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(formatHour(hour)).tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)

                            Text("to")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)

                            Picker("End", selection: $quietHoursEnd) {
                                ForEach(0..<24, id: \.self) { hour in
                                    Text(formatHour(hour)).tag(hour)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                        }
                    }
                }
            }
            .padding(12)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(notificationsEnabled ? 1 : 0.5)
            .disabled(!notificationsEnabled)
        }
    }

    // MARK: - Content Types Section

    private var contentTypesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Content Types")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(NotificationCategory.allCases, id: \.self) { category in
                    categoryToggle(category)
                }
            }
            .padding(12)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(notificationsEnabled ? 1 : 0.5)
            .disabled(!notificationsEnabled)
        }
    }

    private func categoryToggle(_ category: NotificationCategory) -> some View {
        let isEnabled = enabledCategories.contains(category.rawValue)
        return Toggle(isOn: Binding(
            get: { isEnabled },
            set: { newValue in
                if newValue {
                    enabledCategories.insert(category.rawValue)
                } else {
                    enabledCategories.remove(category.rawValue)
                }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                Text(category.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accent)
    }

    // MARK: - Delivery Style Section

    private var deliveryStyleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delivery Style")
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
            .opacity(notificationsEnabled ? 1 : 0.5)
            .disabled(!notificationsEnabled)
        }
    }

    // MARK: - Learning Section

    private var learningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learning")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Learn from my responses", isOn: $learningEnabled)
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    Text("Improves relevance based on clicks and ignores")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                Divider()

                HStack(spacing: 12) {
                    Button("View History") {
                        // TODO: Open notification history view
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .buttonStyle(.plain)

                    Button("Reset Learning Data") {
                        resetLearningData()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.statusError)
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(notificationsEnabled ? 1 : 0.5)
            .disabled(!notificationsEnabled)
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Relevance Threshold")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(String(format: "%.1f", minRelevanceScore))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    HStack(spacing: 8) {
                        Text("Low")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                        Slider(value: $minRelevanceScore, in: 0.4...0.9, step: 0.1)
                            .tint(Theme.accent)
                        Text("High")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                    }

                    Text("Higher threshold = fewer but more relevant notifications")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("Advanced")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)
        }
        .opacity(notificationsEnabled ? 1 : 0.5)
        .disabled(!notificationsEnabled)
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

        // Request permission first
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

                // Create and send the notification
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

        // Deliver immediately
        let request = UNNotificationRequest(
            identifier: notificationId,
            content: content,
            trigger: nil  // nil = immediate delivery
        )

        center.add(request) { error in
            DispatchQueue.main.async {
                if let error = error {
                    testNotificationStatus = "Error: \(error.localizedDescription)"
                } else {
                    testNotificationStatus = "Notification sent! Check your notification center."
                    // Clear status after 3 seconds
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

    private func formatHour(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:00"
        var components = DateComponents()
        components.hour = hour
        if let date = Calendar.current.date(from: components) {
            return formatter.string(from: date)
        }
        return "\(hour):00"
    }

    private func loadSettings() {
        isLoading = true
        notificationsEnabled = SettingsManager.shared.notificationsEnabled
        dailyMax = SettingsManager.shared.notificationsDailyMax
        requireIdle = SettingsManager.shared.notificationsRequireIdle
        quietHoursEnabled = SettingsManager.shared.notificationsQuietHoursEnabled
        quietHoursStart = SettingsManager.shared.notificationsQuietHoursStart
        quietHoursEnd = SettingsManager.shared.notificationsQuietHoursEnd
        enabledCategories = SettingsManager.shared.notificationsEnabledCategories
        preferChatPrompts = SettingsManager.shared.notificationsPreferChatPrompts
        minRelevanceScore = SettingsManager.shared.notificationsMinRelevanceScore
        learningEnabled = SettingsManager.shared.notificationsLearningEnabled
        isLoading = false
    }

    private func saveIfNotLoading() {
        guard !isLoading else { return }
        SettingsManager.shared.notificationsEnabled = notificationsEnabled
        SettingsManager.shared.notificationsDailyMax = dailyMax
        SettingsManager.shared.notificationsRequireIdle = requireIdle
        SettingsManager.shared.notificationsQuietHoursEnabled = quietHoursEnabled
        SettingsManager.shared.notificationsQuietHoursStart = quietHoursStart
        SettingsManager.shared.notificationsQuietHoursEnd = quietHoursEnd
        SettingsManager.shared.notificationsEnabledCategories = enabledCategories
        SettingsManager.shared.notificationsPreferChatPrompts = preferChatPrompts
        SettingsManager.shared.notificationsMinRelevanceScore = minRelevanceScore
        SettingsManager.shared.notificationsLearningEnabled = learningEnabled
    }

    private func resetLearningData() {
        // TODO: Implement reset via engagement tracker
        // NotificationEngagementTracker().resetStats(db: ...)
    }
}
