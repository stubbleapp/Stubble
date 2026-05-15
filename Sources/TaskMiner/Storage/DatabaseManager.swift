import Foundation
import SQLite3
import TaskMinerShared

class DatabaseManager: KnowledgeGraphStore {
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
    private static let schemaVersion = 16

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

        if currentVersion < 12 {
            let granolaSql = """
            CREATE TABLE IF NOT EXISTS granola_meetings (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                granola_id        TEXT NOT NULL UNIQUE,
                title             TEXT NOT NULL,
                meeting_date      TEXT NOT NULL,
                start_time        TEXT NOT NULL,
                end_time          TEXT NOT NULL,
                duration          REAL NOT NULL DEFAULT 0,
                attendees_json    TEXT DEFAULT '[]',
                organizer         TEXT,
                notes_plain       TEXT,
                transcript_text   TEXT,
                summary           TEXT,
                meeting_url       TEXT,
                source_updated_at TEXT NOT NULL,
                imported_at       TEXT NOT NULL
            )
            """
            if !execMigration(granolaSql, label: "12: create granola_meetings table") {
                migrationFailed = true
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_granola_meetings_date ON granola_meetings(meeting_date)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_granola_meetings_granola_id ON granola_meetings(granola_id)", nil, nil, nil)
        }

        if currentVersion < 13 {
            let threadsSql = """
            CREATE TABLE IF NOT EXISTS chat_threads (
                id                INTEGER PRIMARY KEY AUTOINCREMENT,
                title             TEXT NOT NULL DEFAULT '',
                summary           TEXT NOT NULL DEFAULT '',
                context_date      TEXT,
                created_at        TEXT NOT NULL,
                updated_at        TEXT NOT NULL,
                last_message_at   TEXT,
                message_count     INTEGER NOT NULL DEFAULT 0,
                is_archived       INTEGER NOT NULL DEFAULT 0
            )
            """
            if !execMigration(threadsSql, label: "13a: create chat_threads table") {
                migrationFailed = true
            }

            if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_threads_last_message_at ON chat_threads(last_message_at)", nil, nil, nil) != SQLITE_OK {
                Logger.warning("Failed to create idx_chat_threads_last_message_at index")
            }
            if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_threads_updated_at ON chat_threads(updated_at)", nil, nil, nil) != SQLITE_OK {
                Logger.warning("Failed to create idx_chat_threads_updated_at index")
            }

            if !execMigration("ALTER TABLE chat_messages ADD COLUMN thread_id INTEGER NOT NULL DEFAULT 0",
                              label: "13b: add thread_id to chat_messages", ignoreDuplicate: true) {
                migrationFailed = true
            }

            // Backfill legacy date-scoped messages into one thread per day.
            let backfillThreadsSql = """
            INSERT INTO chat_threads (title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived)
            SELECT 'Chat ' || date, '', date, MIN(timestamp), MAX(timestamp), MAX(timestamp), COUNT(*), 0
            FROM chat_messages
            WHERE thread_id = 0
            GROUP BY date
            """
            if !execMigration(backfillThreadsSql, label: "13c: backfill chat_threads from legacy chat_messages") {
                migrationFailed = true
            }

            let backfillThreadIdsSql = """
            UPDATE chat_messages
            SET thread_id = (
                SELECT t.id
                FROM chat_threads t
                WHERE t.context_date = chat_messages.date
                ORDER BY t.id DESC
                LIMIT 1
            )
            WHERE thread_id = 0
            """
            if !execMigration(backfillThreadIdsSql, label: "13d: backfill thread_id on chat_messages") {
                migrationFailed = true
            }

            // Safety fallback for any rows that still don't resolve (only if orphan messages exist).
            let fallbackThreadSql = """
            INSERT INTO chat_threads (title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived)
            SELECT 'Legacy Chat', '', NULL, datetime('now'), datetime('now'), datetime('now'), 0, 0
            WHERE EXISTS (SELECT 1 FROM chat_messages WHERE thread_id = 0)
              AND NOT EXISTS (SELECT 1 FROM chat_threads WHERE title = 'Legacy Chat')
            """
            if !execMigration(fallbackThreadSql, label: "13e: ensure fallback legacy chat thread") {
                migrationFailed = true
            }

            let fallbackAssignSql = """
            UPDATE chat_messages
            SET thread_id = (SELECT id FROM chat_threads WHERE title = 'Legacy Chat' ORDER BY id DESC LIMIT 1)
            WHERE thread_id = 0
            """
            if !execMigration(fallbackAssignSql, label: "13f: assign fallback thread_id") {
                migrationFailed = true
            }

            if sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_messages_thread_id ON chat_messages(thread_id)", nil, nil, nil) != SQLITE_OK {
                Logger.warning("Failed to create idx_chat_messages_thread_id index")
            }
        }

        if currentVersion < 14 {
            // Notification delivery and engagement tracking
            let notificationsSql = """
            CREATE TABLE IF NOT EXISTS notifications (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                category TEXT NOT NULL,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                payload TEXT,
                relevance_score REAL NOT NULL,
                delivered_at TEXT NOT NULL,
                idle_at_delivery INTEGER NOT NULL,
                active_app_at_delivery TEXT,
                engagement TEXT,
                engaged_at TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )
            """
            if !execMigration(notificationsSql, label: "14a: create notifications table") {
                migrationFailed = true
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_notifications_delivered_at ON notifications(delivered_at)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_notifications_category ON notifications(category)", nil, nil, nil)

            // Per-category performance stats (for learning)
            let statsSql = """
            CREATE TABLE IF NOT EXISTS notification_category_stats (
                category TEXT PRIMARY KEY,
                total_sent INTEGER DEFAULT 0,
                total_clicked INTEGER DEFAULT 0,
                total_dismissed INTEGER DEFAULT 0,
                total_ignored INTEGER DEFAULT 0,
                confidence REAL DEFAULT 1.0,
                updated_at TEXT NOT NULL
            )
            """
            if !execMigration(statsSql, label: "14b: create notification_category_stats table") {
                migrationFailed = true
            }

            // Daily caps tracking
            let capsSql = """
            CREATE TABLE IF NOT EXISTS notification_caps (
                date TEXT NOT NULL,
                category TEXT NOT NULL,
                count INTEGER DEFAULT 0,
                PRIMARY KEY (date, category)
            )
            """
            if !execMigration(capsSql, label: "14c: create notification_caps table") {
                migrationFailed = true
            }
        }

        if currentVersion < 15 {
            // Day wrap metrics persistence
            if !execMigration("ALTER TABLE stubs_content ADD COLUMN focus_time_seconds INTEGER",
                            label: "15a: add focus_time_seconds to stubs_content", ignoreDuplicate: true) {
                migrationFailed = true
            }
            if !execMigration("ALTER TABLE stubs_content ADD COLUMN meeting_time_seconds INTEGER",
                            label: "15b: add meeting_time_seconds to stubs_content", ignoreDuplicate: true) {
                migrationFailed = true
            }
            if !execMigration("ALTER TABLE stubs_content ADD COLUMN project_count INTEGER",
                            label: "15c: add project_count to stubs_content", ignoreDuplicate: true) {
                migrationFailed = true
            }
        }

        if currentVersion < 16 {
            // Knowledge graph tables for evolved personalization
            let nodesSql = """
            CREATE TABLE IF NOT EXISTS knowledge_nodes (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                name TEXT NOT NULL,
                aliases TEXT DEFAULT '[]',
                confidence REAL DEFAULT 0.7,
                first_seen TEXT NOT NULL,
                last_seen TEXT NOT NULL,
                reinforcement_count INTEGER DEFAULT 1,
                properties TEXT DEFAULT '{}',
                UNIQUE(type, name)
            )
            """
            if !execMigration(nodesSql, label: "16a: create knowledge_nodes table") {
                migrationFailed = true
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_knowledge_nodes_type ON knowledge_nodes(type)", nil, nil, nil)

            let edgesSql = """
            CREATE TABLE IF NOT EXISTS knowledge_edges (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                source_id TEXT NOT NULL,
                target_id TEXT NOT NULL,
                confidence REAL DEFAULT 0.7,
                first_seen TEXT NOT NULL,
                last_seen TEXT NOT NULL,
                reinforcement_count INTEGER DEFAULT 1,
                context TEXT,
                UNIQUE(type, source_id, target_id)
            )
            """
            if !execMigration(edgesSql, label: "16b: create knowledge_edges table") {
                migrationFailed = true
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_knowledge_edges_source ON knowledge_edges(source_id)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_knowledge_edges_target ON knowledge_edges(target_id)", nil, nil, nil)
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

    // MARK: - Granola Meetings

    /// Insert or update a Granola meeting record (upsert by granola_id).
    func upsertGranolaMeeting(_ record: GranolaMeetingRecord) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO granola_meetings (granola_id, title, meeting_date, start_time, end_time,
            duration, attendees_json, organizer, notes_plain, transcript_text, summary,
            meeting_url, source_updated_at, imported_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(granola_id) DO UPDATE SET
            title = excluded.title,
            notes_plain = excluded.notes_plain,
            transcript_text = excluded.transcript_text,
            summary = excluded.summary,
            attendees_json = excluded.attendees_json,
            source_updated_at = excluded.source_updated_at,
            imported_at = excluded.imported_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.warning("Failed to prepare Granola meeting upsert: \(lastError)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        let startStr = SharedFormatters.iso8601.string(from: record.startTime)
        let endStr = SharedFormatters.iso8601.string(from: record.endTime)

        sqliteBindText(stmt, 1, record.granolaId)
        sqliteBindText(stmt, 2, record.title)
        sqliteBindText(stmt, 3, record.meetingDate)
        sqliteBindText(stmt, 4, startStr)
        sqliteBindText(stmt, 5, endStr)
        sqlite3_bind_double(stmt, 6, record.duration)
        sqliteBindText(stmt, 7, record.attendeesJson)
        if let org = record.organizer { sqliteBindText(stmt, 8, org) } else { sqlite3_bind_null(stmt, 8) }
        if let notes = record.notesPlain { sqliteBindText(stmt, 9, notes) } else { sqlite3_bind_null(stmt, 9) }
        if let transcript = record.transcriptText { sqliteBindText(stmt, 10, transcript) } else { sqlite3_bind_null(stmt, 10) }
        if let summary = record.summary { sqliteBindText(stmt, 11, summary) } else { sqlite3_bind_null(stmt, 11) }
        if let url = record.meetingURL { sqliteBindText(stmt, 12, url) } else { sqlite3_bind_null(stmt, 12) }
        sqliteBindText(stmt, 13, record.sourceUpdatedAt)
        sqliteBindText(stmt, 14, now)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.warning("Failed to upsert Granola meeting \(record.granolaId): \(lastError)")
        }
    }

    /// Fetch Granola meetings within a time range (used by summarization).
    func recentGranolaMeetings(from start: Date, to end: Date) -> [GranolaMeetingRecord] {
        guard db != nil else { return [] }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)
        let sql = """
        SELECT id, granola_id, title, meeting_date, start_time, end_time, duration,
               attendees_json, organizer, notes_plain, transcript_text, summary,
               meeting_url, source_updated_at, imported_at
        FROM granola_meetings
        WHERE start_time >= ? AND start_time < ?
        ORDER BY start_time ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)

        var results: [GranolaMeetingRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(parseGranolaMeetingRow(stmt))
        }
        return results
    }

    /// Prune Granola meetings older than the given number of days.
    func deleteGranolaMeetingsOlderThan(days: Int) {
        guard db != nil else { return }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        let cutoffStr = SharedFormatters.iso8601.string(from: cutoff)
        let sql = "DELETE FROM granola_meetings WHERE imported_at < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, cutoffStr)
        if sqlite3_step(stmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 { Logger.info("Deleted \(deleted) Granola meeting(s) older than \(days) days") }
        }
    }

    private func parseGranolaMeetingRow(_ stmt: OpaquePointer?) -> GranolaMeetingRecord {
        GranolaMeetingRecord(
            id: sqlite3_column_int64(stmt, 0),
            granolaId: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
            title: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
            meetingDate: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
            startTime: sqlite3_column_text(stmt, 4).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date(),
            endTime: sqlite3_column_text(stmt, 5).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date(),
            duration: sqlite3_column_double(stmt, 6),
            attendeesJson: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]",
            organizer: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
            notesPlain: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
            transcriptText: sqlite3_column_text(stmt, 10).map { String(cString: $0) },
            summary: sqlite3_column_text(stmt, 11).map { String(cString: $0) },
            meetingURL: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
            sourceUpdatedAt: sqlite3_column_text(stmt, 13).map { String(cString: $0) } ?? "",
            importedAt: sqlite3_column_text(stmt, 14).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
        )
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

    // MARK: - Notifications

    /// Insert a delivered notification record.
    func insertNotification(_ record: NotificationRecord) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO notifications (id, type, category, title, body, payload, relevance_score,
                                   delivered_at, idle_at_delivery, active_app_at_delivery,
                                   engagement, engaged_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.warning("Failed to prepare notification insert: \(lastError)")
            return
        }
        defer { sqlite3_finalize(stmt) }

        let deliveredStr = SharedFormatters.iso8601.string(from: record.deliveredAt)
        let createdStr = SharedFormatters.iso8601.string(from: record.createdAt)
        let payloadJson: String? = {
            guard let payload = record.payload else { return nil }
            guard let data = try? JSONEncoder().encode(payload),
                  let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }()

        sqliteBindText(stmt, 1, record.id)
        sqliteBindText(stmt, 2, record.type.rawValue)
        sqliteBindText(stmt, 3, record.category.rawValue)
        sqliteBindText(stmt, 4, record.title)
        sqliteBindText(stmt, 5, record.body)
        if let pj = payloadJson { sqliteBindText(stmt, 6, pj) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_double(stmt, 7, record.relevanceScore)
        sqliteBindText(stmt, 8, deliveredStr)
        sqlite3_bind_int(stmt, 9, record.idleAtDelivery ? 1 : 0)
        if let app = record.activeAppAtDelivery { sqliteBindText(stmt, 10, app) } else { sqlite3_bind_null(stmt, 10) }
        if let eng = record.engagement { sqliteBindText(stmt, 11, eng.rawValue) } else { sqlite3_bind_null(stmt, 11) }
        if let eAt = record.engagedAt { sqliteBindText(stmt, 12, SharedFormatters.iso8601.string(from: eAt)) } else { sqlite3_bind_null(stmt, 12) }
        sqliteBindText(stmt, 13, createdStr)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.warning("Failed to insert notification: \(lastError)")
        }
    }

    /// Update the engagement for a notification by ID.
    func updateNotificationEngagement(id: String, engagement: NotificationEngagement) {
        guard db != nil else { return }
        let sql = "UPDATE notifications SET engagement = ?, engaged_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(stmt, 1, engagement.rawValue)
        sqliteBindText(stmt, 2, now)
        sqliteBindText(stmt, 3, id)
        sqlite3_step(stmt)
    }

    /// Get notifications delivered today without engagement (for ignore detection).
    func notificationsWithoutEngagement(olderThan cutoff: Date) -> [NotificationRecord] {
        guard db != nil else { return [] }
        let cutoffStr = SharedFormatters.iso8601.string(from: cutoff)
        let sql = """
        SELECT id, type, category, title, body, payload, relevance_score,
               delivered_at, idle_at_delivery, active_app_at_delivery, engagement, engaged_at, created_at
        FROM notifications
        WHERE engagement IS NULL AND delivered_at < ?
        ORDER BY delivered_at ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, cutoffStr)

        var results: [NotificationRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(parseNotificationRow(stmt))
        }
        return results
    }

    /// Get the count of notifications delivered today.
    func notificationCountToday() -> Int {
        guard db != nil else { return 0 }
        let today = SharedFormatters.dayFormatter.string(from: Date())
        let sql = "SELECT COUNT(*) FROM notifications WHERE date(delivered_at) = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, today)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Get notifications delivered today for a specific category.
    func notificationCountToday(category: NotificationCategory) -> Int {
        guard db != nil else { return 0 }
        let today = SharedFormatters.dayFormatter.string(from: Date())
        let sql = "SELECT COUNT(*) FROM notifications WHERE date(delivered_at) = ? AND category = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, today)
        sqliteBindText(stmt, 2, category.rawValue)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    /// Check if a similar notification was sent recently (for recency deduplication).
    func recentSimilarNotificationExists(category: NotificationCategory, titleSubstring: String, withinHours: Int = 24) -> Bool {
        guard db != nil else { return false }
        let cutoff = Date().addingTimeInterval(-TimeInterval(withinHours * 3600))
        let cutoffStr = SharedFormatters.iso8601.string(from: cutoff)
        let sql = "SELECT 1 FROM notifications WHERE category = ? AND title LIKE ? AND delivered_at > ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, category.rawValue)
        sqliteBindText(stmt, 2, "%\(titleSubstring)%")
        sqliteBindText(stmt, 3, cutoffStr)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func parseNotificationRow(_ stmt: OpaquePointer?) -> NotificationRecord {
        let payloadJson = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let payload: NotificationPayload? = payloadJson.flatMap { json in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(NotificationPayload.self, from: data)
        }
        return NotificationRecord(
            id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
            type: NotificationType(rawValue: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "") ?? .link,
            category: NotificationCategory(rawValue: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "") ?? .bestPractice,
            title: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
            body: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
            payload: payload,
            relevanceScore: sqlite3_column_double(stmt, 6),
            deliveredAt: sqlite3_column_text(stmt, 7).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date(),
            idleAtDelivery: sqlite3_column_int(stmt, 8) != 0,
            activeAppAtDelivery: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
            engagement: sqlite3_column_text(stmt, 10).flatMap { NotificationEngagement(rawValue: String(cString: $0)) },
            engagedAt: sqlite3_column_text(stmt, 11).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) },
            createdAt: sqlite3_column_text(stmt, 12).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
        )
    }

    // MARK: - Notification Category Stats

    /// Get or create stats for a category.
    func notificationCategoryStats(for category: NotificationCategory) -> NotificationCategoryStats {
        guard db != nil else {
            return NotificationCategoryStats(category: category)
        }
        let sql = "SELECT total_sent, total_clicked, total_dismissed, total_ignored, confidence, updated_at FROM notification_category_stats WHERE category = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return NotificationCategoryStats(category: category)
        }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, category.rawValue)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return NotificationCategoryStats(
                category: category,
                totalSent: Int(sqlite3_column_int(stmt, 0)),
                totalClicked: Int(sqlite3_column_int(stmt, 1)),
                totalDismissed: Int(sqlite3_column_int(stmt, 2)),
                totalIgnored: Int(sqlite3_column_int(stmt, 3)),
                confidence: sqlite3_column_double(stmt, 4),
                updatedAt: sqlite3_column_text(stmt, 5).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
            )
        }
        return NotificationCategoryStats(category: category)
    }

    /// Update stats for a category (upsert).
    func updateNotificationCategoryStats(_ stats: NotificationCategoryStats) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO notification_category_stats (category, total_sent, total_clicked, total_dismissed, total_ignored, confidence, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(category) DO UPDATE SET
            total_sent = excluded.total_sent,
            total_clicked = excluded.total_clicked,
            total_dismissed = excluded.total_dismissed,
            total_ignored = excluded.total_ignored,
            confidence = excluded.confidence,
            updated_at = excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(stmt, 1, stats.category.rawValue)
        sqlite3_bind_int(stmt, 2, Int32(stats.totalSent))
        sqlite3_bind_int(stmt, 3, Int32(stats.totalClicked))
        sqlite3_bind_int(stmt, 4, Int32(stats.totalDismissed))
        sqlite3_bind_int(stmt, 5, Int32(stats.totalIgnored))
        sqlite3_bind_double(stmt, 6, stats.confidence)
        sqliteBindText(stmt, 7, now)
        sqlite3_step(stmt)
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

    // MARK: - Crash Recovery

    /// Finalize stale activities that were left open due to a crash or unexpected termination.
    /// Stale activities are those with no end_time (duration IS NULL) that started more than
    /// `staleThreshold` seconds ago.
    /// - Returns: The number of activities finalized.
    @discardableResult
    func finalizeStaleActivities(staleThreshold: TimeInterval = 300) -> Int {
        guard db != nil else { return 0 }

        let cutoff = Date().addingTimeInterval(-staleThreshold)
        let cutoffStr = SharedFormatters.iso8601.string(from: cutoff)

        // Find stale activities (no duration, started before cutoff) with the next activity's timestamp
        // Using a subquery to get the next activity's start time for smarter duration estimation
        let selectSql = """
        SELECT a.id, a.timestamp,
               (SELECT MIN(b.timestamp) FROM activities b WHERE b.timestamp > a.timestamp) as next_timestamp
        FROM activities a
        WHERE a.duration IS NULL AND a.timestamp < ?
        ORDER BY a.timestamp ASC
        """
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(selectStmt) }
        sqliteBindText(selectStmt, 1, cutoffStr)

        var staleActivities: [(id: Int64, timestamp: Date, nextTimestamp: Date?)] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(selectStmt, 0)
            if let tsStr = sqlite3_column_text(selectStmt, 1),
               let ts = SharedFormatters.iso8601.date(from: String(cString: tsStr)) {
                var nextTs: Date? = nil
                if sqlite3_column_type(selectStmt, 2) != SQLITE_NULL,
                   let nextTsStr = sqlite3_column_text(selectStmt, 2) {
                    nextTs = SharedFormatters.iso8601.date(from: String(cString: nextTsStr))
                }
                staleActivities.append((id: id, timestamp: ts, nextTimestamp: nextTs))
            }
        }

        guard !staleActivities.isEmpty else { return 0 }

        // Finalize each stale activity with estimated duration based on next activity
        let updateSql = "UPDATE activities SET end_time = ?, duration = ? WHERE id = ?"
        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSql, -1, &updateStmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(updateStmt) }

        let maxEstimatedDuration: TimeInterval = 3600 // Cap at 1 hour for safety
        let defaultDuration: TimeInterval = 300 // 5 minutes if no next activity

        var count = 0
        for stale in staleActivities {
            let estimatedDuration: TimeInterval
            let endTime: Date

            if let nextTs = stale.nextTimestamp {
                // Use time until next activity, capped at 1 hour
                let timeToNext = nextTs.timeIntervalSince(stale.timestamp)
                estimatedDuration = min(timeToNext, maxEstimatedDuration)
                endTime = stale.timestamp.addingTimeInterval(estimatedDuration)
            } else {
                // No next activity — use default 5 minutes
                estimatedDuration = defaultDuration
                endTime = stale.timestamp.addingTimeInterval(estimatedDuration)
            }

            let endTimeStr = SharedFormatters.iso8601.string(from: endTime)

            sqlite3_reset(updateStmt)
            sqliteBindText(updateStmt, 1, endTimeStr)
            sqlite3_bind_double(updateStmt, 2, estimatedDuration)
            sqlite3_bind_int64(updateStmt, 3, stale.id)

            if sqlite3_step(updateStmt) == SQLITE_DONE {
                count += 1
                Logger.debug("Crash recovery: activity \(stale.id) duration=\(Int(estimatedDuration))s")
            }
        }

        if count > 0 {
            Logger.info("Crash recovery: finalized \(count) stale activities")
        }
        return count
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

    // MARK: - Knowledge Graph

    /// Fetch all knowledge nodes, optionally filtered by type.
    func knowledgeNodes(type: NodeType? = nil) -> [KnowledgeNode] {
        guard db != nil else { return [] }

        let sql: String
        if let nodeType = type {
            sql = """
            SELECT id, type, name, aliases, confidence, first_seen, last_seen, reinforcement_count, properties
            FROM knowledge_nodes
            WHERE type = ?
            ORDER BY confidence DESC, last_seen DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqliteBindText(stmt, 1, nodeType.rawValue)
            return parseKnowledgeNodes(stmt)
        } else {
            sql = """
            SELECT id, type, name, aliases, confidence, first_seen, last_seen, reinforcement_count, properties
            FROM knowledge_nodes
            ORDER BY confidence DESC, last_seen DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            return parseKnowledgeNodes(stmt)
        }
    }

    /// Find a knowledge node by type and name.
    func knowledgeNode(type: NodeType, name: String) -> KnowledgeNode? {
        guard db != nil else { return nil }
        let sql = """
        SELECT id, type, name, aliases, confidence, first_seen, last_seen, reinforcement_count, properties
        FROM knowledge_nodes
        WHERE type = ? AND LOWER(name) = LOWER(?)
        LIMIT 1
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqliteBindText(stmt, 1, type.rawValue)
            sqliteBindText(stmt, 2, name)
            let nodes = parseKnowledgeNodes(stmt)
            sqlite3_finalize(stmt)
            if let node = nodes.first { return node }
        }
        let allNodes = knowledgeNodes(type: type)
        return allNodes.first { $0.matches(name: name) }
    }

    /// Fetch a knowledge node by ID.
    func knowledgeNode(id: UUID) -> KnowledgeNode? {
        guard db != nil else { return nil }
        let sql = """
        SELECT id, type, name, aliases, confidence, first_seen, last_seen, reinforcement_count, properties
        FROM knowledge_nodes
        WHERE id = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, id.uuidString)
        return parseKnowledgeNodes(stmt).first
    }

    private func parseKnowledgeNodes(_ stmt: OpaquePointer?) -> [KnowledgeNode] {
        var results: [KnowledgeNode] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let id = UUID(uuidString: idStr),
                  let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let type = NodeType(rawValue: typeStr),
                  let name = sqlite3_column_text(stmt, 2).map({ String(cString: $0) })
            else { continue }

            let aliasesJson = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "[]"
            let aliases = (try? JSONDecoder().decode([String].self, from: Data(aliasesJson.utf8))) ?? []
            let confidence = sqlite3_column_double(stmt, 4)
            let firstSeen = sqlite3_column_text(stmt, 5).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
            let lastSeen = sqlite3_column_text(stmt, 6).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
            let reinforcementCount = Int(sqlite3_column_int(stmt, 7))
            let propertiesJson = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? "{}"
            let properties = (try? JSONDecoder().decode([String: String].self, from: Data(propertiesJson.utf8))) ?? [:]

            results.append(KnowledgeNode(
                id: id, type: type, name: name, aliases: aliases, confidence: confidence,
                firstSeen: firstSeen, lastSeen: lastSeen, reinforcementCount: reinforcementCount, properties: properties
            ))
        }
        return results
    }

    /// Fetch knowledge edges.
    func knowledgeEdges(from sourceId: UUID? = nil, to targetId: UUID? = nil) -> [KnowledgeEdge] {
        guard db != nil else { return [] }

        var conditions: [String] = []
        if sourceId != nil { conditions.append("source_id = ?") }
        if targetId != nil { conditions.append("target_id = ?") }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT id, type, source_id, target_id, confidence, first_seen, last_seen, reinforcement_count, context
        FROM knowledge_edges
        \(whereClause)
        ORDER BY confidence DESC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var paramIdx: Int32 = 1
        if let src = sourceId {
            sqliteBindText(stmt, paramIdx, src.uuidString)
            paramIdx += 1
        }
        if let tgt = targetId {
            sqliteBindText(stmt, paramIdx, tgt.uuidString)
        }

        return parseKnowledgeEdges(stmt)
    }

    /// Find an edge by type and endpoints.
    func knowledgeEdge(type: EdgeType, source: UUID, target: UUID) -> KnowledgeEdge? {
        guard db != nil else { return nil }
        let sql = """
        SELECT id, type, source_id, target_id, confidence, first_seen, last_seen, reinforcement_count, context
        FROM knowledge_edges
        WHERE type = ? AND source_id = ? AND target_id = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, type.rawValue)
        sqliteBindText(stmt, 2, source.uuidString)
        sqliteBindText(stmt, 3, target.uuidString)
        return parseKnowledgeEdges(stmt).first
    }

    private func parseKnowledgeEdges(_ stmt: OpaquePointer?) -> [KnowledgeEdge] {
        var results: [KnowledgeEdge] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                  let id = UUID(uuidString: idStr),
                  let typeStr = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
                  let type = EdgeType(rawValue: typeStr),
                  let sourceStr = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
                  let sourceId = UUID(uuidString: sourceStr),
                  let targetStr = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let targetId = UUID(uuidString: targetStr)
            else { continue }

            let confidence = sqlite3_column_double(stmt, 4)
            let firstSeen = sqlite3_column_text(stmt, 5).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
            let lastSeen = sqlite3_column_text(stmt, 6).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
            let reinforcementCount = Int(sqlite3_column_int(stmt, 7))
            let context = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

            results.append(KnowledgeEdge(
                id: id, type: type, sourceId: sourceId, targetId: targetId,
                confidence: confidence, firstSeen: firstSeen, lastSeen: lastSeen,
                reinforcementCount: reinforcementCount, context: context
            ))
        }
        return results
    }

    /// Upsert a knowledge node.
    func upsertKnowledgeNode(_ node: KnowledgeNode) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO knowledge_nodes (id, type, name, aliases, confidence, first_seen, last_seen, reinforcement_count, properties)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(type, name) DO UPDATE SET
            aliases = excluded.aliases,
            confidence = MAX(confidence, excluded.confidence),
            last_seen = excluded.last_seen,
            reinforcement_count = reinforcement_count + 1,
            properties = excluded.properties
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let aliasesJson = (try? JSONEncoder().encode(node.aliases)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let propertiesJson = (try? JSONEncoder().encode(node.properties)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        sqliteBindText(stmt, 1, node.id.uuidString)
        sqliteBindText(stmt, 2, node.type.rawValue)
        sqliteBindText(stmt, 3, node.name)
        sqliteBindText(stmt, 4, aliasesJson)
        sqlite3_bind_double(stmt, 5, node.confidence)
        sqliteBindText(stmt, 6, SharedFormatters.iso8601.string(from: node.firstSeen))
        sqliteBindText(stmt, 7, SharedFormatters.iso8601.string(from: node.lastSeen))
        sqlite3_bind_int(stmt, 8, Int32(node.reinforcementCount))
        sqliteBindText(stmt, 9, propertiesJson)

        sqlite3_step(stmt)
    }

    /// Upsert a knowledge edge.
    func upsertKnowledgeEdge(_ edge: KnowledgeEdge) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO knowledge_edges (id, type, source_id, target_id, confidence, first_seen, last_seen, reinforcement_count, context)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(type, source_id, target_id) DO UPDATE SET
            confidence = MAX(confidence, excluded.confidence),
            last_seen = excluded.last_seen,
            reinforcement_count = reinforcement_count + 1,
            context = COALESCE(excluded.context, context)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, edge.id.uuidString)
        sqliteBindText(stmt, 2, edge.type.rawValue)
        sqliteBindText(stmt, 3, edge.sourceId.uuidString)
        sqliteBindText(stmt, 4, edge.targetId.uuidString)
        sqlite3_bind_double(stmt, 5, edge.confidence)
        sqliteBindText(stmt, 6, SharedFormatters.iso8601.string(from: edge.firstSeen))
        sqliteBindText(stmt, 7, SharedFormatters.iso8601.string(from: edge.lastSeen))
        sqlite3_bind_int(stmt, 8, Int32(edge.reinforcementCount))
        if let ctx = edge.context { sqliteBindText(stmt, 9, ctx) } else { sqlite3_bind_null(stmt, 9) }

        sqlite3_step(stmt)
    }

    /// Delete a knowledge node by ID.
    func deleteKnowledgeNode(id: UUID) {
        guard db != nil else { return }
        sqlite3_exec(db, "DELETE FROM knowledge_edges WHERE source_id = '\(id.uuidString)' OR target_id = '\(id.uuidString)'", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM knowledge_nodes WHERE id = '\(id.uuidString)'", nil, nil, nil)
    }

    /// Delete a knowledge edge by ID.
    func deleteKnowledgeEdge(id: UUID) {
        guard db != nil else { return }
        sqlite3_exec(db, "DELETE FROM knowledge_edges WHERE id = '\(id.uuidString)'", nil, nil, nil)
    }

    /// Update node confidence.
    func updateKnowledgeNodeConfidence(id: UUID, confidence: Double) {
        guard db != nil else { return }
        let sql = "UPDATE knowledge_nodes SET confidence = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, confidence)
        sqliteBindText(stmt, 2, id.uuidString)
        sqlite3_step(stmt)
    }

    /// Update edge confidence.
    func updateKnowledgeEdgeConfidence(id: UUID, confidence: Double) {
        guard db != nil else { return }
        let sql = "UPDATE knowledge_edges SET confidence = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, confidence)
        sqliteBindText(stmt, 2, id.uuidString)
        sqlite3_step(stmt)
    }

    /// Prune nodes below threshold.
    func pruneKnowledgeNodes(belowConfidence threshold: Double) -> Int {
        guard db != nil else { return 0 }
        var ids: [UUID] = []
        let selectSql = "SELECT id FROM knowledge_nodes WHERE confidence < ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, threshold)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                   let id = UUID(uuidString: idStr) {
                    ids.append(id)
                }
            }
            sqlite3_finalize(stmt)
        }
        for id in ids { deleteKnowledgeNode(id: id) }
        return ids.count
    }

    /// Prune edges below threshold.
    func pruneKnowledgeEdges(belowConfidence threshold: Double) -> Int {
        guard db != nil else { return 0 }
        let sql = "DELETE FROM knowledge_edges WHERE confidence < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, threshold)
        if sqlite3_step(stmt) == SQLITE_DONE {
            return Int(sqlite3_changes(db))
        }
        return 0
    }

    /// Count of knowledge nodes.
    func knowledgeNodeCount() -> Int {
        guard db != nil else { return 0 }
        let sql = "SELECT COUNT(*) FROM knowledge_nodes"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    // MARK: - Query Methods (for backfill)

    /// Fetch tasks for a specific date string (YYYY-MM-DD).
    func tasks(for dateStr: String) -> [TaskRecord] {
        guard db != nil else { return [] }
        let sql = """
        SELECT id, date, start_time, end_time, title, description, app_names, confidence, relevant_links, active_duration, websites
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
            let activeDuration: TimeInterval? = sqlite3_column_type(stmt, 9) != SQLITE_NULL
                ? sqlite3_column_double(stmt, 9) : nil
            let record = TaskRecord(
                id: sqlite3_column_int64(stmt, 0),
                date: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? dateStr,
                startTime: sqlite3_column_text(stmt, 2).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                endTime: sqlite3_column_text(stmt, 3).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                title: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) ?? "",
                description: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "",
                appNames: sqlite3_column_text(stmt, 6).map({ String(cString: $0) }) ?? "[]",
                confidence: sqlite3_column_double(stmt, 7),
                relevantLinks: sqlite3_column_text(stmt, 8).map({ String(cString: $0) }) ?? "[]",
                activeDuration: activeDuration,
                websites: sqlite3_column_text(stmt, 10).map({ String(cString: $0) }) ?? "[]"
            )
            results.append(record)
        }
        return results
    }

    /// Fetch project activities for a specific date string (YYYY-MM-DD).
    func projectActivities(for dateStr: String) -> [ProjectActivityRecord] {
        guard db != nil else { return [] }
        let sql = """
        SELECT id, date, name, summary, total_duration, app_names, task_titles, start_time, end_time, color_index
        FROM project_activities
        WHERE date = ?
        ORDER BY total_duration DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, dateStr)

        var results: [ProjectActivityRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = ProjectActivityRecord(
                id: sqlite3_column_int64(stmt, 0),
                date: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? dateStr,
                name: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
                summary: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "",
                totalDuration: sqlite3_column_double(stmt, 4),
                appNames: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "[]",
                taskTitles: sqlite3_column_text(stmt, 6).map({ String(cString: $0) }) ?? "[]",
                startTime: sqlite3_column_text(stmt, 7).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                endTime: sqlite3_column_text(stmt, 8).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                colorIndex: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 9)) : 0
            )
            results.append(record)
        }
        return results
    }

    /// Fetch activities for a date range.
    func activities(from start: Date, to end: Date, includeIdle: Bool, limit: Int) -> [ActivityRecord] {
        guard db != nil else { return [] }
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)

        let idleClause = includeIdle ? "" : "AND is_idle = 0"
        let sql = """
        SELECT id, timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle,
               browser_url, document_path, focused_element_role
        FROM activities
        WHERE timestamp >= ? AND timestamp < ? \(idleClause)
        ORDER BY timestamp ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)
        sqlite3_bind_int(stmt, 3, Int32(limit))

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
                isIdle: sqlite3_column_int(stmt, 7) != 0,
                browserURL: sqlite3_column_text(stmt, 8).map({ String(cString: $0) }),
                documentPath: sqlite3_column_text(stmt, 9).map({ String(cString: $0) }),
                focusedElementRole: sqlite3_column_text(stmt, 10).map({ String(cString: $0) })
            )
            results.append(record)
        }
        return results
    }

}
