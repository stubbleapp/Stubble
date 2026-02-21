import Foundation
import SQLite3

/// Write-only database access scoped to the tasks table.
/// Used by the dashboard app for on-demand task generation.
public class TaskWriter {
    private var db: OpaquePointer?

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

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

        // WAL busy timeout for contention with CLI process
        sqlite3_busy_timeout(dbPointer, 5000)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    /// Insert a single task record into the database.
    @discardableResult
    public func insertTask(_ task: TaskRecord) -> Int64 {
        let sql = """
        INSERT INTO tasks (date, start_time, end_time, title, description, app_names, confidence)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.error("TaskWriter: Failed to prepare insertTask: \(lastError)")
            return -1
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
            Logger.error("TaskWriter: Failed to insert task: \(lastError)")
            return -1
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Insert multiple tasks in a single transaction. Rolls back on first failure.
    @discardableResult
    public func insertTasks(_ tasks: [TaskRecord]) -> Int {
        guard !tasks.isEmpty else { return 0 }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        var inserted = 0
        for task in tasks {
            if insertTask(task) <= 0 {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                Logger.error("TaskWriter: insertTasks rolled back after \(inserted) of \(tasks.count) inserts")
                return 0
            }
            inserted += 1
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return inserted
    }

    /// Delete all tasks for a given date (for regeneration).
    public func deleteTasks(for dateString: String) {
        let sql = "DELETE FROM tasks WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.error("TaskWriter: Failed to delete tasks: \(lastError)")
        }
    }

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }
}
