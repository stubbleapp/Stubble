import XCTest
@testable import TaskMinerShared

final class SettingsStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makePath(_ name: String = "settings.json") -> URL {
        tempDir.appendingPathComponent(name)
    }

    private func makeStore(_ name: String = "settings.json") -> SettingsStore {
        SettingsStore(filePath: makePath(name))
    }

    // MARK: - Load / Save Round Trip

    func testLoadReturnsDefaultsWhenFileDoesNotExist() {
        let store = makeStore()
        let settings = store.load()
        XCTAssertNil(settings.customPrompt)
        XCTAssertNil(settings.customPrompt)
        XCTAssertNil(settings.granularity)
        XCTAssertNil(settings.showScreensTab)
        XCTAssertNil(settings.hasCompletedSetup)
        XCTAssertNil(settings.launchAtLogin)
    }

    func testSaveAndLoadRoundTrip() {
        let store = makeStore()
        let original = AppSettings(
            customPrompt: "Focus on coding",
            granularity: .high,
            showScreensTab: true,
            hasCompletedSetup: true,
            launchAtLogin: false
        )
        XCTAssertTrue(store.save(original))

        // Force re-read from disk
        store.invalidateCache()
        let loaded = store.load()
        XCTAssertEqual(loaded, original)
    }

    func testSaveCreatesParentDirectory() {
        let nested = tempDir
            .appendingPathComponent("deep/nested/dir")
            .appendingPathComponent("settings.json")
        let store = SettingsStore(filePath: nested)
        let settings = AppSettings(customPrompt: "test")
        XCTAssertTrue(store.save(settings))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testSaveSetsRestrictedPermissions() {
        let store = makeStore()
        store.save(AppSettings(customPrompt: "secret"))
        let attrs = try? FileManager.default.attributesOfItem(atPath: makePath().path)
        let posix = attrs?[.posixPermissions] as? Int
        XCTAssertEqual(posix, 0o600, "File should have owner-only permissions")
    }

    // MARK: - Caching

    func testLoadUsesCache() {
        let store = makeStore()
        let settings = AppSettings(customPrompt: "key1")
        store.save(settings)

        // Overwrite file directly — the store should still return cached value
        let other = AppSettings(customPrompt: "key2")
        let data = try! JSONEncoder().encode(other)
        try! data.write(to: makePath())

        let loaded = store.load()
        XCTAssertEqual(loaded.customPrompt, "key1", "Should return cached value")
    }

    func testInvalidateCacheForcesReRead() {
        let store = makeStore()
        store.save(AppSettings(customPrompt: "key1"))

        // Overwrite file directly
        let other = AppSettings(customPrompt: "key2")
        let data = try! JSONEncoder().encode(other)
        try! data.write(to: makePath())

        store.invalidateCache()
        let loaded = store.load()
        XCTAssertEqual(loaded.customPrompt, "key2", "Should re-read from disk after cache invalidation")
    }

    // MARK: - Convenience Accessors

    func testGeminiApiKeyAccessor() {
        let store = makeStore()
        XCTAssertNil(store.customPrompt)
        store.customPrompt = "AIzaSyABC"
        XCTAssertEqual(store.customPrompt, "AIzaSyABC")
        store.customPrompt = nil
        XCTAssertNil(store.customPrompt)
    }

    func testCustomPromptAccessor() {
        let store = makeStore()
        XCTAssertNil(store.customPrompt)
        store.customPrompt = "Focus on coding only"
        XCTAssertEqual(store.customPrompt, "Focus on coding only")
    }

    func testGranularityAccessor() {
        let store = makeStore()
        XCTAssertEqual(store.granularity, .medium, "Default should be medium")
        store.granularity = .high
        XCTAssertEqual(store.granularity, .high)
        store.granularity = .low
        XCTAssertEqual(store.granularity, .low)
    }

    func testShowScreensTabAccessor() {
        let store = makeStore()
        XCTAssertFalse(store.showScreensTab, "Default should be false")
        store.showScreensTab = true
        XCTAssertTrue(store.showScreensTab)
    }

    func testHasCompletedSetupAccessor() {
        let store = makeStore()
        XCTAssertFalse(store.hasCompletedSetup, "Default should be false")
        store.hasCompletedSetup = true
        XCTAssertTrue(store.hasCompletedSetup)
    }

    func testLaunchAtLoginAccessor() {
        let store = makeStore()
        XCTAssertTrue(store.launchAtLogin, "Default should be true")
        store.launchAtLogin = false
        XCTAssertFalse(store.launchAtLogin)
    }

    // MARK: - Persistence Across Instances

    func testPersistenceAcrossInstances() {
        let path = makePath("shared.json")
        let store1 = SettingsStore(filePath: path)
        store1.customPrompt = "persistedPrompt"
        store1.granularity = .high

        let store2 = SettingsStore(filePath: path)
        XCTAssertEqual(store2.customPrompt, "persistedPrompt")
        XCTAssertEqual(store2.granularity, .high)
    }

    // MARK: - Codable Compatibility

    func testDecodesUnknownKeysGracefully() {
        // Simulate a settings file with extra keys (forward compatibility)
        let json = """
        {
            "customPrompt": "test123",
            "futureFeature": true,
            "anotherNewField": "value"
        }
        """
        try! json.data(using: .utf8)!.write(to: makePath())
        let store = makeStore()
        let settings = store.load()
        XCTAssertEqual(settings.customPrompt, "test123", "Known keys should decode fine")
    }

    func testDecodesEmptyJSON() {
        try! "{}".data(using: .utf8)!.write(to: makePath())
        let store = makeStore()
        let settings = store.load()
        XCTAssertEqual(settings, AppSettings(), "Empty JSON should produce defaults")
    }

    func testHandlesCorruptedFile() {
        try! "not valid json {{{{".data(using: .utf8)!.write(to: makePath())
        let store = makeStore()
        let settings = store.load()
        XCTAssertEqual(settings, AppSettings(), "Corrupted file should return defaults")
    }

    // MARK: - AppSettings Equatable

    func testAppSettingsEquatable() {
        let a = AppSettings(customPrompt: "test", granularity: .high)
        let b = AppSettings(customPrompt: "test", granularity: .high)
        let c = AppSettings(customPrompt: "different", granularity: .high)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testAppSettingsDefaultInit() {
        let settings = AppSettings()
        XCTAssertNil(settings.customPrompt)
        XCTAssertNil(settings.granularity)
        XCTAssertNil(settings.showScreensTab)
        XCTAssertNil(settings.hasCompletedSetup)
        XCTAssertNil(settings.launchAtLogin)
    }

    // MARK: - Multiple Writes

    func testMultipleWritesPreserveLatest() {
        let store = makeStore()
        store.customPrompt = "first"
        store.customPrompt = "second"
        store.customPrompt = "third"
        XCTAssertEqual(store.customPrompt, "third")

        // Verify on disk too
        store.invalidateCache()
        XCTAssertEqual(store.customPrompt, "third")
    }

    func testPartialUpdatesPreserveOtherFields() {
        let store = makeStore()
        store.customPrompt = "focus on coding"
        store.granularity = .high
        store.minAwayMinutes = 5

        // Update only one field
        store.granularity = .low

        // Other fields should be unchanged
        XCTAssertEqual(store.customPrompt, "focus on coding")
        XCTAssertEqual(store.minAwayMinutes, 5)
        XCTAssertEqual(store.granularity, .low)
    }

    // MARK: - MCP Settings

    func testMcpEnabledAccessor() {
        let store = makeStore()
        XCTAssertFalse(store.mcpEnabled, "Default should be false")
        store.mcpEnabled = true
        XCTAssertTrue(store.mcpEnabled)
        store.mcpEnabled = false
        XCTAssertFalse(store.mcpEnabled)
    }

    func testMcpEnabledPersistsAcrossInstances() {
        let path = makePath("mcp.json")
        let store1 = SettingsStore(filePath: path)
        store1.mcpEnabled = true

        let store2 = SettingsStore(filePath: path)
        XCTAssertTrue(store2.mcpEnabled)
    }
}
