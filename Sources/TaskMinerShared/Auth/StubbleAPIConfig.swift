import Foundation

/// Configuration constants for Stubble's backend services.
///
/// For self-hosted deployments, set these environment variables:
/// - `STUBBLE_SUPABASE_URL`: Your Supabase project URL
/// - `STUBBLE_SUPABASE_ANON_KEY`: Your Supabase public anon key
/// - `STUBBLE_PROXY_URL`: Your Cloudflare Worker URL (optional if using direct API mode)
///
/// Alternatively, for direct Gemini API access without a proxy:
/// - Set `GEMINI_API_KEY` environment variable
/// - No Supabase setup required
public enum StubbleAPIConfig {
    /// Supabase project URL.
    /// Set via `STUBBLE_SUPABASE_URL` environment variable, or replace the placeholder.
    public static let supabaseURL = ProcessInfo.processInfo.environment["STUBBLE_SUPABASE_URL"]
        ?? "https://YOUR_PROJECT.supabase.co"

    /// Supabase public anon key.
    /// Set via `STUBBLE_SUPABASE_ANON_KEY` environment variable, or replace the placeholder.
    /// Safe to embed — it's a public key that only grants access to Auth endpoints.
    public static let supabaseAnonKey = ProcessInfo.processInfo.environment["STUBBLE_SUPABASE_ANON_KEY"]
        ?? "YOUR_SUPABASE_ANON_KEY"

    /// Cloudflare Worker proxy URL. All proxy-mode AI requests go through this.
    /// Set via `STUBBLE_PROXY_URL` environment variable, or replace the placeholder.
    /// Not required if using direct API mode (GEMINI_API_KEY set).
    public static let proxyBaseURL = ProcessInfo.processInfo.environment["STUBBLE_PROXY_URL"]
        ?? "https://YOUR_WORKER.workers.dev"

    /// Custom URL scheme for OAuth callbacks.
    public static let callbackScheme = "com.stubble"

    /// Full OAuth callback URL.
    public static var callbackURL: String { "\(callbackScheme)://auth-callback" }

    /// Paddle Price ID for the Pro subscription.
    /// Set via `STUBBLE_PADDLE_PRICE_ID` environment variable for your own Paddle account.
    public static let paddlePriceId = ProcessInfo.processInfo.environment["STUBBLE_PADDLE_PRICE_ID"]
        ?? "YOUR_PADDLE_PRICE_ID"

    /// Build checkout URL that opens the checkout page with Paddle.js overlay.
    public static func paddleCheckoutURL(userId: String, email: String?) -> URL? {
        // Use custom checkout URL if set, otherwise default to stubble.ai
        let baseURL = ProcessInfo.processInfo.environment["STUBBLE_CHECKOUT_URL"]
            ?? "https://stubble.ai/checkout"

        var components = URLComponents(string: baseURL)
        var queryItems: [URLQueryItem] = []

        queryItems.append(URLQueryItem(name: "user_id", value: userId))

        if let email = email, !email.isEmpty {
            queryItems.append(URLQueryItem(name: "email", value: email))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    /// Enterprise contact URL.
    public static let enterpriseContactURL = ProcessInfo.processInfo.environment["STUBBLE_ENTERPRISE_URL"]
        ?? "mailto:hello@stubble.app?subject=Stubble%20Enterprise"

    /// Free trial duration in days.
    public static let trialDays = 5

    /// Whether the backend is configured for proxy mode.
    /// Returns true if Supabase credentials are set (not placeholder values).
    public static var isConfigured: Bool {
        !supabaseURL.contains("YOUR_") && !supabaseAnonKey.contains("YOUR_")
    }

    /// Whether direct API mode is available (GEMINI_API_KEY env var is set).
    /// In direct mode, requests go straight to Gemini without the proxy.
    public static var isDirectModeAvailable: Bool {
        ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil
    }
}
