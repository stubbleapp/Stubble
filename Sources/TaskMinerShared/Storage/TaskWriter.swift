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
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
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
        // Enable WAL mode for better concurrent read/write performance
        sqlite3_exec(dbPointer, "PRAGMA journal_mode=WAL", nil, nil, nil)
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    /// Insert a single task record into the database.
    @discardableResult
    public func insertTask(_ task: TaskRecord) throws -> Int64 {
        let sql = """
        INSERT INTO tasks (date, start_time, end_time, title, description, app_names, confidence, relevant_links, active_duration, websites)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        sqliteBindText(stmt, 10, task.websites)

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

    // MARK: - Chat Messages

    /// Create a chat thread and return its row ID.
    @discardableResult
    public func createChatThread(
        title: String,
        summary: String = "",
        contextDate: String? = nil
    ) throws -> Int64 {
        let sql = """
        INSERT INTO chat_threads (title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(stmt, 1, title)
        sqliteBindText(stmt, 2, summary)
        if let contextDate {
            sqliteBindText(stmt, 3, contextDate)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqliteBindText(stmt, 4, now)
        sqliteBindText(stmt, 5, now)
        sqlite3_bind_null(stmt, 6)
        sqlite3_bind_int(stmt, 7, 0)
        sqlite3_bind_int(stmt, 8, 0)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Update chat thread summary.
    public func updateChatThreadSummary(threadId: Int64, summary: String) throws {
        let sql = "UPDATE chat_threads SET summary = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, summary)
        sqliteBindText(stmt, 2, SharedFormatters.iso8601.string(from: Date()))
        sqlite3_bind_int64(stmt, 3, threadId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    /// Rename chat thread title.
    public func renameChatThread(threadId: Int64, title: String) throws {
        let sql = "UPDATE chat_threads SET title = ?, updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, title)
        sqliteBindText(stmt, 2, SharedFormatters.iso8601.string(from: Date()))
        sqlite3_bind_int64(stmt, 3, threadId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    /// Update activity metadata for a chat thread.
    public func touchChatThread(threadId: Int64, lastMessageAt: Date, messageCount: Int) throws {
        let sql = """
        UPDATE chat_threads
        SET last_message_at = ?, message_count = ?, updated_at = ?
        WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(stmt, 1, SharedFormatters.iso8601.string(from: lastMessageAt))
        sqlite3_bind_int(stmt, 2, Int32(messageCount))
        sqliteBindText(stmt, 3, now)
        sqlite3_bind_int64(stmt, 4, threadId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    /// Insert a single chat message record into the database.
    @discardableResult
    public func insertChatMessage(_ message: ChatMessageRecord) throws -> Int64 {
        let sql = """
        INSERT INTO chat_messages (thread_id, date, role, content, timestamp)
        VALUES (?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, message.threadId)
        sqliteBindText(stmt, 2, message.date)
        sqliteBindText(stmt, 3, message.role)
        sqliteBindText(stmt, 4, message.content)
        sqliteBindText(stmt, 5, SharedFormatters.iso8601.string(from: message.timestamp))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Delete all chat messages for a given date.
    public func deleteChatMessages(for dateString: String) throws {
        let sql = "DELETE FROM chat_messages WHERE date = ?"
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

    /// Delete all messages in a given thread.
    public func deleteChatMessages(threadId: Int64) throws {
        let sql = "DELETE FROM chat_messages WHERE thread_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, threadId)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
    }

    /// Delete a chat thread and all of its messages.
    public func deleteChatThread(threadId: Int64) throws {
        guard sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed("BEGIN TRANSACTION failed: \(lastError)")
        }
        do {
            try deleteChatMessages(threadId: threadId)

            let threadSql = "DELETE FROM chat_threads WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, threadSql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.executionFailed(lastError)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, threadId)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.executionFailed(lastError)
            }

            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw DatabaseError.executionFailed("COMMIT failed: \(lastError)")
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    // MARK: - Stubs Content

    /// Insert or replace stubs content for a given date (one record per day).
    @discardableResult
    public func insertOrReplaceStubsContent(_ record: StubsContentRecord) throws -> Int64 {
        let sql = """
        INSERT OR REPLACE INTO stubs_content
        (date, greeting_context, day_summary, questions_json, recommendations_json, generated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(lastError)
        }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, record.date)
        sqliteBindText(stmt, 2, record.greetingContext)
        if let summary = record.daySummary {
            sqliteBindText(stmt, 3, summary)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqliteBindText(stmt, 4, record.questionsJson)
        sqliteBindText(stmt, 5, record.recommendationsJson)
        sqliteBindText(stmt, 6, SharedFormatters.iso8601.string(from: record.generatedAt))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw DatabaseError.executionFailed(lastError)
        }
        return sqlite3_last_insert_rowid(db)
    }

    /// Delete stubs content for a given date.
    public func deleteStubsContent(for dateString: String) throws {
        let sql = "DELETE FROM stubs_content WHERE date = ?"
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

        // Safety: placeholders are always literal "?" characters, never interpolated values.
        // The actual IDs are bound via sqlite3_bind_int64 below, preventing SQL injection.
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
