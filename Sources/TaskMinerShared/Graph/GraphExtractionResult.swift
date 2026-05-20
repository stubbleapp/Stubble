import Foundation

/// Result of extracting knowledge graph updates from activity or chat.
public struct GraphExtractionResult: Sendable {
    public let nodes: [KnowledgeNode]
    public let edges: [KnowledgeEdge]

    public init(nodes: [KnowledgeNode] = [], edges: [KnowledgeEdge] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    public var isEmpty: Bool {
        nodes.isEmpty && edges.isEmpty
    }
}

/// Raw node data from AI response (before creating KnowledgeNode with UUID).
public struct RawNodeData: Sendable {
    public let type: NodeType
    public let name: String
    public let confidence: Double
    public let aliases: [String]

    public init(type: NodeType, name: String, confidence: Double = 0.7, aliases: [String] = []) {
        self.type = type
        self.name = name
        self.confidence = confidence
        self.aliases = aliases
    }
}

/// Raw edge data from AI response (before resolving node UUIDs).
public struct RawEdgeData: Sendable {
    public let type: EdgeType
    public let sourceName: String      // Name of source node
    public let sourceType: NodeType    // Type of source node
    public let targetName: String      // Name of target node
    public let targetType: NodeType    // Type of target node
    public let confidence: Double
    public let context: String?

    public init(
        type: EdgeType,
        sourceName: String,
        sourceType: NodeType,
        targetName: String,
        targetType: NodeType,
        confidence: Double = 0.7,
        context: String? = nil
    ) {
        self.type = type
        self.sourceName = sourceName
        self.sourceType = sourceType
        self.targetName = targetName
        self.targetType = targetType
        self.confidence = confidence
        self.context = context
    }
}
