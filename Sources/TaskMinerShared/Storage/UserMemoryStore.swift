import Foundation

// MARK: - Memory Model

public enum MemoryCategory: String, Codable, CaseIterable, Sendable {
    case identity
    case project
    case technology
    case workflow
    case interest
}

public enum MemorySource: String, Codable, Sendable {
    case activityInference
    case chatInteraction
    case userExplicit
}

/// A single learned fact about the user, categorized and tracked over time.
public struct MemoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public let category: MemoryCategory
    public let content: String
    public let confidence: Double
    public let firstSeen: Date
    public var lastSeen: Date
    public var reinforcementCount: Int
    public var source: MemorySource

    public init(
        id: UUID = UUID(),
        category: MemoryCategory = .workflow,
        content: String,
        confidence: Double = 0.7,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        reinforcementCount: Int = 1,
        source: MemorySource = .activityInference
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.confidence = min(1.0, max(0.0, confidence))
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.reinforcementCount = reinforcementCount
        self.source = source
    }
}

// MARK: - Persisted File Format

/// Top-level JSON structure for memory.json. Holds entries plus
/// an optional synthesized profile paragraph used in prompt injection.
struct MemoryFile: Codable {
    var entries: [MemoryEntry]
    var profile: String?

    init(entries: [MemoryEntry] = [], profile: String? = nil) {
        self.entries = entries
        self.profile = profile
    }
}

// MARK: - Store

/// Persistent store for user memory — categorized facts about the user's
/// projects, habits, and workflows. Backed by a JSON file on disk.
public final class UserMemoryStore: Sendable {
    private let filePath: URL
    private let lockPath: URL

    public init(filePath: URL) {
        self.filePath = filePath
        self.lockPath = filePath.deletingLastPathComponent().appendingPathComponent(".memory.lock")
    }

    // MARK: - File Locking

    private func withFileLock<T>(_ body: () -> T) -> T {
        FileManager.default.createFile(atPath: lockPath.path, contents: nil)
        guard let lockFd = FileHandle(forWritingAtPath: lockPath.path) else {
            return body()
        }
        flock(lockFd.fileDescriptor, LOCK_EX)
        defer {
            flock(lockFd.fileDescriptor, LOCK_UN)
            lockFd.closeFile()
        }
        return body()
    }

    // MARK: - Load / Save

    /// Load the full memory file (entries + profile) from disk.
    /// Transparently migrates the legacy flat-array format on first read.
    func loadFile() -> MemoryFile {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            return MemoryFile()
        }
        do {
            let data = try Data(contentsOf: filePath)
            // Try new format first
            if let file = try? JSONDecoder.iso8601.decode(MemoryFile.self, from: data) {
                return file
            }
            // Fall back to legacy flat array of old-style entries
            let legacy = try JSONDecoder.iso8601.decode([LegacyMemoryEntry].self, from: data)
            let migrated = legacy.map { old in
                MemoryEntry(
                    id: old.id,
                    category: .workflow,
                    content: old.content,
                    confidence: 0.7,
                    firstSeen: old.learnedAt,
                    lastSeen: old.learnedAt,
                    reinforcementCount: 1,
                    source: .activityInference
                )
            }
            let file = MemoryFile(entries: migrated)
            saveImpl(file)
            Logger.info("UserMemoryStore: migrated \(migrated.count) legacy entries to structured format")
            return file
        } catch {
            Logger.error("UserMemoryStore: failed to load from \(filePath.lastPathComponent): \(error.localizedDescription)")
            return MemoryFile()
        }
    }

    private func saveImpl(_ file: MemoryFile) {
        let dir = filePath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Logger.error("UserMemoryStore: failed to create directory \(dir.path): \(error.localizedDescription)")
            return
        }
        do {
            let data = try JSONEncoder.iso8601.encode(file)
            try data.write(to: filePath, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
        } catch {
            Logger.error("UserMemoryStore: failed to save to \(filePath.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Load all memory entries from disk.
    public func load() -> [MemoryEntry] {
        loadFile().entries
    }

    /// Replace the entire entry list and persist to disk (file-locked).
    public func save(_ entries: [MemoryEntry]) {
        withFileLock {
            var file = loadFile()
            file.entries = entries
            saveImpl(file)
        }
    }

    // MARK: - Profile

    /// The synthesized user profile paragraph, or nil if not yet generated.
    public func loadProfile() -> String? {
        loadFile().profile
    }

    /// Persist an updated synthesized profile (file-locked).
    public func saveProfile(_ profile: String) {
        withFileLock {
            var file = loadFile()
            file.profile = profile
            saveImpl(file)
        }
    }

    // MARK: - Context for Prompts

    /// Returns the synthesized profile if available, otherwise falls back to
    /// a bullet-list of all entries grouped by category.
    public func contextString() -> String? {
        let file = loadFile()
        if let profile = file.profile, !profile.isEmpty {
            return profile
        }
        guard !file.entries.isEmpty else { return nil }
        return buildFallbackContext(from: file.entries)
    }

    /// Build a structured bullet-list from entries, grouped by category
    /// and sorted by confidence descending within each group.
    private func buildFallbackContext(from entries: [MemoryEntry]) -> String {
        let grouped = Dictionary(grouping: entries, by: \.category)
        let categoryOrder: [MemoryCategory] = [.identity, .project, .technology, .workflow, .interest]
        var lines: [String] = []
        for cat in categoryOrder {
            guard let items = grouped[cat], !items.isEmpty else { continue }
            let sorted = items.sorted { $0.confidence > $1.confidence }
            lines.append("\(cat.rawValue.capitalized):")
            for item in sorted {
                lines.append("- \(item.content)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Delete / Clear

    /// Remove all memory entries and profile (file-locked).
    public func clear() {
        withFileLock { saveImpl(MemoryFile()) }
    }

    /// Delete a single entry by ID (file-locked).
    public func delete(id: UUID) {
        withFileLock {
            var file = loadFile()
            file.entries.removeAll { $0.id == id }
            saveImpl(file)
        }
    }

    // MARK: - Merge (structured entries)

    /// Merge new structured entries with existing memory using heuristic
    /// deduplication: same category + high word overlap = reinforcement.
    public func mergeStructured(newEntries: [MemoryEntry]) {
        withFileLock {
            var file = loadFile()
            let now = Date()

            for incoming in newEntries {
                let trimmed = incoming.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if let matchIdx = findBestMatch(for: incoming, in: file.entries) {
                    // Reinforce existing entry
                    file.entries[matchIdx].lastSeen = now
                    file.entries[matchIdx].reinforcementCount += 1
                } else {
                    file.entries.append(MemoryEntry(
                        category: incoming.category,
                        content: trimmed,
                        confidence: incoming.confidence,
                        firstSeen: now,
                        lastSeen: now,
                        reinforcementCount: 1,
                        source: incoming.source
                    ))
                }
            }

            // Decay: lower confidence of stale, weakly-reinforced entries
            for i in file.entries.indices {
                let age = now.timeIntervalSince(file.entries[i].lastSeen)
                let isWeak = file.entries[i].reinforcementCount <= 1
                if isWeak && age > 30 * 86400 {
                    file.entries[i] = MemoryEntry(
                        id: file.entries[i].id,
                        category: file.entries[i].category,
                        content: file.entries[i].content,
                        confidence: max(0.1, file.entries[i].confidence - 0.1),
                        firstSeen: file.entries[i].firstSeen,
                        lastSeen: file.entries[i].lastSeen,
                        reinforcementCount: file.entries[i].reinforcementCount,
                        source: file.entries[i].source
                    )
                }
            }

            // Remove entries that decayed below threshold
            file.entries.removeAll { $0.confidence < 0.15 }

            // Cap at 50 entries — drop lowest-confidence first
            if file.entries.count > 50 {
                file.entries.sort { $0.confidence > $1.confidence }
                file.entries = Array(file.entries.prefix(50))
            }

            saveImpl(file)
        }
    }

    /// Legacy merge for flat string entries (backward compatibility with
    /// callers that haven't been updated yet).
    public func merge(newEntries: [String]) {
        let structured = newEntries.compactMap { content -> MemoryEntry? in
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return MemoryEntry(category: .workflow, content: trimmed)
        }
        mergeStructured(newEntries: structured)
    }

    // MARK: - Heuristic Matching

    /// Find the best matching existing entry for an incoming one.
    /// Matches on same category + >50% word overlap.
    private func findBestMatch(for incoming: MemoryEntry, in entries: [MemoryEntry]) -> Int? {
        let incomingWords = wordSet(incoming.content)
        var bestIdx: Int?
        var bestOverlap: Double = 0

        for (i, existing) in entries.enumerated() {
            guard existing.category == incoming.category else { continue }
            let existingWords = wordSet(existing.content)
            let intersection = incomingWords.intersection(existingWords)
            let union = incomingWords.union(existingWords)
            guard !union.isEmpty else { continue }
            let jaccard = Double(intersection.count) / Double(union.count)
            if jaccard > 0.5 && jaccard > bestOverlap {
                bestOverlap = jaccard
                bestIdx = i
            }
        }

        return bestIdx
    }

    private func wordSet(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 2 })
    }
}

// MARK: - Legacy Migration

/// The old MemoryEntry format (pre-structured), used only for migration.
private struct LegacyMemoryEntry: Codable {
    let id: UUID
    let content: String
    let learnedAt: Date
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
