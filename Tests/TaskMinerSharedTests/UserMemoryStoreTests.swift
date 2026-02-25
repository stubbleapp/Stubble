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
            MemoryEntry(content: "Building a macOS app called Stubble"),
            MemoryEntry(content: "Uses Swift and SQLite"),
        ]

        store.save(entries)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].content, "Building a macOS app called Stubble")
        XCTAssertEqual(loaded[1].content, "Uses Swift and SQLite")
    }

    func testSavePreservesIDs() {
        let id = UUID()
        let entries = [MemoryEntry(id: id, content: "Test")]

        store.save(entries)
        let loaded = store.load()

        XCTAssertEqual(loaded[0].id, id)
    }

    func testSavePreservesLearnedAtDate() {
        let date = Date().addingTimeInterval(-86400)
        let entries = [MemoryEntry(content: "Old fact", learnedAt: date)]

        store.save(entries)
        let loaded = store.load()

        XCTAssertEqual(loaded[0].learnedAt.timeIntervalSince1970,
                       date.timeIntervalSince1970, accuracy: 1.0)
    }

    // MARK: - Merge

    func testMergeAddsNewEntries() {
        store.save([MemoryEntry(content: "Existing fact")])

        store.merge(newEntries: ["New fact"])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2)
        XCTAssertTrue(loaded.contains(where: { $0.content == "Existing fact" }))
        XCTAssertTrue(loaded.contains(where: { $0.content == "New fact" }))
    }

    func testMergeDeduplicatesCaseInsensitive() {
        store.save([MemoryEntry(content: "Uses Swift and SQLite")])

        store.merge(newEntries: ["uses swift and sqlite"])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1, "Duplicate (case-insensitive) should not be added")
    }

    func testMergeSkipsEmptyAndWhitespace() {
        store.save([])

        store.merge(newEntries: ["", "   ", "\n", "Valid entry"])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "Valid entry")
    }

    func testMergeTrimsWhitespace() {
        store.save([])

        store.merge(newEntries: ["  Fact with spaces  "])
        let loaded = store.load()

        XCTAssertEqual(loaded[0].content, "Fact with spaces")
    }

    func testMergeCapsAt50() {
        // Pre-fill with 48 entries
        let existing = (0..<48).map { MemoryEntry(content: "Fact \($0)") }
        store.save(existing)

        // Merge 5 more
        store.merge(newEntries: ["New 1", "New 2", "New 3", "New 4", "New 5"])

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 50, "Should be capped at 50")

        // The newest entries should be present (they're at the end)
        XCTAssertTrue(loaded.contains(where: { $0.content == "New 5" }))
    }

    func testMergeDropsOldestWhenOverCap() {
        let existing = (0..<50).map { MemoryEntry(content: "Old \($0)") }
        store.save(existing)

        store.merge(newEntries: ["Brand new fact"])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 50)
        // Oldest should have been dropped
        XCTAssertFalse(loaded.contains(where: { $0.content == "Old 0" }))
        XCTAssertTrue(loaded.contains(where: { $0.content == "Brand new fact" }))
    }

    // MARK: - Delete

    func testDeleteRemovesEntry() {
        let id = UUID()
        store.save([
            MemoryEntry(id: id, content: "To delete"),
            MemoryEntry(content: "To keep"),
        ])

        store.delete(id: id)
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].content, "To keep")
    }

    func testDeleteNonexistentIDNoOp() {
        store.save([MemoryEntry(content: "Existing")])

        store.delete(id: UUID())
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1, "Deleting nonexistent ID should not affect existing entries")
    }

    // MARK: - Clear

    func testClearRemovesAll() {
        store.save([
            MemoryEntry(content: "Fact 1"),
            MemoryEntry(content: "Fact 2"),
        ])

        store.clear()
        let loaded = store.load()

        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - contextString

    func testContextStringWithEntries() {
        store.save([
            MemoryEntry(content: "Builds macOS apps"),
            MemoryEntry(content: "Uses Swift"),
        ])

        let context = store.contextString()
        XCTAssertNotNil(context)
        XCTAssertTrue(context!.contains("- Builds macOS apps"))
        XCTAssertTrue(context!.contains("- Uses Swift"))
    }

    func testContextStringEmptyReturnsNil() {
        let context = store.contextString()
        XCTAssertNil(context)
    }

    // MARK: - MemoryEntry

    func testMemoryEntryDefaultInit() {
        let entry = MemoryEntry(content: "Test")
        XCTAssertNotNil(entry.id)
        XCTAssertEqual(entry.content, "Test")
        // learnedAt should be approximately now
        XCTAssertEqual(entry.learnedAt.timeIntervalSinceNow, 0, accuracy: 2.0)
    }

    func testMemoryEntryCodable() throws {
        let entry = MemoryEntry(content: "Test fact", learnedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MemoryEntry.self, from: data)

        XCTAssertEqual(decoded.id, entry.id)
        XCTAssertEqual(decoded.content, entry.content)
    }
}
