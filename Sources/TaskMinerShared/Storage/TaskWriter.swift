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
    public func insertTask(_ task: TaskRecord) throws -> Int64 {
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

    /// Insert multiple tasks in a single transaction. Rolls back on first failure.
    @discardableResult
    public func insertTasks(_ tasks: [TaskRecord]) throws -> Int {
        guard !tasks.isEmpty else { return 0 }

        sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
        do {
            var inserted = 0
            for task in tasks {
                _ = try insertTask(task)
                inserted += 1
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return inserted
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Delete all tasks for a given date (for regeneration).
    public func deleteTasks(for dateString: String) throws {
        let sql = "DELETE FROM tasks WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (dateString as NSString).utf8String, -1, nil)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - Task Editing

    /// Update a task's title and description by ID.
    public func updateTask(id: Int64, title: String, description: String) throws {
        let sql = "UPDATE tasks SET title = ?, description = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (description as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 3, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    /// Delete a single task by its ID.
    public func deleteTask(id: Int64) throws {
        let sql = "DELETE FROM tasks WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - Screenshot Deletion

    /// Delete screenshot records by their IDs (single or bulk).
    public func deleteScreenshots(ids: Set<Int64>) throws {
        guard !ids.isEmpty else { return }

        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM screenshots WHERE id IN (\(placeholders))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(stmt, Int32(index + 1), id)
        }

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    // MARK: - Helpers

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }
}
