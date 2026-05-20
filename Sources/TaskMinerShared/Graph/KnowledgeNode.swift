import Foundation

// MARK: - Node Types

/// The type of entity a knowledge node represents.
public enum NodeType: String, Codable, CaseIterable, Sendable {
    case identity     // Personal facts: name, role, company, background
    case project      // Active projects the user works on
    case technology   // Languages, frameworks, tools, platforms
    case skill        // Capabilities like debugging, API design, ML
    case topic        // Areas of interest or expertise
    // Future: person, organization, resource
}

// MARK: - Knowledge Node

/// A single entity in the knowledge graph representing something the user
/// works with, knows about, or is interested in.
public struct KnowledgeNode: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let type: NodeType
    public var name: String                    // Canonical name
    public var aliases: [String]               // Alternative names (e.g., "JS" → "JavaScript")
    public var confidence: Double              // 0-1
    public var firstSeen: Date
    public var lastSeen: Date
    public var reinforcementCount: Int
    public var properties: [String: String]    // Type-specific metadata

    public init(
        id: UUID = UUID(),
        type: NodeType,
        name: String,
        aliases: [String] = [],
        confidence: Double = 0.7,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        reinforcementCount: Int = 1,
        properties: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.aliases = aliases
        self.confidence = min(1.0, max(0.0, confidence))
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.reinforcementCount = reinforcementCount
        self.properties = properties
    }

    // MARK: - Decay Rates

    /// Decay rate per node type — reflects how quickly facts in each category become stale.
    public static func decayRate(for type: NodeType) -> Double {
        switch type {
        case .identity:   return 0.03  // Identity rarely changes
        case .project:    return 0.15  // Projects wrap up / change often
        case .technology: return 0.08  // Tech stacks are stickier
        case .skill:      return 0.06  // Skills persist longer
        case .topic:      return 0.10  // Interests drift over time
        }
    }

    // MARK: - Property Accessors

    /// The sentence-form description/fact associated with this node.
    /// Stored in properties["description"].
    public var description: String? {
        get { properties["description"] }
        set {
            var props = properties
            props["description"] = newValue
            // Note: This creates a new instance since KnowledgeNode is a struct
        }
    }

    /// The source of this node (activityInference, chatInteraction, userExplicit).
    /// Stored in properties["source"].
    public var source: String? {
        properties["source"]
    }

    /// Create a node with a description (convenience initializer).
    public static func withDescription(
        type: NodeType,
        name: String,
        description: String,
        source: String = "activityInference",
        confidence: Double = 0.7
    ) -> KnowledgeNode {
        KnowledgeNode(
            type: type,
            name: name,
            confidence: confidence,
            properties: [
                "description": description,
                "source": source
            ]
        )
    }

    // MARK: - Matching

    /// Check if this node matches a given name (canonical or alias), case-insensitive.
    public func matches(name searchName: String) -> Bool {
        let lowered = searchName.lowercased()
        if name.lowercased() == lowered { return true }
        return aliases.contains { $0.lowercased() == lowered }
    }

    /// Compute Jaccard word overlap between this node's name and another string.
    public func wordOverlap(with other: String) -> Double {
        let selfWords = wordSet(name)
        let otherWords = wordSet(other)
        guard !selfWords.isEmpty && !otherWords.isEmpty else { return 0 }
        let intersection = selfWords.intersection(otherWords)
        let union = selfWords.union(otherWords)
        return Double(intersection.count) / Double(union.count)
    }

    private func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 })
    }
}

// MARK: - Codable Helpers

extension KnowledgeNode {
    enum CodingKeys: String, CodingKey {
        case id, type, name, aliases, confidence
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case reinforcementCount = "reinforcement_count"
        case properties
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(NodeType.self, forKey: .type)
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        confidence = try container.decode(Double.self, forKey: .confidence)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        reinforcementCount = try container.decodeIfPresent(Int.self, forKey: .reinforcementCount) ?? 1
        properties = try container.decodeIfPresent([String: String].self, forKey: .properties) ?? [:]
    }
}
