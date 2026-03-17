import SwiftUI
import ServiceManagement
import AuthenticationServices
import TaskMinerShared

/// First-launch setup wizard that guides the user through:
/// 1. Welcome / data privacy overview
/// 2. Google sign-in
/// 3. System permissions (Accessibility + Screen Recording)
struct SetupWizardView: View {
    @Environment(DashboardViewModel.self) var viewModel
    var onComplete: () -> Void

    /// Central flow controller — business logic is testable via SetupFlowControllerTests.
    @State private var flow: SetupFlowController

    /// Combined permission flag — PermissionsPage writes here, synced to flow controller.
    @State private var permissionsGranted = false

    /// Handle for the auto-advance Task after sign-in, so it can be cancelled if the user taps Back.
    @State private var autoAdvanceTask: Task<Void, Never>?

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
        // Restore wizard state from settings
        let savedPage = SettingsManager.shared.wizardPage
        let isSignedIn = AuthManager.shared.isSignedIn
        let flow = SetupFlowController()
        // If user was already signed in, restore that state
        if isSignedIn {
            flow.isSignedInViaGoogle = true
        }
        // Restore to saved page, but not beyond what makes sense
        // (e.g., don't restore to page 2 if not signed in yet)
        if savedPage > 0 {
            if savedPage == 1 && isSignedIn {
                // Already signed in, skip to permissions
                flow.setPage(2)
            } else if savedPage >= 2 && isSignedIn {
                // Restore to saved page
                flow.setPage(savedPage)
            } else if savedPage == 1 {
                // On sign-in page but not signed in yet
                flow.setPage(1)
            }
        }
        self._flow = State(initialValue: flow)
    }

    var body: some View {
        @Bindable var flow = flow

        VStack(spacing: 0) {
            // Step indicator at top (only shown after welcome page)
            if flow.currentPage > 0 {
                HStack(spacing: 12) {
                    ForEach(1...2, id: \.self) { step in
                        let isActive = (flow.currentPage >= step)
                        HStack(spacing: 6) {
                            Text("\(step)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isActive ? .white : Theme.textMuted)
                                .frame(width: 20, height: 20)
                                .background(isActive ? Theme.accent : Theme.textQuaternary.opacity(0.3))
                                .clipShape(Circle())
                        }
                        .accessibilityIdentifier("wizard-step-\(step)")
                    }
                }
                .padding(.top, 20)
                .padding(.bottom, 8)
            }

            // Page content
            Group {
                switch flow.currentPage {
                case 0: WelcomePage()
                    .accessibilityIdentifier("wizard-welcome")
                case 1: SignInPage(flow: flow) {
                    // Auto-advance to Permissions after a brief delay
                    autoAdvanceTask?.cancel()
                    autoAdvanceTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        _ = withAnimation(.easeInOut(duration: 0.25)) {
                            flow.advance()
                        }
                    }
                }
                    .accessibilityIdentifier("wizard-sign-in")
                case 2: PermissionsPage(allGranted: $permissionsGranted)
                    .accessibilityIdentifier("wizard-permissions")
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom navigation - show Continue on pages 0, 2, or page 1 when signed in
            if flow.currentPage == 0 || flow.currentPage == 2 || (flow.currentPage == 1 && flow.isSignedInViaGoogle) {
                VStack(spacing: 16) {
                    Button {
                        handleContinue()
                    } label: {
                        HStack(spacing: 4) {
                            Text(flow.continueButtonLabel)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
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
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
        }
        .frame(width: 560, height: 480)
        .background {
            if #available(macOS 26.0, *) {
                Theme.primaryBackground.opacity(0.55)
                    .ignoresSafeArea()
            } else {
                Theme.primaryBackground
                    .ignoresSafeArea()
            }
        }
        .compositingGroup()
        .modifier(WizardGlassModifier())
        .onChange(of: permissionsGranted) { _, granted in
            // Sync combined permission flag to the flow controller
            flow.accessibilityGranted = granted
            flow.screenRecordingGranted = granted
        }
        .onChange(of: flow.currentPage) { _, newPage in
            // Persist wizard page so we can resume after Quit & Reopen
            SettingsManager.shared.wizardPage = newPage
        }
    }

    private func handleContinue() {
        // On the last page (permissions), complete setup instead of advancing
        if flow.isOnLastPage && flow.canContinue {
            finish()
            return
        }
        _ = flow.handleContinue()
    }

    private func finish() {
        // Enable launch at login by default
        SettingsManager.shared.launchAtLogin = true
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        }
        // Clear wizard page state since setup is complete
        SettingsManager.shared.wizardPage = 0
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

            Text("AI that understands how you work — with personalised\ninsights, focus patterns, and recommendations.")
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
                        Text("Privacy-First")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("All data is processed and stored locally on your Mac. Screenshots never leave your computer.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learns How You Work")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Understands your workflow and organises everything into tasks, projects, and actionable insights.")
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
                        Text("Start with a free 10-day trial. Pause monitoring or delete your data at any time.")
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
    @State private var authSession: ASWebAuthenticationSession?

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

                Text("Sign in to get a 10-day free trial with full AI features.\nNo credit card required.")
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
                                GoogleLogo(size: 18)
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

    private func startGoogleSignIn() {
        guard let (url, codeVerifier) = AuthManager.shared.buildGoogleSignInURL() else {
            signInError = "Unable to connect to authentication service. Please try again later."
            return
        }

        isSigningIn = true
        signInError = nil

        authSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: StubbleAPIConfig.callbackScheme
        ) { callbackURL, error in
            Task { @MainActor in
                defer {
                    isSigningIn = false
                    authSession = nil
                }

                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    signInError = AuthHelpers.friendlyAuthError(error)
                    return
                }

                guard let callbackURL = callbackURL else {
                    signInError = "No callback received from authentication."
                    return
                }

                // Check if Supabase returned an error in the callback
                if let authError = AuthManager.extractAuthError(from: callbackURL) {
                    signInError = authError
                    return
                }

                guard let code = AuthManager.extractAuthCode(from: callbackURL) else {
                    Logger.error("OAuth callback URL missing code: \(callbackURL.absoluteString)")
                    signInError = "Authentication completed but no authorization code was returned. Please try again."
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
                    signInError = AuthHelpers.friendlyAuthError(error)
                }
            }
        }

        authSession!.presentationContextProvider = AuthContextProvider.shared
        authSession!.prefersEphemeralWebBrowserSession = true

        if !authSession!.start() {
            isSigningIn = false
            authSession = nil
            signInError = "Could not start authentication session."
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

// MARK: - Liquid Glass Modifier

private struct WizardGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
        } else {
            content
        }
    }
}


