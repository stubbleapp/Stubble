import Foundation

/// API mode for Gemini requests.
public enum GeminiAPIMode: Sendable {
    /// Requests go through the Stubble Cloudflare Worker (requires Supabase auth).
    case proxy
    /// Requests go directly to Gemini API (requires GEMINI_API_KEY env var).
    case direct
}

/// Lightweight Gemini REST API client using URLSession (text-only, no vision).
///
/// Supports two modes:
/// - **Proxy mode** (default): Requests go through the Stubble Cloudflare Worker,
///   authenticated with a Supabase JWT. The Worker adds the Gemini API key and
///   enforces tier/rate limits.
/// - **Direct mode**: When `GEMINI_API_KEY` environment variable is set, requests
///   go directly to the Gemini API. No Supabase setup required.
public final class GeminiClient: Sendable {

    private let model: String
    private let apiMode: GeminiAPIMode

    /// Maximum number of retry attempts for transient failures.
    private static let maxRetries = 2
    /// Base delay between retries (doubles each attempt).
    private static let retryBaseDelay: TimeInterval = 1.0

    /// Direct Gemini API base URL.
    private static let geminiDirectURL = "https://generativelanguage.googleapis.com/v1beta/models"

    /// Create a client with the specified API mode.
    /// - Parameters:
    ///   - model: The Gemini model to use (default: gemini-2.5-flash)
    ///   - apiMode: Whether to use proxy or direct mode
    public init(model: String = "gemini-2.5-flash", apiMode: GeminiAPIMode = .proxy) {
        self.model = model
        self.apiMode = apiMode
    }

    /// The base URL for API requests.
    private var baseURL: String {
        switch apiMode {
        case .proxy:
            return "\(StubbleAPIConfig.proxyBaseURL)/v1beta/models"
        case .direct:
            return Self.geminiDirectURL
        }
    }

    /// Resolve the client based on available configuration.
    ///
    /// Priority:
    /// 1. Direct mode if `GEMINI_API_KEY` env var is set
    /// 2. Proxy mode if signed in with valid session and backend configured
    /// 3. Returns nil if neither is available
    public static func resolvedClient() -> GeminiClient? {
        // Direct mode takes priority — no auth required
        if StubbleAPIConfig.isDirectModeAvailable {
            return GeminiClient(apiMode: .direct)
        }

        // Proxy mode requires auth and backend configuration
        let auth = AuthManager.shared
        guard auth.isSignedIn && StubbleAPIConfig.isConfigured && !auth.isTrialExpired else {
            return nil
        }
        return GeminiClient(apiMode: .proxy)
    }

    /// Whether this client is using proxy mode.
    public var isProxyMode: Bool { apiMode == .proxy }

    /// Whether this client is using direct mode.
    public var isDirectMode: Bool { apiMode == .direct }

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

                    // Handle proxy-specific error codes (only in proxy mode)
                    if self.apiMode == .proxy,
                       let proxyError = self.checkProxyError(statusCode: httpResponse.statusCode) {
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

    /// Apply authentication headers based on API mode.
    private func applyAuth(to request: inout URLRequest) async throws {
        switch apiMode {
        case .proxy:
            let token = try await AuthManager.shared.validAccessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .direct:
            guard let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] else {
                throw GeminiError.missingAPIKey
            }
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
    }

    /// Check for proxy-specific HTTP error codes and return a user-friendly error.
    /// Returns nil if the status code is not a known proxy error.
    private func checkProxyError(statusCode: Int) -> GeminiError? {
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

                // Check for proxy-specific errors (non-retryable, only in proxy mode)
                if apiMode == .proxy, let proxyError = checkProxyError(statusCode: httpResponse.statusCode) {
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

    // MARK: - Function Calling

    /// Result of a function calling request.
    public struct FunctionCallResult: Sendable {
        /// The final text response after all function calls are resolved.
        public let text: String
        /// The function calls that were made (for logging/debugging).
        public let functionCalls: [FunctionCall]
    }

    /// A function call requested by the model.
    public struct FunctionCall: Sendable {
        public let name: String
        public let arguments: [String: Any]

        public init(name: String, arguments: [String: Any]) {
            self.name = name
            self.arguments = arguments
        }
    }

    /// Generate content with function calling support.
    /// The model can request function calls, which are executed via the provided handler.
    /// This continues until the model returns a text response.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt
    ///   - systemInstruction: Optional system instruction
    ///   - functions: Array of function declarations (Gemini format)
    ///   - conversationHistory: Optional previous conversation turns
    ///   - executeFunction: Handler that executes a function call and returns the result as a string
    /// - Returns: The final text response and list of function calls made
    public func generateWithFunctions(
        prompt: String,
        systemInstruction: String? = nil,
        functions: [[String: Any]],
        conversationHistory: [[String: Any]]? = nil,
        executeFunction: @escaping (FunctionCall) async throws -> String
    ) async throws -> FunctionCallResult {
        var contents: [[String: Any]] = conversationHistory ?? []
        contents.append([
            "role": "user",
            "parts": [["text": prompt]]
        ])

        var allFunctionCalls: [FunctionCall] = []
        let maxIterations = 10  // Prevent infinite loops

        for _ in 0..<maxIterations {
            let response = try await sendFunctionCallRequest(
                contents: contents,
                systemInstruction: systemInstruction,
                functions: functions
            )

            // Check if the response contains function calls
            if let functionCalls = response.functionCalls, !functionCalls.isEmpty {
                // Execute each function call
                var functionResponses: [[String: Any]] = []

                for call in functionCalls {
                    let fc = FunctionCall(name: call.name, arguments: call.arguments)
                    allFunctionCalls.append(fc)

                    let result = try await executeFunction(fc)
                    functionResponses.append([
                        "functionResponse": [
                            "name": call.name,
                            "response": ["result": result]
                        ]
                    ])
                }

                // Add the model's function call to history
                contents.append([
                    "role": "model",
                    "parts": functionCalls.map { call in
                        [
                            "functionCall": [
                                "name": call.name,
                                "args": call.arguments
                            ]
                        ]
                    }
                ])

                // Add function responses to history
                contents.append([
                    "role": "user",
                    "parts": functionResponses
                ])
            } else if let text = response.text {
                // Model returned a text response — we're done
                return FunctionCallResult(text: text, functionCalls: allFunctionCalls)
            } else {
                throw GeminiError.parseError("Response contained neither text nor function calls")
            }
        }

        throw GeminiError.parseError("Function calling loop exceeded maximum iterations")
    }

    /// Internal response structure for function calling.
    private struct FunctionCallResponse {
        let text: String?
        let functionCalls: [ParsedFunctionCall]?

        struct ParsedFunctionCall {
            let name: String
            let arguments: [String: Any]
        }
    }

    /// Send a request that may return function calls or text.
    private func sendFunctionCallRequest(
        contents: [[String: Any]],
        systemInstruction: String?,
        functions: [[String: Any]]
    ) async throws -> FunctionCallResponse {
        var components = URLComponents(string: baseURL)
        components?.path += "/\(model):generateContent"
        guard let url = components?.url else {
            throw GeminiError.invalidURL
        }

        var body: [String: Any] = ["contents": contents]

        if let system = systemInstruction {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }

        body["generationConfig"] = [
            "temperature": 0.3,
            "maxOutputTokens": 8192,
            "thinkingConfig": ["thinkingBudget": 1024]
        ] as [String: Any]

        // Add function declarations
        body["tools"] = [
            ["functionDeclarations": functions]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try await applyAuth(to: &request)
        request.httpBody = jsonData
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        if apiMode == .proxy, let proxyError = checkProxyError(statusCode: httpResponse.statusCode) {
            throw proxyError
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw GeminiError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        return try parseFunctionCallResponse(data)
    }

    /// Parse response that may contain function calls or text.
    private func parseFunctionCallResponse(_ data: Data) throws -> FunctionCallResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "?"
            throw GeminiError.parseError("Could not parse function call response: \(preview)")
        }

        // Check for function calls
        var functionCalls: [FunctionCallResponse.ParsedFunctionCall] = []
        var textParts: [String] = []

        for part in parts {
            // Skip thought parts
            if part["thought"] != nil { continue }

            if let functionCall = part["functionCall"] as? [String: Any],
               let name = functionCall["name"] as? String {
                let args = functionCall["args"] as? [String: Any] ?? [:]
                functionCalls.append(FunctionCallResponse.ParsedFunctionCall(name: name, arguments: args))
            } else if let text = part["text"] as? String, !text.isEmpty {
                textParts.append(text)
            }
        }

        if !functionCalls.isEmpty {
            return FunctionCallResponse(text: nil, functionCalls: functionCalls)
        } else if !textParts.isEmpty {
            return FunctionCallResponse(text: textParts.joined(), functionCalls: nil)
        } else {
            throw GeminiError.parseError("Response contained no usable parts")
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
    /// Direct mode: GEMINI_API_KEY environment variable not set.
    case missingAPIKey

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
        case .missingAPIKey:
            return "GEMINI_API_KEY environment variable not set. Set it to use direct API mode."
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
