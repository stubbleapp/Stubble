import Foundation

/// Lightweight Gemini REST API client using URLSession (text-only, no vision).
public final class GeminiClient: Sendable {
    private let apiKey: String
    private let model: String
    private let baseURL: String

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

    /// Resolve client: Keychain first, then GEMINI_API_KEY. Use from both Dashboard and CLI.
    public static func resolvedClient() -> GeminiClient? {
        if let key = GeminiKeychain.get(), let client = GeminiClient.fromAPIKey(key) {
            return client
        }
        return GeminiClient.fromEnvironment()
    }

    /// Send a text prompt to Gemini and return the response text.
    public func generateContent(prompt: String, systemInstruction: String? = nil) async throws -> String {
        var components = URLComponents(string: baseURL)
        components?.path = "/v1beta/models/\(model):generateContent"
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components?.url else {
            throw GeminiError.invalidURL
        }

        let contents: [[String: Any]] = [
            [
                "role": "user",
                "parts": [["text": prompt]]
            ]
        ]

        var body: [String: Any] = [
            "contents": contents
        ]

        if let system = systemInstruction {
            body["systemInstruction"] = [
                "parts": [["text": system]]
            ]
        }

        // Configure generation parameters
        // Disable thinking to avoid it consuming output tokens and truncating JSON
        body["generationConfig"] = [
            "temperature": 0.3,
            "maxOutputTokens": 8192,
            "responseMimeType": "application/json",
            "thinkingConfig": ["thinkingBudget": 0]
        ] as [String: Any]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw GeminiError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        // Parse response JSON
        // Gemini 2.5 Flash may include "thought" parts before the actual content,
        // so we find the last part that has a "text" key and is not a thought.
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "?"
            throw GeminiError.parseError("Could not parse response structure: \(preview)")
        }

        // Find the last non-thought part with text content
        let text = parts.reversed()
            .first(where: { $0["thought"] == nil && $0["text"] != nil })?["text"] as? String
            ?? parts.last?["text"] as? String

        guard let resultText = text else {
            throw GeminiError.parseError("No text found in \(parts.count) response parts")
        }

        return resultText
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
