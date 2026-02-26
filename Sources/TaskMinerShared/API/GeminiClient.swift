import Foundation

/// Lightweight Gemini REST API client using URLSession (text-only, no vision).
public final class GeminiClient: Sendable {
    private let apiKey: String
    private let model: String
    private let baseURL: String

    /// Maximum number of retry attempts for transient failures.
    private static let maxRetries = 2
    /// Base delay between retries (doubles each attempt).
    private static let retryBaseDelay: TimeInterval = 1.0

    public init(apiKey: String, model: String = "gemini-2.5-flash") {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = "https://generativelanguage.googleapis.com/v1beta/models"
    }

    /// Create from GEMINI_API_KEY environment variable. Returns nil if not set.
    public static func fromEnvironment() -> GeminiClient? {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
              !key.isEmpty else {
            return nil
        }
        return GeminiClient(apiKey: key)
    }

    /// Create from an explicit API key string. Returns nil if the key is empty.
    public static func fromAPIKey(_ key: String) -> GeminiClient? {
        guard !key.isEmpty else { return nil }
        return GeminiClient(apiKey: key)
    }

    /// Resolve client: settings file first, then GEMINI_API_KEY env var.
    /// Both the Dashboard and CLI/daemon share the same settings.json file.
    public static func resolvedClient() -> GeminiClient? {
        if let key = readKeyFromSettings(), let client = GeminiClient.fromAPIKey(key) {
            return client
        }
        return GeminiClient.fromEnvironment()
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

    /// Send a text prompt to Gemini and return the response text.
    public func generateContent(prompt: String, systemInstruction: String? = nil) async throws -> String {
        let contents: [[String: Any]] = [
            [
                "role": "user",
                "parts": [["text": prompt]]
            ]
        ]

        let generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 65536,
            "responseMimeType": "application/json",
            "thinkingConfig": ["thinkingBudget": 0]
        ]

        return try await sendRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig
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
                    components?.path = "/v1beta/models/\(model):streamGenerateContent"
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
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.httpBody = jsonData
                    request.timeoutInterval = 120

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: GeminiError.invalidResponse)
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
                        else { continue }

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

    /// Common request + retry + response parsing.
    private func sendRequest(
        contents: [[String: Any]],
        systemInstruction: String?,
        generationConfig: [String: Any]
    ) async throws -> String {
        var components = URLComponents(string: baseURL)
        components?.path = "/v1beta/models/\(model):generateContent"
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

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        // Retry loop for transient failures
        var lastError: Error = GeminiError.invalidResponse
        for attempt in 0...Self.maxRetries {
            if attempt > 0 {
                let delay = Self.retryBaseDelay * pow(2.0, Double(attempt - 1))
                Logger.warning("GeminiClient: retry \(attempt)/\(Self.maxRetries) after \(String(format: "%.1f", delay))s delay")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GeminiError.invalidResponse
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
        }
    }
}
