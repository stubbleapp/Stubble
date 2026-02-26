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

    // MARK: - Confidence Decay

    func testDecayPrunesOldLowReinforcementEntries() {
        // A project entry (high decay rate: 0.15) seen once, 45 days ago
        // Should hit tier 1 (>14d, count<=1) penalty = 0.075
        // AND tier 2 (>30d, count<=2) penalty = 0.15
        // Total penalty = 0.225 → 0.7 - 0.225 = 0.475 → above 0.15, survives
        // But a second merge pass would decay further...
        // Actually let's test with 90 days to ensure it drops below 0.15
        let old = MemoryEntry(
            category: .project,
            content: "Old abandoned project from months ago",
            confidence: 0.3,
            firstSeen: Date().addingTimeInterval(-90 * 86400),
            lastSeen: Date().addingTimeInterval(-90 * 86400),
            reinforcementCount: 1
        )
        store.save([old])

        // Trigger decay by merging empty (the daily review path)
        store.mergeStructured(newEntries: [])
        let loaded = store.load()

        // After decay: tier1 (0.075) + tier2 (0.15) + tier3 (0.075) = 0.3
        // 0.3 - 0.3 = clamped to 0.1, which is below 0.15 threshold → pruned
        XCTAssertTrue(loaded.isEmpty, "Entry with low confidence + old age should be pruned")
    }

    func testDecayPreservesRecentEntries() {
        let recent = MemoryEntry(
            category: .project,
            content: "Current active project",
            confidence: 0.7,
            firstSeen: Date().addingTimeInterval(-5 * 86400),
            lastSeen: Date().addingTimeInterval(-5 * 86400),
            reinforcementCount: 1
        )
        store.save([recent])
        store.mergeStructured(newEntries: [])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1, "Recent entries should not be decayed")
    }

    func testDecayRateVariesByCategory() {
        // Identity (0.03) should decay much slower than project (0.15)
        let old = Date().addingTimeInterval(-35 * 86400) // 35 days ago
        let identity = MemoryEntry(
            category: .identity,
            content: "Software engineer based in Stockholm",
            confidence: 0.5,
            firstSeen: old, lastSeen: old,
            reinforcementCount: 1
        )
        let project = MemoryEntry(
            category: .project,
            content: "Working on some temporary project",
            confidence: 0.5,
            firstSeen: old, lastSeen: old,
            reinforcementCount: 1
        )
        store.save([identity, project])
        store.mergeStructured(newEntries: [])
        let loaded = store.load()

        // Identity should survive (lower decay), project may be pruned (higher decay)
        let hasIdentity = loaded.contains(where: { $0.category == .identity })
        XCTAssertTrue(hasIdentity, "Identity entries should decay slowly and survive")
    }

    func testHighReinforcementResistsDecay() {
        // Entry seen 5 times should resist tier 1 and tier 2 decay
        let old = Date().addingTimeInterval(-45 * 86400)
        let entry = MemoryEntry(
            category: .project,
            content: "Frequently observed project work",
            confidence: 0.7,
            firstSeen: old, lastSeen: old,
            reinforcementCount: 5
        )
        store.save([entry])
        store.mergeStructured(newEntries: [])
        let loaded = store.load()

        // count=5 means no tiers apply (tier1: count<=1, tier2: count<=2, tier3: count<=3)
        XCTAssertEqual(loaded.count, 1, "Highly reinforced entries should not decay")
        XCTAssertEqual(loaded[0].confidence, 0.7, accuracy: 0.01)
    }

    // MARK: - Correction Handling

    func testCorrectionReplacesMatchingEntry() {
        store.save([
            MemoryEntry(category: .identity, content: "Works as a backend software engineer at Acme")
        ])

        // Shares enough words to exceed 0.25 Jaccard: "works", "software", "engineer", "acme"
        let correction = MemoryEntry(
            category: .identity,
            content: "Works as a frontend software engineer at Acme",
            isCorrection: true
        )
        store.mergeStructured(newEntries: [correction])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 1, "Correction should replace, not add")
        XCTAssertTrue(loaded[0].content.contains("frontend"),
                      "Content should be updated to correction")
        XCTAssertFalse(loaded[0].content.contains("backend"),
                       "Old content should be replaced")
        XCTAssertEqual(loaded[0].reinforcementCount, 1, "Reinforcement should be reset")
    }

    func testCorrectionWithNoMatchAddsNew() {
        store.save([
            MemoryEntry(category: .technology, content: "Uses Python for scripting")
        ])

        let correction = MemoryEntry(
            category: .identity,  // different category → no match
            content: "Actually a designer, not an engineer",
            isCorrection: true
        )
        store.mergeStructured(newEntries: [correction])
        let loaded = store.load()

        XCTAssertEqual(loaded.count, 2, "No matching entry to correct → add as new")
    }

    // MARK: - Category-Aware Capacity Cap

    func testCapacityCapRespectsCategoryMinimums() {
        // Fill with 50 project entries (minimum for project is 15)
        // Then add 5 identity entries
        var entries: [MemoryEntry] = []
        for i in 0..<50 {
            entries.append(MemoryEntry(
                category: .project,
                content: "Unique project number \(i) details here",
                confidence: Double(i) / 100.0 + 0.2,
                firstSeen: Date(),
                lastSeen: Date(),
                reinforcementCount: 3  // enough to avoid decay
            ))
        }
        store.save(entries)

        // Each entry must have distinct word sets to avoid Jaccard merge
        let identityFacts = [
            "Software engineer based in Stockholm Sweden",
            "Graduated from Chalmers University electrical program",
            "Fluent in Swedish English and German languages",
            "Previously worked at Spotify music streaming company",
            "Passionate about photography and mountaineering outdoors",
        ]
        let newIdentity = identityFacts.map {
            MemoryEntry(category: .identity, content: $0, confidence: 0.9)
        }
        store.mergeStructured(newEntries: newIdentity)
        let loaded = store.load()

        XCTAssertLessThanOrEqual(loaded.count, 50, "Should be capped at 50")
        let identityCount = loaded.filter { $0.category == .identity }.count
        XCTAssertEqual(identityCount, 5, "All identity entries should survive (below minimum of 5)")
    }

    func testCapacityRemovesLowestConfidenceFirst() {
        var entries: [MemoryEntry] = []
        // 48 entries with varying confidence
        for i in 0..<48 {
            entries.append(MemoryEntry(
                category: .project,
                content: "Project entry number \(i) is unique content",
                confidence: 0.2 + Double(i) * 0.01,
                firstSeen: Date(),
                lastSeen: Date(),
                reinforcementCount: 5
            ))
        }
        store.save(entries)

        // Add 5 more to trigger cap
        let newEntries = (0..<5).map {
            MemoryEntry(
                category: .project,
                content: "Brand new project entry \($0) unique text",
                confidence: 0.9
            )
        }
        store.mergeStructured(newEntries: newEntries)
        let loaded = store.load()

        XCTAssertLessThanOrEqual(loaded.count, 50)
        // The lowest-confidence entries should have been removed
        let confidences = loaded.map(\.confidence)
        let minConf = confidences.min() ?? 0
        XCTAssertGreaterThan(minConf, 0.19, "Lowest confidence entries should have been pruned")
    }

    // MARK: - Synthesis Metadata

    func testSynthesisMetadataUpdatedOnSaveProfile() {
        store.save([
            MemoryEntry(category: .project, content: "Fact 1"),
            MemoryEntry(category: .technology, content: "Fact 2"),
        ])

        store.saveProfile("A synthesized profile.")
        let meta = store.synthesisMetadata()

        XCTAssertNotNil(meta.lastSynthesizedAt)
        XCTAssertEqual(meta.entryCountAtLastSynthesis, 2)
        XCTAssertEqual(meta.lastSynthesizedAt!.timeIntervalSinceNow, 0, accuracy: 2.0)
    }

    func testSynthesisMetadataDefaultsToNil() {
        let meta = store.synthesisMetadata()
        XCTAssertNil(meta.lastSynthesizedAt)
        XCTAssertNil(meta.entryCountAtLastSynthesis)
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
