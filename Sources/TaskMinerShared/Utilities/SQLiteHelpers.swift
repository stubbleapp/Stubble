import Foundation
import SQLite3

// MARK: - Shared SQLite Helpers

/// SQLITE_TRANSIENT equivalent: tells SQLite to copy the string bytes immediately.
private let SQLITE_TRANSIENT = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

/// Bind a Swift String as TEXT with SQLITE_TRANSIENT so SQLite copies the bytes.
/// Safe for temporary / stack-allocated pointers.
public func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
    let rc = value.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT)
    }
    if rc != SQLITE_OK {
        Logger.warning("sqliteBindText failed at index \(index): rc=\(rc)")
    }
}

// MARK: - Shared Date Formatters

public enum SharedFormatters {
    /// ISO 8601 with fractional seconds — used for all database timestamps.
    public static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// "yyyy-MM-dd" — used for task date strings and DB queries.
    /// Fixed locale prevents non-Gregorian calendars (Buddhist, Japanese) from producing wrong years.
    public static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "HH:mm" — used for time display throughout the UI.
    public static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    /// "HH:mm:ss" — used for CSV export and AI prompt building.
    public static let timeSecondsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// "EEEE, MMMM d" — section headers (e.g. "Monday, January 6").
    public static let headerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    /// "EEEE, MMMM d, yyyy" — full date with year.
    public static let longDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f
    }()

    /// "EEE d" — short format for day selector (e.g. "Mon 6").
    public static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f
    }()
}
