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
    _ = value.withCString { cStr in
        sqlite3_bind_text(stmt, index, cStr, -1, SQLITE_TRANSIENT)
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

    /// "yyyy-MM-dd" formatter — used for task date strings.
    public static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
