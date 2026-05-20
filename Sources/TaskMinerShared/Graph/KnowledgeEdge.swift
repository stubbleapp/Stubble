import Foundation

// MARK: - Edge Types

/// The type of relationship an edge represents between two nodes.
public enum EdgeType: String, Codable, CaseIterable, Sendable {
    case uses           // project → technology ("Stubble uses Swift")
    case requires       // project → skill ("Stubble requires macOS expertise")
    case relatedTo      // any → any, bidirectional similarity
    case interestedIn   // implicit user → topic (stored as edge from "self" node)
    // Future: dependsOn, partOf, worksAt
}

// MARK: - Knowledge Edge

/// A directed relationship between two nodes in the knowledge graph.
public struct KnowledgeEdge: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let type: EdgeType
    public let sourceId: UUID
    public let targetId: UUID
    public var confidence: Double
    public var firstSeen: Date
    public var lastSeen: Date
    public var reinforcementCount: Int
    public var context: String?  // Optional context about the relationship

    public init(
        id: UUID = UUID(),
        type: EdgeType,
        sourceId: UUID,
        targetId: UUID,
        confidence: Double = 0.7,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        reinforcementCount: Int = 1,
        context: String? = nil
    ) {
        self.id = id
        self.type = type
        self.sourceId = sourceId
        self.targetId = targetId
        self.confidence = min(1.0, max(0.0, confidence))
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.reinforcementCount = reinforcementCount
        self.context = context
    }

    /// Returns true if this edge connects the same nodes with the same type (ignoring direction for relatedTo).
    public func matches(type edgeType: EdgeType, source: UUID, target: UUID) -> Bool {
        guard self.type == edgeType else { return false }
        if edgeType == .relatedTo {
            // Bidirectional — matches if either direction
            return (sourceId == source && targetId == target) ||
                   (sourceId == target && targetId == source)
        }
        return sourceId == source && targetId == target
    }
}

// MARK: - Codable Helpers

extension KnowledgeEdge {
    enum CodingKeys: String, CodingKey {
        case id, type
        case sourceId = "source_id"
        case targetId = "target_id"
        case confidence
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case reinforcementCount = "reinforcement_count"
        case context
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(EdgeType.self, forKey: .type)
        sourceId = try container.decode(UUID.self, forKey: .sourceId)
        targetId = try container.decode(UUID.self, forKey: .targetId)
        confidence = try container.decode(Double.self, forKey: .confidence)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        reinforcementCount = try container.decodeIfPresent(Int.self, forKey: .reinforcementCount) ?? 1
        context = try container.decodeIfPresent(String.self, forKey: .context)
    }
}
