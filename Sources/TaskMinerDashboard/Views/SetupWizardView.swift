import SwiftUI
import ServiceManagement
import AuthenticationServices
import TaskMinerShared

/// First-launch setup wizard that guides the user through:
/// 1. Welcome / data privacy overview
/// 2. Gemini API key entry
/// 3. System permissions (Accessibility + Screen Recording)
/// 4. Preferences (launch at login) + finish
struct SetupWizardView: View {
    @Environment(DashboardViewModel.self) var viewModel
    var onComplete: () -> Void

    /// Central flow controller — business logic is testable via SetupFlowControllerTests.
    @State private var flow = SetupFlowController()

    /// Combined permission flag — PermissionsPage writes here, synced to flow controller.
    @State private var permissionsGranted = false

    var body: some View {
        @Bindable var flow = flow

        VStack(spacing: 0) {
            // Page content
            Group {
                switch flow.currentPage {
                case 0: WelcomePage()
                    .accessibilityIdentifier("wizard-welcome")
                case 1: SignInPage(flow: flow) {
                    // Auto-advance to Permissions after a brief delay
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeInOut(duration: 0.25)) {
                            flow.advance()
                        }
                    }
                }
                    .accessibilityIdentifier("wizard-sign-in")
                case 2: PermissionsPage(allGranted: $permissionsGranted)
                    .accessibilityIdentifier("wizard-permissions")
                case 3: PreferencesPage(onComplete: finish)
                    .accessibilityIdentifier("wizard-preferences")
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar: progress dots + navigation
            VStack(spacing: 16) {
                // Progress dots
                HStack(spacing: 8) {
                    ForEach(0..<flow.totalPages, id: \.self) { index in
                        Circle()
                            .fill(index == flow.currentPage ? Theme.accent : Theme.textQuaternary.opacity(0.5))
                            .frame(width: 7, height: 7)
                            .accessibilityIdentifier("wizard-progress-dot-\(index)")
                    }
                }

                // Navigation buttons
                HStack {
                    if flow.canGoBack {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                _ = flow.goBack()
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("wizard-back")
                    }

                    Spacer()

                    if !flow.isOnLastPage {
                        Button {
                            handleContinue()
                        } label: {
                            HStack(spacing: 4) {
                                if flow.isValidating {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(.white)
                                    Text("Verifying…")
                                } else {
                                    Text(flow.continueButtonLabel)
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(flow.canContinue ? Theme.accent : Theme.accent.opacity(0.35))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(!flow.canContinue)
                        .accessibilityIdentifier("wizard-continue")
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 560, height: 480)
        .background(Theme.primaryBackground)
        .onChange(of: permissionsGranted) { _, granted in
            // Sync combined permission flag to the flow controller
            flow.accessibilityGranted = granted
            flow.screenRecordingGranted = granted
        }
    }

    private func handleContinue() {
        switch flow.handleContinue() {
        case .advance:
            break // flow controller already advanced
        case .validate:
            validateApiKeyThenAdvance()
        case .blocked:
            break
        }
    }

    private func validateApiKeyThenAdvance() {
        if let error = flow.validateApiKeyFormat() {
            flow.setApiKeyError(error)
            return
        }

        let key = flow.apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        flow.beginValidation()

        Task {
            do {
                guard let client = GeminiClient.fromAPIKey(key) else {
                    flow.cancelValidation("Invalid key format.")
                    return
                }
                let _ = try await client.generateText(
                    prompt: "Reply with the single word: ok",
                    systemInstruction: nil
                )
                flow.handleValidationSuccess()
            } catch {
                flow.handleValidationFailure(error)
            }
        }
    }

    private func finish() {
        // Ensure the API key is persisted before completing setup.
        // The onChange handler on ApiKeyPage should have already saved it,
        // but this guards against edge cases (e.g. paste without triggering onChange).
        let key = flow.apiKey.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if !key.isEmpty {
            SettingsManager.shared.geminiApiKey = key
        }
        SettingsManager.shared.hasCompletedSetup = true
        onComplete()
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            if let logo = Self.loadLogo() {
                Image(nsImage: logo)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .padding(.bottom, 20)
            }

            Text("Welcome to Stubble")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 6)

            Text("An AI time tracker for macOS that watches what you do\nand turns it into clear tasks, project breakdowns, and tips.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.bottom, 28)
                .padding(.horizontal, 40)

            // Privacy cards — Grid guarantees all icons share
            // a single column width so the text column aligns perfectly.
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Theme.accent)
                        .gridColumnAlignment(.center)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Processed Locally")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Screenshots are captured and stored on your Mac. They never leave your computer.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Image(systemName: "brain")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI-Powered Insights")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Text extracted from screenshots and window titles is sent to AI to generate your tasks and insights. No images or files are ever transmitted.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You're in Control")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Sign in for a free trial, or bring your own API key. Delete anything at any time.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    /// Load the Stubble logo from the app bundle or development Resources directory.
    private static func loadLogo() -> NSImage? {
        // 1) App bundle — standard location
        if let path = Bundle.main.path(forResource: "logo", ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
        // 2) Development — look relative to the binary's package checkout
        let binaryPath = ProcessInfo.processInfo.arguments[0]
        let binaryDir = (binaryPath as NSString).deletingLastPathComponent
        for ancestor in ["../../..", "../../../.."] {
            let candidate = (binaryDir as NSString).appendingPathComponent("\(ancestor)/Resources/logo.png")
            let resolved = (candidate as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                return NSImage(contentsOfFile: resolved)
            }
        }
        return nil
    }
}

// MARK: - Page 2: Sign In

private struct SignInPage: View {
    @Bindable var flow: SetupFlowController
    var onSignInSuccess: (() -> Void)?

    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var showKey = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(Theme.accent)
                .padding(.bottom, 16)

            if flow.isSignedInViaGoogle {
                // Success state
                signInSuccessView
            } else {
                Text("Sign In")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 6)

                Text("Sign in to get a 30-day free trial with full AI features.\nNo credit card required.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.bottom, 28)
                    .padding(.horizontal, 40)

                VStack(spacing: 16) {
                    // Google sign-in button
                    Button {
                        startGoogleSignIn()
                    } label: {
                        HStack(spacing: 8) {
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "g.circle.fill")
                                    .font(.system(size: 18))
                            }
                            Text(isSigningIn ? "Signing in..." : "Sign in with Google")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .background(Theme.accent)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSigningIn)
                    .accessibilityIdentifier("wizard-google-signin")

                    // Error
                    if let error = signInError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12))
                            Text(error)
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.statusError)
                    }

                    // BYOK toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            flow.showBYOKInput.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "key")
                                .font(.system(size: 10))
                            Text("I have my own API key")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    // BYOK input (conditionally shown)
                    if flow.showBYOKInput {
                        byokInputView
                    }

                    // Skip
                    Button {
                        flow.skipSignIn()
                    } label: {
                        Text("Skip for now")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .accessibilityIdentifier("wizard-skip-signin")
                }
                .padding(.horizontal, 60)
            }

            Spacer()
        }
    }

    private var signInSuccessView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.statusActive)

            Text("Signed In")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            if let email = AuthManager.shared.userEmail {
                Text(email)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            if let remaining = AuthManager.shared.trialDaysRemaining {
                Text("\(remaining)-day free trial started")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
            }
        }
    }

    private var byokInputView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("Paste your Gemini API key", text: $flow.apiKey)
                    } else {
                        SecureField("Paste your Gemini API key", text: $flow.apiKey)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(10)
                .background(.ultraThinMaterial)
                .cornerRadius(8)
                .accessibilityIdentifier("wizard-api-key-input")

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
            }

            if let error = flow.apiKeyError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12))
                }
                .foregroundStyle(Theme.statusError)
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
                        .font(.system(size: 11))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            flow.apiKey = SettingsManager.shared.geminiApiKey ?? ""
        }
        .onChange(of: flow.apiKey) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                SettingsManager.shared.geminiApiKey = trimmed
            }
        }
    }

    private func startGoogleSignIn() {
        guard let (url, codeVerifier) = AuthManager.shared.buildGoogleSignInURL() else {
            signInError = "Backend not configured. Use an API key instead."
            flow.showBYOKInput = true
            return
        }

        isSigningIn = true
        signInError = nil

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: StubbleAPIConfig.callbackScheme
        ) { callbackURL, error in
            Task { @MainActor in
                defer { isSigningIn = false }

                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    signInError = Self.friendlyAuthError(error)
                    return
                }

                guard let callbackURL = callbackURL,
                      let code = AuthManager.extractAuthCode(from: callbackURL)
                else {
                    signInError = "No authorization code received."
                    return
                }

                do {
                    try await AuthManager.shared.exchangeCode(code, codeVerifier: codeVerifier)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        flow.isSignedInViaGoogle = true
                    }
                    // Auto-advance after a brief pause so the user sees the success state
                    onSignInSuccess?()
                } catch {
                    signInError = Self.friendlyAuthError(error)
                }
            }
        }

        session.presentationContextProvider = WizardAuthContextProvider.shared
        session.prefersEphemeralWebBrowserSession = false

        if !session.start() {
            isSigningIn = false
            signInError = "Could not start authentication session."
        }
    }

    /// Convert raw OAuth/network errors into user-friendly messages.
    private static func friendlyAuthError(_ error: Error) -> String {
        let desc = error.localizedDescription.lowercased()
        if desc.contains("network") || desc.contains("offline") || desc.contains("not connected") {
            return "No internet connection. Please check your network and try again."
        } else if desc.contains("timeout") || desc.contains("timed out") {
            return "The request timed out. Please try again."
        } else if desc.contains("unsupported_grant_type") || desc.contains("invalid_grant") {
            return "Authentication configuration error. Please try again or use an API key."
        } else if desc.contains("server") || desc.contains("500") || desc.contains("503") {
            return "The authentication server is temporarily unavailable. Please try again later."
        } else {
            return "Sign-in failed. Please try again."
        }
    }
}

/// ASWebAuthenticationSession presentation context for the setup wizard window.
@MainActor
private class WizardAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WizardAuthContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? NSWindow()
    }
}

/// Numbered step label for setup instructions.
private struct SetupStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent.opacity(0.8))
                .clipShape(Circle())

            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
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
                        PermissionManager.openAccessibilitySettings()
                    }
                )
                .accessibilityIdentifier("wizard-perm-accessibility")

                PermissionRow(
                    icon: "camera.metering.spot",
                    title: "Screen Recording",
                    detail: "Captures periodic screenshots for OCR. Screenshots stay on your Mac and are never uploaded.",
                    granted: screenRecordingGranted,
                    action: {
                        PermissionManager.openScreenRecordingSettings()
                    }
                )
                .accessibilityIdentifier("wizard-perm-screen-recording")
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
                .accessibilityIdentifier("wizard-perms-granted")
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
        accessibilityGranted = PermissionManager.checkAccessibility(promptIfNeeded: false)
        Task {
            let hasScreenRecording = await PermissionManager.checkScreenRecording()
            screenRecordingGranted = hasScreenRecording
            allGranted = accessibilityGranted && hasScreenRecording
        }
    }
}

// MARK: - Page 4: Preferences + Finish

private struct PreferencesPage: View {
    var onComplete: () -> Void
    @State private var launchAtLogin = true

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
                .accessibilityIdentifier("wizard-launch-at-login")
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
            .accessibilityIdentifier("wizard-finish")
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
