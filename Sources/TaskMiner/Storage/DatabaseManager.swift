import Foundation
import SQLite3
import TaskMinerShared

class DatabaseManager {
    private var db: OpaquePointer?

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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

    private func runMigrations() {
        // Migration: add ocr_text column to screenshots if not present
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, "ALTER TABLE screenshots ADD COLUMN ocr_text TEXT", nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? ""
            sqlite3_free(errMsg)
            if !msg.contains("duplicate column") {
                Logger.error("Migration failed: \(msg)")
            }
        } else {
            Logger.info("Migration: added ocr_text column to screenshots")
        }
    }

    // MARK: - Activity CRUD

    @discardableResult
    func insertActivity(_ record: ActivityRecord) throws -> Int64 {
        let sql = """
        INSERT INTO activities (timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let ts = Self.iso8601.string(from: record.timestamp)
        sqlite3_bind_text(stmt, 1, (ts as NSString).utf8String, -1, nil)

        if let endTime = record.endTime {
            let et = Self.iso8601.string(from: endTime)
            sqlite3_bind_text(stmt, 2, (et as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 2)
        }

        sqlite3_bind_text(stmt, 3, (record.appName as NSString).utf8String, -1, nil)

        if let bundleId = record.bundleId {
            sqlite3_bind_text(stmt, 4, (bundleId as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        if let title = record.windowTitle {
            sqlite3_bind_text(stmt, 5, (title as NSString).utf8String, -1, nil)
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
        let sql = "UPDATE activities SET end_time = ?, duration = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let et = Self.iso8601.string(from: endTime)
        sqlite3_bind_text(stmt, 1, (et as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, duration)
        sqlite3_bind_int64(stmt, 3, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    func updateWindowTitle(id: Int64, title: String) throws {
        let sql = "UPDATE activities SET window_title = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - Screenshot CRUD

    func insertScreenshot(_ record: ScreenshotRecord) throws {
        let sql = """
        INSERT INTO screenshots (timestamp, file_path, file_size, activity_id, trigger_type, ocr_text)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let ts = Self.iso8601.string(from: record.timestamp)
        sqlite3_bind_text(stmt, 1, (ts as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (record.filePath as NSString).utf8String, -1, nil)

        if let size = record.fileSize {
            sqlite3_bind_int(stmt, 3, Int32(size))
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        if let activityId = record.activityId {
            sqlite3_bind_int64(stmt, 4, activityId)
        } else {
            sqlite3_bind_null(stmt, 4)
        }

        sqlite3_bind_text(stmt, 5, (record.trigger.rawValue as NSString).utf8String, -1, nil)

        if let ocrText = record.ocrText {
            sqlite3_bind_text(stmt, 6, (ocrText as NSString).utf8String, -1, nil)
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
        let sql = """
        INSERT INTO tasks (date, start_time, end_time, title, description, app_names, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (task.date as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (Self.iso8601.string(from: task.startTime) as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (Self.iso8601.string(from: task.endTime) as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 4, (task.title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (task.description as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (task.appNames as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 7, task.confidence)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Daily Summary

    func generateDailySummary(for date: Date) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

        let startStr = Self.iso8601.string(from: startOfDay)
        let endStr = Self.iso8601.string(from: endOfDay)
        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: date)
        }()

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

        sqlite3_bind_text(stmt, 1, (startStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (endStr as NSString).utf8String, -1, nil)

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
            sqlite3_bind_text(countStmt, 1, (startStr as NSString).utf8String, -1, nil)
            sqlite3_bind_text(countStmt, 2, (endStr as NSString).utf8String, -1, nil)
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

        let now = Self.iso8601.string(from: Date())
        sqlite3_bind_text(upsertStmt, 1, (dateStr as NSString).utf8String, -1, nil)
        sqlite3_bind_double(upsertStmt, 2, totalActive)
        sqlite3_bind_double(upsertStmt, 3, totalIdle)
        sqlite3_bind_text(upsertStmt, 4, (appUsageJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_text(upsertStmt, 5, (topWindowsJSON as NSString).utf8String, -1, nil)
        sqlite3_bind_int(upsertStmt, 6, Int32(screenshotCount))
        sqlite3_bind_text(upsertStmt, 7, (now as NSString).utf8String, -1, nil)

        if sqlite3_step(upsertStmt) != SQLITE_DONE {
            Logger.error("Failed to upsert daily summary: \(lastError)")
        } else {
            Logger.info("Generated daily summary for \(dateStr): \(Int(totalActive))s active, \(Int(totalIdle))s idle, \(screenshotCount) screenshots")
        }
    }

    // MARK: - Summarization Queries

    /// Returns activity + OCR data for a time range (used by AI summarization)
    func recentActivitiesWithOCR(from start: Date, to end: Date) -> [SummarizationInput] {
        let startStr = Self.iso8601.string(from: start)
        let endStr = Self.iso8601.string(from: end)

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

        sqlite3_bind_text(stmt, 1, (startStr as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (endStr as NSString).utf8String, -1, nil)

        var results: [SummarizationInput] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let input = SummarizationInput(
                appName: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "Unknown",
                bundleId: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                windowTitle: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                timestamp: sqlite3_column_text(stmt, 3).flatMap { Self.iso8601.date(from: String(cString: $0)) } ?? Date(),
                duration: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : nil,
                isIdle: sqlite3_column_int(stmt, 5) != 0,
                ocrText: sqlite3_column_text(stmt, 6).map { String(cString: $0) }
            )
            results.append(input)
        }
        return results
    }

    // MARK: - Cleanup

    /// Returns file paths of screenshots older than the cutoff that already have OCR text extracted.
    /// These are safe to delete from disk since their text content is preserved in the database.
    func analyzedScreenshotPaths(olderThan cutoff: Date) -> [(id: Int64, filePath: String)] {
        let cutoffStr = Self.iso8601.string(from: cutoff)
        let sql = """
        SELECT id, file_path FROM screenshots
        WHERE timestamp < ? AND ocr_text IS NOT NULL AND ocr_text != ''
        ORDER BY timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (cutoffStr as NSString).utf8String, -1, nil)

        var results: [(id: Int64, filePath: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            results.append((id: id, filePath: path))
        }
        return results
    }

    /// Mark a screenshot's file as deleted (set file_path to empty) after the file has been removed from disk.
    /// We keep the DB row so OCR text and metadata remain available for queries.
    func markScreenshotFileDeleted(id: Int64) {
        let sql = "UPDATE screenshots SET file_path = '', file_size = NULL WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    /// Delete all screenshot rows with timestamp before the given date (e.g. start of today).
    /// Used to keep only the current day's screenshots.
    func deleteScreenshots(before cutoff: Date) {
        let cutoffStr = Self.iso8601.string(from: cutoff)
        let sql = "DELETE FROM screenshots WHERE timestamp < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (cutoffStr as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                Logger.info("Deleted \(deleted) screenshot record(s) from previous days")
            }
        }
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
