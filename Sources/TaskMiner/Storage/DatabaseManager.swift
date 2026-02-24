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
    private static let schemaVersion = 5

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
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_pa_date ON project_activities(date)", nil, nil, nil)
        }

        if currentVersion < 5 {
            if !execMigration("ALTER TABLE tasks ADD COLUMN active_duration REAL",
                              label: "5: add active_duration", ignoreDuplicate: true) {
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

    private func setUserVersion(_ version: Int) {
        sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil)
    }

    // MARK: - Activity CRUD

    @discardableResult
    func insertActivity(_ record: ActivityRecord) throws -> Int64 {
        guard let db = db else { throw DatabaseError.closed }
        let sql = """
        INSERT INTO activities (timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle)
        VALUES (?, ?, ?, ?, ?, ?, ?)
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

    // MARK: - Summarization Queries

    /// Returns activity + OCR data for a time range (used by AI summarization)
    func recentActivitiesWithOCR(from start: Date, to end: Date) -> [SummarizationInput] {
        guard db != nil else { return [] }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)

        let sql = """
        SELECT a.app_name, a.bundle_id, a.window_title, a.timestamp, a.duration, a.is_idle,
               s.ocr_text, s.timestamp as screenshot_time
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
                ocrText: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            )
            results.append(input)
        }
        return results
    }

    // MARK: - Cleanup

    /// Delete the oldest screenshot rows, keeping only the most recent `keep` entries.
    /// Returns the file paths of deleted rows so the caller can remove the files from disk.
    func deleteScreenshotsKeepingLatest(_ keep: Int) -> [String] {
        guard db != nil else { return [] }

        // 1. Collect file paths of rows that will be deleted
        let selectSql = """
        SELECT file_path FROM screenshots
        WHERE id NOT IN (SELECT id FROM screenshots ORDER BY timestamp DESC LIMIT ?)
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(selectStmt) }
        sqlite3_bind_int(selectStmt, 1, Int32(keep))

        var paths: [String] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(selectStmt, 0) {
                paths.append(String(cString: cStr))
            }
        }

        guard !paths.isEmpty else { return [] }

        // 2. Delete the rows
        let deleteSql = """
        DELETE FROM screenshots
        WHERE id NOT IN (SELECT id FROM screenshots ORDER BY timestamp DESC LIMIT ?)
        """
        var deleteStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(deleteStmt) }
        sqlite3_bind_int(deleteStmt, 1, Int32(keep))

        if sqlite3_step(deleteStmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                Logger.info("Deleted \(deleted) screenshot record(s) (keeping latest \(keep))")
            }
        }

        return paths
    }

    deinit {
        close()
    }

    func close() {
        if let db = db {
            sqlite3_close(db)
            Logger.debug("Database closed")
        }
        db = nil
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
