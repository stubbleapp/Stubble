import XCTest
import SQLite3
@testable import TaskMinerShared

/// Tests that verify data written by TaskWriter can be read back correctly by DatabaseReader.
/// Uses a temporary SQLite database created fresh for each test.
final class DatabaseRoundTripTests: XCTestCase {

    private var tempDir: URL!
    private var dbPath: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubbleDBTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbPath = tempDir.appendingPathComponent("test.db")

        // Bootstrap the database schema by opening a DatabaseReader (which runs migrations)
        // We need to do this on the MainActor since DatabaseReader is @MainActor
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // Helper: create the schema by opening a reader (which runs migrations)
    @MainActor
    private func createSchema() throws -> DatabaseReader {
        // First create the database file with the activities/screenshots tables
        // since DatabaseReader.init runs migrations but needs base tables
        createBaseTables()
        return try DatabaseReader(path: dbPath)
    }

    /// Create base tables that the daemon normally creates (DatabaseManager).
    /// DatabaseReader's migrations add columns/tables ON TOP of these.
    private func createBaseTables() {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        let sqls = [
            """
            CREATE TABLE IF NOT EXISTS activities (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                end_time TEXT,
                app_name TEXT NOT NULL,
                bundle_id TEXT,
                window_title TEXT,
                duration REAL,
                is_idle INTEGER DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_activities_timestamp ON activities(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_activities_bundle ON activities(bundle_id)",
            """
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp TEXT NOT NULL,
                file_path TEXT NOT NULL,
                file_size INTEGER,
                activity_id INTEGER,
                trigger_type TEXT DEFAULT 'manual',
                FOREIGN KEY (activity_id) REFERENCES activities(id)
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_screenshots_timestamp ON screenshots(timestamp)",
            """
            CREATE TABLE IF NOT EXISTS daily_summaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date TEXT NOT NULL UNIQUE,
                total_active_seconds REAL DEFAULT 0,
                total_idle_seconds REAL DEFAULT 0,
                app_usage_json TEXT DEFAULT '{}',
                top_windows_json TEXT DEFAULT '[]',
                screenshot_count INTEGER DEFAULT 0,
                generated_at TEXT NOT NULL
            )
            """,
        ]

        for sql in sqls {
            sqlite3_exec(db, sql, nil, nil, nil)
        }
    }

    /// Insert an activity record directly via SQL (simulating what the daemon does)
    private func insertActivity(db: OpaquePointer?, record: ActivityRecord) -> Int64 {
        let sql = """
        INSERT INTO activities (timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, SharedFormatters.iso8601.string(from: record.timestamp))
        if let endTime = record.endTime {
            sqliteBindText(stmt, 2, SharedFormatters.iso8601.string(from: endTime))
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqliteBindText(stmt, 3, record.appName)
        if let bundleId = record.bundleId {
            sqliteBindText(stmt, 4, bundleId)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let title = record.windowTitle {
            sqliteBindText(stmt, 5, title)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let dur = record.duration {
            sqlite3_bind_double(stmt, 6, dur)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_int(stmt, 7, record.isIdle ? 1 : 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Task Round Trip

    @MainActor
    func testTaskWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
        let end = cal.date(bySettingHour: 11, minute: 30, second: 0, of: date)!

        let task = TaskRecord(
            date: "2025-06-15",
            startTime: start,
            endTime: end,
            title: "Developing SwiftUI settings",
            description: "Working on the settings view layout.",
            appNames: "[\"Xcode\",\"Safari\"]",
            confidence: 0.85,
            relevantLinks: "[\"https://developer.apple.com\"]",
            activeDuration: 7200
        )

        let insertedId = try writer.insertTask(task)
        XCTAssertGreaterThan(insertedId, 0)

        let tasks = reader.tasks(for: date)
        XCTAssertEqual(tasks.count, 1)

        let loaded = tasks[0]
        XCTAssertEqual(loaded.date, "2025-06-15")
        XCTAssertEqual(loaded.title, "Developing SwiftUI settings")
        XCTAssertEqual(loaded.description, "Working on the settings view layout.")
        XCTAssertEqual(loaded.appNamesList, ["Xcode", "Safari"])
        XCTAssertEqual(loaded.confidence, 0.85, accuracy: 0.01)
        XCTAssertEqual(loaded.linksList.count, 1)
        XCTAssertEqual(loaded.activeDuration, 7200)
    }

    @MainActor
    func testBulkTaskInsert() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let cal = Calendar.current

        let tasks = (0..<5).map { i in
            TaskRecord(
                date: "2025-06-15",
                startTime: cal.date(bySettingHour: 9 + i, minute: 0, second: 0, of: date)!,
                endTime: cal.date(bySettingHour: 10 + i, minute: 0, second: 0, of: date)!,
                title: "Task \(i)",
                description: "Description \(i)"
            )
        }

        let count = try writer.insertTasks(tasks)
        XCTAssertEqual(count, 5)

        let loaded = reader.tasks(for: date)
        XCTAssertEqual(loaded.count, 5)
    }

    @MainActor
    func testDeleteTasksForDate() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        let task = TaskRecord(
            date: "2025-06-15",
            startTime: date,
            endTime: date.addingTimeInterval(3600),
            title: "To Delete",
            description: ""
        )
        _ = try writer.insertTask(task)
        XCTAssertEqual(reader.tasks(for: date).count, 1)

        try writer.deleteTasks(for: "2025-06-15")
        XCTAssertEqual(reader.tasks(for: date).count, 0)
    }

    @MainActor
    func testUpdateTask() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        let task = TaskRecord(
            date: "2025-06-15",
            startTime: date,
            endTime: date.addingTimeInterval(3600),
            title: "Original Title",
            description: "Original Description"
        )
        let id = try writer.insertTask(task)

        try writer.updateTask(id: id, title: "Updated Title", description: "Updated Description")

        let loaded = reader.tasks(for: date)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Updated Title")
        XCTAssertEqual(loaded[0].description, "Updated Description")
    }

    @MainActor
    func testDeleteSingleTask() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        let task1 = TaskRecord(date: "2025-06-15", startTime: date, endTime: date.addingTimeInterval(3600), title: "Keep", description: "")
        let task2 = TaskRecord(date: "2025-06-15", startTime: date.addingTimeInterval(3600), endTime: date.addingTimeInterval(7200), title: "Delete", description: "")

        _ = try writer.insertTask(task1)
        let deleteId = try writer.insertTask(task2)

        try writer.deleteTask(id: deleteId)

        let loaded = reader.tasks(for: date)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].title, "Keep")
    }

    // MARK: - Project Activity Round Trip

    @MainActor
    func testProjectActivityWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let cal = Calendar.current
        let start = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
        let end = cal.date(bySettingHour: 17, minute: 0, second: 0, of: date)!

        let project = ProjectActivityRecord(
            date: "2025-06-15",
            name: "Stubble Development",
            summary: "Main project work on the macOS app.",
            totalDuration: 18000,
            appNames: "[\"Xcode\",\"Terminal\"]",
            taskTitles: "[\"Coding\",\"Testing\"]",
            startTime: start,
            endTime: end,
            colorIndex: 2
        )

        let id = try writer.insertProjectActivity(project)
        XCTAssertGreaterThan(id, 0)

        let loaded = reader.projectActivities(for: date)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Stubble Development")
        XCTAssertEqual(loaded[0].summary, "Main project work on the macOS app.")
        XCTAssertEqual(loaded[0].totalDuration, 18000, accuracy: 0.1)
        XCTAssertEqual(loaded[0].appNamesList, ["Xcode", "Terminal"])
        XCTAssertEqual(loaded[0].taskTitlesList, ["Coding", "Testing"])
        XCTAssertEqual(loaded[0].colorIndex, 2)
    }

    @MainActor
    func testDeleteProjectActivities() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        let project = ProjectActivityRecord(
            date: "2025-06-15",
            name: "Test",
            summary: "",
            totalDuration: 3600,
            startTime: date,
            endTime: date.addingTimeInterval(3600)
        )

        _ = try writer.insertProjectActivity(project)
        XCTAssertEqual(reader.projectActivities(for: date).count, 1)

        try writer.deleteProjectActivities(for: "2025-06-15")
        XCTAssertEqual(reader.projectActivities(for: date).count, 0)
    }

    // MARK: - Activity Queries

    @MainActor
    func testActivitiesForDate() throws {
        let reader = try createSchema()

        // Insert activities directly (simulating daemon)
        var db: OpaquePointer?
        sqlite3_open(dbPath.path, &db)
        defer { sqlite3_close(db) }

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let cal = Calendar.current
        let time1 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)!
        let time2 = cal.date(bySettingHour: 10, minute: 0, second: 0, of: date)!

        let activity1 = ActivityRecord(
            timestamp: time1,
            appName: "Xcode",
            bundleId: "com.apple.dt.Xcode",
            windowTitle: "File.swift",
            duration: 3600,
            isIdle: false
        )
        let activity2 = ActivityRecord(
            timestamp: time2,
            appName: "Safari",
            bundleId: "com.google.Chrome",
            windowTitle: "Stack Overflow",
            duration: 1800,
            isIdle: false
        )

        _ = insertActivity(db: db, record: activity1)
        _ = insertActivity(db: db, record: activity2)

        let loaded = reader.activities(for: date)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].appName, "Xcode")
        XCTAssertEqual(loaded[1].appName, "Safari")
    }

    @MainActor
    func testActivitiesFilteredByDate() throws {
        let reader = try createSchema()

        var db: OpaquePointer?
        sqlite3_open(dbPath.path, &db)
        defer { sqlite3_close(db) }

        let date1 = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let date2 = SharedFormatters.dayFormatter.date(from: "2025-06-16")!

        _ = insertActivity(db: db, record: ActivityRecord(
            timestamp: date1.addingTimeInterval(3600 * 9),
            appName: "Xcode", bundleId: nil, duration: 3600
        ))
        _ = insertActivity(db: db, record: ActivityRecord(
            timestamp: date2.addingTimeInterval(3600 * 9),
            appName: "Safari", bundleId: nil, duration: 1800
        ))

        let day1Activities = reader.activities(for: date1)
        let day2Activities = reader.activities(for: date2)

        XCTAssertEqual(day1Activities.count, 1)
        XCTAssertEqual(day1Activities[0].appName, "Xcode")
        XCTAssertEqual(day2Activities.count, 1)
        XCTAssertEqual(day2Activities[0].appName, "Safari")
    }

    // MARK: - computeSummary

    @MainActor
    func testComputeSummary() throws {
        let reader = try createSchema()

        var db: OpaquePointer?
        sqlite3_open(dbPath.path, &db)
        defer { sqlite3_close(db) }

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        _ = insertActivity(db: db, record: ActivityRecord(
            timestamp: date.addingTimeInterval(3600 * 9),
            appName: "Xcode", bundleId: nil, duration: 3600, isIdle: false
        ))
        _ = insertActivity(db: db, record: ActivityRecord(
            timestamp: date.addingTimeInterval(3600 * 10),
            appName: "Idle", bundleId: nil, duration: 600, isIdle: true
        ))

        let summary = reader.computeSummary(for: date)

        XCTAssertEqual(summary.activeSeconds, 3600, accuracy: 0.1)
        XCTAssertEqual(summary.idleSeconds, 600, accuracy: 0.1)
        XCTAssertEqual(summary.activityCount, 2)
    }

    // MARK: - appNameToBundleIdMap

    @MainActor
    func testAppNameToBundleIdMap() throws {
        let reader = try createSchema()

        var db: OpaquePointer?
        sqlite3_open(dbPath.path, &db)
        defer { sqlite3_close(db) }

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        _ = insertActivity(db: db, record: ActivityRecord(
            timestamp: date.addingTimeInterval(3600 * 9),
            appName: "Xcode", bundleId: "com.apple.dt.Xcode", duration: 60
        ))
        _ = insertActivity(db: db, record: ActivityRecord(
            timestamp: date.addingTimeInterval(3600 * 10),
            appName: "Safari", bundleId: "com.apple.Safari", duration: 60
        ))

        let map = reader.appNameToBundleIdMap()

        XCTAssertEqual(map["Xcode"], "com.apple.dt.Xcode")
        XCTAssertEqual(map["Safari"], "com.apple.Safari")
    }

    // MARK: - Null active_duration

    @MainActor
    func testTaskWithNullActiveDuration() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        let task = TaskRecord(
            date: "2025-06-15",
            startTime: date,
            endTime: date.addingTimeInterval(3600),
            title: "No active duration",
            description: "",
            activeDuration: nil
        )

        _ = try writer.insertTask(task)
        let loaded = reader.tasks(for: date)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].activeDuration)
        // duration computed property should fall back to span time
        XCTAssertEqual(loaded[0].duration, 3600, accuracy: 1.0)
    }

    // MARK: - Empty Results

    @MainActor
    func testEmptyDatabaseReturnsEmptyArrays() throws {
        let reader = try createSchema()

        let date = Date()
        XCTAssertTrue(reader.activities(for: date).isEmpty)
        XCTAssertTrue(reader.tasks(for: date).isEmpty)
        XCTAssertTrue(reader.screenshots(for: date).isEmpty)
        XCTAssertTrue(reader.projectActivities(for: date).isEmpty)
    }

    // MARK: - Chat Message Round Trip

    @MainActor
    func testChatMessageWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let now = Date()

        let message = ChatMessageRecord(
            date: "2025-06-15",
            role: "user",
            content: "What did I work on today?",
            timestamp: now
        )

        let id = try writer.insertChatMessage(message)
        XCTAssertGreaterThan(id, 0)

        let loaded = reader.chatMessages(for: date)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].date, "2025-06-15")
        XCTAssertEqual(loaded[0].role, "user")
        XCTAssertEqual(loaded[0].content, "What did I work on today?")
        XCTAssertNotNil(loaded[0].id)
    }

    @MainActor
    func testDeleteChatMessages() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date = SharedFormatters.dayFormatter.date(from: "2025-06-15")!

        let msg1 = ChatMessageRecord(date: "2025-06-15", role: "user", content: "Hello")
        let msg2 = ChatMessageRecord(date: "2025-06-15", role: "assistant", content: "Hi there!")

        _ = try writer.insertChatMessage(msg1)
        _ = try writer.insertChatMessage(msg2)
        XCTAssertEqual(reader.chatMessages(for: date).count, 2)

        try writer.deleteChatMessages(for: "2025-06-15")
        XCTAssertEqual(reader.chatMessages(for: date).count, 0)
    }

    @MainActor
    func testChatMessagesScopedByDate() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let date1 = SharedFormatters.dayFormatter.date(from: "2025-06-15")!
        let date2 = SharedFormatters.dayFormatter.date(from: "2025-06-16")!

        _ = try writer.insertChatMessage(ChatMessageRecord(date: "2025-06-15", role: "user", content: "Day 1 message"))
        _ = try writer.insertChatMessage(ChatMessageRecord(date: "2025-06-16", role: "user", content: "Day 2 message"))
        _ = try writer.insertChatMessage(ChatMessageRecord(date: "2025-06-15", role: "assistant", content: "Day 1 reply"))

        let day1 = reader.chatMessages(for: date1)
        let day2 = reader.chatMessages(for: date2)

        XCTAssertEqual(day1.count, 2)
        XCTAssertEqual(day2.count, 1)
        XCTAssertEqual(day1[0].content, "Day 1 message")
        XCTAssertEqual(day1[1].content, "Day 1 reply")
        XCTAssertEqual(day2[0].content, "Day 2 message")
    }

    @MainActor
    func testChatThreadWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let threadId = try writer.createChatThread(
            title: "Planning Thread",
            contextDate: "2025-06-15"
        )
        XCTAssertGreaterThan(threadId, 0)

        let message = ChatMessageRecord(
            threadId: threadId,
            date: "2025-06-15",
            role: "user",
            content: "Let's plan the release notes."
        )
        _ = try writer.insertChatMessage(message)
        try writer.touchChatThread(threadId: threadId, lastMessageAt: Date(), messageCount: 1)

        let thread = reader.chatThread(id: threadId)
        XCTAssertNotNil(thread)
        XCTAssertEqual(thread?.title, "Planning Thread")
        XCTAssertEqual(thread?.contextDate, "2025-06-15")
        XCTAssertEqual(thread?.messageCount, 1)

        let messages = reader.chatMessages(threadId: threadId)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].threadId, threadId)
        XCTAssertEqual(messages[0].content, "Let's plan the release notes.")
    }

    @MainActor
    func testDeleteChatThreadCascadesMessages() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let threadId = try writer.createChatThread(title: "To Delete", contextDate: "2025-06-15")
        _ = try writer.insertChatMessage(ChatMessageRecord(threadId: threadId, date: "2025-06-15", role: "user", content: "hello"))
        _ = try writer.insertChatMessage(ChatMessageRecord(threadId: threadId, date: "2025-06-15", role: "assistant", content: "hi"))
        try writer.touchChatThread(threadId: threadId, lastMessageAt: Date(), messageCount: 2)

        XCTAssertEqual(reader.chatMessages(threadId: threadId).count, 2)

        try writer.deleteChatThread(threadId: threadId)

        XCTAssertTrue(reader.chatMessages(threadId: threadId).isEmpty)
        XCTAssertNil(reader.chatThread(id: threadId))
    }

    @MainActor
    func testChatMigrationBackfillsLegacyDateScopedRows() throws {
        // Build a DB at schema version 12 with legacy chat_messages rows (no thread_id),
        // then let DatabaseReader run migration 13.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        sqlite3_exec(db, """
        CREATE TABLE chat_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL
        );
        """, nil, nil, nil)

        sqlite3_exec(db, """
        INSERT INTO chat_messages (date, role, content, timestamp) VALUES
        ('2025-06-15', 'user', 'day1 msg', '2025-06-15T09:00:00Z'),
        ('2025-06-15', 'assistant', 'day1 reply', '2025-06-15T09:01:00Z'),
        ('2025-06-16', 'user', 'day2 msg', '2025-06-16T09:00:00Z');
        """, nil, nil, nil)

        sqlite3_exec(db, "PRAGMA user_version = 12", nil, nil, nil)

        // Close direct handle before opening DatabaseReader.
        sqlite3_close(db)
        db = nil

        let reader = try DatabaseReader(path: dbPath)
        let threads = reader.chatThreads(limit: 10)
        XCTAssertGreaterThanOrEqual(threads.count, 2, "Should backfill one thread per legacy date")

        // Ensure migrated messages are addressable by thread_id and no row remains at thread_id=0.
        var dbCheck: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath.path, &dbCheck), SQLITE_OK)
        defer { sqlite3_close(dbCheck) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(dbCheck, "SELECT COUNT(*) FROM chat_messages WHERE thread_id = 0", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0)
    }

    // MARK: - Transaction Rollback

    @MainActor
    func testEmptyBulkInsertReturnsZero() throws {
        _ = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let count = try writer.insertTasks([])
        XCTAssertEqual(count, 0)
    }

    // MARK: - Stubs Content

    @MainActor
    func testStubsContentWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let record = StubsContentRecord(
            date: "2024-11-01",
            greetingContext: "You've been deep into Swift concurrency",
            daySummary: "A productive day focused on async code.",
            questionsJson: "[\"How to use actors?\"]",
            recommendationsJson: "[{\"title\":\"Learn Actors\"}]"
        )
        let rowId = try writer.insertOrReplaceStubsContent(record)
        XCTAssertGreaterThan(rowId, 0)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let date = df.date(from: "2024-11-01")!

        let loaded = reader.stubsContent(for: date)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.date, "2024-11-01")
        XCTAssertEqual(loaded?.greetingContext, "You've been deep into Swift concurrency")
        XCTAssertEqual(loaded?.daySummary, "A productive day focused on async code.")
        XCTAssertEqual(loaded?.questionsJson, "[\"How to use actors?\"]")
        XCTAssertEqual(loaded?.recommendationsJson, "[{\"title\":\"Learn Actors\"}]")
    }

    @MainActor
    func testStubsContentReplaceOnSameDate() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let first = StubsContentRecord(date: "2024-11-01", greetingContext: "First")
        try writer.insertOrReplaceStubsContent(first)

        let second = StubsContentRecord(date: "2024-11-01", greetingContext: "Second")
        try writer.insertOrReplaceStubsContent(second)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let date = df.date(from: "2024-11-01")!

        let loaded = reader.stubsContent(for: date)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.greetingContext, "Second")
    }

    @MainActor
    func testDeleteStubsContent() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let record = StubsContentRecord(date: "2024-11-01", greetingContext: "Hello")
        try writer.insertOrReplaceStubsContent(record)

        try writer.deleteStubsContent(for: "2024-11-01")

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let date = df.date(from: "2024-11-01")!

        let loaded = reader.stubsContent(for: date)
        XCTAssertNil(loaded)
    }

    // MARK: - Day Wrap

    @MainActor
    func testDayWrapWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let updated = Date()
        let record = DayWrapRecord(
            date: "2025-03-15",
            summary: "Shipped the timeline fix.",
            focusTimeSeconds: 42,
            meetingTimeSeconds: 1800,
            projectCount: 3,
            updatedAt: updated
        )
        try writer.insertOrReplaceDayWrap(record)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        let date = df.date(from: "2025-03-15")!

        let loaded = reader.dayWrap(for: date)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.summary, "Shipped the timeline fix.")
        XCTAssertEqual(loaded?.focusTimeSeconds, 42)
        XCTAssertEqual(loaded?.meetingTimeSeconds, 1800)
        XCTAssertEqual(loaded?.projectCount, 3)

        let viaTimeline = reader.timelineDayWrap(for: date)
        XCTAssertEqual(viaTimeline?.summary, "Shipped the timeline fix.")
    }

    // MARK: - Window Snapshots

    @MainActor
    func testWindowSnapshotWriteAndRead() throws {
        let reader = try createSchema()
        let writer = try TaskWriter(path: dbPath)

        let now = Date()
        let windows = [
            WindowInfo(
                windowId: 1,
                appName: "Xcode",
                bundleId: "com.apple.dt.Xcode",
                pid: 12345,
                title: "MyProject.swift",
                layer: 0,
                x: 0,
                y: 0,
                width: 960,  // Half screen (side-by-side)
                height: 1080,
                isOnScreen: true,
                alpha: 1.0
            ),
            WindowInfo(
                windowId: 2,
                appName: "Safari",
                bundleId: "com.apple.Safari",
                pid: 12346,
                title: "Apple Developer",
                layer: 0,
                x: 960,
                y: 0,
                width: 960,  // Half screen (side-by-side)
                height: 1080,
                isOnScreen: true,
                alpha: 1.0
            )
        ]

        let snapshot = WindowSnapshot(
            timestamp: now,
            windows: windows,
            displayWidth: 1920,
            displayHeight: 1080
        )

        try writer.insertWindowSnapshot(snapshot, activityId: nil)

        // Query back
        let start = now.addingTimeInterval(-60)
        let end = now.addingTimeInterval(60)
        let loaded = reader.windowSnapshots(from: start, to: end)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.windows.count, 2)
        XCTAssertEqual(loaded.first?.displayWidth, 1920)
        XCTAssertEqual(loaded.first?.windows.first?.appName, "Xcode")

        // Test layout summary
        let summary = WindowLayoutSummary(from: loaded.first!)
        XCTAssertEqual(summary.activeApp, "Xcode")
        XCTAssertEqual(summary.visibleWindowCount, 2)
        XCTAssertTrue(summary.hasSideBySide)
    }
}
