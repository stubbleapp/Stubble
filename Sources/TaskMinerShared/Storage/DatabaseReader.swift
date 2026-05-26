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

@MainActor
public class DatabaseReader: @preconcurrency KnowledgeGraphStore {
    private var db: OpaquePointer?

    public init(path: URL) throws {
        var dbPointer: OpaquePointer?
        let rc = sqlite3_open_v2(
            path.path, &dbPointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard rc == SQLITE_OK else {
            let msg = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(dbPointer)
            throw DatabaseError.openFailed(msg)
        }
        self.db = dbPointer
        sqlite3_busy_timeout(dbPointer, 5000)
        // Enable WAL mode for better concurrent read/write performance.
        // Dashboard reads while daemon writes — WAL prevents lock contention.
        sqlite3_exec(dbPointer, "PRAGMA journal_mode=WAL", nil, nil, nil)
        runMigrations()
    }

    /// Current schema version. Bump this when adding new migrations.
    private static let schemaVersion = 18

    /// Apply schema migrations so the dashboard works even if the CLI hasn't run yet.
    /// Uses PRAGMA user_version to track which migrations have already run.
    private func runMigrations() {
        let currentVersion = getUserVersion()

        // Forward-compatibility guard: if the database was created by a newer version
        // of Stubble, don't touch the schema — we might corrupt newer structures.
        if currentVersion > Self.schemaVersion {
            Logger.warning("Database schema version \(currentVersion) is newer than this binary supports (\(Self.schemaVersion)). Skipping migrations.")
            return
        }

        // Run migrations sequentially — stop on first failure to prevent schema corruption.
        // Failed migrations will be retried on next launch since the version isn't bumped.

        if currentVersion < 1 {
            guard execMigration("ALTER TABLE screenshots ADD COLUMN ocr_text TEXT",
                              label: "1: add ocr_text", ignoreDuplicate: true) else {
                Logger.error("Migration 1 failed — stopping migrations")
                return
            }
        }

        if currentVersion < 2 {
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
            guard execMigration(tasksSql, label: "2: create tasks table") else {
                Logger.error("Migration 2 failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tasks_date ON tasks(date)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_tasks_start ON tasks(start_time)", nil, nil, nil)
        }

        if currentVersion < 3 {
            guard execMigration("ALTER TABLE tasks ADD COLUMN relevant_links TEXT DEFAULT '[]'",
                              label: "3: add relevant_links", ignoreDuplicate: true) else {
                Logger.error("Migration 3 failed — stopping migrations")
                return
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
            guard execMigration(paSql, label: "4: create project_activities table") else {
                Logger.error("Migration 4 failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_pa_date ON project_activities(date)", nil, nil, nil)
        }

        if currentVersion < 5 {
            guard execMigration("ALTER TABLE tasks ADD COLUMN active_duration REAL",
                              label: "5: add active_duration", ignoreDuplicate: true) else {
                Logger.error("Migration 5 failed — stopping migrations")
                return
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
            guard execMigration(chatSql, label: "6: create chat_messages table") else {
                Logger.error("Migration 6 failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_date ON chat_messages(date)", nil, nil, nil)
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
            guard execMigration(stubsSql, label: "7: create stubs_content table") else {
                Logger.error("Migration 7 failed — stopping migrations")
                return
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
            guard execMigration(digestSql, label: "8: create ocr_digests table") else {
                Logger.error("Migration 8 failed — stopping migrations")
                return
            }
        }

        if currentVersion < 9 {
            guard execMigration("ALTER TABLE activities ADD COLUMN browser_url TEXT",
                              label: "9a: add browser_url", ignoreDuplicate: true) else {
                Logger.error("Migration 9a failed — stopping migrations")
                return
            }
            guard execMigration("ALTER TABLE activities ADD COLUMN document_path TEXT",
                              label: "9b: add document_path", ignoreDuplicate: true) else {
                Logger.error("Migration 9b failed — stopping migrations")
                return
            }
            guard execMigration("ALTER TABLE activities ADD COLUMN focused_element_role TEXT",
                              label: "9c: add focused_element_role", ignoreDuplicate: true) else {
                Logger.error("Migration 9c failed — stopping migrations")
                return
            }
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
            guard execMigration(fileEventsSql, label: "9d: create file_events table") else {
                Logger.error("Migration 9d failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_file_events_timestamp ON file_events(timestamp)", nil, nil, nil)
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
            guard execMigration(habitsSql, label: "10: create habits_analysis table") else {
                Logger.error("Migration 10 failed — stopping migrations")
                return
            }
        }

        if currentVersion < 11 {
            guard execMigration("ALTER TABLE tasks ADD COLUMN websites TEXT DEFAULT '[]'",
                              label: "11: add websites to tasks", ignoreDuplicate: true) else {
                Logger.error("Migration 11 failed — stopping migrations")
                return
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
            guard execMigration(granolaSql, label: "12: create granola_meetings table") else {
                Logger.error("Migration 12 failed — stopping migrations")
                return
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
            guard execMigration(threadsSql, label: "13a: create chat_threads table") else {
                Logger.error("Migration 13a failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_threads_last_message_at ON chat_threads(last_message_at)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_threads_updated_at ON chat_threads(updated_at)", nil, nil, nil)

            guard execMigration("ALTER TABLE chat_messages ADD COLUMN thread_id INTEGER NOT NULL DEFAULT 0",
                              label: "13b: add thread_id to chat_messages", ignoreDuplicate: true) else {
                Logger.error("Migration 13b failed — stopping migrations")
                return
            }

            let backfillThreadsSql = """
            INSERT INTO chat_threads (title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived)
            SELECT 'Chat ' || date, '', date, MIN(timestamp), MAX(timestamp), MAX(timestamp), COUNT(*), 0
            FROM chat_messages
            WHERE thread_id = 0
            GROUP BY date
            """
            guard execMigration(backfillThreadsSql, label: "13c: backfill chat_threads from legacy chat_messages") else {
                Logger.error("Migration 13c failed — stopping migrations")
                return
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
            guard execMigration(backfillThreadIdsSql, label: "13d: backfill thread_id on chat_messages") else {
                Logger.error("Migration 13d failed — stopping migrations")
                return
            }

            let fallbackThreadSql = """
            INSERT INTO chat_threads (title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived)
            SELECT 'Legacy Chat', '', NULL, datetime('now'), datetime('now'), datetime('now'), 0, 0
            WHERE EXISTS (SELECT 1 FROM chat_messages WHERE thread_id = 0)
              AND NOT EXISTS (SELECT 1 FROM chat_threads WHERE title = 'Legacy Chat')
            """
            guard execMigration(fallbackThreadSql, label: "13e: ensure fallback legacy chat thread") else {
                Logger.error("Migration 13e failed — stopping migrations")
                return
            }

            let fallbackAssignSql = """
            UPDATE chat_messages
            SET thread_id = (SELECT id FROM chat_threads WHERE title = 'Legacy Chat' ORDER BY id DESC LIMIT 1)
            WHERE thread_id = 0
            """
            guard execMigration(fallbackAssignSql, label: "13f: assign fallback thread_id") else {
                Logger.error("Migration 13f failed — stopping migrations")
                return
            }

            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_chat_messages_thread_id ON chat_messages(thread_id)", nil, nil, nil)
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
            guard execMigration(notificationsSql, label: "14a: create notifications table") else {
                Logger.error("Migration 14a failed — stopping migrations")
                return
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
            guard execMigration(statsSql, label: "14b: create notification_category_stats table") else {
                Logger.error("Migration 14b failed — stopping migrations")
                return
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
            guard execMigration(capsSql, label: "14c: create notification_caps table") else {
                Logger.error("Migration 14c failed — stopping migrations")
                return
            }
        }

        if currentVersion < 15 {
            // Day wrap metrics persistence
            guard execMigration("ALTER TABLE stubs_content ADD COLUMN focus_time_seconds INTEGER",
                              label: "15a: add focus_time_seconds to stubs_content", ignoreDuplicate: true) else {
                Logger.error("Migration 15a failed — stopping migrations")
                return
            }
            guard execMigration("ALTER TABLE stubs_content ADD COLUMN meeting_time_seconds INTEGER",
                              label: "15b: add meeting_time_seconds to stubs_content", ignoreDuplicate: true) else {
                Logger.error("Migration 15b failed — stopping migrations")
                return
            }
            guard execMigration("ALTER TABLE stubs_content ADD COLUMN project_count INTEGER",
                              label: "15c: add project_count to stubs_content", ignoreDuplicate: true) else {
                Logger.error("Migration 15c failed — stopping migrations")
                return
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
            guard execMigration(nodesSql, label: "16a: create knowledge_nodes table") else {
                Logger.error("Migration 16a failed — stopping migrations")
                return
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
            guard execMigration(edgesSql, label: "16b: create knowledge_edges table") else {
                Logger.error("Migration 16b failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_knowledge_edges_source ON knowledge_edges(source_id)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_knowledge_edges_target ON knowledge_edges(target_id)", nil, nil, nil)
        }

        if currentVersion < 17 {
            // Day wrap + narrative: dedicated table (Stubs UI removed; stubs_content kept for legacy MCP/backfill).
            let dayWrapSql = """
            CREATE TABLE IF NOT EXISTS day_wrap (
                date                   TEXT PRIMARY KEY,
                summary                TEXT,
                focus_time_seconds     INTEGER,
                meeting_time_seconds   INTEGER,
                project_count          INTEGER,
                updated_at             TEXT NOT NULL
            )
            """
            guard execMigration(dayWrapSql, label: "17a: create day_wrap table") else {
                Logger.error("Migration 17a failed — stopping migrations")
                return
            }

            let backfillSql = """
            INSERT OR REPLACE INTO day_wrap (date, summary, focus_time_seconds, meeting_time_seconds, project_count, updated_at)
            SELECT date,
                   NULLIF(trim(day_summary), ''),
                   focus_time_seconds,
                   meeting_time_seconds,
                   project_count,
                   generated_at
            FROM stubs_content
            WHERE (day_summary IS NOT NULL AND length(trim(day_summary)) > 0)
               OR focus_time_seconds IS NOT NULL
               OR meeting_time_seconds IS NOT NULL
               OR project_count IS NOT NULL
            """
            guard execMigration(backfillSql, label: "17b: backfill day_wrap from stubs_content") else {
                Logger.error("Migration 17b failed — stopping migrations")
                return
            }
        }

        if currentVersion < 18 {
            // Window geometry snapshots — captures z-order, position, and size of visible windows
            let windowSnapshotsSql = """
            CREATE TABLE IF NOT EXISTS window_snapshots (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp       TEXT NOT NULL,
                activity_id     INTEGER,
                display_width   INTEGER NOT NULL,
                display_height  INTEGER NOT NULL,
                window_count    INTEGER NOT NULL,
                layout_json     TEXT NOT NULL,
                FOREIGN KEY (activity_id) REFERENCES activities(id)
            )
            """
            guard execMigration(windowSnapshotsSql, label: "18a: create window_snapshots table") else {
                Logger.error("Migration 18a failed — stopping migrations")
                return
            }
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_window_snapshots_timestamp ON window_snapshots(timestamp)", nil, nil, nil)
            sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS idx_window_snapshots_activity ON window_snapshots(activity_id)", nil, nil, nil)
        }

        // All migrations succeeded — bump the version
        if currentVersion < Self.schemaVersion {
            setUserVersion(Self.schemaVersion)
            Logger.info("DatabaseReader schema version updated: \(currentVersion) → \(Self.schemaVersion)")
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
                return true
            }
            Logger.error("DatabaseReader migration \(label) failed: \(msg)")
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

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - Activities

    public func activities(for date: Date) -> [ActivityRecord] {
        let range = dateRange(for: date)
        let sql = """
        SELECT id, timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle,
               browser_url, document_path, focused_element_role
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
                isIdle: sqlite3_column_int(stmt, 7) != 0,
                browserURL: sqlite3_column_text(stmt, 8).map({ String(cString: $0) }),
                documentPath: sqlite3_column_text(stmt, 9).map({ String(cString: $0) }),
                focusedElementRole: sqlite3_column_text(stmt, 10).map({ String(cString: $0) })
            )
            results.append(record)
        }
        return results
    }

    /// Fetch only idle activities for a date (optimized for timeline gap detection).
    public func idleActivities(for date: Date) -> [ActivityRecord] {
        let range = dateRange(for: date)
        let sql = """
        SELECT id, timestamp, end_time, app_name, bundle_id, window_title, duration, is_idle,
               browser_url, document_path, focused_element_role
        FROM activities
        WHERE timestamp >= ? AND timestamp < ? AND is_idle = 1
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
                isIdle: true, // Always true in this query
                browserURL: sqlite3_column_text(stmt, 8).map({ String(cString: $0) }),
                documentPath: sqlite3_column_text(stmt, 9).map({ String(cString: $0) }),
                focusedElementRole: sqlite3_column_text(stmt, 10).map({ String(cString: $0) })
            )
            results.append(record)
        }
        return results
    }

    /// Aggregate app durations for a date from activity records.
    /// This is more accurate than task-level attribution since it uses actual per-app time.
    public func appDurationsForDate(_ date: Date) -> [String: TimeInterval] {
        let range = dateRange(for: date)
        let sql = """
        SELECT app_name, SUM(duration) as total_duration
        FROM activities
        WHERE timestamp >= ? AND timestamp < ?
          AND is_idle = 0
          AND duration IS NOT NULL
        GROUP BY app_name
        ORDER BY total_duration DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, range.start)
        sqliteBindText(stmt, 2, range.end)

        var results: [String: TimeInterval] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let appName = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) ?? "Unknown"
            let duration = sqlite3_column_double(stmt, 1)
            results[appName] = duration
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

    // MARK: - File Events

    public func fileEvents(for date: Date) -> [FileEventRecord] {
        let range = dateRange(for: date)
        let sql = """
        SELECT id, timestamp, file_path, event_type, activity_id
        FROM file_events
        WHERE timestamp >= ? AND timestamp < ?
        ORDER BY timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, range.start)
        sqliteBindText(stmt, 2, range.end)

        var results: [FileEventRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = FileEventRecord(
                id: sqlite3_column_int64(stmt, 0),
                timestamp: sqlite3_column_text(stmt, 1).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                filePath: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
                eventType: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "modified",
                activityId: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_int64(stmt, 4) : nil
            )
            results.append(record)
        }
        return results
    }

    // MARK: - Granola Meetings

    public func granolaMeetings(for date: Date) -> [GranolaMeetingRecord] {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)
        let sql = """
        SELECT id, granola_id, title, meeting_date, start_time, end_time, duration,
               attendees_json, organizer, notes_plain, transcript_text, summary,
               meeting_url, source_updated_at, imported_at
        FROM granola_meetings
        WHERE meeting_date = ?
        ORDER BY start_time ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, dateStr)

        var results: [GranolaMeetingRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            results.append(GranolaMeetingRecord(
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
            ))
        }
        return results
    }

    // MARK: - Tasks

    public func tasks(for date: Date) -> [TaskRecord] {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

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

    // MARK: - Project Activities

    public func projectActivities(for date: Date) -> [ProjectActivityRecord] {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

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
                colorIndex: Int(sqlite3_column_int(stmt, 9))
            )
            results.append(record)
        }
        return results
    }

    /// Returns all unique project activities across all dates (one per unique name, most recent wins).
    public func allUniqueProjectActivities() -> [ProjectActivityRecord] {
        // Get the most recent record for each unique project name
        let sql = """
        SELECT id, date, name, summary, total_duration, app_names, task_titles, start_time, end_time, color_index
        FROM project_activities
        WHERE id IN (
            SELECT MAX(id) FROM project_activities GROUP BY name
        )
        ORDER BY name
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [ProjectActivityRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = ProjectActivityRecord(
                id: sqlite3_column_int64(stmt, 0),
                date: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? "",
                name: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
                summary: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "",
                totalDuration: sqlite3_column_double(stmt, 4),
                appNames: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "[]",
                taskTitles: sqlite3_column_text(stmt, 6).map({ String(cString: $0) }) ?? "[]",
                startTime: sqlite3_column_text(stmt, 7).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                endTime: sqlite3_column_text(stmt, 8).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                colorIndex: Int(sqlite3_column_int(stmt, 9))
            )
            results.append(record)
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

    // MARK: - Chat Messages

    public func chatThreads(limit: Int = 100) -> [ChatThreadRecord] {
        let sql = """
        SELECT id, title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived
        FROM chat_threads
        ORDER BY COALESCE(last_message_at, updated_at) DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var results: [ChatThreadRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = ChatThreadRecord(
                id: sqlite3_column_int64(stmt, 0),
                title: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? "",
                summary: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
                contextDate: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                createdAt: sqlite3_column_text(stmt, 4).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                updatedAt: sqlite3_column_text(stmt, 5).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
                lastMessageAt: sqlite3_column_text(stmt, 6).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }),
                messageCount: Int(sqlite3_column_int(stmt, 7)),
                isArchived: sqlite3_column_int(stmt, 8) != 0
            )
            results.append(record)
        }
        return results
    }

    public func chatThread(id: Int64) -> ChatThreadRecord? {
        let sql = """
        SELECT id, title, summary, context_date, created_at, updated_at, last_message_at, message_count, is_archived
        FROM chat_threads
        WHERE id = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ChatThreadRecord(
            id: sqlite3_column_int64(stmt, 0),
            title: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? "",
            summary: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
            contextDate: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
            createdAt: sqlite3_column_text(stmt, 4).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
            updatedAt: sqlite3_column_text(stmt, 5).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
            lastMessageAt: sqlite3_column_text(stmt, 6).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }),
            messageCount: Int(sqlite3_column_int(stmt, 7)),
            isArchived: sqlite3_column_int(stmt, 8) != 0
        )
    }

    public func chatMessages(threadId: Int64) -> [ChatMessageRecord] {
        let sql = """
        SELECT id, thread_id, date, role, content, timestamp
        FROM chat_messages
        WHERE thread_id = ?
        ORDER BY timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, threadId)

        var results: [ChatMessageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = ChatMessageRecord(
                id: sqlite3_column_int64(stmt, 0),
                threadId: sqlite3_column_int64(stmt, 1),
                date: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
                role: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "user",
                content: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) ?? "",
                timestamp: sqlite3_column_text(stmt, 5).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date()
            )
            results.append(record)
        }
        return results
    }

    public func chatMessages(for date: Date) -> [ChatMessageRecord] {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

        let sql = """
        SELECT id, thread_id, date, role, content, timestamp
        FROM chat_messages
        WHERE date = ?
        ORDER BY timestamp ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, dateStr)

        var results: [ChatMessageRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let record = ChatMessageRecord(
                id: sqlite3_column_int64(stmt, 0),
                threadId: sqlite3_column_int64(stmt, 1),
                date: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? dateStr,
                role: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }) ?? "user",
                content: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) ?? "",
                timestamp: sqlite3_column_text(stmt, 5).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date()
            )
            results.append(record)
        }
        return results
    }

    // MARK: - Stubs Content

    /// Load the persisted stubs content for a given date (one record per day, or nil if not generated yet).
    public func stubsContent(for date: Date) -> StubsContentRecord? {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)

        let sql = """
        SELECT id, date, greeting_context, day_summary, questions_json, recommendations_json, generated_at,
               focus_time_seconds, meeting_time_seconds, project_count
        FROM stubs_content
        WHERE date = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, dateStr)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return StubsContentRecord(
            id: sqlite3_column_int64(stmt, 0),
            date: sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) ?? dateStr,
            greetingContext: sqlite3_column_text(stmt, 2).map({ String(cString: $0) }) ?? "",
            daySummary: sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
            questionsJson: sqlite3_column_text(stmt, 4).map({ String(cString: $0) }) ?? "[]",
            recommendationsJson: sqlite3_column_text(stmt, 5).map({ String(cString: $0) }) ?? "[]",
            generatedAt: sqlite3_column_text(stmt, 6).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date(),
            focusTimeSeconds: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil,
            meetingTimeSeconds: sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 8)) : nil,
            projectCount: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 9)) : nil
        )
    }

    // MARK: - Day Wrap (timeline narrative + metrics)

    /// Row from `day_wrap` only.
    public func dayWrap(for date: Date) -> DayWrapRecord? {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)
        let sql = """
        SELECT date, summary, focus_time_seconds, meeting_time_seconds, project_count, updated_at
        FROM day_wrap
        WHERE date = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, dateStr)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let summaryRaw = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
        let summaryTrimmed = summaryRaw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String? = (summaryTrimmed?.isEmpty == false) ? summaryTrimmed : nil

        return DayWrapRecord(
            date: sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) ?? dateStr,
            summary: summary,
            focusTimeSeconds: sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 2)) : nil,
            meetingTimeSeconds: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 3)) : nil,
            projectCount: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 4)) : nil,
            updatedAt: sqlite3_column_text(stmt, 5).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }) ?? Date()
        )
    }

    /// Prefer `day_wrap`; fall back to legacy `stubs_content` for older databases.
    public func timelineDayWrap(for date: Date) -> DayWrapRecord? {
        if let row = dayWrap(for: date) {
            let hasSummary = row.summary.map { !$0.isEmpty } ?? false
            let hasMetrics = row.focusTimeSeconds != nil || row.meetingTimeSeconds != nil || row.projectCount != nil
            if hasSummary || hasMetrics { return row }
        }
        guard let stubs = stubsContent(for: date) else { return nil }
        let s = stubs.daySummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary: String? = (s?.isEmpty == false) ? s : nil
        let legacy = DayWrapRecord(
            date: stubs.date,
            summary: summary,
            focusTimeSeconds: stubs.focusTimeSeconds,
            meetingTimeSeconds: stubs.meetingTimeSeconds,
            projectCount: stubs.projectCount,
            updatedAt: stubs.generatedAt
        )
        let hasLegacySummary = legacy.summary.map { !$0.isEmpty } ?? false
        let hasLegacyMetrics = legacy.focusTimeSeconds != nil || legacy.meetingTimeSeconds != nil || legacy.projectCount != nil
        if hasLegacySummary || hasLegacyMetrics { return legacy }
        return nil
    }

    // MARK: - Window Snapshots

    /// Fetch window snapshots for a date range.
    public func windowSnapshots(from start: Date, to end: Date, limit: Int = 100) -> [WindowSnapshot] {
        let startStr = SharedFormatters.iso8601.string(from: start)
        let endStr = SharedFormatters.iso8601.string(from: end)
        let sql = """
        SELECT timestamp, display_width, display_height, layout_json
        FROM window_snapshots
        WHERE timestamp >= ? AND timestamp < ?
        ORDER BY timestamp ASC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, startStr)
        sqliteBindText(stmt, 2, endStr)
        sqlite3_bind_int(stmt, 3, Int32(limit))

        var results: [WindowSnapshot] = []
        let decoder = JSONDecoder()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let ts = sqlite3_column_text(stmt, 0).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }),
                  let layoutJson = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
                  let layoutData = layoutJson.data(using: .utf8),
                  let windows = try? decoder.decode([WindowInfo].self, from: layoutData) else {
                continue
            }

            let displayWidth = Int(sqlite3_column_int(stmt, 1))
            let displayHeight = Int(sqlite3_column_int(stmt, 2))

            results.append(WindowSnapshot(
                timestamp: ts,
                windows: windows,
                displayWidth: displayWidth,
                displayHeight: displayHeight
            ))
        }
        return results
    }

    /// Fetch window layout summaries for a date (lightweight, for prompt context).
    public func windowLayoutSummaries(for date: Date) -> [WindowLayoutSummary] {
        let range = dateRange(for: date)
        guard let start = SharedFormatters.iso8601.date(from: range.start),
              let end = SharedFormatters.iso8601.date(from: range.end) else { return [] }
        return windowSnapshots(from: start, to: end).map { WindowLayoutSummary(from: $0) }
    }

    /// Get the most recent window snapshot (useful for current context).
    public func latestWindowSnapshot() -> WindowSnapshot? {
        let sql = """
        SELECT timestamp, display_width, display_height, layout_json
        FROM window_snapshots
        ORDER BY timestamp DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let ts = sqlite3_column_text(stmt, 0).flatMap({ SharedFormatters.iso8601.date(from: String(cString: $0)) }),
              let layoutJson = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
              let layoutData = layoutJson.data(using: .utf8),
              let windows = try? JSONDecoder().decode([WindowInfo].self, from: layoutData) else {
            return nil
        }

        return WindowSnapshot(
            timestamp: ts,
            windows: windows,
            displayWidth: Int(sqlite3_column_int(stmt, 1)),
            displayHeight: Int(sqlite3_column_int(stmt, 2))
        )
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

    // MARK: - OCR Digest

    /// Fetch the cached OCR digest for a date. Returns nil if not yet computed.
    public func ocrDigest(for date: Date) -> String? {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)
        let sql = "SELECT digest FROM ocr_digests WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, dateStr)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(stmt, 0).map { String(cString: $0) }
    }

    /// Fetch the cached OCR digest record for a date, including generated_at timestamp.
    public func ocrDigestRecord(for date: Date) -> OCRDigestRecord? {
        let dateStr = SharedFormatters.dayFormatter.string(from: date)
        let sql = "SELECT date, digest, generated_at FROM ocr_digests WHERE date = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, dateStr)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return OCRDigestRecord(
            date: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? dateStr,
            digest: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
            generatedAt: sqlite3_column_text(stmt, 2).flatMap { SharedFormatters.iso8601.date(from: String(cString: $0)) } ?? Date()
        )
    }

    /// Fetch all OCR texts for a date (used to build digest on-demand in the dashboard).
    public func ocrTextsForDate(_ date: Date) -> [String] {
        let range = dateRange(for: date)
        let sql = "SELECT ocr_text FROM screenshots WHERE timestamp >= ? AND timestamp < ? AND ocr_text IS NOT NULL AND ocr_text != ''"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqliteBindText(stmt, 1, range.start)
        sqliteBindText(stmt, 2, range.end)

        var texts: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                texts.append(String(cString: cStr))
            }
        }
        return texts
    }

    /// Insert or replace the cached OCR digest for a date (used by dashboard on-demand computation).
    public func insertOrReplaceOCRDigest(date: String, digest: String) {
        guard db != nil else { return }
        let sql = """
        INSERT INTO ocr_digests (date, digest, generated_at) VALUES (?, ?, ?)
        ON CONFLICT(date) DO UPDATE SET digest = excluded.digest, generated_at = excluded.generated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        let now = SharedFormatters.iso8601.string(from: Date())
        sqliteBindText(stmt, 1, date)
        sqliteBindText(stmt, 2, digest)
        sqliteBindText(stmt, 3, now)
        sqlite3_step(stmt)
    }

    // MARK: - Clear All Data

    /// Delete all rows from every table. Returns the number of screenshot file paths
    /// that were in the database (caller should delete the files from disk).
    public func clearAllData() -> [String] {
        guard db != nil else { return [] }

        // Collect screenshot file paths before deleting rows (skip empty paths from pruned images)
        var paths: [String] = []
        let selectSql = "SELECT file_path FROM screenshots WHERE file_path IS NOT NULL AND file_path != ''"
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK {
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(selectStmt, 0) {
                    let path = String(cString: cStr)
                    if !path.isEmpty { paths.append(path) }
                }
            }
            sqlite3_finalize(selectStmt)
        }

        // Delete all rows from every table (explicit statements — no string interpolation)
        sqlite3_exec(db, "DELETE FROM tasks", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM project_activities", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM screenshots", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM activities", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM daily_summaries", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM chat_messages", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM chat_threads", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM stubs_content", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM day_wrap", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM ocr_digests", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM file_events", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM habits_analysis", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM granola_meetings", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM knowledge_nodes", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM knowledge_edges", nil, nil, nil)

        Logger.info("Cleared all data from core tables (\(paths.count) screenshot files)")
        return paths
    }

    // MARK: - Knowledge Graph

    /// Fetch all knowledge nodes, optionally filtered by type.
    public func knowledgeNodes(type: NodeType? = nil) -> [KnowledgeNode] {
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

    /// Find a knowledge node by type and name (exact or alias match).
    public func knowledgeNode(type: NodeType, name: String) -> KnowledgeNode? {
        guard db != nil else { return nil }

        // First try exact name match
        let exactSql = """
        SELECT id, type, name, aliases, confidence, first_seen, last_seen, reinforcement_count, properties
        FROM knowledge_nodes
        WHERE type = ? AND LOWER(name) = LOWER(?)
        LIMIT 1
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, exactSql, -1, &stmt, nil) == SQLITE_OK {
            sqliteBindText(stmt, 1, type.rawValue)
            sqliteBindText(stmt, 2, name)
            let nodes = parseKnowledgeNodes(stmt)
            sqlite3_finalize(stmt)
            if let node = nodes.first { return node }
        }

        // Fall back to alias search — requires loading all nodes of the type
        let allNodes = knowledgeNodes(type: type)
        return allNodes.first { $0.matches(name: name) }
    }

    /// Fetch a knowledge node by ID.
    public func knowledgeNode(id: UUID) -> KnowledgeNode? {
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
                id: id,
                type: type,
                name: name,
                aliases: aliases,
                confidence: confidence,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                reinforcementCount: reinforcementCount,
                properties: properties
            ))
        }
        return results
    }

    /// Fetch all knowledge edges, optionally filtered by source or target.
    public func knowledgeEdges(from sourceId: UUID? = nil, to targetId: UUID? = nil) -> [KnowledgeEdge] {
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

    /// Fetch a knowledge edge by type and endpoints.
    public func knowledgeEdge(type: EdgeType, source: UUID, target: UUID) -> KnowledgeEdge? {
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
                id: id,
                type: type,
                sourceId: sourceId,
                targetId: targetId,
                confidence: confidence,
                firstSeen: firstSeen,
                lastSeen: lastSeen,
                reinforcementCount: reinforcementCount,
                context: context
            ))
        }
        return results
    }

    /// Insert or update a knowledge node (upsert by type + name).
    public func upsertKnowledgeNode(_ node: KnowledgeNode) {
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.warning("Failed to prepare knowledge node upsert: \(lastError)")
            return
        }
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

        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.warning("Failed to upsert knowledge node '\(node.name)': \(lastError)")
        }
    }

    /// Insert or update a knowledge edge (upsert by type + source + target).
    public func upsertKnowledgeEdge(_ edge: KnowledgeEdge) {
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
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Logger.warning("Failed to prepare knowledge edge upsert: \(lastError)")
            return
        }
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

        if sqlite3_step(stmt) != SQLITE_DONE {
            Logger.warning("Failed to upsert knowledge edge: \(lastError)")
        }
    }

    /// Delete a knowledge node by ID (also deletes connected edges).
    public func deleteKnowledgeNode(id: UUID) {
        guard db != nil else { return }
        // Delete connected edges first
        let edgeSql = "DELETE FROM knowledge_edges WHERE source_id = ? OR target_id = ?"
        var edgeStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, edgeSql, -1, &edgeStmt, nil) == SQLITE_OK {
            sqliteBindText(edgeStmt, 1, id.uuidString)
            sqliteBindText(edgeStmt, 2, id.uuidString)
            sqlite3_step(edgeStmt)
            sqlite3_finalize(edgeStmt)
        }

        // Delete the node
        let nodeSql = "DELETE FROM knowledge_nodes WHERE id = ?"
        var nodeStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, nodeSql, -1, &nodeStmt, nil) == SQLITE_OK {
            sqliteBindText(nodeStmt, 1, id.uuidString)
            sqlite3_step(nodeStmt)
            sqlite3_finalize(nodeStmt)
        }
    }

    /// Delete a knowledge edge by ID.
    public func deleteKnowledgeEdge(id: UUID) {
        guard db != nil else { return }
        let sql = "DELETE FROM knowledge_edges WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, id.uuidString)
        sqlite3_step(stmt)
    }

    /// Prune knowledge nodes with confidence below threshold.
    public func pruneKnowledgeNodes(belowConfidence threshold: Double) -> Int {
        guard db != nil else { return 0 }

        // Get IDs to prune
        let selectSql = "SELECT id FROM knowledge_nodes WHERE confidence < ?"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSql, -1, &selectStmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(selectStmt) }
        sqlite3_bind_double(selectStmt, 1, threshold)

        var idsToDelete: [UUID] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            if let idStr = sqlite3_column_text(selectStmt, 0).map({ String(cString: $0) }),
               let id = UUID(uuidString: idStr) {
                idsToDelete.append(id)
            }
        }

        for id in idsToDelete {
            deleteKnowledgeNode(id: id)
        }

        if !idsToDelete.isEmpty {
            Logger.info("Pruned \(idsToDelete.count) knowledge node(s) below confidence \(threshold)")
        }
        return idsToDelete.count
    }

    /// Prune knowledge edges with confidence below threshold.
    public func pruneKnowledgeEdges(belowConfidence threshold: Double) -> Int {
        guard db != nil else { return 0 }
        let sql = "DELETE FROM knowledge_edges WHERE confidence < ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, threshold)

        if sqlite3_step(stmt) == SQLITE_DONE {
            let deleted = sqlite3_changes(db)
            if deleted > 0 {
                Logger.info("Pruned \(deleted) knowledge edge(s) below confidence \(threshold)")
            }
            return Int(deleted)
        }
        return 0
    }

    /// Update confidence for a node (used by decay).
    public func updateKnowledgeNodeConfidence(id: UUID, confidence: Double) {
        guard db != nil else { return }
        let sql = "UPDATE knowledge_nodes SET confidence = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, confidence)
        sqliteBindText(stmt, 2, id.uuidString)
        sqlite3_step(stmt)
    }

    /// Update confidence for an edge (used by decay).
    public func updateKnowledgeEdgeConfidence(id: UUID, confidence: Double) {
        guard db != nil else { return }
        let sql = "UPDATE knowledge_edges SET confidence = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, confidence)
        sqliteBindText(stmt, 2, id.uuidString)
        sqlite3_step(stmt)
    }

    /// Count of knowledge nodes.
    public func knowledgeNodeCount() -> Int {
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

    private var lastError: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "no database"
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
