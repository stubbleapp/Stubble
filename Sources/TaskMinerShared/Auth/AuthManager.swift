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
        case cancelled
        case noAuthCode
        case networkError(String)
        case tokenExchangeFailed(String)
        case sessionExpired
        case notConfigured

        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid authentication URL"
            case .cancelled: return "Sign-in was cancelled"
            case .noAuthCode: return "No authorization code received"
            case .networkError(let msg): return "Network error: \(msg)"
            case .tokenExchangeFailed(let msg): return "Authentication failed: \(msg)"
            case .sessionExpired: return "Session expired. Please sign in again."
            case .notConfigured: return "Authentication not configured"
            }
        }
    }

    // MARK: - State

    public private(set) var isSignedIn: Bool = false
    public private(set) var userEmail: String?
    public private(set) var userName: String?
    public private(set) var userAvatarURL: URL?
    public private(set) var currentState: AuthState = .signedOut
    public private(set) var subscriptionTier: String?

    // MARK: - Session Data

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date?
    private var userCreatedAt: Date?
    private var userId: String?

    /// Serial queue for thread-safe session access.
    private let sessionQueue = DispatchQueue(label: "com.stubble.auth.session")

    /// Stores the PKCE code verifier from the most recent `buildGoogleSignInURL()` call
    /// so that `handleCallback(url:)` can complete the exchange when `onOpenURL` fires.
    private var pendingCodeVerifier: String?

    /// File path for auth.json.
    private let authFilePath: URL

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

        var components = URLComponents(string: "\(StubbleAPIConfig.supabaseURL)/auth/v1/authorize")
        components?.queryItems = [
            URLQueryItem(name: "provider", value: "google"),
            URLQueryItem(name: "redirect_to", value: StubbleAPIConfig.callbackURL),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        guard let url = components?.url else { return nil }
        pendingCodeVerifier = codeVerifier
        return (url, codeVerifier)
    }

    /// Extract the auth code from an OAuth callback URL.
    /// Returns nil if the URL is not an auth callback.
    public static func extractAuthCode(from url: URL) -> String? {
        guard url.scheme == StubbleAPIConfig.callbackScheme,
              url.host == "auth-callback",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else { return nil }
        return code
    }

    /// Convenience method for `onOpenURL` — extracts the auth code and exchanges it
    /// using the pending code verifier from the most recent `buildGoogleSignInURL()` call.
    /// Returns `true` if the URL was an auth callback and was handled successfully.
    @discardableResult
    public func handleCallback(url: URL) async -> Bool {
        guard let code = Self.extractAuthCode(from: url),
              let verifier = pendingCodeVerifier
        else { return false }

        pendingCodeVerifier = nil
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
    public func validAccessToken() async throws -> String {
        guard isSignedIn else { throw AuthError.sessionExpired }

        // Refresh if token expires within 60 seconds
        if let expiresAt = tokenExpiresAt, expiresAt.timeIntervalSinceNow < 60 {
            try await refreshSession()
        }

        guard let token = accessToken else { throw AuthError.sessionExpired }
        return token
    }

    /// Refresh the session token if it's expired or about to expire.
    /// Safe to call even if the token is still valid (no-op).
    public func refreshSessionIfNeeded() async throws {
        guard isSignedIn else { return }

        if let expiresAt = tokenExpiresAt, expiresAt.timeIntervalSinceNow < 60 {
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

    /// Sign out — clears session and deletes auth.json.
    public func signOut() {
        sessionQueue.sync {
            accessToken = nil
            refreshToken = nil
            tokenExpiresAt = nil
            userCreatedAt = nil
            userId = nil
            userEmail = nil
            userName = nil
            userAvatarURL = nil
            subscriptionTier = nil
            isSignedIn = false
            currentState = .signedOut
        }

        // Delete auth.json
        try? FileManager.default.removeItem(at: authFilePath)

        NotificationCenter.default.post(name: .authStateChanged, object: nil)
    }

    // MARK: - Token Refresh

    private func refreshSession() async throws {
        guard let currentRefresh = refreshToken else {
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

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // Refresh failed — clear session
            signOut()
            throw AuthError.sessionExpired
        }

        try parseAndStoreSession(data: data)
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
                self.userEmail = user["email"] as? String

                if let createdAtStr = user["created_at"] as? String {
                    self.userCreatedAt = ISO8601DateFormatter().date(from: createdAtStr)
                }

                if let metadata = user["user_metadata"] as? [String: Any] {
                    self.subscriptionTier = metadata["subscription_tier"] as? String
                    if let avatarStr = metadata["avatar_url"] as? String {
                        self.userAvatarURL = URL(string: avatarStr)
                    }
                    if let name = metadata["full_name"] as? String ?? metadata["name"] as? String {
                        self.userName = name
                    }
                    // Google profile might provide email via metadata
                    if self.userEmail == nil, let email = metadata["email"] as? String {
                        self.userEmail = email
                    }
                }
            }

            self.isSignedIn = true
        }

        updateAuthState()
        persistSession()

        NotificationCenter.default.post(name: .authStateChanged, object: nil)
    }

    // MARK: - Auth State Derivation

    private func updateAuthState() {
        if isSignedIn {
            if subscriptionTier == "pro" {
                currentState = .pro
            } else if let remaining = trialDaysRemaining, remaining > 0 {
                currentState = .trial(daysRemaining: remaining)
            } else {
                currentState = .expired
            }
        } else if hasBYOKKey() {
            currentState = .byok
        } else {
            currentState = .signedOut
        }
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
        var dict: [String: Any] = [:]
        if let accessToken { dict["access_token"] = accessToken }
        if let refreshToken { dict["refresh_token"] = refreshToken }
        if let tokenExpiresAt { dict["expires_at"] = tokenExpiresAt.timeIntervalSince1970 }
        if let userId { dict["user_id"] = userId }
        if let userEmail { dict["user_email"] = userEmail }
        if let userName { dict["user_name"] = userName }
        if let userCreatedAt { dict["user_created_at"] = ISO8601DateFormatter().string(from: userCreatedAt) }
        if let subscriptionTier { dict["subscription_tier"] = subscriptionTier }
        if let userAvatarURL { dict["avatar_url"] = userAvatarURL.absoluteString }

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
        userEmail = dict["user_email"] as? String
        userName = dict["user_name"] as? String
        subscriptionTier = dict["subscription_tier"] as? String
        if let createdAtStr = dict["user_created_at"] as? String {
            userCreatedAt = ISO8601DateFormatter().date(from: createdAtStr)
        }
        if let avatarStr = dict["avatar_url"] as? String {
            userAvatarURL = URL(string: avatarStr)
        }

        isSignedIn = (accessToken != nil && refreshToken != nil)
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
