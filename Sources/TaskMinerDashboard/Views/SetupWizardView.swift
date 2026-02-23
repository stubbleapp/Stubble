import SwiftUI
import ServiceManagement
import TaskMinerShared

/// First-launch setup wizard that guides the user through:
/// 1. Welcome / data privacy overview
/// 2. Gemini API key entry
/// 3. System permissions (Accessibility + Screen Recording)
/// 4. Preferences (launch at login) + finish
struct SetupWizardView: View {
    @Environment(DashboardViewModel.self) var viewModel
    var onComplete: () -> Void

    @State private var currentPage = 0
    @State private var permissionsGranted = false
    private let totalPages = 4

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            Group {
                switch currentPage {
                case 0: WelcomePage()
                case 1: ApiKeyPage()
                case 2: PermissionsPage(allGranted: $permissionsGranted)
                case 3: PreferencesPage(onComplete: finish)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar: progress dots + navigation
            VStack(spacing: 16) {
                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Theme.accent : Theme.textQuaternary.opacity(0.5))
                            .frame(width: 7, height: 7)
                    }
                }

                // Navigation buttons
                HStack {
                    if currentPage > 0 {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentPage -= 1
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    if currentPage < totalPages - 1 {
                        let canAdvance = currentPage != 2 || permissionsGranted
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                currentPage += 1
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(currentPage == 0 ? "Get Started" : "Continue")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(canAdvance ? Theme.accent : Theme.accent.opacity(0.35))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canAdvance)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 480)
        .background(Theme.primaryBackground)
    }

    private func finish() {
        SettingsManager.shared.hasCompletedSetup = true
        onComplete()
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 16)

            Text("Welcome to Stubble")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)

            Text("Understand how you spend your time on your Mac.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 28)

            // Privacy cards
            VStack(spacing: 12) {
                InfoRow(
                    icon: "desktopcomputer",
                    title: "Processed Locally",
                    detail: "Screenshots, OCR text, and window titles are captured and stored on your Mac. Nothing leaves your device without your knowledge."
                )
                InfoRow(
                    icon: "brain",
                    title: "AI-Powered Summaries",
                    detail: "Window titles and OCR text are sent to Google Gemini to generate task summaries. Screenshots are never sent to any server."
                )
                InfoRow(
                    icon: "lock.shield",
                    title: "You're in Control",
                    detail: "Pause monitoring any time, delete any screenshot or task, and all data stays in your local Application Support folder."
                )
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }
}

// MARK: - Page 2: API Key

private struct ApiKeyPage: View {
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "key.fill")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 16)

            Text("Gemini API Key")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)

            Text("Stubble uses Google Gemini to turn your raw activity into meaningful tasks.\nA free API key is all you need.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 24)
                .padding(.horizontal, 40)

            // Key input
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Group {
                        if showKey {
                            TextField("Paste your Gemini API key", text: $apiKey)
                        } else {
                            SecureField("Paste your Gemini API key", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        GeminiKeychain.set(apiKey)
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                    } label: {
                        HStack(spacing: 4) {
                            if saved {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(saved ? "Saved" : "Save")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(saved ? Theme.statusActive : Theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .animation(.easeInOut(duration: 0.2), value: saved)
                }

                Button {
                    if let url = URL(string: "https://aistudio.google.com/apikey") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                        Text("Get a free key from Google AI Studio")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Text("You can also set this later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 60)

            Spacer()
        }
        .onAppear {
            apiKey = GeminiKeychain.get() ?? ""
        }
    }
}

// MARK: - Page 3: Permissions

private struct PermissionsPage: View {
    @Binding var allGranted: Bool
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 16)

            Text("System Permissions")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)

            Text("Stubble needs two macOS permissions to monitor your activity.\nThese are standard system APIs — no workarounds or hacks.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 28)
                .padding(.horizontal, 40)

            VStack(spacing: 16) {
                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    detail: "Reads window titles so Stubble knows which app and document you're working in.",
                    granted: accessibilityGranted,
                    action: {
                        // Prompt the system trust dialog
                        _ = PermissionChecker.checkAccessibility(promptIfNeeded: true)
                        PermissionChecker.openAccessibilitySettings()
                    }
                )

                PermissionRow(
                    icon: "camera.metering.spot",
                    title: "Screen Recording",
                    detail: "Captures periodic screenshots for OCR. Screenshots stay on your Mac and are never uploaded.",
                    granted: screenRecordingGranted,
                    action: {
                        PermissionChecker.openScreenRecordingSettings()
                    }
                )
            }
            .padding(.horizontal, 50)

            if accessibilityGranted && screenRecordingGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.statusActive)
                    Text("All permissions granted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.statusActive)
                }
                .padding(.top, 20)
            } else {
                Text("Grant permissions in System Settings, then return here.\nThe status will update automatically.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }

            Spacer()
        }
        .onAppear {
            checkPermissions()
            // Poll every 2 seconds to detect when the user grants access
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Task { @MainActor in
                    checkPermissions()
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func checkPermissions() {
        accessibilityGranted = PermissionChecker.checkAccessibility(promptIfNeeded: false)
        screenRecordingGranted = PermissionChecker.checkScreenRecording()
        allGranted = accessibilityGranted && screenRecordingGranted
    }
}

// MARK: - Page 4: Preferences + Finish

private struct PreferencesPage: View {
    var onComplete: () -> Void
    @State private var launchAtLogin = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 16)

            Text("You're All Set")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)

            Text("Stubble will run in the background and summarize your day.\nYou can access it from the menu bar icon any time.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 32)
                .padding(.horizontal, 40)

            // Launch at login toggle
            VStack(spacing: 16) {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at login")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Start Stubble automatically when you log in to your Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .padding(.horizontal, 60)
                .onChange(of: launchAtLogin) { _, enabled in
                    updateLoginItem(enabled: enabled)
                }
            }

            Spacer()

            Button {
                onComplete()
            } label: {
                Text("Open Stubble")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
        }
    }

    private func updateLoginItem(enabled: Bool) {
        SettingsManager.shared.launchAtLogin = enabled
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Logger.error("Failed to update login item: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Reusable Components

private struct InfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(granted ? Theme.statusActive : Theme.textMuted)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if granted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.statusActive)
                    }
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !granted {
                Button("Open Settings") {
                    action()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Theme.accent)
                .clipShape(Capsule())
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(granted ? Theme.statusActive.opacity(0.3) : Theme.cardBorder.opacity(0.6), lineWidth: 0.5)
        )
    }
}
