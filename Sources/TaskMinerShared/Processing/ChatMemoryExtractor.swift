import Foundation

/// Extracts user-revealed facts from chat conversations and feeds them
/// back into the memory store. This captures information the user
/// explicitly shares (role, company, preferences) or corrections they
/// make to the AI's understanding.
public final class ChatMemoryExtractor: Sendable {
    private let geminiClient: GeminiClient

    public init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    /// Analyze a chat exchange and return any new memory entries.
    /// Only the user's message and the assistant's response are analyzed
    /// (not the full history) to keep the call cheap.
    public func extract(
        userMessage: String,
        assistantResponse: String,
        existingProfile: String?
    ) async -> [MemoryEntry] {
        let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return [] }

        // Skip very short messages unlikely to contain self-revelations
        guard trimmedUser.count > 15 else { return [] }

        let categories = MemoryCategory.allCases.map { $0.rawValue }.joined(separator: ", ")

        var prompt = """
        Analyze this chat exchange between a user and an AI assistant. \
        Extract any DURABLE facts the user revealed about themselves.

        User message:
        \(trimmedUser)

        Assistant response:
        \(String(assistantResponse.prefix(500)))
        """

        if let profile = existingProfile, !profile.isEmpty {
            prompt += """

            Current user profile (do NOT repeat facts already known):
            \(profile)
            """
        }

        prompt += """

        Look for:
        - Self-identification ("I'm a...", "I work at...", "My role is...")
        - Corrections ("That's not my project", "I don't use X anymore")
        - Preferences ("I prefer...", "I usually...", "I always...")
        - Project/work context revealed naturally in questions

        For corrections, return an entry with "correction": true to signal that \
        a previous fact should be reconsidered.

        Return a JSON array. Each object has:
        - "category": one of [\(categories)]
        - "content": a short factual sentence
        - "confidence": 0.5-1.0 (higher for explicit statements, lower for inferred)
        - "correction": true/false (true if this corrects a previous belief)

        Return [] if the user didn't reveal anything durable about themselves. \
        Most casual chat exchanges yield nothing — that's fine.
        """

        let systemInstruction = """
        You extract self-revealed facts from chat conversations. \
        Return ONLY a JSON array. No markdown, no explanation. \
        Be very conservative — most messages don't contain durable facts. \
        An empty array [] is the most common correct response. \
        Only extract facts the user explicitly stated or strongly implied. \
        Never include the content of the user's questions as facts.
        """

        do {
            let response = try await geminiClient.generateContent(
                prompt: prompt,
                systemInstruction: systemInstruction
            )

            guard let parsed = JSONSanitizer.parse(response) else { return [] }

            let dictArray: [[String: Any]]
            if let direct = parsed as? [[String: Any]] {
                dictArray = direct
            } else if let obj = parsed as? [String: Any],
                      let nested = obj.values.first(where: { $0 is [[String: Any]] }) as? [[String: Any]] {
                dictArray = nested
            } else {
                return []
            }

            let entries = dictArray.compactMap { dict -> MemoryEntry? in
                guard let content = dict["content"] as? String else { return nil }
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let category = (dict["category"] as? String).flatMap { MemoryCategory(rawValue: $0) } ?? .workflow
                let confidence = dict["confidence"] as? Double ?? 0.7
                return MemoryEntry(
                    category: category,
                    content: trimmed,
                    confidence: confidence,
                    source: .chatInteraction
                )
            }

            if !entries.isEmpty {
                Logger.debug("ChatMemoryExtractor: extracted \(entries.count) entries from chat")
            }
            return entries
        } catch {
            Logger.debug("ChatMemoryExtractor failed (non-fatal): \(error.localizedDescription)")
            return []
        }
    }
}
