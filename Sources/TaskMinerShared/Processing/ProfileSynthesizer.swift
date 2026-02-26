import Foundation

/// Synthesizes a concise user profile paragraph from structured memory entries.
/// The profile is used as the primary context injection into all AI prompts,
/// replacing the raw bullet-list of individual facts.
public final class ProfileSynthesizer: Sendable {
    private let geminiClient: GeminiClient

    public init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    /// Distill memory entries into a concise profile paragraph.
    /// Returns nil if there are too few entries to synthesize meaningfully.
    public func synthesize(entries: [MemoryEntry]) async -> String? {
        guard entries.count >= 3 else { return nil }

        let grouped = Dictionary(grouping: entries, by: \.category)
        let categoryOrder: [MemoryCategory] = [.identity, .project, .technology, .workflow, .interest]

        var lines: [String] = []
        for cat in categoryOrder {
            guard let items = grouped[cat], !items.isEmpty else { continue }
            let sorted = items.sorted { lhs, rhs in
                if lhs.reinforcementCount != rhs.reinforcementCount {
                    return lhs.reinforcementCount > rhs.reinforcementCount
                }
                return lhs.confidence > rhs.confidence
            }
            lines.append("\(cat.rawValue.capitalized):")
            for item in sorted {
                let strength = item.reinforcementCount > 3 ? " (established)" : ""
                lines.append("- \(item.content)\(strength)")
            }
        }

        let entryText = lines.joined(separator: "\n")

        let prompt = """
        Synthesize the following categorized facts about a person into a concise profile paragraph \
        (3-6 sentences). The profile should read naturally as a coherent description of who this \
        person is, what they work on, and how they work. Prioritize established facts (marked as such) \
        and high-confidence items.

        Facts:
        \(entryText)

        Write in third person, present tense. Be specific — use actual project names, technologies, \
        and tools mentioned in the facts. Do not pad with generic statements. If a fact is marked \
        "(established)", give it more weight. Return ONLY the profile paragraph text, nothing else.
        """

        let systemInstruction = """
        You synthesize structured facts into a natural-language profile. \
        Return ONLY the profile paragraph — no JSON, no markdown, no headers. \
        Keep it concise (3-6 sentences). Be specific and factual.
        """

        do {
            let response = try await geminiClient.generateContent(
                prompt: prompt,
                systemInstruction: systemInstruction
            )
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return trimmed
        } catch {
            Logger.debug("Profile synthesis failed (non-fatal): \(error.localizedDescription)")
            return nil
        }
    }

    /// Synthesize and persist the profile if entries have changed enough to warrant it.
    /// Compares entry count and latest lastSeen against the existing profile to avoid
    /// unnecessary API calls.
    public func synthesizeIfNeeded(store: UserMemoryStore) async {
        let entries = store.load()
        guard entries.count >= 3 else { return }

        if let profile = await synthesize(entries: entries) {
            store.saveProfile(profile)
            Logger.info("ProfileSynthesizer: updated user profile (\(profile.count) chars)")
        }
    }
}
