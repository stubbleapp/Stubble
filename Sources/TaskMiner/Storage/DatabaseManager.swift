import Foundation
import SQLite3
import TaskMinerShared

class DatabaseManager {
    private var db: OpaquePointer?

    init(path: URL) throws {
        var dbPointer: OpaquePointer?
        let rc = sqlite3_open(path.path, &dbPointer)
        guard rc == SQLITE_OK else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPointer)
            throw DatabaseError.openFailed(msg)
        }
        self.db = dbPointer
        sqlite3_busy_timeout(dbPointer, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA wal_autocheckpoint=1000")
        try execute("PRAGMA foreign_keys=ON")
        try createSchema()
        runMigrations()
        // Restrict database file to owner-only access (0600) — contains OCR text and activity data.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    // MARK: - Schema

    private func createSchema() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS activities (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp   TEXT NOT NULL,
            end_time    TEXT,
            app_name    TEXT NOT NULL,
            bundle_id   TEXT,
            window_title TEXT,
            duration    REAL,
            is_idle     INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_activities_timestamp ON activities(timestamp);
        CREATE INDEX IF NOT EXISTS idx_activities_bundle_id ON activities(bundle_id);

        CREATE TABLE IF NOT EXISTS screenshots (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp   TEXT NOT NULL,
            file_path   TEXT NOT NULL,
            file_size   INTEGER,
            activity_id INTEGER,
            trigger_type TEXT,
            FOREIGN KEY (activity_id) REFERENCES activities(id)
        );
        CREATE INDEX IF NOT EXISTS idx_screenshots_timestamp ON screenshots(timestamp);
        CREATE INDEX IF NOT EXISTS idx_screenshots_activity ON screenshots(activity_id);

        CREATE TABLE IF NOT EXISTS daily_summaries (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            date        TEXT NOT NULL UNIQUE,
            total_active_seconds  REAL,
            total_idle_seconds    REAL,
            app_usage_json        TEXT,
            top_windows_json      TEXT,
            screenshot_count      INTEGER,
            generated_at          TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_daily_summaries_date ON daily_summaries(date);

        CREATE TABLE IF NOT EXISTS tasks (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            date        TEXT NOT NULL,
            start_time  TEXT NOT NULL,
            end_time    TEXT NOT NULL,
            title       TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            app_names   TEXT DEFAULT '[]',
            confidence  REAL DEFAULT 0.0
        );
        CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date);
        CREATE INDEX IF NOT EXISTS idx_tasks_start ON tasks(start_time);
        """
        for statement in schema.components(separatedBy: ";") {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try execute(trimmed)
        }
    }

    /// Current schema version — kept in sync with DatabaseReader's migrations.
    private static let schemaVersion = 11

    private func runMigrations() {
        let currentVersion = getUserVersion()

        // Forward-compatibility guard: if the database was created by a newer version
        // of Stubble, don't touch the schema — we might corrupt newer structures.
        if currentVersion > Self.schemaVersion {
            Logger.warning("Database schema version \(currentVersion) is newer than this binary supports (\(Self.schemaVersion)). Skipping migrations.")
            return
        }

        var migrationFailed = false

        if currentVersion < 1 {
            if !execMigration("ALTER TABLE screenshots ADD COLUMN ocr_text TEXT",
                              label: "1: add ocr_text", ignoreDuplicate: true) {
                migrationFailed = true
            }
        }

        // Migration 2 is CREATE TABLE tasks — already in createSchema()

        if currentVersion < 3 {
            if !execMigration("ALTER TABLE tasks ADD COLUMN relevant_links TEXT DEFAULT '[]'",
                              label: "3: add relevant_links", ignoreDuplicate: true) {
                migrationFailed = true
            }
        }

        if currentVersion < 4 {
            let paSql = """
            CREATE TABLE IF NOT EXISTS project_activities (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                date        TEXT NOT NULL,
                name        TEXT NOT NULL,
                summary     TEXT NOT NULL DEFAULT '',
                total_duration REAL DEFAULT 0,
                app_names   TEXT DEFAULT '[]',
                task_titles TEXT DEFAULT '[]',
                start_time  TEXT NOT NULL,
                end_time    TEXT NOT NULL,
                color_index INTEGER DEFAULT 0
            )
            """
            if !execMigration(paSql, label: "4: create project_activities table") {
                migrationFailed = true
            }
            if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_pa_date ON project_activities(date)", nil, nil, nil) != SQLITE_OK {
                Logger.warning("Failed to create idx_pa_date index")
            }
        }

        if currentVersion < 5 {
            if !execMigration("ALTER TABLE tasks ADD COLUMN active_duration REAL",
                              label: "5: add active_duration", ignoreDuplicate: true) {
                migrationFailed = true
            }
        }

        if currentVersion < 6 {
            let chatSql = """
            CREATE TABLE IF NOT EXISTS chat_messages (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                date      TEXT NOT NULL,
                role      TEXT NOT NULL,
                content   TEXT NOT NULL,
                timestamp TEXT NOT NULL
            )
            """
            if !execMigration(chatSql, label: "6: create chat_messages table") {
                migrationFailed = true
            }
            if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_date ON chat_messages(date)", nil, nil, nil) != SQLITE_OK {
                Logger.warning("Failed to create idx_chat_date index")
            }
        }

        if currentVersion < 7 {
            let stubsSql = """
            CREATE TABLE IF NOT EXISTS stubs_content (
                id                   INTEGER PRIMARY KEY AUTOINCREMENT,
                date                 TEXT NOT NULL UNIQUE,
                greeting_context     TEXT NOT NULL DEFAULT '',
                day_summary          TEXT,
                questions_json       TEXT NOT NULL DEFAULT '[]',
                recommendations_json TEXT NOT NULL DEFAULT '[]',
                generated_at         TEXT NOT NULL
            )
            """
            if !execMigration(stubsSql, label: "7: create stubs_content table") {
                migrationFailed = true
            }
        }

        if currentVersion < 8 {
            let digestSql = """
            CREATE TABLE IF NOT EXISTS ocr_digests (
                date         TEXT PRIMARY KEY,
                digest       TEXT NOT NULL,
                generated_at TEXT NOT NULL
            )
            """
            if !execMigration(digestSql, label: "8: create ocr_digests table") {
                migrationFailed = true
            }
        }

        if currentVersion < 9 {
            // Extended activity context: browser URLs, document paths, focused element roles
            if !execMigration("ALTER TABLE activities ADD COLUMN browser_url TEXT",
                              label: "9a: add browser_url", ignoreDuplicate: true) {
                migrationFailed = true
            }
            if !execMigration("ALTER TABLE activities ADD COLUMN document_path TEXT",
                              label: "9b: add document_path", ignoreDuplicate: true) {
                migrationFailed = true
            }
            if !execMigration("ALTER TABLE activities ADD COLUMN focused_element_role TEXT",
                              label: "9c: add focused_element_role", ignoreDuplicate: true) {
                migrationFailed = true
            }
            // File activity events table — stores aggregated file system change events
            let fileEventsSql = """
            CREATE TABLE IF NOT EXISTS file_events (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp   TEXT NOT NULL,
                file_path   TEXT NOT NULL,
                event_type  TEXT NOT NULL DEFAULT 'modified',
                activity_id INTEGER,
                FOREIGN KEY (activity_id) REFERENCES activities(id)
            )
            """
            if !execMigration(fileEventsSql, label: "9d: create file_events table") {
                migrationFailed = true
            }
            if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_file_events_timestamp ON file_events(timestamp)", nil, nil, nil) != SQLITE_OK {
                Logger.warning("Failed to create idx_file_events_timestamp index")
            }
        }

        if currentVersion < 10 {
            let habitsSql = """
            CREATE TABLE IF NOT EXISTS habits_analysis (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                generated_at  TEXT NOT NULL,
                days_analyzed INTEGER NOT NULL,
                analysis_json TEXT NOT NULL,
                snapshot_hash TEXT NOT NULL
            )
            """
            if !execMigration(habitsSql, label: "10: create habits_analysis table") {
                migrationFailed = true
            }
        }

        if currentVersion < 11 {
            if !execMigration("ALTER TABLE tasks ADD COLUMN websites TEXT DEFAULT '[]'",
                              label: "11: add websites to tasks", ignoreDuplicate: true) {
                migrationFailed = true
            }
        }

        // Only bump the version if all migrations succeeded — failed migrations
        // will be retried on the next launch.
        if migrationFailed {
            Logger.error("One or more migrations failed — schema version NOT updated (will retry next launch)")
        } else if currentVersion < Self.schemaVersion {
            setUserVersion(Self.schemaVersion)
            Logger.info("Schema version updated: \(currentVersion) → \(Self.schemaVersion)")
        }
    }

    /// Execute a single migration. Returns true on success, false on failure.
    @discardableResult
    private func execMigration(_ sql: String, label: String, ignoreDuplicate: Bool = false) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? ""
            sqlite3_free(errMsg)
            if ignoreDuplicate && msg.contains("duplicate column") {
                return true // Column already exists — that's fine
            }
            Logger.error("DatabaseManager migration \(label) failed: \(msg)")
            return false
        }
        return true
    }

    private func getUserVersion() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Note: PRAGMA doesn't support parameter binding — integer interpolation is safe here.
    private func setUserVersion(_ version: Int) {
        if sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil) != SQLITE_OK {
            Logger.warning("Failed to set user_version to \(version)")
        }
    }

    // MARK: - Activity CRUD

    @discardableResult
    func insertActivity(_ record: ActivityRecord) throws -> Int64 {
        guard let db = db else { throw DatabaseError.closed }
        let sql = """
        INSERT INTO activities (timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle,
                                browser_url, document_path, focused_element_role)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let ts = SharedFormatters.iso8601.string(from: record.timestamp)
        sqliteBindText(stmt, 1, ts)

        if let endTime = record.endTime {
            let et = SharedFormatters.iso8601.string(from: endTime)
            sqliteBindText(stmt, 2, et)
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

        if let duration = record.duration {
            sqlite3_bind_double(stmt, 6, duration)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        sqlite3_bind_int(stmt, 7, record.isIdle ? 1 : 0)

        if let url = record.browserURL { sqliteBindText(stmt, 8, url) } else { sqlite3_bind_null(stmt, 8) }
        if let doc = record.documentPath { sqliteBindText(stmt, 9, doc) } else { sqlite3_bind_null(stmt, 9) }
        if let role = record.focusedElementRole { sqliteBindText(stmt, 10, role) } else { sqlite3_bind_null(stmt, 10) }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }

        return sqlite3_last_insert_rowid(db)
    }

    func finalizeActivity(id: Int64, endTime: Date, duration: TimeInterval) throws {
        guard db != nil else { throw DatabaseError.closed }
        let sql = "UPDATE activities SET end_time = ?, duration = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let et = SharedFormatters.iso8601.string(from: endTime)
        sqliteBindText(stmt, 1, et)
        sqlite3_bind_double(stmt, 2, duration)
        sqlite3_bind_int64(stmt, 3, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - File Events

    /// Insert a batch of file change events observed by FSEvents.
    func insertFileEvents(_ events: [(path: String, type: String)], activityId: Int64?) {
        guard db != nil else { return }
        let sql = "INSERT INTO file_events (timestamp, file_path, event_type, activity_id) VALUES (?, ?, ?, ?)"
        let now = SharedFormatters.iso8601.string(from: Date())

        for event in events {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqliteBindText(stmt, 1, now)
            sqliteBindText(stmt, 2, event.path)
            sqliteBindText(stmt, 3, event.type)
            if let aid = activityId { sqlite3_bind_int64(stmt, 4, aid) } else { sqlite3_bind_null(stmt, 4) }
            if sqlite3_step(stmt) != SQLITE_DONE {
                Logger.warning("Failed to insert file event for \(event.path): \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    /// Fetch recently modified file paths for a time range (used by summarization).
    func recentFileEvents(from start: Date, to end: Date, limit: Int = 100) -> [String] {
        guard db != nil else { return [] }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)
        let sql = """
        SELECT DISTINCT file_path FROM file_events
        WHERE timestamp >= ? AND timestamp < ?
        ORDER BY timestamp DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                paths.append(String(cString: cStr))
            }
        }
        return paths
    }

    /// Prune file events older than the given number of days.
    func deleteFileEventsOlderThan(days: Int) {
        guard db != nil else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let cutoffStr = SharedFormatters.iso8601.string(from: cutoff)
        let sql = "DELETE FROM file_events WHERE timestamp < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, cutoffStr)
        if sqlite3_step(stmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 { Logger.info("Deleted \(deleted) file event(s) older than \(days) days") }
        }
    }

    // MARK: - Screenshot CRUD

    func insertScreenshot(_ record: ScreenshotRecord) throws {
        guard db != nil else { throw DatabaseError.closed }
        let sql = """
        INSERT INTO screenshots (timestamp, file_path, file_size, activity_id, trigger_type, ocr_text)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let ts = SharedFormatters.iso8601.string(from: record.timestamp)
        sqliteBindText(stmt, 1, ts)
        sqliteBindText(stmt, 2, record.filePath)

        if let size = record.fileSize {
            sqlite3_bind_int64(stmt, 3, Int64(size))
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let activityId = record.activityId {
            sqlite3_bind_int64(stmt, 4, activityId)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqliteBindText(stmt, 5, record.trigger.rawValue)

        if let ocrText = record.ocrText {
            sqliteBindText(stmt, 6, ocrText)
        } else {
            sqlite3_bind_null(stmt, 6)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - Task CRUD

    @discardableResult
    func insertTask(_ task: TaskRecord) throws -> Int64 {
        guard db != nil else { throw DatabaseError.closed }
        let sql = """
        INSERT INTO tasks (date, start_time, end_time, title, description, app_names, confidence, relevant_links, active_duration)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, task.date)
        sqliteBindText(stmt, 2, SharedFormatters.iso8601.string(from: task.startTime))
        sqliteBindText(stmt, 3, SharedFormatters.iso8601.string(from: task.endTime))
        sqliteBindText(stmt, 4, task.title)
        sqliteBindText(stmt, 5, task.description)
        sqliteBindText(stmt, 6, task.appNames)
        sqlite3_bind_double(stmt, 7, task.confidence)
        sqliteBindText(stmt, 8, task.relevantLinks)
        if let activeDuration = task.activeDuration {
            sqlite3_bind_double(stmt, 9, activeDuration)
        } else {
            sqlite3_bind_null(stmt, 9)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    func deleteTasks(for dateString: String) throws {
        guard db != nil else { throw DatabaseError.closed }
        let sql = "DELETE FROM tasks WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, dateString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - Project Activities

    func deleteProjectActivities(for dateString: String) throws {
        guard db != nil else { throw DatabaseError.closed }
        let sql = "DELETE FROM project_activities WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, dateString)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    func insertProjectActivities(_ records: [ProjectActivityRecord]) throws {
        guard db != nil else { throw DatabaseError.closed }
        let sql = """
        INSERT INTO project_activities (date, name, summary, total_duration, app_names, task_titles, start_time, end_time, color_index)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        for record in records {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw DatabaseError.executionFailed(lastError)
            }
            defer { sqlite3_finalize(stmt) }
            sqliteBindText(stmt, 1, record.date)
            sqliteBindText(stmt, 2, record.name)
            sqliteBindText(stmt, 3, record.summary)
            sqlite3_bind_double(stmt, 4, record.totalDuration)
            sqliteBindText(stmt, 5, record.appNames)
            sqliteBindText(stmt, 6, record.taskTitles)
            sqliteBindText(stmt, 7, SharedFormatters.iso8601.string(from: record.startTime))
            sqliteBindText(stmt, 8, SharedFormatters.iso8601.string(from: record.endTime))
            sqlite3_bind_int(stmt, 9, Int32(record.colorIndex))
            if sqlite3_step(stmt) != SQLITE_DONE {
                Logger.warning("Failed to insert project activity '\(record.name)': \(lastError)")
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    func projectActivityNames(for dateString: String) -> [String] {
        guard db != nil else { return [] }
        let sql = "SELECT DISTINCT name FROM project_activities WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, dateString)
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                names.append(String(cString: cStr))
            }
        }
        return names
    }

    // MARK: - Daily Summary

    func generateDailySummary(for date: Date) {
        guard db != nil else { return }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
            Logger.error("Failed to compute end-of-day date")
            return
        }

        let startStr = SharedFormatters.iso8601.string(from: startOfDay)
        let endStr = SharedFormatters.iso8601.string(from: endOfDay)
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

        var totalActive: Double = 0
        var totalIdle: Double = 0
        var appUsage: [String: Double] = [:]
        var windowUsage: [String: Double] = [:]

        let querySql = """
        SELECT app_name, bundle_id, window_title, duration, is_idle
        FROM activities WHERE timestamp >= ? AND timestamp < ? AND duration IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, querySql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let duration = sqlite3_column_double(stmt, 3)
            let isIdle = sqlite3_column_int(stmt, 4) != 0

            if isIdle {
                totalIdle += duration
            } else {
                totalActive += duration
                if let bundleId = sqlite3_column_text(stmt, 1) {
                    let key = String(cString: bundleId)
                    appUsage[key, default: 0] += duration
                }
                if let title = sqlite3_column_text(stmt, 2) {
                    let key = String(cString: title)
                    windowUsage[key, default: 0] += duration
                }
            }
        }

        let countSql = "SELECT COUNT(*) FROM screenshots WHERE timestamp >= ? AND timestamp < ?"
        var countStmt: OpaquePointer?
        var screenshotCount = 0
        if sqlite3_prepare_v2(db, countSql, -1, &countStmt, nil) == SQLITE_OK {
            sqliteBindText(countStmt, 1, startStr)
            sqliteBindText(countStmt, 2, endStr)
            if sqlite3_step(countStmt) == SQLITE_ROW {
                screenshotCount = Int(sqlite3_column_int(countStmt, 0))
            }
            sqlite3_finalize(countStmt)
        }

        let topWindows = windowUsage.sorted { $0.value > $1.value }
            .prefix(20)
            .map { ["title": $0.key, "seconds": $0.value] as [String: Any] }

        let appUsageJSON = (try? JSONSerialization.data(withJSONObject: appUsage)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let topWindowsJSON = (try? JSONSerialization.data(withJSONObject: topWindows)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let upsertSql = """
        INSERT INTO daily_summaries (date, total_active_seconds, total_idle_seconds, app_usage_json, top_windows_json, screenshot_count, generated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET
            total_active_seconds = excluded.total_active_seconds,
            total_idle_seconds = excluded.total_idle_seconds,
            app_usage_json = excluded.app_usage_json,
            top_windows_json = excluded.top_windows_json,
            screenshot_count = excluded.screenshot_count,
            generated_at = excluded.generated_at
        """
        var upsertStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, upsertSql, -1, &upsertStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(upsertStmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(upsertStmt, 1, dateStr)
        sqlite3_bind_double(upsertStmt, 2, totalActive)
        sqlite3_bind_double(upsertStmt, 3, totalIdle)
        sqliteBindText(upsertStmt, 4, appUsageJSON)
        sqliteBindText(upsertStmt, 5, topWindowsJSON)
        sqlite3_bind_int(upsertStmt, 6, Int32(screenshotCount))
        sqliteBindText(upsertStmt, 7, now)

        if sqlite3_step(upsertStmt) != SQLITE_DONE {
            Logger.error("Failed to upsert daily summary: \(lastError)")
        } else {
            Logger.info("Generated daily summary for \(dateStr): \(Int(totalActive))s active, \(Int(totalIdle))s idle, \(screenshotCount) screenshots")
        }
    }

    // MARK: - OCR Digest

    /// Fetch all OCR texts for a given date (used by OCRDigestBuilder).
    func ocrTextsForDate(_ date: Date) -> [String] {
        guard db != nil else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)

        let sql = "SELECT ocr_text FROM screenshots WHERE timestamp >= ? AND timestamp < ? AND ocr_text IS NOT NULL AND ocr_text != ''"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)

        var texts: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                texts.append(String(cString: cStr))
            }
        }
        return texts
    }

    /// Insert or replace the cached OCR digest for a date.
    func insertOrReplaceOCRDigest(date: String, digest: String) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO ocr_digests (date, digest, generated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET digest = excluded.digest, generated_at = excluded.generated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(stmt, 1, date)
        sqliteBindText(stmt, 2, digest)
        sqliteBindText(stmt, 3, now)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.error("Failed to upsert OCR digest: \(lastError)")
        }
    }

    // MARK: - Summarization Queries

    /// Count non-idle activities since a given timestamp (lightweight check before expensive AI call).
    func nonIdleActivityCount(since start: Date) -> Int {
        guard db != nil else { return 0 }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let sql = "SELECT COUNT(*) FROM activities WHERE timestamp >= ? AND is_idle = 0"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, startStr)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Returns activity + OCR data for a time range (used by AI summarization)
    func recentActivitiesWithOCR(from start: Date, to end: Date) -> [SummarizationInput] {
        guard db != nil else { return [] }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)

        let sql = """
        SELECT a.app_name, a.bundle_id, a.window_title, a.timestamp, a.duration, a.is_idle,
               s.ocr_text, s.timestamp as screenshot_time,
               a.browser_url, a.document_path, a.focused_element_role
        FROM activities a
        LEFT JOIN screenshots s ON s.activity_id = a.id
        WHERE a.timestamp >= ? AND a.timestamp < ?
        ORDER BY a.timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.error("Failed to prepare recentActivitiesWithOCR: \(lastError)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)

        var results: [SummarizationInput] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let input = SummarizationInput(
                appName: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "Unknown",
                bundleId: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                windowTitle: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                timestamp: sqlite3_column_text(stmt, 3).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date(),
                duration: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : nil,
                isIdle: sqlite3_column_int(stmt, 5) != 0,
                ocrText: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                browserURL: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                documentPath: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                focusedElementRole: sqlite3_column_text(stmt, 10).map { String(cString: $0) }
            )
            results.append(input)
        }
        return results
    }

    // MARK: - Cleanup

    /// Tier 1: Strip image files from old screenshots but keep DB rows (OCR text is preserved).
    /// Returns file paths to delete from disk for screenshots beyond the latest `keep`.
    func pruneScreenshotImages(keepLatest keep: Int) -> [String] {
        guard db != nil else { return [] }

        // Find rows that have a non-empty file_path and are beyond the latest `keep`
        let selectSql = """
        SELECT file_path FROM screenshots
        WHERE file_path != '' AND file_path IS NOT NULL
          AND id NOT IN (SELECT id FROM screenshots ORDER BY timestamp DESC LIMIT ?)
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(selectStmt) }
        sqlite3_bind_int(selectStmt, 1, Int32(keep))

        var paths: [String] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(selectStmt, 0) {
                let path = String(cString: cStr)
                if !path.isEmpty { paths.append(path) }
            }
        }

        guard !paths.isEmpty else { return [] }

        // Clear file_path (keep the row for OCR text)
        let updateSql = """
        UPDATE screenshots SET file_path = ''
        WHERE file_path != '' AND file_path IS NOT NULL
          AND id NOT IN (SELECT id FROM screenshots ORDER BY timestamp DESC LIMIT ?)
        """
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return paths }
        defer { sqlite3_finalize(updateStmt) }
        sqlite3_bind_int(updateStmt, 1, Int32(keep))

        if sqlite3_step(updateStmt) == SQLITE_DONE {
            let updated = sqlite3_changes(db)
            if updated > 0 {
                Logger.info("Pruned images from \(updated) screenshot(s) (keeping latest \(keep) images, OCR text preserved)")
            }
        }

        return paths
    }

    /// Tier 2: Delete screenshot DB rows older than `days` to prevent unbounded growth.
    func deleteScreenshotsOlderThan(days: Int) {
        guard db != nil else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let cutoffStr = SharedFormatters.iso8601.string(from: cutoff)

        let sql = "DELETE FROM screenshots WHERE timestamp < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, cutoffStr)

        if sqlite3_step(stmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                Logger.info("Deleted \(deleted) screenshot row(s) older than \(days) days")
            }
        }
    }

    deinit {
        close()
    }

    func close() {
        guard let db = db else { return }
        self.db = nil
        sqlite3_close(db)
        Logger.debug("Database closed")
    }

    // MARK: - Helpers

    @discardableResult
    private func execute(_ sql: String) throws -> Int32 {
        guard let db = db else { throw DatabaseError.closed }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK && rc != SQLITE_ROW {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errMsg)
            throw DatabaseError.executionFailed(msg)
        }
        return rc
    }

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }

}
