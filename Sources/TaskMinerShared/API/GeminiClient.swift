import Foundation

/// Lightweight Gemini REST API client using URLSession (text-only, no vision).
///
/// Supports two modes:
/// - **Direct** (BYOK): requests go directly to Google's Gemini API using a user-provided key.
/// - **Proxy**: requests go through the Stubble Cloudflare Worker, authenticated with a Supabase JWT.
///   The Worker adds the Gemini API key and enforces tier/rate limits.
public final class GeminiClient: Sendable {

    /// How this client authenticates with the AI backend.
    public enum ClientMode: Sendable {
        /// Direct Gemini API access using a user-provided API key (BYOK).
        case direct(apiKey: String)
        /// Proxy mode via Cloudflare Worker. JWT is resolved at request time from AuthManager.
        case proxy
    }

    public let mode: ClientMode
    private let model: String

    /// Gemini API base URL for direct mode.
    private static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Maximum number of retry attempts for transient failures.
    private static let maxRetries = 2
    /// Base delay between retries (doubles each attempt).
    private static let retryBaseDelay: TimeInterval = 1.0

    /// Create a direct-mode client with an explicit API key (BYOK).
    public init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.mode = .direct(apiKey: apiKey)
        self.model = model
    }

    /// Create a proxy-mode client that authenticates via Supabase JWT.
    public init(proxy: Bool, model: String = "gemini-2.5-flash") {
        self.mode = .proxy
        self.model = model
    }

    /// The base URL for API requests, derived from mode.
    private var baseURL: String {
        switch mode {
        case .direct:
            return Self.geminiBaseURL
        case .proxy:
            return "\(StubbleAPIConfig.proxyBaseURL)/v1beta/models"
        }
    }

    /// Create from GEMINI_API_KEY environment variable. Returns nil if not set.
    /// Only available in debug builds — env vars are visible to system monitors in production.
    public static func fromEnvironment() -> GeminiClient? {
        #if DEBUG
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
              !key.isEmpty else {
            return nil
        }
        return GeminiClient(apiKey: key)
        #else
        return nil
        #endif
    }

    /// Create from an explicit API key string. Returns nil if the key is empty.
    public static func fromAPIKey(_ key: String) -> GeminiClient? {
        guard !key.isEmpty else { return nil }
        return GeminiClient(apiKey: key)
    }

    /// Resolve the best available client:
    /// 1. Proxy mode if signed in with valid session + backend configured
    /// 2. BYOK from settings.json
    /// 3. BYOK from GEMINI_API_KEY env var
    ///
    /// Both the Dashboard and CLI/daemon share the same resolution logic.
    public static func resolvedClient() -> GeminiClient? {
        // 1. Try proxy mode: signed in + backend configured + trial not expired
        let auth = AuthManager.shared
        if auth.isSignedIn && StubbleAPIConfig.isConfigured && !auth.isTrialExpired {
            return GeminiClient(proxy: true)
        }

        // 2. Fall back to BYOK
        if let key = readKeyFromSettings(), let client = GeminiClient.fromAPIKey(key) {
            return client
        }
        return GeminiClient.fromEnvironment()
    }

    /// Whether this client is using proxy mode.
    public var isProxyMode: Bool {
        if case .proxy = mode { return true }
        return false
    }

    /// Read the Gemini API key from the shared settings.json file.
    private static func readKeyFromSettings() -> String? {
        guard let config = try? SharedConfiguration(),
              let data = try? Data(contentsOf: config.settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = json["geminiApiKey"] as? String,
              !key.isEmpty
        else { return nil }
        return key
    }

    // MARK: - Public API (unchanged signatures — zero consumer changes needed)

    /// Send a text prompt to Gemini and return the response text.
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - systemInstruction: Optional system instruction
    ///   - tools: Optional tools array (e.g., `[["google_search": [:]]]` for search grounding)
    ///
    /// Note: When tools are provided, JSON response mode is disabled (they're incompatible).
    /// The response will be plain text that should contain JSON.
    public func generateContent(
        prompt: String,
        systemInstruction: String? = nil,
        tools: [[String: Any]]? = nil
    ) async throws -> String {
        let contents: [[String: Any]] = [
            [
                "role": "user",
                "parts": [["text": prompt]]
            ]
        ]

        // Search grounding is incompatible with JSON response mode
        // When tools are provided, use text mode and rely on prompt to get JSON
        var generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 65536,
            "thinkingConfig": ["thinkingBudget": 0]
        ]

        if tools == nil {
            generationConfig["responseMimeType"] = "application/json"
        }

        return try await sendRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig,
            tools: tools
        )
    }

    /// Send a conversational prompt to Gemini and return a plain-text response.
    /// Unlike `generateContent()` which forces JSON, this returns natural language.
    public func generateText(
        prompt: String,
        systemInstruction: String? = nil,
        conversationHistory: [[String: Any]]? = nil
    ) async throws -> String {
        // Build contents: optional conversation history + current user message
        var contents: [[String: Any]] = conversationHistory ?? []
        contents.append([
            "role": "user",
            "parts": [["text": prompt]]
        ])

        let generationConfig: [String: Any] = [
            "temperature": 0.5,
            "maxOutputTokens": 4096,
            "responseMimeType": "text/plain",
            "thinkingConfig": ["thinkingBudget": 1024]
        ]

        return try await sendRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig
        )
    }

    /// Stream a conversational response from Gemini using Server-Sent Events (SSE).
    /// Yields text chunks as they arrive. The caller appends each chunk to build the full response.
    /// No retry logic — the user can resend on failure.
    public func streamGenerateText(
        prompt: String,
        systemInstruction: String? = nil,
        conversationHistory: [[String: Any]]? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var contents: [[String: Any]] = conversationHistory ?? []
                    contents.append([
                        "role": "user",
                        "parts": [["text": prompt]]
                    ])

                    var components = URLComponents(string: baseURL)
                    components?.path += "/\(model):streamGenerateContent"
                    components?.queryItems = [URLQueryItem(name: "alt", value: "sse")]

                    guard let url = components?.url else {
                        continuation.finish(throwing: GeminiError.invalidURL)
                        return
                    }

                    var body: [String: Any] = ["contents": contents]
                    if let system = systemInstruction {
                        body["systemInstruction"] = ["parts": [["text": system]]]
                    }
                    body["generationConfig"] = [
                        "temperature": 0.5,
                        "maxOutputTokens": 4096,
                        "responseMimeType": "text/plain",
                        "thinkingConfig": ["thinkingBudget": 1024]
                    ] as [String: Any]

                    let jsonData = try JSONSerialization.data(withJSONObject: body)

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    try await self.applyAuth(to: &request)
                    request.httpBody = jsonData
                    request.timeoutInterval = 120

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: GeminiError.invalidResponse)
                        return
                    }

                    // Handle proxy-specific error codes
                    if let proxyError = self.checkProxyError(statusCode: httpResponse.statusCode) {
                        continuation.finish(throwing: proxyError)
                        return
                    }

                    guard httpResponse.statusCode == 200 else {
                        // Read full body for error message
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }
                        let errorBody = String(data: errorData, encoding: .utf8) ?? "unknown"
                        continuation.finish(throwing: GeminiError.apiError(statusCode: httpResponse.statusCode, message: errorBody))
                        return
                    }

                    // Parse SSE lines: each line starts with "data: " followed by a JSON chunk
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let lineData = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let firstCandidate = candidates.first,
                              let content = firstCandidate["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]]
                        else {
                            // Log malformed SSE chunks for debugging (may indicate API changes or network issues)
                            let preview = jsonStr.prefix(100)
                            Logger.warning("GeminiClient: skipped malformed SSE chunk: \(preview)...")
                            continue
                        }

                        // Yield only non-thought text parts
                        for part in parts {
                            if part["thought"] != nil { continue }
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private

    /// Apply authentication headers based on the client mode.
    private func applyAuth(to request: inout URLRequest) async throws {
        switch mode {
        case .direct(let apiKey):
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        case .proxy:
            let token = try await AuthManager.shared.validAccessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Check for proxy-specific HTTP error codes and return a user-friendly error.
    /// Returns nil if the status code is not a known proxy error.
    private func checkProxyError(statusCode: Int) -> GeminiError? {
        guard isProxyMode else { return nil }

        switch statusCode {
        case 401:
            return .sessionExpired
        case 403:
            return .trialExpired
        case 429:
            return .rateLimited
        default:
            return nil
        }
    }

    /// Common request + retry + response parsing.
    private func sendRequest(
        contents: [[String: Any]],
        systemInstruction: String?,
        generationConfig: [String: Any],
        tools: [[String: Any]]? = nil
    ) async throws -> String {
        var components = URLComponents(string: baseURL)
        components?.path += "/\(model):generateContent"
        guard let url = components?.url else {
            throw GeminiError.invalidURL
        }

        var body: [String: Any] = [
            "contents": contents
        ]

        if let system = systemInstruction {
            body["systemInstruction"] = [
                "parts": [["text": system]]
            ]
        }

        body["generationConfig"] = generationConfig

        // Add tools (e.g., google_search for grounding)
        if let tools {
            body["tools"] = tools
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(to: &request)
        request.httpBody = jsonData
        request.timeoutInterval = 120

        // Retry loop for transient failures
        var lastError: Error = GeminiError.invalidResponse
        for attempt in 0...Self.maxRetries {
            if attempt > 0 {
                let delay = Self.retryBaseDelay * pow(2.0, Double(attempt - 1))
                Logger.warning("GeminiClient: retry \(attempt)/\(Self.maxRetries) after \(String(format: "%.1f", delay))s delay")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Re-apply auth for retries (token may have been refreshed)
                try await applyAuth(to: &request)
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GeminiError.invalidResponse
                }

                // Check for proxy-specific errors (non-retryable)
                if let proxyError = checkProxyError(statusCode: httpResponse.statusCode) {
                    throw proxyError
                }

                // Retry on transient HTTP errors
                if Self.isRetryableStatusCode(httpResponse.statusCode) && attempt < Self.maxRetries {
                    let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                    lastError = GeminiError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
                    continue
                }

                guard httpResponse.statusCode == 200 else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
                    throw GeminiError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
                }

                return try parseResponseText(data)
            } catch let error as URLError where Self.isRetryableURLError(error) && attempt < Self.maxRetries {
                Logger.warning("GeminiClient: transient network error: \(error.localizedDescription)")
                lastError = error
                continue
            } catch {
                // Non-retryable error (parse error, non-retryable HTTP, non-retryable network) — fail immediately
                throw error
            }
        }

        throw lastError
    }

    /// Parse the Gemini response JSON and extract the text content.
    func parseResponseText(_ data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "?"
            throw GeminiError.parseError("Could not parse response structure: \(preview)")
        }

        // Warn if the response was truncated due to token limit
        if let finishReason = firstCandidate["finishReason"] as? String, finishReason == "MAX_TOKENS" {
            Logger.warning("GeminiClient: response truncated (MAX_TOKENS) — output hit the token limit")
        }

        // Find the last non-thought part with text content
        // (Gemini 2.5 Flash may include "thought" parts before the actual content)
        let text = parts.reversed()
            .first(where: { $0["thought"] == nil && $0["text"] != nil })?["text"] as? String
            ?? parts.last?["text"] as? String

        guard let resultText = text else {
            throw GeminiError.parseError("No text found in \(parts.count) response parts")
        }

        return resultText
    }

    /// HTTP status codes that indicate a transient/retryable server issue.
    static func isRetryableStatusCode(_ code: Int) -> Bool {
        code == 429 || code == 500 || code == 502 || code == 503
    }

    /// URLError codes that indicate transient network issues worth retrying.
    static func isRetryableURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }
}

public enum GeminiError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError(String)
    /// Proxy: session expired or invalid JWT (401).
    case sessionExpired
    /// Proxy: trial has expired (403).
    case trialExpired
    /// Proxy: rate limit exceeded (429).
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Gemini API URL (check model or base URL)"
        case .invalidResponse:
            return "Invalid response from Gemini API"
        case .apiError(let code, let msg):
            return "Gemini API error \(code): \(msg)"
        case .parseError(let msg):
            return "Failed to parse Gemini response: \(msg)"
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .trialExpired:
            return "Your free trial has ended. Upgrade to Pro for unlimited access."
        case .rateLimited:
            return "Daily request limit reached. Upgrade to Pro for unlimited access."
        }
    }

    /// Convert a network error into a user-friendly message.
    /// Use this for errors that may be URLErrors or other network-related failures.
    public static func friendlyNetworkError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet:
                return "No internet connection. Check your network and try again."
            case .timedOut:
                return "Request timed out. The server may be slow or unreachable."
            case .networkConnectionLost:
                return "Connection lost. Please try again."
            case .cannotFindHost, .cannotConnectToHost:
                return "Cannot reach the server. Check your connection and try again."
            case .dnsLookupFailed:
                return "Network error. Check your connection and try again."
            default:
                return "Network error. Please check your connection."
            }
        }
        return error.localizedDescription
    }
}
