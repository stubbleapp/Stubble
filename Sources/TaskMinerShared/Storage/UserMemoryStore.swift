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
    /// When true, this entry corrects/replaces a previously held belief.
    public var isCorrection: Bool

    public init(
        id: UUID = UUID(),
        category: MemoryCategory = .workflow,
        content: String,
        confidence: Double = 0.7,
        firstSeen: Date = Date(),
        lastSeen: Date = Date(),
        reinforcementCount: Int = 1,
        source: MemorySource = .activityInference,
        isCorrection: Bool = false
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.confidence = min(1.0, max(0.0, confidence))
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.reinforcementCount = reinforcementCount
        self.source = source
        self.isCorrection = isCorrection
    }

    // Custom decoder for backward compatibility — isCorrection defaults to false
    // when loading old memory.json files that don't have the field.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        category = try container.decode(MemoryCategory.self, forKey: .category)
        content = try container.decode(String.self, forKey: .content)
        confidence = try container.decode(Double.self, forKey: .confidence)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        reinforcementCount = try container.decode(Int.self, forKey: .reinforcementCount)
        source = try container.decode(MemorySource.self, forKey: .source)
        isCorrection = try container.decodeIfPresent(Bool.self, forKey: .isCorrection) ?? false
    }
}

// MARK: - Persisted File Format

/// Top-level JSON structure for memory.json. Holds entries plus
/// an optional synthesized profile paragraph used in prompt injection.
struct MemoryFile: Codable {
    var entries: [MemoryEntry]
    var profile: String?
    /// Timestamp of the last profile synthesis (for throttling).
    var lastSynthesizedAt: Date?
    /// Entry count at the time of last synthesis (for change detection).
    var entryCountAtLastSynthesis: Int?

    init(entries: [MemoryEntry] = [], profile: String? = nil,
         lastSynthesizedAt: Date? = nil, entryCountAtLastSynthesis: Int? = nil) {
        self.entries = entries
        self.profile = profile
        self.lastSynthesizedAt = lastSynthesizedAt
        self.entryCountAtLastSynthesis = entryCountAtLastSynthesis
    }

    // Custom decoder for backward compatibility with old memory.json files.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decode([MemoryEntry].self, forKey: .entries)
        profile = try container.decodeIfPresent(String.self, forKey: .profile)
        lastSynthesizedAt = try container.decodeIfPresent(Date.self, forKey: .lastSynthesizedAt)
        entryCountAtLastSynthesis = try container.decodeIfPresent(Int.self, forKey: .entryCountAtLastSynthesis)
    }
}

// MARK: - Store

/// Persistent store for user memory — categorized facts about the user's
/// projects, habits, and workflows. Backed by a JSON file on disk.
public final class UserMemoryStore: @unchecked Sendable {
    private let filePath: URL
    private let lockPath: URL
    /// In-process lock to prevent data races between concurrent async tasks.
    /// flock() alone is per-file-descriptor, not per-file within the same process,
    /// so two tasks opening separate FileHandles would both acquire the flock.
    private let inProcessLock = NSLock()

    public init(filePath: URL) {
        self.filePath = filePath
        self.lockPath = filePath.deletingLastPathComponent().appendingPathComponent(".memory.lock")
    }

    // MARK: - File Locking

    private func withFileLock<T>(_ body: () -> T) -> T {
        inProcessLock.lock()
        defer { inProcessLock.unlock() }

        FileManager.default.createFile(atPath: lockPath.path, contents: nil)
        guard let lockFd = FileHandle(forWritingAtPath: lockPath.path) else {
            // File lock acquisition failed — log warning and proceed with in-process lock only.
            // This is a degraded state that could allow concurrent writes from daemon + dashboard.
            Logger.warning("UserMemoryStore: failed to acquire file lock, proceeding with in-process lock only")
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
    /// Also records synthesis metadata for throttling.
    public func saveProfile(_ profile: String) {
        withFileLock {
            var file = loadFile()
            file.profile = profile
            file.lastSynthesizedAt = Date()
            file.entryCountAtLastSynthesis = file.entries.count
            saveImpl(file)
        }
    }

    /// Returns synthesis metadata for throttling decisions.
    public func synthesisMetadata() -> (lastSynthesizedAt: Date?, entryCountAtLastSynthesis: Int?) {
        let file = loadFile()
        return (file.lastSynthesizedAt, file.entryCountAtLastSynthesis)
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
    /// Corrections replace contradicted entries. Decay is category-aware.
    public func mergeStructured(newEntries: [MemoryEntry]) {
        withFileLock {
            var file = loadFile()
            let now = Date()

            for incoming in newEntries {
                let trimmed = incoming.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                if incoming.isCorrection {
                    // Correction: replace the contradicted entry (lower match threshold)
                    if let matchIdx = findBestMatch(for: incoming, in: file.entries, threshold: 0.25) {
                        // Replace content and reset reinforcement
                        file.entries[matchIdx] = MemoryEntry(
                            id: file.entries[matchIdx].id,
                            category: incoming.category,
                            content: trimmed,
                            confidence: incoming.confidence,
                            firstSeen: file.entries[matchIdx].firstSeen,
                            lastSeen: now,
                            reinforcementCount: 1,
                            source: incoming.source,
                            isCorrection: false  // correction applied, no longer flagged
                        )
                        Logger.debug("UserMemoryStore: correction replaced entry \(file.entries[matchIdx].id)")
                    } else {
                        // No match found — add as new entry
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
                } else if let matchIdx = findBestMatch(for: incoming, in: file.entries) {
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

            // Category-aware confidence decay
            applyDecay(entries: &file.entries, now: now)

            // Remove entries that decayed below threshold
            file.entries.removeAll { $0.confidence < 0.15 }

            // Category-aware capacity cap (50 total)
            applyCategoryCap(entries: &file.entries)

            saveImpl(file)
        }
    }

    // MARK: - Category-Aware Decay

    /// Decay rate per category — reflects how quickly facts in each category become stale.
    private static func decayRate(for category: MemoryCategory) -> Double {
        switch category {
        case .project:    return 0.15  // projects wrap up / change often
        case .technology: return 0.08  // tech stacks are stickier
        case .workflow:   return 0.06  // habits are very sticky
        case .identity:   return 0.03  // identity rarely changes
        case .interest:   return 0.10  // interests drift over time
        }
    }

    /// Apply tiered confidence decay based on category and age.
    /// Stronger-reinforced entries survive longer but still eventually decay.
    private func applyDecay(entries: inout [MemoryEntry], now: Date) {
        for i in entries.indices {
            let age = now.timeIntervalSince(entries[i].lastSeen)
            let count = entries[i].reinforcementCount
            let rate = Self.decayRate(for: entries[i].category)
            var penalty = 0.0

            // Tier 1: >14 days, seen only once
            if age > 14 * 86400 && count <= 1 {
                penalty += rate * 0.5
            }
            // Tier 2: >30 days, seen 1-2 times
            if age > 30 * 86400 && count <= 2 {
                penalty += rate
            }
            // Tier 3: >60 days, even moderately reinforced entries start to fade
            if age > 60 * 86400 && count <= 3 {
                penalty += rate * 0.5
            }

            if penalty > 0 {
                entries[i] = MemoryEntry(
                    id: entries[i].id,
                    category: entries[i].category,
                    content: entries[i].content,
                    confidence: max(0.1, entries[i].confidence - penalty),
                    firstSeen: entries[i].firstSeen,
                    lastSeen: entries[i].lastSeen,
                    reinforcementCount: entries[i].reinforcementCount,
                    source: entries[i].source,
                    isCorrection: entries[i].isCorrection
                )
            }
        }
    }

    // MARK: - Category-Aware Capacity Cap

    /// Minimum reserved slots per category to ensure balanced memory.
    private static let categoryMinimums: [MemoryCategory: Int] = [
        .identity: 5,
        .project: 15,
        .technology: 12,
        .workflow: 10,
        .interest: 8,
    ]

    private static let maxEntries = 50

    /// Enforce a 50-entry cap while respecting per-category minimums.
    private func applyCategoryCap(entries: inout [MemoryEntry]) {
        guard entries.count > Self.maxEntries else { return }

        let grouped = Dictionary(grouping: entries.indices, by: { entries[$0].category })
        var indicesToRemove = Set<Int>()

        // Phase 1: Within each category, sort by confidence and mark excess entries
        // (those beyond the category minimum) for potential removal, lowest-confidence first.
        var removableByCat: [(index: Int, confidence: Double)] = []
        for (cat, indices) in grouped {
            let minimum = Self.categoryMinimums[cat] ?? 5
            if indices.count > minimum {
                let sorted = indices.sorted { entries[$0].confidence < entries[$1].confidence }
                for idx in sorted.prefix(indices.count - minimum) {
                    removableByCat.append((index: idx, confidence: entries[idx].confidence))
                }
            }
        }

        // Phase 2: Sort all removable entries by confidence ascending, remove until at cap
        removableByCat.sort { $0.confidence < $1.confidence }
        let excess = entries.count - Self.maxEntries
        for item in removableByCat.prefix(excess) {
            indicesToRemove.insert(item.index)
        }

        // Phase 3: If still over cap (all categories at minimum), drop globally lowest
        if entries.count - indicesToRemove.count > Self.maxEntries {
            let remaining = entries.indices.filter { !indicesToRemove.contains($0) }
            let sorted = remaining.sorted { entries[$0].confidence < entries[$1].confidence }
            let stillOver = (entries.count - indicesToRemove.count) - Self.maxEntries
            for idx in sorted.prefix(stillOver) {
                indicesToRemove.insert(idx)
            }
        }

        entries = entries.enumerated().compactMap { indicesToRemove.contains($0.offset) ? nil : $0.element }
    }

    // MARK: - Heuristic Matching

    /// Find the best matching existing entry for an incoming one.
    /// Matches on same category + word overlap above `threshold` (default 0.5).
    /// Corrections use a lower threshold (0.25) since corrected facts often use different words.
    private func findBestMatch(for incoming: MemoryEntry, in entries: [MemoryEntry], threshold: Double = 0.5) -> Int? {
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
            if jaccard > threshold && jaccard > bestOverlap {
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
