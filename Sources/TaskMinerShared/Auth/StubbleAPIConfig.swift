import Foundation

/// Configuration constants for Stubble's backend services.
///
/// The Supabase URL and anon key are **public** (safe to embed in the binary) —
/// Supabase gates access via Row Level Security and JWT verification, not key secrecy.
/// The anon key only grants access to the Auth endpoints and public-facing APIs.
public enum StubbleAPIConfig {
    /// Supabase project URL.
    /// Replace with your actual project URL after creating the Supabase project.
    public static let supabaseURL = "https://uyeacjkroneihbtjswnv.supabase.co"

    /// Supabase public anon key.
    /// Replace with your actual anon key (safe to embed — it's a public key).
    public static let supabaseAnonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InV5ZWFjamtyb25laWhidGpzd252Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIyODUyMDEsImV4cCI6MjA4Nzg2MTIwMX0.-GcJdFcbNgaUW49tf1S8Mnl0djSLbmJmElIQ_b7_53g"

    /// Cloudflare Worker proxy URL. All proxy-mode AI requests go through this.
    public static let proxyBaseURL = "https://api.stubble.ai"

    /// Custom URL scheme for OAuth callbacks.
    public static let callbackScheme = "com.stubble"

    /// Full OAuth callback URL.
    public static var callbackURL: String { "\(callbackScheme)://auth-callback" }

    /// Paddle Price ID for the Pro subscription ($10/month).
    public static let paddlePriceId = "pri_01kjwwnmrahnxxdbbna0p1myee"

    /// Build checkout URL that opens stubble.ai/checkout with Paddle.js overlay.
    public static func paddleCheckoutURL(userId: String, email: String?) -> URL? {
        var components = URLComponents(string: "https://stubble.ai/checkout")
        var queryItems: [URLQueryItem] = []

        queryItems.append(URLQueryItem(name: "user_id", value: userId))

        if let email = email, !email.isEmpty {
            queryItems.append(URLQueryItem(name: "email", value: email))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    /// Enterprise contact URL.
    public static let enterpriseContactURL = "mailto:hello@stubble.app?subject=Stubble%20Enterprise"

    /// Free trial duration in days.
    public static let trialDays = 5

    /// Whether the backend is configured (placeholder values replaced).
    public static var isConfigured: Bool {
        !supabaseURL.contains("PLACEHOLDER") && !supabaseAnonKey.contains("PLACEHOLDER")
    }
}
