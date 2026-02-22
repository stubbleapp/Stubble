import Foundation
import SQLite3

public enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case executionFailed(String)
    case migrationFailed(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Database open failed: \(msg)"
        case .executionFailed(let msg): return "Database error: \(msg)"
        case .migrationFailed(let msg): return "Migration failed: \(msg)"
        case .closed: return "Database connection is closed"
        }
    }
}

public class DatabaseReader {
    private var db: OpaquePointer?

    public init(path: URL) throws {
        var dbPointer: OpaquePointer?
        let rc = sqlite3_open_v2(
            path.path, &dbPointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX,
            nil
        )
        guard rc == SQLITE_OK else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPointer)
            throw DatabaseError.openFailed(msg)
        }
        self.db = dbPointer
        runMigrations()
    }

    /// Apply schema migrations so the dashboard works even if the CLI hasn't run yet.
    private func runMigrations() {
        // Migration 1: add ocr_text column to screenshots
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc1 = sqlite3_exec(db, "ALTER TABLE screenshots ADD COLUMN ocr_text TEXT", nil, nil, &errMsg)
        if rc1 != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? ""
            sqlite3_free(errMsg)
            if !msg.contains("duplicate column") {
                Logger.error("DatabaseReader migration failed: \(msg)")
            }
        }

        // Migration 2: create tasks table
        errMsg = nil
        let tasksSql = """
        CREATE TABLE IF NOT EXISTS tasks (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            date        TEXT NOT NULL,
            start_time  TEXT NOT NULL,
            end_time    TEXT NOT NULL,
            title       TEXT NOT NULL,
            description TEXT NOT NULL DEFAULT '',
            app_names   TEXT DEFAULT '[]',
            confidence  REAL DEFAULT 0.0
        )
        """
        let rc2 = sqlite3_exec(db, tasksSql, nil, nil, &errMsg)
        if rc2 != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? ""
            sqlite3_free(errMsg)
            Logger.error("DatabaseReader tasks migration failed: \(msg)")
        }

        // Migration 2b: indexes for tasks
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date)", nil, nil, nil)
        sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tasks_start ON tasks(start_time)", nil, nil, nil)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Activities

    public func activities(for date: Date) -> [ActivityRecord] {
        let range = dateRange(for: date)
        let sql = """
        SELECT id, timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle
        FROM activities
        WHERE timestamp >= ? AND timestamp < ?
        ORDER BY timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, range.start)
        sqliteBindText(stmt, 2, range.end)

        var results: [ActivityRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = ActivityRecord(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: sqlite3_column_text(stmt, 1).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                endTime: sqlite3_column_text(stmt, 2).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }),
                appName: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "Unknown",
                bundleId: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
                windowTitle: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }),
                duration: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_double(stmt, 6) : nil,
                isIdle: sqlite3_column_int(stmt, 7) != 0
            )
            results.append(record)
        }
        return results
    }

    // MARK: - Screenshots

    public func screenshots(for date: Date) -> [ScreenshotRecord] {
        let range = dateRange(for: date)
        let sql = """
        SELECT id, timestamp, file_path, file_size, activity_id, trigger_type, ocr_text
        FROM screenshots
        WHERE timestamp >= ? AND timestamp < ?
        ORDER BY timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, range.start)
        sqliteBindText(stmt, 2, range.end)

        var results: [ScreenshotRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let triggerStr = sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "manual"
            let record = ScreenshotRecord(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: sqlite3_column_text(stmt, 1).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                filePath: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
                fileSize: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil,
                activityId: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_int64(stmt, 4) : nil,
                trigger: ScreenshotTrigger(rawValue: triggerStr) ?? .manual,
                ocrText: sqlite3_column_text(stmt, 6).map({ String(cString: $0) })
            )
            results.append(record)
        }
        return results
    }

    // MARK: - Tasks

    public func tasks(for date: Date) -> [TaskRecord] {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

        let sql = """
        SELECT id, date, start_time, end_time, title, description, app_names, confidence
        FROM tasks
        WHERE date = ?
        ORDER BY start_time ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, dateStr)

        var results: [TaskRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = TaskRecord(
                id: sqlite3_column_int64(stmt, 0),
                date: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? dateStr,
                startTime: sqlite3_column_text(stmt, 2).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                endTime: sqlite3_column_text(stmt, 3).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                title: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) ?? "",
                description: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "",
                appNames: sqlite3_column_text(stmt, 6).map({ String(cString: $0) }) ?? "[]",
                confidence: sqlite3_column_double(stmt, 7)
            )
            results.append(record)
        }
        return results
    }

    /// Get all activities with OCR text for a date (used for on-demand summarization from dashboard)
    public func activitiesWithOCR(for date: Date) -> [SummarizationInput] {
        let range = dateRange(for: date)

        let sql = """
        SELECT a.app_name, a.bundle_id, a.window_title, a.timestamp, a.duration, a.is_idle,
               s.ocr_text
        FROM activities a
        LEFT JOIN screenshots s ON s.activity_id = a.id
        WHERE a.timestamp >= ? AND a.timestamp < ?
        ORDER BY a.timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, range.start)
        sqliteBindText(stmt, 2, range.end)

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

    // MARK: - Activity by ID

    public func activity(byId activityId: Int64) -> ActivityRecord? {
        let sql = """
        SELECT id, timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle
        FROM activities
        WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, activityId)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return ActivityRecord(
            id: sqlite3_column_int64(stmt, 0),
            timestamp: sqlite3_column_text(stmt, 1).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
            endTime: sqlite3_column_text(stmt, 2).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }),
            appName: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "Unknown",
            bundleId: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }),
            windowTitle: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }),
            duration: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? sqlite3_column_double(stmt, 6) : nil,
            isIdle: sqlite3_column_int(stmt, 7) != 0
        )
    }

    // MARK: - Dates with Data

    public func datesWithData() -> [String] {
        let sql = "SELECT DISTINCT date(timestamp) as d FROM activities ORDER BY d DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let dateStr = sqlite3_column_text(stmt, 0) {
                results.append(String(cString: dateStr))
            }
        }
        return results
    }

    /// Compute activity totals on-the-fly for days without a pre-generated summary
    public func computeSummary(for date: Date) -> (activeSeconds: Double, idleSeconds: Double, activityCount: Int, screenshotCount: Int) {
        let range = dateRange(for: date)

        // Activity totals
        let actSql = """
        SELECT COALESCE(SUM(CASE WHEN is_idle = 0 THEN duration ELSE 0 END), 0),
               COALESCE(SUM(CASE WHEN is_idle = 1 THEN duration ELSE 0 END), 0),
               COUNT(*)
        FROM activities WHERE timestamp >= ? AND timestamp < ? AND duration IS NOT NULL
        """
        var actStmt: OpaquePointer?
        var activeSeconds: Double = 0
        var idleSeconds: Double = 0
        var activityCount: Int = 0

        if sqlite3_prepare_v2(db, actSql, -1, &actStmt, nil) == SQLITE_OK {
            sqliteBindText(actStmt, 1, range.start)
            sqliteBindText(actStmt, 2, range.end)
            if sqlite3_step(actStmt) == SQLITE_ROW {
                activeSeconds = sqlite3_column_double(actStmt, 0)
                idleSeconds = sqlite3_column_double(actStmt, 1)
                activityCount = Int(sqlite3_column_int(actStmt, 2))
            }
            sqlite3_finalize(actStmt)
        }

        // Screenshot count
        let ssSql = "SELECT COUNT(*) FROM screenshots WHERE timestamp >= ? AND timestamp < ?"
        var ssStmt: OpaquePointer?
        var screenshotCount: Int = 0

        if sqlite3_prepare_v2(db, ssSql, -1, &ssStmt, nil) == SQLITE_OK {
            sqliteBindText(ssStmt, 1, range.start)
            sqliteBindText(ssStmt, 2, range.end)
            if sqlite3_step(ssStmt) == SQLITE_ROW {
                screenshotCount = Int(sqlite3_column_int(ssStmt, 0))
            }
            sqlite3_finalize(ssStmt)
        }

        return (activeSeconds, idleSeconds, activityCount, screenshotCount)
    }

    // MARK: - App Name → Bundle ID Mapping

    /// Returns a dictionary mapping app display names to bundle identifiers.
    public func appNameToBundleIdMap() -> [String: String] {
        let sql = "SELECT DISTINCT app_name, bundle_id FROM activities WHERE bundle_id IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        var map: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 0),
               let bundleId = sqlite3_column_text(stmt, 1) {
                map[String(cString: name)] = String(cString: bundleId)
            }
        }
        return map
    }

    // MARK: - Helpers

    private func dateRange(for date: Date) -> (start: String, end: String) {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        guard let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) else {
            return (SharedFormatters.iso8601.string(from: startOfDay), SharedFormatters.iso8601.string(from: startOfDay))
        }
        return (SharedFormatters.iso8601.string(from: startOfDay), SharedFormatters.iso8601.string(from: endOfDay))
    }
}
