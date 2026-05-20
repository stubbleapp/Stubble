import Foundation

/// Class that manages the knowledge graph — nodes (entities) and edges (relationships).
/// Provides CRUD operations, graph queries, maintenance (decay/pruning), and context generation.
/// Marked @MainActor to ensure thread-safe access to the underlying store.
@MainActor
public final class KnowledgeGraph: Sendable {
    private let store: KnowledgeGraphStore

    public init(store: KnowledgeGraphStore) {
        self.store = store
    }

    /// Convenience initializer for DatabaseReader.
    public convenience init(dbReader: DatabaseReader) {
        self.init(store: dbReader)
    }

    // MARK: - Node Operations

    /// Upsert a node — if same type + name exists, reinforce it; otherwise insert.
    public func upsertNode(_ node: KnowledgeNode) {
        // First check for existing node with same type and matching name/alias
        if let existing = findNode(type: node.type, nameOrAlias: node.name) {
            // Merge aliases
            var updatedAliases = existing.aliases
            for alias in node.aliases where !existing.matches(name: alias) {
                updatedAliases.append(alias)
            }
            // Also add the new name as an alias if different from canonical
            if existing.name.lowercased() != node.name.lowercased() && !existing.matches(name: node.name) {
                updatedAliases.append(node.name)
            }

            let updated = KnowledgeNode(
                id: existing.id,
                type: existing.type,
                name: existing.name,  // Keep canonical name
                aliases: updatedAliases,
                confidence: max(existing.confidence, node.confidence),
                firstSeen: existing.firstSeen,
                lastSeen: Date(),
                reinforcementCount: existing.reinforcementCount + 1,
                properties: existing.properties.merging(node.properties) { _, new in new }
            )
            store.upsertKnowledgeNode(updated)
        } else {
            store.upsertKnowledgeNode(node)
        }
    }

    /// Find a node by type and name (exact or alias match).
    public func findNode(type: NodeType, nameOrAlias: String) -> KnowledgeNode? {
        store.knowledgeNode(type: type, name: nameOrAlias)
    }

    /// Find a node by ID.
    public func node(id: UUID) -> KnowledgeNode? {
        store.knowledgeNode(id: id)
    }

    /// Get all nodes, optionally filtered by type.
    public func allNodes(type: NodeType? = nil) -> [KnowledgeNode] {
        store.knowledgeNodes(type: type)
    }

    /// Delete a node and its connected edges.
    public func deleteNode(id: UUID) {
        store.deleteKnowledgeNode(id: id)
    }

    // MARK: - Edge Operations

    /// Upsert an edge — if same type + source + target exists, reinforce it; otherwise insert.
    public func upsertEdge(_ edge: KnowledgeEdge) {
        if let existing = store.knowledgeEdge(type: edge.type, source: edge.sourceId, target: edge.targetId) {
            let updated = KnowledgeEdge(
                id: existing.id,
                type: existing.type,
                sourceId: existing.sourceId,
                targetId: existing.targetId,
                confidence: max(existing.confidence, edge.confidence),
                firstSeen: existing.firstSeen,
                lastSeen: Date(),
                reinforcementCount: existing.reinforcementCount + 1,
                context: edge.context ?? existing.context
            )
            store.upsertKnowledgeEdge(updated)
        } else {
            store.upsertKnowledgeEdge(edge)
        }
    }

    /// Get edges from a source node.
    public func edges(from nodeId: UUID) -> [KnowledgeEdge] {
        store.knowledgeEdges(from: nodeId, to: nil)
    }

    /// Get edges to a target node.
    public func edges(to nodeId: UUID) -> [KnowledgeEdge] {
        store.knowledgeEdges(from: nil, to: nodeId)
    }

    /// Get all edges (optionally filtered).
    public func allEdges() -> [KnowledgeEdge] {
        store.knowledgeEdges(from: nil, to: nil)
    }

    /// Delete an edge by ID.
    public func deleteEdge(id: UUID) {
        store.deleteKnowledgeEdge(id: id)
    }

    // MARK: - Graph Queries

    /// Get direct neighbors (nodes connected by edges).
    public func neighbors(of nodeId: UUID, depth: Int = 1) -> [KnowledgeNode] {
        var visited = Set<UUID>()
        var frontier = [nodeId]
        var results: [KnowledgeNode] = []

        for _ in 0..<depth {
            var nextFrontier: [UUID] = []
            for id in frontier where !visited.contains(id) {
                visited.insert(id)
                let outEdges = edges(from: id)
                let inEdges = edges(to: id)
                for edge in outEdges {
                    if !visited.contains(edge.targetId) {
                        nextFrontier.append(edge.targetId)
                    }
                }
                for edge in inEdges {
                    if !visited.contains(edge.sourceId) {
                        nextFrontier.append(edge.sourceId)
                    }
                }
            }
            for nid in nextFrontier {
                if let node = node(id: nid) {
                    results.append(node)
                }
            }
            frontier = nextFrontier
        }

        return results
    }

    /// Get nodes related via specific edge types.
    public func relatedNodes(to nodeId: UUID, edgeTypes: [EdgeType]) -> [KnowledgeNode] {
        let allOutEdges = edges(from: nodeId).filter { edgeTypes.contains($0.type) }
        let allInEdges = edges(to: nodeId).filter { edgeTypes.contains($0.type) }

        var results: [KnowledgeNode] = []
        var seen = Set<UUID>()
        for edge in allOutEdges {
            if seen.insert(edge.targetId).inserted, let n = node(id: edge.targetId) {
                results.append(n)
            }
        }
        for edge in allInEdges {
            if seen.insert(edge.sourceId).inserted, let n = node(id: edge.sourceId) {
                results.append(n)
            }
        }
        return results
    }

    // MARK: - Maintenance

    /// Apply time-based confidence decay to all nodes and edges.
    /// Returns the number of items decayed.
    @discardableResult
    public func applyDecay() -> Int {
        let now = Date()
        var decayedCount = 0

        // Decay nodes
        for node in allNodes() {
            let age = now.timeIntervalSince(node.lastSeen)
            let rate = KnowledgeNode.decayRate(for: node.type)
            var penalty = 0.0

            // Tiered decay (same logic as UserMemoryStore)
            if age > 14 * 86400 && node.reinforcementCount <= 1 {
                penalty += rate * 0.5
            }
            if age > 30 * 86400 && node.reinforcementCount <= 2 {
                penalty += rate
            }
            if age > 60 * 86400 && node.reinforcementCount <= 3 {
                penalty += rate * 0.5
            }

            if penalty > 0 {
                let newConfidence = max(0.1, node.confidence - penalty)
                store.updateKnowledgeNodeConfidence(id: node.id, confidence: newConfidence)
                decayedCount += 1
            }
        }

        // Decay edges — inherit decay rate from source node type
        for edge in allEdges() {
            guard let sourceNode = node(id: edge.sourceId) else { continue }
            let age = now.timeIntervalSince(edge.lastSeen)
            let rate = KnowledgeNode.decayRate(for: sourceNode.type)
            var penalty = 0.0

            if age > 14 * 86400 && edge.reinforcementCount <= 1 {
                penalty += rate * 0.5
            }
            if age > 30 * 86400 && edge.reinforcementCount <= 2 {
                penalty += rate
            }
            if age > 60 * 86400 && edge.reinforcementCount <= 3 {
                penalty += rate * 0.5
            }

            if penalty > 0 {
                let newConfidence = max(0.1, edge.confidence - penalty)
                store.updateKnowledgeEdgeConfidence(id: edge.id, confidence: newConfidence)
                decayedCount += 1
            }
        }

        return decayedCount
    }

    /// Prune nodes and edges below confidence threshold.
    @discardableResult
    public func prune(belowConfidence threshold: Double = 0.15) -> Int {
        let prunedNodes = store.pruneKnowledgeNodes(belowConfidence: threshold)
        let prunedEdges = store.pruneKnowledgeEdges(belowConfidence: threshold)
        return prunedNodes + prunedEdges
    }

    /// Merge duplicate nodes into a single canonical node.
    /// Edges from merged nodes are redirected to the canonical node.
    public func mergeNodes(_ ids: [UUID], canonical canonicalId: UUID) throws {
        guard ids.contains(canonicalId) else {
            throw KnowledgeGraphError.invalidMerge("Canonical ID must be in the list of IDs to merge")
        }
        guard let canonicalNode = node(id: canonicalId) else {
            throw KnowledgeGraphError.nodeNotFound(canonicalId)
        }

        let otherIds = ids.filter { $0 != canonicalId }

        // Collect aliases from all nodes being merged
        var mergedAliases = canonicalNode.aliases
        var highestConfidence = canonicalNode.confidence
        var totalReinforcement = canonicalNode.reinforcementCount
        var earliestSeen = canonicalNode.firstSeen
        var latestSeen = canonicalNode.lastSeen
        var mergedProperties = canonicalNode.properties

        for otherId in otherIds {
            guard let otherNode = node(id: otherId) else { continue }

            // Add the other node's name as an alias if not already present
            if !canonicalNode.matches(name: otherNode.name) {
                mergedAliases.append(otherNode.name)
            }
            for alias in otherNode.aliases where !canonicalNode.matches(name: alias) {
                mergedAliases.append(alias)
            }

            highestConfidence = max(highestConfidence, otherNode.confidence)
            totalReinforcement += otherNode.reinforcementCount
            earliestSeen = min(earliestSeen, otherNode.firstSeen)
            latestSeen = max(latestSeen, otherNode.lastSeen)
            mergedProperties.merge(otherNode.properties) { _, new in new }

            // Delete the merged node (edges will be deleted automatically)
            deleteNode(id: otherId)
        }

        // Update the canonical node
        let updated = KnowledgeNode(
            id: canonicalId,
            type: canonicalNode.type,
            name: canonicalNode.name,
            aliases: mergedAliases,
            confidence: highestConfidence,
            firstSeen: earliestSeen,
            lastSeen: latestSeen,
            reinforcementCount: totalReinforcement,
            properties: mergedProperties
        )
        store.upsertKnowledgeNode(updated)
    }

    // MARK: - Context Generation

    /// Generate a structured context string for AI prompts.
    /// Includes both entity names and their descriptions/facts when available.
    public func contextString() -> String? {
        let identities = allNodes(type: .identity).filter { $0.confidence > 0.5 }.sorted { $0.confidence > $1.confidence }
        let projects = allNodes(type: .project).filter { $0.confidence > 0.5 }.sorted { $0.lastSeen > $1.lastSeen }
        let technologies = allNodes(type: .technology).filter { $0.confidence > 0.5 }
        let skills = allNodes(type: .skill).filter { $0.confidence > 0.5 }
        let topics = allNodes(type: .topic).filter { $0.confidence > 0.5 }

        guard !identities.isEmpty || !projects.isEmpty || !technologies.isEmpty || !skills.isEmpty || !topics.isEmpty else {
            return nil
        }

        var sections: [String] = []

        // Identity facts (personal background, role, etc.)
        if !identities.isEmpty {
            let identityFacts = identities.prefix(5).compactMap { node -> String? in
                // Prefer description if available, otherwise use name
                if let desc = node.properties["description"], !desc.isEmpty {
                    return desc
                }
                return node.name
            }
            if !identityFacts.isEmpty {
                sections.append("Identity:\n" + identityFacts.map { "- \($0)" }.joined(separator: "\n"))
            }
        }

        // Projects with descriptions
        if !projects.isEmpty {
            var projectLines: [String] = []
            for project in projects.prefix(5) {
                if let desc = project.properties["description"], !desc.isEmpty {
                    projectLines.append("- \(project.name): \(desc)")
                } else {
                    projectLines.append("- \(project.name)")
                }
            }
            sections.append("Projects:\n" + projectLines.joined(separator: "\n"))
        }

        // Technologies
        if !technologies.isEmpty {
            sections.append("Technologies: \(technologies.map(\.name).joined(separator: ", "))")
        }

        // Skills with descriptions
        if !skills.isEmpty {
            var skillLines: [String] = []
            for skill in skills.prefix(8) {
                if let desc = skill.properties["description"], !desc.isEmpty {
                    skillLines.append("- \(skill.name): \(desc)")
                } else {
                    skillLines.append("- \(skill.name)")
                }
            }
            sections.append("Skills:\n" + skillLines.joined(separator: "\n"))
        }

        // Topics/interests
        if !topics.isEmpty {
            sections.append("Interests: \(topics.map(\.name).joined(separator: ", "))")
        }

        // Add tech stack relationships
        let usesEdges = allEdges().filter { $0.type == .uses && $0.confidence > 0.6 }
        if !usesEdges.isEmpty {
            var relationships: [String] = []
            for edge in usesEdges.prefix(10) {
                if let source = node(id: edge.sourceId), let target = node(id: edge.targetId) {
                    relationships.append("\(source.name) uses \(target.name)")
                }
            }
            if !relationships.isEmpty {
                sections.append("Tech stack: \(relationships.joined(separator: "; "))")
            }
        }

        return sections.isEmpty ? nil : sections.joined(separator: "\n")
    }

    /// Generate a synthesized profile paragraph from graph nodes.
    /// Similar to ProfileSynthesizer but works directly from graph data.
    public func synthesizedProfile(using geminiClient: GeminiClient) async -> String? {
        guard let context = contextString() else { return nil }

        let prompt = """
        Synthesize the following facts about a person into a concise profile paragraph \
        (3-6 sentences). The profile should read naturally as a coherent description of who this \
        person is, what they work on, and how they work.

        Facts:
        \(context)

        Write in third person, present tense. Be specific — use actual project names, technologies, \
        and tools mentioned in the facts. Do not pad with generic statements. \
        Return ONLY the profile paragraph text, nothing else.
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
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            Logger.debug("Graph profile synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get a summary of the graph for UI display.
    public func graphSummary() -> GraphSummary {
        let nodes = allNodes()
        let edges = allEdges()

        let identityCount = nodes.filter { $0.type == .identity }.count
        let projectCount = nodes.filter { $0.type == .project }.count
        let techCount = nodes.filter { $0.type == .technology }.count
        let skillCount = nodes.filter { $0.type == .skill }.count
        let topicCount = nodes.filter { $0.type == .topic }.count

        return GraphSummary(
            totalNodes: nodes.count,
            totalEdges: edges.count,
            identityCount: identityCount,
            projectCount: projectCount,
            technologyCount: techCount,
            skillCount: skillCount,
            topicCount: topicCount
        )
    }
}

// MARK: - Supporting Types

public struct GraphSummary: Sendable {
    public let totalNodes: Int
    public let totalEdges: Int
    public let identityCount: Int
    public let projectCount: Int
    public let technologyCount: Int
    public let skillCount: Int
    public let topicCount: Int
}

public enum KnowledgeGraphError: Error, LocalizedError {
    case nodeNotFound(UUID)
    case invalidMerge(String)

    public var errorDescription: String? {
        switch self {
        case .nodeNotFound(let id): return "Node not found: \(id)"
        case .invalidMerge(let reason): return "Invalid merge: \(reason)"
        }
    }
}
