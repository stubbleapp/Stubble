import Foundation

/// Result of extracting both legacy memory entries and knowledge graph updates from chat.
public struct ChatExtractionResult: Sendable {
    public let memoryEntries: [MemoryEntry]
    public let graphUpdates: GraphExtractionResult

    public init(memoryEntries: [MemoryEntry] = [], graphUpdates: GraphExtractionResult = GraphExtractionResult()) {
        self.memoryEntries = memoryEntries
        self.graphUpdates = graphUpdates
    }

    public var isEmpty: Bool {
        memoryEntries.isEmpty && graphUpdates.isEmpty
    }
}

/// Extracts user-revealed facts from chat conversations and feeds them
/// back into the memory store. This captures information the user
/// explicitly shares (role, company, preferences) or corrections they
/// make to the AI's understanding.
public final class ChatMemoryExtractor: Sendable {
    private let geminiClient: GeminiClient

    public init(geminiClient: GeminiClient) {
        self.geminiClient = geminiClient
    }

    /// Analyze a chat exchange and return both legacy memory entries and graph updates.
    public func extractFull(
        userMessage: String,
        assistantResponse: String,
        existingProfile: String?
    ) async -> ChatExtractionResult {
        let memoryEntries = await extract(userMessage: userMessage, assistantResponse: assistantResponse, existingProfile: existingProfile)
        let graphUpdates = await extractGraph(userMessage: userMessage, assistantResponse: assistantResponse, existingProfile: existingProfile)
        return ChatExtractionResult(memoryEntries: memoryEntries, graphUpdates: graphUpdates)
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
                let isCorrection = dict["correction"] as? Bool ?? false
                return MemoryEntry(
                    category: category,
                    content: trimmed,
                    confidence: confidence,
                    source: .chatInteraction,
                    isCorrection: isCorrection
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

    // MARK: - Knowledge Graph Extraction

    /// Extract knowledge graph nodes and edges from chat exchange.
    private func extractGraph(
        userMessage: String,
        assistantResponse: String,
        existingProfile: String?
    ) async -> GraphExtractionResult {
        let trimmedUser = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty && trimmedUser.count > 15 else { return GraphExtractionResult() }

        var prompt = """
        Analyze this chat exchange and extract knowledge graph entities the user revealed about themselves.

        User message:
        \(trimmedUser)

        Assistant response:
        \(String(assistantResponse.prefix(500)))
        """

        if let profile = existingProfile, !profile.isEmpty {
            prompt += """

            Current user profile (avoid duplicates):
            \(profile)
            """
        }

        prompt += """

        Entity types (each needs a "description" field with a sentence explaining it):
        - identity: Personal facts (role, company, expertise level, background)
        - project: Projects/codebases the user works on
        - technology: Languages, frameworks, tools they use
        - skill: Capabilities and expertise
        - topic: Areas of interest

        Relationship types:
        - uses: Project uses technology
        - requires: Project requires skill
        - relatedTo: Symmetric relationship

        Return a JSON object:
        {
          "nodes": [
            {"type": "identity", "name": "iOS Developer", "description": "Works as an iOS developer at a startup", "confidence": 0.9},
            {"type": "project", "name": "MyApp", "description": "Building a mobile app for task management", "confidence": 0.8}
          ],
          "edges": [{"type": "uses", "source": "MyApp", "source_type": "project", "target": "React", "target_type": "technology", "confidence": 0.8}]
        }

        Only extract entities the user explicitly mentioned. Return {"nodes": [], "edges": []} if none.
        """

        let systemInstruction = """
        You extract knowledge graph entities from chat conversations.
        Return ONLY a JSON object with "nodes" and "edges" arrays. No markdown.
        Every node MUST have a "description" field explaining the entity.
        Be conservative — most messages reveal nothing. Empty result is fine.
        Never include sensitive data or the content of user questions.
        """

        do {
            let response = try await geminiClient.generateContent(
                prompt: prompt,
                systemInstruction: systemInstruction
            )

            guard let parsed = JSONSanitizer.parse(response) as? [String: Any] else {
                return GraphExtractionResult()
            }

            let nodesArray = parsed["nodes"] as? [[String: Any]] ?? []
            let edgesArray = parsed["edges"] as? [[String: Any]] ?? []

            let now = Date()

            // Parse nodes
            var nodes: [KnowledgeNode] = []
            var nodeNameToId: [String: UUID] = [:]

            for dict in nodesArray {
                guard let typeStr = dict["type"] as? String,
                      let type = NodeType(rawValue: typeStr),
                      let name = dict["name"] as? String else { continue }

                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // Validate node name to prevent garbage data
                guard NodeValidator.isValidName(trimmed, type: type) else {
                    Logger.debug("Graph: rejected '\(trimmed)' from chat - failed validation")
                    continue
                }

                let confidence = dict["confidence"] as? Double ?? 0.7
                let id = UUID()
                nodeNameToId[trimmed.lowercased()] = id

                // Build properties dictionary with description and source
                var properties: [String: String] = ["source": "chatInteraction"]
                if let description = dict["description"] as? String {
                    let trimmedDesc = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedDesc.isEmpty {
                        properties["description"] = trimmedDesc
                    }
                }

                nodes.append(KnowledgeNode(
                    id: id,
                    type: type,
                    name: trimmed,
                    confidence: confidence,
                    firstSeen: now,
                    lastSeen: now,
                    properties: properties
                ))
            }

            // Parse edges
            var edges: [KnowledgeEdge] = []
            for dict in edgesArray {
                guard let typeStr = dict["type"] as? String,
                      let type = EdgeType(rawValue: typeStr),
                      let sourceName = dict["source"] as? String,
                      let targetName = dict["target"] as? String else { continue }

                guard let sourceId = nodeNameToId[sourceName.lowercased()],
                      let targetId = nodeNameToId[targetName.lowercased()] else { continue }

                let confidence = dict["confidence"] as? Double ?? 0.7
                let context = dict["context"] as? String

                edges.append(KnowledgeEdge(
                    type: type,
                    sourceId: sourceId,
                    targetId: targetId,
                    confidence: confidence,
                    firstSeen: now,
                    lastSeen: now,
                    context: context
                ))
            }

            if !nodes.isEmpty {
                Logger.debug("ChatMemoryExtractor: extracted \(nodes.count) graph nodes, \(edges.count) edges")
            }
            return GraphExtractionResult(nodes: nodes, edges: edges)
        } catch {
            Logger.debug("ChatMemoryExtractor graph extraction failed (non-fatal): \(error.localizedDescription)")
            return GraphExtractionResult()
        }
    }
}
