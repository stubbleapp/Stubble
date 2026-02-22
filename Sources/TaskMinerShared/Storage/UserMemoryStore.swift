import Foundation

/// A single learned fact about the user.
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let content: String
    public let learnedAt: Date

    public init(id: UUID = UUID(), content: String, learnedAt: Date = Date()) {
        self.id = id
        self.content = content
        self.learnedAt = learnedAt
    }
}

/// Persistent store for user memory — a flat list of learned facts about the user's
/// projects, habits, and workflows. Backed by a JSON file on disk.
public final class UserMemoryStore: Sendable {
    private let filePath: URL

    public init(filePath: URL) {
        self.filePath = filePath
    }

    /// Load all memory entries from disk.
    public func load() -> [MemoryEntry] {
        guard FileManager.default.fileExists(atPath: filePath.path),
              let data = try? Data(contentsOf: filePath),
              let entries = try? JSONDecoder.iso8601.decode([MemoryEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    /// Replace the entire memory with new entries and persist to disk.
    public func save(_ entries: [MemoryEntry]) {
        let dir = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder.iso8601.encode(entries) {
            try? data.write(to: filePath, options: .atomic)
        }
    }

    /// Build a compact text representation of memory for injection into prompts.
    /// Returns nil if there are no entries.
    public func contextString() -> String? {
        let entries = load()
        guard !entries.isEmpty else { return nil }
        return entries.map { "- \($0.content)" }.joined(separator: "\n")
    }

    /// Delete a single entry by ID.
    public func delete(id: UUID) {
        var entries = load()
        entries.removeAll { $0.id == id }
        save(entries)
    }

    /// Merge new AI-generated entries with existing memory, replacing duplicates.
    public func merge(newEntries: [String]) {
        var existing = load()
        let existingSet = Set(existing.map { $0.content.lowercased() })

        for content in newEntries {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !existingSet.contains(trimmed.lowercased()) else { continue }
            existing.append(MemoryEntry(content: trimmed))
        }

        // Cap at 50 entries — drop oldest if needed
        if existing.count > 50 {
            existing = Array(existing.suffix(50))
        }

        save(existing)
    }
}

// MARK: - ISO 8601 Coder helpers

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
