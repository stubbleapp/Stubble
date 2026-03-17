import SwiftUI
import AuthenticationServices
import TaskMinerShared

// MARK: - Settings Category

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case account
    case general
    case notifications
    case exclusions
    case personalisation
    case data
    case about

    var id: Self { self }

    var label: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .notifications: return "Notifications"
        case .exclusions: return "Exclusions"
        case .personalisation: return "Personalisation"
        case .data: return "Data"
        case .about: return "About"
        }
    }

    var icon: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape"
        case .notifications: return "bell"
        case .exclusions: return "eye.slash"
        case .personalisation: return "person"
        case .data: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Away Duration Options

private enum AwayDuration: Int, CaseIterable, Identifiable {
    case five = 5
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    var id: Int { rawValue }

    var label: String { "\(rawValue) min" }
}

private enum DayWrapTime: Int, CaseIterable, Identifiable {
    case fourPM = 16
    case fivePM = 17
    case sixPM = 18
    case sevenPM = 19
    case eightPM = 20
    case never = 24

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .fourPM: return "4 PM"
        case .fivePM: return "5 PM"
        case .sixPM: return "6 PM"
        case .sevenPM: return "7 PM"
        case .eightPM: return "8 PM"
        case .never: return "Never"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @EnvironmentObject var updater: SoftwareUpdater
    @Environment(\.dismiss) var dismiss
    @State private var selectedCategory: SettingsCategory? = .account

    // Account
    @State private var isSigningIn = false
    @State private var signInError: String?
    @State private var authSession: ASWebAuthenticationSession?

    // General
    @State private var customPrompt: String = ""
    @State private var granularity: TaskGranularity = .medium
    @State private var minAwayMinutes: Int = 15
    @State private var dayWrapHour: Int = 18
    @State private var appearanceMode: AppearanceMode = .system

    // Exclusions
    @State private var exclusions: [String] = []
    @State private var newExclusion: String = ""

    // Personalisation
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var synthesizedProfile: String = ""
    @State private var newMemoryContent: String = ""
    @State private var newMemoryCategory: MemoryCategory = .workflow

    // Data
    @State private var showClearConfirmation = false

    // Auth state reactivity — AuthManager is not @Observable, so we use a
    // counter that increments on .authStateChanged to trigger SwiftUI re-render.
    @State private var authStateVersion: Int = 0

    /// Suppresses `.onChange` persistence during initial `loadSettings()`.
    @State private var isLoading = true

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    let isSelected = (selectedCategory ?? .general) == category
                    Button {
                        selectedCategory = category
                    } label: {
                        Label(category.label, systemImage: category.icon)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Theme.selectedSurface : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)

            Divider()

            // Detail pane
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedCategory ?? .account {
                    case .account:
                        accountPane
                    case .general:
                        generalPane
                    case .notifications:
                        NotificationSettingsView()
                    case .exclusions:
                        exclusionsPane
                    case .personalisation:
                        personalisationPane
                    case .data:
                        dataPane
                    case .about:
                        aboutPane
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
        .background(Theme.primaryBackground)
        .frame(width: 620, height: 480)
        .onAppear { loadSettings() }
        .onChange(of: appearanceMode) {
            guard !isLoading else { return }
            SettingsManager.shared.appearanceMode = appearanceMode
            NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
        }
        .onChange(of: granularity) {
            guard !isLoading else { return }
            SettingsManager.shared.granularity = granularity
        }
        .onChange(of: minAwayMinutes) {
            guard !isLoading else { return }
            SettingsManager.shared.minAwayMinutes = minAwayMinutes
        }
        .onChange(of: dayWrapHour) {
            guard !isLoading else { return }
            SettingsManager.shared.dayWrapHour = dayWrapHour
        }
        .onChange(of: customPrompt) {
            guard !isLoading else { return }
            let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            SettingsManager.shared.customPrompt = trimmed.isEmpty ? nil : trimmed
        }
        .onReceive(NotificationCenter.default.publisher(for: .authStateChanged)) { _ in
            // Bump version to force SwiftUI to re-evaluate accountPane
            // (AuthManager is not @Observable, so direct reads are stale).
            authStateVersion += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAboutInSettings)) { _ in
            selectedCategory = .about
        }
        .alert("Clear All Data?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Everything", role: .destructive) {
                viewModel.clearAllData()
                dismiss()
            }
        } message: {
            Text("This will permanently delete all tasks, activities, screenshots, and learned memory. Your settings and sign-in will be kept. This cannot be undone.")
        }
    }

    // MARK: - Load Settings

    private func loadSettings() {
        isLoading = true
        customPrompt = SettingsManager.shared.customPrompt ?? ""
        granularity = SettingsManager.shared.granularity
        minAwayMinutes = SettingsManager.shared.minAwayMinutes
        dayWrapHour = SettingsManager.shared.dayWrapHour
        appearanceMode = SettingsManager.shared.appearanceMode
        exclusions = SettingsManager.shared.exclusions
        loadMemoryEntries()
        isLoading = false
    }

    // MARK: - General Pane

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Appearance
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appearanceMode = mode
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: appearanceIcon(mode))
                                    .font(.system(size: 10))
                                Text(mode.displayName)
                                    .font(.system(size: 12, weight: appearanceMode == mode ? .semibold : .regular))
                            }
                            .foregroundStyle(appearanceMode == mode ? Theme.textPrimary : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(appearanceMode == mode ? Theme.selectedSurface : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
            }

            // Task Granularity
            VStack(alignment: .leading, spacing: 8) {
                Text("Task Granularity")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    ForEach(TaskGranularity.allCases, id: \.self) { level in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                granularity = level
                            }
                        } label: {
                            Text(level.displayName)
                                .font(.system(size: 12, weight: granularity == level ? .semibold : .regular))
                                .foregroundStyle(granularity == level ? Theme.textPrimary : Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(granularity == level ? Theme.selectedSurface : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .accessibilityIdentifier("settings-granularity")

                Text(granularity.description)
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }

            // Minimum Away Duration
            VStack(alignment: .leading, spacing: 8) {
                Text("Minimum Away Duration")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    ForEach(AwayDuration.allCases) { duration in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                minAwayMinutes = duration.rawValue
                            }
                        } label: {
                            Text(duration.label)
                                .font(.system(size: 12, weight: minAwayMinutes == duration.rawValue ? .semibold : .regular))
                                .foregroundStyle(minAwayMinutes == duration.rawValue ? Theme.textPrimary : Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(minAwayMinutes == duration.rawValue ? Theme.selectedSurface : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .accessibilityIdentifier("settings-min-away")

                Text("Away periods shorter than this are hidden in the timeline. Tasks are generated per work session separated by these breaks.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }

            // Day Wrap Hour
            VStack(alignment: .leading, spacing: 8) {
                Text("Day Wrap Time")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    ForEach(DayWrapTime.allCases) { time in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                dayWrapHour = time.rawValue
                            }
                        } label: {
                            Text(time.label)
                                .font(.system(size: 12, weight: dayWrapHour == time.rawValue ? .semibold : .regular))
                                .foregroundStyle(dayWrapHour == time.rawValue ? Theme.textPrimary : Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(dayWrapHour == time.rawValue ? Theme.selectedSurface : Color.clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.surfaceElevated)
                )
                .accessibilityIdentifier("settings-day-wrap-hour")

                Text("After this time, today's view shows a Day Wrap summary with the timeline collapsed.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }

            // Custom Instructions
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Instructions")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                TextEditor(text: $customPrompt)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 60, maxHeight: 100)
                    .padding(8)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("e.g. Ignore all YouTube and social media activity. Focus only on coding and design work.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
                    .italic()
            }

        }
    }

    // MARK: - Account Pane

    private var accountPane: some View {
        // Read authStateVersion to establish a SwiftUI dependency —
        // when .authStateChanged fires, this view rebuilds with fresh AuthManager state.
        let _ = authStateVersion
        return VStack(alignment: .leading, spacing: 24) {
            if AuthManager.shared.isSignedIn {
                signedInAccountView
            } else {
                signedOutAccountView
            }
        }
    }

    private var signedInAccountView: some View {
        VStack(alignment: .leading, spacing: 20) {
            // User info
            HStack(spacing: 12) {
                // Avatar
                if let avatarURL = AuthManager.shared.userAvatarURL {
                    AsyncImage(url: avatarURL) { image in
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.textMuted)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let name = AuthManager.shared.userName {
                        Text(name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                    if let email = AuthManager.shared.userEmail {
                        Text(email)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                Spacer()
            }

            // Subscription tier badge
            subscriptionBadge

            Divider()

            // Tier actions
            tierActionsView

            Divider()

            // Sign out
            Button {
                AuthManager.shared.signOut()
                viewModel.refreshForAuthChange()
            } label: {
                Text("Sign Out")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.statusError)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var subscriptionBadge: some View {
        let auth = AuthManager.shared
        HStack(spacing: 8) {
            switch auth.currentState {
            case .trial(let daysRemaining):
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Free Trial")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(daysRemaining) days remaining")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            case .pro:
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.statusActive)
                Text("Pro")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.statusActive)
            case .expired:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.statusError)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Trial Expired")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.statusError)
                    Text("Upgrade to Pro for unlimited access")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            default:
                EmptyView()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tierActionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Upgrade to Pro (for non-Pro users)
            if AuthManager.shared.currentState != .pro {
                Button {
                    openPaddleCheckout()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11))
                        Text("Upgrade to Pro")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.accent)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            // Manage Subscription (for Pro users)
            if AuthManager.shared.currentState == .pro {
                Button {
                    // Open email to manage subscription - Paddle sends portal links in receipts
                    if let url = URL(string: "mailto:info@stubble.ai?subject=Manage%20Subscription&body=Please%20help%20me%20manage%20my%20Stubble%20Pro%20subscription.%0A%0AAccount%20email%3A%20\(AuthManager.shared.userEmail ?? "")") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "creditcard")
                            .font(.system(size: 10))
                        Text("Manage Subscription")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            // Enterprise
            Button {
                if let url = URL(string: StubbleAPIConfig.enterpriseContactURL) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "building.2")
                        .font(.system(size: 10))
                    Text("Enterprise")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var signedOutAccountView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Text("Sign in with Google to get a 5-day free trial with full AI features. No API key needed.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Google sign-in button
            Button {
                startGoogleSignIn()
            } label: {
                HStack(spacing: 8) {
                    if isSigningIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        GoogleLogo(size: 16)
                    }
                    Text(isSigningIn ? "Signing in..." : "Sign in with Google")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Theme.accent)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isSigningIn)

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
                        // User cancelled — no error to show
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
                    viewModel.refreshForAuthChange()
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

    private func openPaddleCheckout() {
        guard let userId = AuthManager.shared.publicUserId else {
            // Fallback: open generic checkout (no user attribution)
            if let url = URL(string: "https://checkout.paddle.com/checkout/custom/\(StubbleAPIConfig.paddlePriceId)") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        if let url = StubbleAPIConfig.paddleCheckoutURL(
            userId: userId,
            email: AuthManager.shared.userEmail
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Exclusions Pane

    private var exclusionsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Content Exclusions")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Text("Activity matching these rules will be silently excluded from tasks and summaries.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Current exclusion rules
            VStack(spacing: 6) {
                ForEach(Array(exclusions.enumerated()), id: \.offset) { index, rule in
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 20)

                        Text(rule)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                _ = exclusions.remove(at: index)
                            }
                            SettingsManager.shared.exclusions = exclusions
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 20, height: 20)
                                .background(Theme.surfaceElevated)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Add new exclusion
            HStack(spacing: 8) {
                TextField("e.g. Exclude social media browsing", text: $newExclusion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onSubmit { addExclusion() }

                Button {
                    addExclusion()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(newExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            exclusions.append(trimmed)
        }
        newExclusion = ""
        SettingsManager.shared.exclusions = exclusions
    }

    // MARK: - Personalisation Pane

    private var personalisationPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Learned Context")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(memoryEntries.count) facts")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }

            Text("Facts Stubble has learned about you from activity and chat. Used to personalize AI responses.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            memoryManagementContent
        }
    }

    // MARK: - Data Pane

    private var dataPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data Management")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    showClearConfirmation = true
                } label: {
                    Text("Clear All Data")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.statusError)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings-clear-data")

                Text("Permanently deletes all tasks, activities, screenshots, and memory. Your settings and sign-in are kept.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: - About Pane

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Logo + version
            VStack(alignment: .leading, spacing: 8) {
                if let logo = Self.loadLogo() {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 32)
                }

                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                Text("Version \(version) (\(build))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }

            Divider()

            // Check for Updates
            if updater.isAvailable {
                Button {
                    updater.checkForUpdates()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12))
                        Text("Check for Updates")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(updater.canCheckForUpdates ? Theme.textPrimary : Theme.textMuted)
                }
                .buttonStyle(.plain)
                .disabled(!updater.canCheckForUpdates)
            }

            Divider()

            // Links
            VStack(alignment: .leading, spacing: 12) {
                aboutLink("Website", url: "https://stubble.ai", icon: "globe")
                aboutLink("Privacy Policy", url: "https://stubble.ai/privacy", icon: "lock.shield")
                aboutLink("Terms of Service", url: "https://stubble.ai/terms", icon: "doc.text")
            }

            Divider()

            // Open Logs Folder
            Button {
                if let config = try? SharedConfiguration() {
                    NSWorkspace.shared.open(config.dataDirectory)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                    Text("Open Data Folder")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func aboutLink(_ title: String, url: String, icon: String) -> some View {
        Button {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }

    /// Load the Stubble logo from the app bundle or development Resources directory.
    private static func loadLogo() -> NSImage? {
        if let path = Bundle.main.path(forResource: "logo", ofType: "png") {
            return NSImage(contentsOfFile: path)
        }
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

    // MARK: - Memory Management

    private var memoryManagementContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Synthesized profile
            if !synthesizedProfile.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Synthesized Profile")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(synthesizedProfile)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Entries grouped by category
            let grouped = Dictionary(grouping: memoryEntries, by: \.category)
            let categoryOrder: [MemoryCategory] = [.identity, .project, .technology, .workflow, .interest]

            ForEach(categoryOrder, id: \.self) { category in
                if let items = grouped[category], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(categoryLabel(category))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)

                        ForEach(items) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.content)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textPrimary)
                                    HStack(spacing: 8) {
                                        Text(sourceLabel(entry.source))
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.textMuted)
                                        if entry.reinforcementCount > 1 {
                                            Text("seen \(entry.reinforcementCount)x")
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.textMuted)
                                        }
                                        Text(relativeDate(entry.lastSeen))
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                                Spacer()
                                Button {
                                    deleteMemoryEntry(id: entry.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.textMuted)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }

            // Add manual entry
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a fact")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Picker("", selection: $newMemoryCategory) {
                        ForEach(MemoryCategory.allCases, id: \.self) { cat in
                            Text(categoryLabel(cat)).tag(cat)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    TextField("e.g. Works as a product manager at Acme", text: $newMemoryContent)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(6)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Button {
                        addManualEntry()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, height: 24)
                            .background(Theme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Memory Helpers

    private func loadMemoryEntries() {
        memoryEntries = viewModel.memoryStore.load()
        synthesizedProfile = viewModel.memoryStore.loadProfile() ?? ""
    }

    private func deleteMemoryEntry(id: UUID) {
        viewModel.memoryStore.delete(id: id)
        loadMemoryEntries()
    }

    private func addManualEntry() {
        let trimmed = newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = MemoryEntry(
            category: newMemoryCategory,
            content: trimmed,
            confidence: 1.0,
            source: .userExplicit
        )
        viewModel.memoryStore.mergeStructured(newEntries: [entry])
        newMemoryContent = ""
        loadMemoryEntries()
    }

    private func categoryLabel(_ category: MemoryCategory) -> String {
        switch category {
        case .identity: return "Identity"
        case .project: return "Projects"
        case .technology: return "Technology"
        case .workflow: return "Workflow"
        case .interest: return "Interests"
        }
    }

    private func sourceLabel(_ source: MemorySource) -> String {
        switch source {
        case .activityInference: return "observed"
        case .chatInteraction: return "from chat"
        case .userExplicit: return "manual"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let days = Int(-date.timeIntervalSinceNow / 86400)
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }

    private func appearanceIcon(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

