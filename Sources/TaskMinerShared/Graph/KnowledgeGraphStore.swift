import Foundation

/// Protocol for storage backends that can read/write knowledge graph data.
/// Conformers: DatabaseReader (dashboard), DatabaseManager (daemon)
/// Note: Not marked @MainActor to avoid forcing conforming types to be main-actor isolated.
/// The KnowledgeGraph class is @MainActor and handles isolation for external callers.
public protocol KnowledgeGraphStore: AnyObject {
    func knowledgeNodes(type: NodeType?) -> [KnowledgeNode]
    func knowledgeNode(type: NodeType, name: String) -> KnowledgeNode?
    func knowledgeNode(id: UUID) -> KnowledgeNode?
    func knowledgeEdges(from sourceId: UUID?, to targetId: UUID?) -> [KnowledgeEdge]
    func knowledgeEdge(type: EdgeType, source: UUID, target: UUID) -> KnowledgeEdge?
    func upsertKnowledgeNode(_ node: KnowledgeNode)
    func upsertKnowledgeEdge(_ edge: KnowledgeEdge)
    func deleteKnowledgeNode(id: UUID)
    func deleteKnowledgeEdge(id: UUID)
    func updateKnowledgeNodeConfidence(id: UUID, confidence: Double)
    func updateKnowledgeEdgeConfidence(id: UUID, confidence: Double)
    func pruneKnowledgeNodes(belowConfidence threshold: Double) -> Int
    func pruneKnowledgeEdges(belowConfidence threshold: Double) -> Int
    func knowledgeNodeCount() -> Int
}
