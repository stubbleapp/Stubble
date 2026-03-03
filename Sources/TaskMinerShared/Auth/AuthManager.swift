import Foundation
import CryptoKit

/// Manages Supabase authentication state, session persistence, and token refresh.
///
/// Shared singleton between dashboard and daemon via file-based session storage (`auth.json`).
/// The OAuth browser flow (ASWebAuthenticationSession) is handled by the dashboard UI —
/// this class only provides the URL to open and processes the resulting auth code.
///
/// ## Architecture
/// - Dashboard: calls `buildGoogleSignInURL()` to get the OAuth URL, opens it in
///   `ASWebAuthenticationSession`, then calls `exchangeCode(_:codeVerifier:)` with the result.
/// - Daemon: reads the persisted session from `auth.json` and calls `refreshSessionIfNeeded()`
///   before making proxy requests.
/// - Both: call `validAccessToken()` to get a JWT for the Cloudflare Worker proxy.
public final class AuthManager: @unchecked Sendable {
    public static let shared = AuthManager()

    // MARK: - Auth State

    public enum AuthState: Equatable, Sendable {
        case signedOut
        case trial(daysRemaining: Int)
        case pro
        case expired
        case byok
    }

    public enum AuthError: LocalizedError, Sendable {
        case invalidURL
        case noAuthCode
        case networkError(String)
        case tokenExchangeFailed(String)
        case sessionExpired

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid authentication URL"
            case .noAuthCode: return "No authorization code received"
            case .networkError(let msg): return "Network error: \(msg)"
            case .tokenExchangeFailed(let msg): return "Authentication failed: \(msg)"
            case .sessionExpired: return "Session expired. Please sign in again."
            }
        }
    }

    // MARK: - State (thread-safe via sessionQueue)

    /// Thread-safe access to sign-in state.
    public var isSignedIn: Bool {
        sessionQueue.sync { _isSignedIn }
    }
    public var userEmail: String? {
        sessionQueue.sync { _userEmail }
    }
    public var userName: String? {
        sessionQueue.sync { _userName }
    }
    public var userAvatarURL: URL? {
        sessionQueue.sync { _userAvatarURL }
    }
    public var currentState: AuthState {
        sessionQueue.sync { _currentState }
    }
    public var subscriptionTier: String? {
        sessionQueue.sync { _subscriptionTier }
    }

    // Backing storage (accessed only via sessionQueue)
    private var _isSignedIn: Bool = false
    private var _userEmail: String?
    private var _userName: String?
    private var _userAvatarURL: URL?
    private var _currentState: AuthState = .signedOut
    private var _subscriptionTier: String?

    // MARK: - Session Data

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date?
    private var userCreatedAt: Date?
    private var userId: String?

    /// Serial queue for thread-safe session access.
    private let sessionQueue = DispatchQueue(label: "com.stubble.auth.session")

    /// Shared in-flight refresh task to prevent concurrent refresh races.
    /// Two simultaneous callers that both see token near-expiry will share
    /// the same refresh Task instead of firing two competing requests.
    private var refreshTask: Task<Void, Error>?

    /// Stores the PKCE code verifier from the most recent `buildGoogleSignInURL()` call
    /// so that `handleCallback(url:)` can complete the exchange when `onOpenURL` fires.
    private var pendingCodeVerifier: String?

    /// OAuth state parameter for CSRF protection (validated in handleCallback).
    private var pendingState: String?

    /// File path for auth.json.
    private let authFilePath: URL

    /// Shared ISO8601 formatter — avoids allocating a new one on every parse/format call.
    private static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Init

    private init() {
        let config = try? SharedConfiguration()
        let baseDir = config?.dataDirectory ?? FileManager.default.temporaryDirectory
        self.authFilePath = baseDir.appendingPathComponent("auth.json")
        loadSession()
        updateAuthState()
    }

    // MARK: - Public API

    /// Build the Google OAuth sign-in URL for use with ASWebAuthenticationSession.
    /// Returns the URL to open and the PKCE code verifier needed for the token exchange.
    public func buildGoogleSignInURL() -> (url: URL, codeVerifier: String)? {
        guard StubbleAPIConfig.isConfigured else { return nil }

        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.generateCodeChallenge(from: codeVerifier)

        // Do NOT pass a client `state` parameter — Supabase GoTrue encodes its own
        // flow_state_id into the state sent to the OAuth provider. A client-provided
        // state can override it, causing "OAuth state not found or expired" on callback.
        // CSRF protection is provided by the PKCE code verifier binding.
        var components = URLComponents(string: "\(StubbleAPIConfig.supabaseURL)/auth/v1/authorize")
        components?.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: StubbleAPIConfig.callbackURL),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components?.url else { return nil }
        pendingCodeVerifier = codeVerifier
        pendingState = nil
        return (url, codeVerifier)
    }

    /// Extract the auth code from an OAuth callback URL.
    /// Returns nil if the URL is not an auth callback or if the code is missing.
    /// Checks both query parameters and fragment (Supabase may use either depending on flow type).
    public static func extractAuthCode(from url: URL) -> String? {
        guard url.scheme == StubbleAPIConfig.callbackScheme,
              url.host == "auth-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        // Check query parameters first (standard PKCE flow)
        if let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
            return code
        }

        // Fall back to fragment parameters (some Supabase configurations return code in fragment)
        if let fragment = components.fragment {
            let fragmentComponents = URLComponents(string: "?\(fragment)")
            if let code = fragmentComponents?.queryItems?.first(where: { $0.name == "code" })?.value {
                return code
            }
        }

        return nil
    }

    /// Extract an error description from an OAuth callback URL (Supabase returns these on failure).
    public static func extractAuthError(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Check both query params and fragment params — Supabase may use either
        var items = components.queryItems ?? []
        if let fragment = components.fragment {
            // Parse fragment as query items (e.g., #error=...&error_description=...)
            let fragmentComponents = URLComponents(string: "?\(fragment)")
            items.append(contentsOf: fragmentComponents?.queryItems ?? [])
        }

        let errorDesc = items.first(where: { $0.name == "error_description" })?.value
        let error = items.first(where: { $0.name == "error" })?.value

        if let errorDesc {
            return errorDesc.replacingOccurrences(of: "+", with: " ")
        } else if let error {
            return error.replacingOccurrences(of: "+", with: " ")
        }
        return nil
    }

    /// Convenience method for `onOpenURL` — extracts the auth code and exchanges it
    /// using the pending code verifier from the most recent `buildGoogleSignInURL()` call.
    /// Returns `true` if the URL was an auth callback and was handled successfully.
    @discardableResult
    public func handleCallback(url: URL) async -> Bool {
        guard let code = Self.extractAuthCode(from: url),
              let verifier = pendingCodeVerifier
        else { return false }

        // Validate OAuth state parameter (CSRF protection)
        if let expectedState = pendingState {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let returnedState = components?.queryItems?.first(where: { $0.name == "state" })?.value
            guard returnedState == expectedState else {
                Logger.warning("AuthManager: OAuth state mismatch — possible CSRF attack")
                pendingCodeVerifier = nil
                pendingState = nil
                return false
            }
        }

        pendingCodeVerifier = nil
        pendingState = nil
        do {
            try await exchangeCode(code, codeVerifier: verifier)
            return true
        } catch {
            Logger.error("OAuth callback exchange failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Exchange an OAuth authorization code for a Supabase session.
    /// Call this after ASWebAuthenticationSession returns with a callback URL.
    public func exchangeCode(_ code: String, codeVerifier: String) async throws {
        let url = URL(string: "\(StubbleAPIConfig.supabaseURL)/auth/v1/token?grant_type=pkce")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(StubbleAPIConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(StubbleAPIConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "auth_code": code,
            "code_verifier": codeVerifier,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AuthError.tokenExchangeFailed(errorBody)
        }

        try parseAndStoreSession(data: data)
    }

    /// Get a valid access token for proxy requests.
    /// Automatically refreshes the token if it's expired or about to expire.
    /// Multiple concurrent callers share a single in-flight refresh to prevent races.
    public func validAccessToken() async throws -> String {
        // Use _isSignedIn directly to avoid nested sessionQueue.sync (deadlock)
        let signedIn = sessionQueue.sync { self._isSignedIn }
        guard signedIn else { throw AuthError.sessionExpired }

        // Refresh if token expires within 60 seconds
        let needsRefresh = sessionQueue.sync { () -> Bool in
            guard let expiresAt = self.tokenExpiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
        if needsRefresh {
            try await refreshSession()
        }

        let token = sessionQueue.sync { self.accessToken }
        guard let token else { throw AuthError.sessionExpired }
        return token
    }

    /// Refresh the session token if it's expired or about to expire.
    /// Safe to call even if the token is still valid (no-op).
    public func refreshSessionIfNeeded() async throws {
        // Use _isSignedIn directly to avoid nested sessionQueue.sync (deadlock)
        let signedIn = sessionQueue.sync { self._isSignedIn }
        guard signedIn else { return }

        let needsRefresh = sessionQueue.sync { () -> Bool in
            guard let expiresAt = self.tokenExpiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
        if needsRefresh {
            try await refreshSession()
        }
    }

    /// Trial days remaining. Returns nil if not signed in.
    public var trialDaysRemaining: Int? {
        guard let createdAt = userCreatedAt else { return nil }
        let daysSinceSignup = Calendar.current.dateComponents([.day], from: createdAt, to: Date()).day ?? 0
        let remaining = StubbleAPIConfig.trialDays - daysSinceSignup
        return max(0, remaining)
    }

    /// Whether the free trial has expired.
    public var isTrialExpired: Bool {
        guard isSignedIn else { return false }
        guard let remaining = trialDaysRemaining else { return false }
        return remaining <= 0 && subscriptionTier != "pro"
    }

    /// Sign out — revokes server session (best-effort) then clears local state.
    public func signOut() {
        // Revoke the session on the server before clearing local tokens
        let tokenToRevoke = sessionQueue.sync { self.accessToken }
        if let token = tokenToRevoke, StubbleAPIConfig.isConfigured {
            Task.detached(priority: .utility) {
                var request = URLRequest(url: URL(string: "\(StubbleAPIConfig.supabaseURL)/auth/v1/logout")!)
                request.httpMethod = "POST"
                request.setValue(StubbleAPIConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 5
                _ = try? await URLSession.shared.data(for: request)
            }
        }

        sessionQueue.sync {
            accessToken = nil
            refreshToken = nil
            tokenExpiresAt = nil
            userCreatedAt = nil
            userId = nil
            _userEmail = nil
            _userName = nil
            _userAvatarURL = nil
            _subscriptionTier = nil
            _isSignedIn = false
            _currentState = .signedOut
        }

        // Delete auth.json
        try? FileManager.default.removeItem(at: authFilePath)

        NotificationCenter.default.post(name: .authStateChanged, object: nil)
    }

    // MARK: - Token Refresh

    private func refreshSession() async throws {
        // Coalesce concurrent refresh calls into a single in-flight task.
        // This prevents the race where two callers both see near-expiry,
        // both call Supabase, and the second invalidates the first's new token.
        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<Void, Error> {
            defer { refreshTask = nil }

            let currentRefresh = sessionQueue.sync { self.refreshToken }
            guard let currentRefresh else {
                throw AuthError.sessionExpired
            }

            let url = URL(string: "\(StubbleAPIConfig.supabaseURL)/auth/v1/token?grant_type=refresh_token")!

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(StubbleAPIConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(StubbleAPIConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")

            let body: [String: String] = ["refresh_token": currentRefresh]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 30

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw AuthError.networkError("Invalid response")
                }

                if httpResponse.statusCode == 200 {
                    try self.parseAndStoreSession(data: data)
                } else if httpResponse.statusCode == 400 || httpResponse.statusCode == 401 {
                    // Auth error (invalid/revoked refresh token) — sign out
                    self.signOut()
                    throw AuthError.sessionExpired
                } else {
                    // Server error (5xx) — don't sign out, just fail this request
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw AuthError.networkError("Refresh failed (\(httpResponse.statusCode)): \(errorBody)")
                }
            } catch let error as URLError {
                // Network error (timeout, offline) — don't sign out
                throw AuthError.networkError(error.localizedDescription)
            }
        }

        refreshTask = task
        try await task.value
    }

    // MARK: - Session Parsing

    private func parseAndStoreSession(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.tokenExchangeFailed("Invalid JSON response")
        }

        guard let newAccessToken = json["access_token"] as? String,
              let newRefreshToken = json["refresh_token"] as? String
        else {
            throw AuthError.tokenExchangeFailed("Missing tokens in response")
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600

        sessionQueue.sync {
            self.accessToken = newAccessToken
            self.refreshToken = newRefreshToken
            self.tokenExpiresAt = Date().addingTimeInterval(expiresIn)

            // Parse user info
            if let user = json["user"] as? [String: Any] {
                self.userId = user["id"] as? String
                self._userEmail = user["email"] as? String

                if let createdAtStr = user["created_at"] as? String {
                    self.userCreatedAt = Self.iso8601Formatter.date(from: createdAtStr)
                }

                if let metadata = user["user_metadata"] as? [String: Any] {
                    self._subscriptionTier = metadata["subscription_tier"] as? String
                    if let avatarStr = metadata["avatar_url"] as? String,
                       avatarStr.hasPrefix("https://") {
                        self._userAvatarURL = URL(string: avatarStr)
                    }
                    if let name = metadata["full_name"] as? String ?? metadata["name"] as? String {
                        self._userName = name
                    }
                    // Google profile might provide email via metadata
                    if self._userEmail == nil, let email = metadata["email"] as? String {
                        self._userEmail = email
                    }
                }
            }

            self._isSignedIn = true
        }

        updateAuthState()
        persistSession()

        NotificationCenter.default.post(name: .authStateChanged, object: nil)
    }

    // MARK: - Auth State Derivation

    private func updateAuthState() {
        sessionQueue.sync {
            if _isSignedIn {
                if _subscriptionTier == "pro" {
                    _currentState = .pro
                } else if let remaining = computeTrialDaysRemaining(), remaining > 0 {
                    _currentState = .trial(daysRemaining: remaining)
                } else {
                    _currentState = .expired
                }
            } else if hasBYOKKey() {
                _currentState = .byok
            } else {
                _currentState = .signedOut
            }
        }
    }

    /// Internal helper for trial days calculation (called within sessionQueue).
    private func computeTrialDaysRemaining() -> Int? {
        guard let createdAt = userCreatedAt else { return nil }
        let daysSinceSignup = Calendar.current.dateComponents([.day], from: createdAt, to: Date()).day ?? 0
        let remaining = StubbleAPIConfig.trialDays - daysSinceSignup
        return max(0, remaining)
    }

    /// Check if a BYOK API key exists in settings.json (same pattern as GeminiClient).
    private func hasBYOKKey() -> Bool {
        guard let config = try? SharedConfiguration(),
              let data = try? Data(contentsOf: config.settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["geminiApiKey"] as? String,
              !key.isEmpty
        else { return false }
        return true
    }

    // MARK: - Persistence (auth.json)

    private func persistSession() {
        let dict: [String: Any] = sessionQueue.sync {
            var d: [String: Any] = [:]
            if let accessToken { d["access_token"] = accessToken }
            if let refreshToken { d["refresh_token"] = refreshToken }
            if let tokenExpiresAt { d["expires_at"] = tokenExpiresAt.timeIntervalSince1970 }
            if let userId { d["user_id"] = userId }
            if let email = _userEmail { d["user_email"] = email }
            if let name = _userName { d["user_name"] = name }
            if let userCreatedAt { d["user_created_at"] = Self.iso8601Formatter.string(from: userCreatedAt) }
            if let tier = _subscriptionTier { d["subscription_tier"] = tier }
            if let avatar = _userAvatarURL { d["avatar_url"] = avatar.absoluteString }
            return d
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: authFilePath, options: .atomic)
            // Set file permissions to 0600 (owner-only) — same pattern as settings.json
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: authFilePath.path
            )
        } catch {
            Logger.error("Failed to persist auth session: \(error.localizedDescription)")
        }
    }

    private func loadSession() {
        guard FileManager.default.fileExists(atPath: authFilePath.path),
              let data = try? Data(contentsOf: authFilePath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        accessToken = dict["access_token"] as? String
        refreshToken = dict["refresh_token"] as? String
        if let expiresAt = dict["expires_at"] as? TimeInterval {
            tokenExpiresAt = Date(timeIntervalSince1970: expiresAt)
        }
        userId = dict["user_id"] as? String
        _userEmail = dict["user_email"] as? String
        _userName = dict["user_name"] as? String
        _subscriptionTier = dict["subscription_tier"] as? String
        if let createdAtStr = dict["user_created_at"] as? String {
            userCreatedAt = Self.iso8601Formatter.date(from: createdAtStr)
        }
        if let avatarStr = dict["avatar_url"] as? String {
            _userAvatarURL = URL(string: avatarStr)
        }

        _isSignedIn = (accessToken != nil && refreshToken != nil)
    }

    // MARK: - PKCE Helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted when the authentication state changes (sign in, sign out, token refresh).
    static let authStateChanged = Notification.Name("stubble.authStateChanged")
}
