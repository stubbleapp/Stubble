import Foundation
import SQLite3

/// Write-only database access scoped to the tasks table.
/// Used by the dashboard app for on-demand task generation.
public class TaskWriter {
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
        INSERT INTO tasks (date, start_time, end_time, title, description, app_names, confidence, relevant_links)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Insert multiple tasks in a single transaction. Rolls back on first failure.
    @discardableResult
    public func insertTasks(_ tasks: [TaskRecord]) throws -> Int {
        guard !tasks.isEmpty else { return 0 }

        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed("BEGIN TRANSACTION failed: \(lastError)")
        }
        do {
            var inserted = 0
            for task in tasks {
                _ = try insertTask(task)
                inserted += 1
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.executionFailed("COMMIT failed: \(lastError)")
            }
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

        sqliteBindText(stmt, 1, dateString)

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

        sqliteBindText(stmt, 1, title)
        sqliteBindText(stmt, 2, description)
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

    // MARK: - Project Activities

    /// Insert a single project activity record.
    @discardableResult
    public func insertProjectActivity(_ record: ProjectActivityRecord) throws -> Int64 {
        let sql = """
        INSERT INTO project_activities (date, name, summary, total_duration, app_names, task_titles, start_time, end_time, color_index)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
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

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Insert multiple project activities in a transaction.
    @discardableResult
    public func insertProjectActivities(_ records: [ProjectActivityRecord]) throws -> Int {
        guard !records.isEmpty else { return 0 }

        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed("BEGIN TRANSACTION failed: \(lastError)")
        }
        do {
            var inserted = 0
            for record in records {
                _ = try insertProjectActivity(record)
                inserted += 1
            }
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.executionFailed("COMMIT failed: \(lastError)")
            }
            return inserted
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Delete all project activities for a given date.
    public func deleteProjectActivities(for dateString: String) throws {
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
