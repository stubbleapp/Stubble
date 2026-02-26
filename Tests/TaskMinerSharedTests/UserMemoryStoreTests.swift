import XCTest
@testable import TaskMinerShared

final class UserMemoryStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: UserMemoryStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubbleTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = UserMemoryStore(filePath: tempDir.appendingPathComponent("memory.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Basic CRUD

    func testLoadEmptyReturnsEmptyArray() {
        let entries = store.load()
        XCTAssertTrue(entries.isEmpty)
    }

    func testSaveAndLoad() {
        let entries = [
            MemoryEntry(category: .project, content: "Building a macOS app called Stubble"),
            MemoryEntry(category: .technology, content: "Uses Swift and SQLite"),
        ]

        store.save(entries)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].content, "Building a macOS app called Stubble")
        XCTAssertEqual(loaded[0].category, .project)
        XCTAssertEqual(loaded[1].content, "Uses Swift and SQLite")
        XCTAssertEqual(loaded[1].category, .technology)
    }

    func testSavePreservesIDs() {
        let id = UUID()
        let entries = [MemoryEntry(id: id, category: .workflow, content: "Test")]

        store.save(entries)
        let loaded = store.load()

        XCTAssertEqual(loaded[0].id, id)
    }

    func testSavePreservesFirstSeenDate() {
        let date = Date().addingTimeInterval(-86400)
        let entries = [MemoryEntry(category: .identity, content: "Old fact", firstSeen: date, lastSeen: date)]

        store.save(entries)
        let loaded = store.load()

        XCTAssertEqual(loaded[0].firstSeen.timeIntervalSince1970,
                       date.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - Structured Merge

    func testMergeAddsNewEntries() {
        store.save([MemoryEntry(category: .project, content: "Existing project")])

        store.mergeStructured(newEntries: [
            MemoryEntry(category: .technology, content: "New technology fact")
        ])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains(where: { $0.content == "Existing project" }))
        XCTAssertTrue(loaded.contains(where: { $0.content == "New technology fact" }))
    }

    func testMergeReinforcesMatchingEntry() {
        store.save([MemoryEntry(category: .project, content: "Building Stubble macOS activity tracker")])

        store.mergeStructured(newEntries: [
            MemoryEntry(category: .project, content: "Building Stubble macOS desktop tracker")
        ])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1, "Should reinforce existing, not add duplicate")
        XCTAssertEqual(loaded[0].reinforcementCount, 2)
    }

    func testMergeDifferentCategoryNotReinforced() {
        store.save([MemoryEntry(category: .project, content: "Building Stubble")])

        store.mergeStructured(newEntries: [
            MemoryEntry(category: .technology, content: "Building Stubble")
        ])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2, "Different categories should not match")
    }

    func testMergeSkipsEmptyAndWhitespace() {
        store.save([])

        store.mergeStructured(newEntries: [
            MemoryEntry(category: .workflow, content: ""),
            MemoryEntry(category: .workflow, content: "   "),
            MemoryEntry(category: .workflow, content: "Valid entry"),
        ])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "Valid entry")
    }

    func testMergeCapsAt50() {
        let existing = (0..<48).map { MemoryEntry(category: .project, content: "Alpha project number \($0) details", confidence: 0.8) }
        store.save(existing)

        let newEntries = (0..<5).map { MemoryEntry(category: .technology, content: "Brand unique technology entry \($0)", confidence: 0.9) }
        store.mergeStructured(newEntries: newEntries)

        let loaded = store.load()
        XCTAssertLessThanOrEqual(loaded.count, 50, "Should be capped at 50")
        XCTAssertGreaterThan(loaded.count, 48, "New entries should have been added")
    }

    // MARK: - Legacy Merge (backward compat)

    func testLegacyMergeStillWorks() {
        store.save([MemoryEntry(category: .workflow, content: "Existing fact")])

        store.merge(newEntries: ["New fact"])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains(where: { $0.content == "New fact" }))
    }

    // MARK: - Delete

    func testDeleteRemovesEntry() {
        let id = UUID()
        store.save([
            MemoryEntry(id: id, category: .workflow, content: "To delete"),
            MemoryEntry(category: .workflow, content: "To keep"),
        ])

        store.delete(id: id)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "To keep")
    }

    func testDeleteNonexistentIDNoOp() {
        store.save([MemoryEntry(category: .workflow, content: "Existing")])

        store.delete(id: UUID())
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1, "Deleting nonexistent ID should not affect existing entries")
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        store.save([
            MemoryEntry(category: .project, content: "Fact 1"),
            MemoryEntry(category: .technology, content: "Fact 2"),
        ])

        store.clear()
        let loaded = store.load()

        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Profile

    func testSaveAndLoadProfile() {
        store.saveProfile("A software developer building Stubble.")
        let profile = store.loadProfile()
        XCTAssertEqual(profile, "A software developer building Stubble.")
    }

    func testContextStringPrefersProfile() {
        store.save([MemoryEntry(category: .workflow, content: "Some fact")])
        store.saveProfile("Synthesized profile text.")

        let context = store.contextString()
        XCTAssertEqual(context, "Synthesized profile text.")
    }

    func testContextStringFallsThroughToEntries() {
        store.save([
            MemoryEntry(category: .project, content: "Builds macOS apps"),
            MemoryEntry(category: .technology, content: "Uses Swift"),
        ])

        let context = store.contextString()
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("Builds macOS apps"))
        XCTAssertTrue(context!.contains("Uses Swift"))
    }

    func testContextStringEmptyReturnsNil() {
        let context = store.contextString()
        XCTAssertNil(context)
    }

    // MARK: - Legacy Migration

    func testLegacyFormatMigration() {
        let legacyJSON = """
        [
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "content": "Building a macOS app",
            "learnedAt": "2025-01-15T10:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try! legacyJSON.write(to: tempDir.appendingPathComponent("memory.json"))

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "Building a macOS app")
        XCTAssertEqual(loaded[0].category, .workflow)
        XCTAssertEqual(loaded[0].reinforcementCount, 1)
        XCTAssertEqual(loaded[0].source, .activityInference)
    }

    // MARK: - MemoryEntry

    func testMemoryEntryDefaultInit() {
        let entry = MemoryEntry(content: "Test")
        XCTAssertNotNil(entry.id)
        XCTAssertEqual(entry.content, "Test")
        XCTAssertEqual(entry.category, .workflow)
        XCTAssertEqual(entry.reinforcementCount, 1)
        XCTAssertEqual(entry.source, .activityInference)
        XCTAssertEqual(entry.firstSeen.timeIntervalSinceNow, 0, accuracy: 2.0)
    }

    func testMemoryEntryCodable() throws {
        let entry = MemoryEntry(category: .project, content: "Test fact", confidence: 0.9)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MemoryEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.content, entry.content)
        XCTAssertEqual(decoded.category, .project)
        XCTAssertEqual(decoded.confidence, 0.9)
    }
}
