import XCTest
import SQLite3
@testable import TaskMinerShared

/// Tests for the KnowledgeGraph actor and related models.
final class KnowledgeGraphTests: XCTestCase {

    private var tempDir: URL!
    private var dbPath: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubbleGraphTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("test.db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    private func createDbReader() throws -> DatabaseReader {
        createBaseTables()
        return try DatabaseReader(path: dbPath)
    }

    private func createBaseTables() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        // Create minimal tables needed for schema migrations
        let sqls = [
            "CREATE TABLE IF NOT EXISTS activities (id INTEGER PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS screenshots (id INTEGER PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY)",
        ]
        for sql in sqls {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    // MARK: - KnowledgeNode Tests

    func testKnowledgeNodeMatching() {
        let node = KnowledgeNode(
            type: .technology,
            name: "JavaScript",
            aliases: ["JS", "ECMAScript"]
        )

        // Exact match
        XCTAssertTrue(node.matches(name: "JavaScript"))
        XCTAssertTrue(node.matches(name: "javascript"))  // Case insensitive

        // Alias match
        XCTAssertTrue(node.matches(name: "JS"))
        XCTAssertTrue(node.matches(name: "ECMAScript"))

        // No match
        XCTAssertFalse(node.matches(name: "TypeScript"))
    }

    func testKnowledgeNodeWordOverlap() {
        let node = KnowledgeNode(type: .project, name: "Stubble macOS App")

        // High overlap
        let overlap1 = node.wordOverlap(with: "Stubble macOS Application")
        XCTAssertGreaterThanOrEqual(overlap1, 0.5)

        // Low overlap
        let overlap2 = node.wordOverlap(with: "React Native Mobile")
        XCTAssertLessThan(overlap2, 0.3)
    }

    func testKnowledgeNodeDecayRates() {
        XCTAssertEqual(KnowledgeNode.decayRate(for: .project), 0.15)
        XCTAssertEqual(KnowledgeNode.decayRate(for: .technology), 0.08)
        XCTAssertEqual(KnowledgeNode.decayRate(for: .skill), 0.06)
        XCTAssertEqual(KnowledgeNode.decayRate(for: .topic), 0.10)
    }

    // MARK: - KnowledgeEdge Tests

    func testKnowledgeEdgeMatching() {
        let sourceId = UUID()
        let targetId = UUID()

        let edge = KnowledgeEdge(
            type: .uses,
            sourceId: sourceId,
            targetId: targetId
        )

        // Exact match
        XCTAssertTrue(edge.matches(type: .uses, source: sourceId, target: targetId))

        // Wrong type
        XCTAssertFalse(edge.matches(type: .requires, source: sourceId, target: targetId))

        // Wrong direction (for non-symmetric edge)
        XCTAssertFalse(edge.matches(type: .uses, source: targetId, target: sourceId))
    }

    func testKnowledgeEdgeSymmetricMatching() {
        let id1 = UUID()
        let id2 = UUID()

        let edge = KnowledgeEdge(
            type: .relatedTo,
            sourceId: id1,
            targetId: id2
        )

        // Both directions should match for relatedTo
        XCTAssertTrue(edge.matches(type: .relatedTo, source: id1, target: id2))
        XCTAssertTrue(edge.matches(type: .relatedTo, source: id2, target: id1))
    }

    // MARK: - Graph CRUD Tests

    @MainActor
    func testUpsertAndFindNode() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        let node = KnowledgeNode(
            type: .project,
            name: "TestProject",
            confidence: 0.8
        )

        await graph.upsertNode(node)

        let found = await graph.findNode(type: .project, nameOrAlias: "TestProject")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "TestProject")
        XCTAssertEqual(found?.type, .project)
    }

    @MainActor
    func testUpsertNodeReinforces() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        // First insert
        let node1 = KnowledgeNode(
            type: .technology,
            name: "Swift",
            confidence: 0.7
        )
        await graph.upsertNode(node1)

        // Second insert with same type+name should reinforce
        let node2 = KnowledgeNode(
            type: .technology,
            name: "Swift",
            confidence: 0.9
        )
        await graph.upsertNode(node2)

        let found = await graph.findNode(type: .technology, nameOrAlias: "Swift")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.reinforcementCount, 2)
        XCTAssertEqual(found?.confidence, 0.9)  // Takes max confidence
    }

    @MainActor
    func testUpsertNodeMergesAliases() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        // First insert with alias
        let node1 = KnowledgeNode(
            type: .technology,
            name: "JavaScript",
            aliases: ["JS"]
        )
        await graph.upsertNode(node1)

        // Second insert with different alias
        let node2 = KnowledgeNode(
            type: .technology,
            name: "JavaScript",
            aliases: ["ECMAScript"]
        )
        await graph.upsertNode(node2)

        let found = await graph.findNode(type: .technology, nameOrAlias: "JavaScript")
        XCTAssertNotNil(found)
        // Both aliases should be present
        XCTAssertTrue(found?.aliases.contains("JS") ?? false)
        XCTAssertTrue(found?.aliases.contains("ECMAScript") ?? false)
    }

    @MainActor
    func testAllNodes() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        await graph.upsertNode(KnowledgeNode(type: .project, name: "Project1"))
        await graph.upsertNode(KnowledgeNode(type: .technology, name: "Tech1"))
        await graph.upsertNode(KnowledgeNode(type: .project, name: "Project2"))

        let allNodes = await graph.allNodes()
        XCTAssertEqual(allNodes.count, 3)

        let projects = await graph.allNodes(type: .project)
        XCTAssertEqual(projects.count, 2)

        let tech = await graph.allNodes(type: .technology)
        XCTAssertEqual(tech.count, 1)
    }

    @MainActor
    func testDeleteNode() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        let node = KnowledgeNode(type: .project, name: "ToDelete")
        await graph.upsertNode(node)

        var found = await graph.findNode(type: .project, nameOrAlias: "ToDelete")
        XCTAssertNotNil(found)

        await graph.deleteNode(id: node.id)

        found = await graph.findNode(type: .project, nameOrAlias: "ToDelete")
        XCTAssertNil(found)
    }

    // MARK: - Edge Tests

    @MainActor
    func testUpsertAndQueryEdges() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        let project = KnowledgeNode(type: .project, name: "MyApp")
        let tech = KnowledgeNode(type: .technology, name: "Swift")
        await graph.upsertNode(project)
        await graph.upsertNode(tech)

        let edge = KnowledgeEdge(
            type: .uses,
            sourceId: project.id,
            targetId: tech.id,
            confidence: 0.9
        )
        await graph.upsertEdge(edge)

        let outEdges = await graph.edges(from: project.id)
        XCTAssertEqual(outEdges.count, 1)
        XCTAssertEqual(outEdges.first?.type, .uses)

        let inEdges = await graph.edges(to: tech.id)
        XCTAssertEqual(inEdges.count, 1)
    }

    @MainActor
    func testRelatedNodes() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        let project = KnowledgeNode(type: .project, name: "MyApp")
        let swift = KnowledgeNode(type: .technology, name: "Swift")
        let sqlite = KnowledgeNode(type: .technology, name: "SQLite")
        await graph.upsertNode(project)
        await graph.upsertNode(swift)
        await graph.upsertNode(sqlite)

        await graph.upsertEdge(KnowledgeEdge(type: .uses, sourceId: project.id, targetId: swift.id))
        await graph.upsertEdge(KnowledgeEdge(type: .uses, sourceId: project.id, targetId: sqlite.id))

        let related = await graph.relatedNodes(to: project.id, edgeTypes: [.uses])
        XCTAssertEqual(related.count, 2)
        let names = Set(related.map(\.name))
        XCTAssertTrue(names.contains("Swift"))
        XCTAssertTrue(names.contains("SQLite"))
    }

    // MARK: - Context String Tests

    @MainActor
    func testContextString() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        await graph.upsertNode(KnowledgeNode(type: .project, name: "Stubble", confidence: 0.9))
        await graph.upsertNode(KnowledgeNode(type: .technology, name: "Swift", confidence: 0.9))
        await graph.upsertNode(KnowledgeNode(type: .skill, name: "API Design", confidence: 0.8))
        await graph.upsertNode(KnowledgeNode(type: .topic, name: "Distributed Systems", confidence: 0.7))

        let context = await graph.contextString()
        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("Stubble") ?? false)
        XCTAssertTrue(context?.contains("Swift") ?? false)
        XCTAssertTrue(context?.contains("API Design") ?? false)
        XCTAssertTrue(context?.contains("Distributed Systems") ?? false)
    }

    @MainActor
    func testContextStringFiltersLowConfidence() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        await graph.upsertNode(KnowledgeNode(type: .project, name: "HighConf", confidence: 0.9))
        await graph.upsertNode(KnowledgeNode(type: .project, name: "LowConf", confidence: 0.3))

        let context = await graph.contextString()
        XCTAssertTrue(context?.contains("HighConf") ?? false)
        XCTAssertFalse(context?.contains("LowConf") ?? true)
    }

    // MARK: - Graph Summary Tests

    @MainActor
    func testGraphSummary() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        await graph.upsertNode(KnowledgeNode(type: .project, name: "P1"))
        await graph.upsertNode(KnowledgeNode(type: .project, name: "P2"))
        await graph.upsertNode(KnowledgeNode(type: .technology, name: "T1"))
        await graph.upsertNode(KnowledgeNode(type: .skill, name: "S1"))

        let summary = await graph.graphSummary()
        XCTAssertEqual(summary.totalNodes, 4)
        XCTAssertEqual(summary.projectCount, 2)
        XCTAssertEqual(summary.technologyCount, 1)
        XCTAssertEqual(summary.skillCount, 1)
        XCTAssertEqual(summary.topicCount, 0)
    }

    // MARK: - Decay and Pruning Tests

    @MainActor
    func testPruneRemovesLowConfidenceNodes() async throws {
        let dbReader = try createDbReader()
        let graph = KnowledgeGraph(dbReader: dbReader)

        await graph.upsertNode(KnowledgeNode(type: .project, name: "HighConf", confidence: 0.9))
        await graph.upsertNode(KnowledgeNode(type: .project, name: "LowConf", confidence: 0.1))

        let pruned = await graph.prune(belowConfidence: 0.15)
        XCTAssertEqual(pruned, 1)

        let remaining = await graph.allNodes()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.name, "HighConf")
    }
}

// MARK: - GraphMigration Tests

final class GraphMigrationTests: XCTestCase {

    private var tempDir: URL!
    private var memoryPath: URL!
    private var dbPath: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubbleMigrationTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        memoryPath = tempDir.appendingPathComponent("memory.json")
        dbPath = tempDir.appendingPathComponent("test.db")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func createBaseTables() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let sqls = [
            "CREATE TABLE IF NOT EXISTS activities (id INTEGER PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS screenshots (id INTEGER PRIMARY KEY)",
            "CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY)",
        ]
        for sql in sqls {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    @MainActor
    func testMigrationSkipsIfNoMemoryFile() async throws {
        createBaseTables()
        let dbReader = try DatabaseReader(path: dbPath)

        let result = GraphMigration.migrateIfNeeded(memoryPath: memoryPath, store: dbReader)
        XCTAssertNil(result)
    }

    @MainActor
    func testMigrationConvertsMemoryEntries() async throws {
        // Create memory.json with entries
        let store = UserMemoryStore(filePath: memoryPath)
        store.save([
            MemoryEntry(category: .project, content: "Building Stubble macOS app"),
            MemoryEntry(category: .technology, content: "Uses Swift and SwiftUI"),
            MemoryEntry(category: .workflow, content: "Prefers test-driven development"),
            MemoryEntry(category: .interest, content: "Interested in distributed systems"),
        ])

        createBaseTables()
        let dbReader = try DatabaseReader(path: dbPath)

        let result = GraphMigration.migrateIfNeeded(memoryPath: memoryPath, store: dbReader)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result ?? 0, 0)

        // Verify nodes were created
        let nodes = dbReader.knowledgeNodes()
        XCTAssertFalse(nodes.isEmpty)
    }

    @MainActor
    func testMigrationCreatesBackup() async throws {
        let store = UserMemoryStore(filePath: memoryPath)
        store.save([MemoryEntry(category: .project, content: "Test project")])

        createBaseTables()
        let dbReader = try DatabaseReader(path: dbPath)

        _ = GraphMigration.migrateIfNeeded(memoryPath: memoryPath, store: dbReader)

        let backupPath = memoryPath.deletingLastPathComponent().appendingPathComponent("memory.json.backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath.path))
    }

    @MainActor
    func testMigrationSkipsIfGraphAlreadyPopulated() async throws {
        let store = UserMemoryStore(filePath: memoryPath)
        store.save([MemoryEntry(category: .project, content: "Test")])

        createBaseTables()
        let dbReader = try DatabaseReader(path: dbPath)

        // First migration
        let result1 = GraphMigration.migrateIfNeeded(memoryPath: memoryPath, store: dbReader)
        XCTAssertNotNil(result1)

        // Second migration should skip
        let result2 = GraphMigration.migrateIfNeeded(memoryPath: memoryPath, store: dbReader)
        XCTAssertNil(result2)
    }
}

// MARK: - GraphExtractionResult Tests

final class GraphExtractionResultTests: XCTestCase {

    func testIsEmptyWhenNoNodesOrEdges() {
        let result = GraphExtractionResult()
        XCTAssertTrue(result.isEmpty)
    }

    func testIsNotEmptyWithNodes() {
        let result = GraphExtractionResult(
            nodes: [KnowledgeNode(type: .project, name: "Test")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testIsNotEmptyWithEdges() {
        let result = GraphExtractionResult(
            edges: [KnowledgeEdge(type: .uses, sourceId: UUID(), targetId: UUID())]
        )
        XCTAssertFalse(result.isEmpty)
    }
}

// MARK: - NodeValidator Tests

final class NodeValidatorTests: XCTestCase {

    // MARK: - Minimum Length Tests

    func testRejectsShortNames() {
        // Less than 4 characters should be rejected
        XCTAssertFalse(NodeValidator.isValidName("API", type: .technology))
        XCTAssertFalse(NodeValidator.isValidName("JS", type: .technology))
        XCTAssertFalse(NodeValidator.isValidName("Sam", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("UI", type: .topic))
    }

    func testAcceptsValidLengthNames() {
        XCTAssertTrue(NodeValidator.isValidName("Swift", type: .technology))
        XCTAssertTrue(NodeValidator.isValidName("Python", type: .technology))
        XCTAssertTrue(NodeValidator.isValidName("React Native", type: .technology))
    }

    // MARK: - Blocked Terms Tests

    func testRejectsBlockedTerms() {
        // Short abbreviations
        XCTAssertFalse(NodeValidator.isValidName("code", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("test", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("file", type: .skill))

        // Common first names
        XCTAssertFalse(NodeValidator.isValidName("mike", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("dave", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("john", type: .skill))

        // App names
        XCTAssertFalse(NodeValidator.isValidName("xcode", type: .technology))
        XCTAssertFalse(NodeValidator.isValidName("slack", type: .technology))
    }

    func testBlockedTermsCaseInsensitive() {
        XCTAssertFalse(NodeValidator.isValidName("SAM", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("Code", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("TEST", type: .skill))
    }

    // MARK: - All-Caps Acronym Tests

    func testRejectsShortAllCapsAcronyms() {
        XCTAssertFalse(NodeValidator.isValidName("SAM", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("API", type: .technology))
        XCTAssertFalse(NodeValidator.isValidName("IDE", type: .technology))
        XCTAssertFalse(NodeValidator.isValidName("SQL", type: .technology))
    }

    func testAcceptsLongerNames() {
        XCTAssertTrue(NodeValidator.isValidName("GRAPHQL", type: .technology))
        XCTAssertTrue(NodeValidator.isValidName("SwiftUI", type: .technology))
    }

    // MARK: - Skill-Specific Tests

    func testSkillsRequireSubstance() {
        // Single short words rejected
        XCTAssertFalse(NodeValidator.isValidName("Debug", type: .skill))
        XCTAssertFalse(NodeValidator.isValidName("Build", type: .skill))

        // Multi-word skills accepted
        XCTAssertTrue(NodeValidator.isValidName("API Design", type: .skill))
        XCTAssertTrue(NodeValidator.isValidName("Performance Tuning", type: .skill))
        XCTAssertTrue(NodeValidator.isValidName("Database Optimization", type: .skill))

        // Single words with 6+ chars accepted
        XCTAssertTrue(NodeValidator.isValidName("Design", type: .skill))
        XCTAssertTrue(NodeValidator.isValidName("Testing", type: .skill))
    }

    // MARK: - Topic-Specific Tests

    func testTopicsRequireSubstance() {
        // Very short single words rejected
        XCTAssertFalse(NodeValidator.isValidName("News", type: .topic))

        // Longer single words or multi-word accepted
        XCTAssertTrue(NodeValidator.isValidName("Machine Learning", type: .topic))
        XCTAssertTrue(NodeValidator.isValidName("Security", type: .topic))
        XCTAssertTrue(NodeValidator.isValidName("iOS Development", type: .topic))
    }

    // MARK: - Project and Technology Tests

    func testProjectsMoreLenient() {
        // Projects can be single words if 4+ chars
        XCTAssertTrue(NodeValidator.isValidName("Stubble", type: .project))
        XCTAssertTrue(NodeValidator.isValidName("Rails", type: .project))
    }

    func testTechnologiesAcceptValidNames() {
        XCTAssertTrue(NodeValidator.isValidName("PostgreSQL", type: .technology))
        XCTAssertTrue(NodeValidator.isValidName("TypeScript", type: .technology))
        XCTAssertTrue(NodeValidator.isValidName("Kubernetes", type: .technology))
    }

    // MARK: - Identity Type Tests

    func testIdentityNodesAllowSentences() {
        // Identity nodes can be longer sentence-form facts
        XCTAssertTrue(NodeValidator.isValidName("Senior Engineer", type: .identity))
        XCTAssertTrue(NodeValidator.isValidName("Works as a developer at Acme Corp", type: .identity))
        XCTAssertTrue(NodeValidator.isValidName("iOS Developer", type: .identity))
    }

    func testIdentityNodesStillRequireMinLength() {
        // But still need at least 4 chars
        XCTAssertFalse(NodeValidator.isValidName("CEO", type: .identity))
        XCTAssertFalse(NodeValidator.isValidName("Dev", type: .identity))
    }

    // MARK: - Edge Cases

    func testRejectsPureNumbers() {
        XCTAssertFalse(NodeValidator.isValidName("12345", type: .project))
        XCTAssertFalse(NodeValidator.isValidName("1.2.3", type: .technology))
    }

    func testHandlesWhitespace() {
        XCTAssertTrue(NodeValidator.isValidName("  Swift  ", type: .technology))
        XCTAssertFalse(NodeValidator.isValidName("   ", type: .technology))
    }
}
