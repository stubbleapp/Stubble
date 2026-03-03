import Foundation
import TaskMinerShared

/// Manages habits analysis state and operations, separate from the main DashboardViewModel.
@Observable
@MainActor
final class HabitsViewModel {

    // MARK: - Dependencies

    private let dbReader: DatabaseReader?
    private let taskWriter: TaskWriter?
    private let memoryStore: UserMemoryStore
    var habitsGenerator: HabitsGenerator?

    /// Reference to parent for loading OCR digest.
    private weak var dashboardViewModel: DashboardViewModel?

    // MARK: - State

    var analysis: HabitsAnalysis?
    var snapshot: HabitsDataSnapshot?
    var isGenerating = false
    var error: String?
    var hasAttemptedGeneration = false

    /// Cached result of whether the database has sufficient activity data.
    var hasSufficientData: Bool?

    /// In-flight task handle for cancellation.
    private var generationTask: Task<Void, Never>?

    // MARK: - Init

    init(
        dashboardViewModel: DashboardViewModel,
        dbReader: DatabaseReader?,
        taskWriter: TaskWriter?,
        memoryStore: UserMemoryStore,
        habitsGenerator: HabitsGenerator?
    ) {
        self.dashboardViewModel = dashboardViewModel
        self.dbReader = dbReader
        self.taskWriter = taskWriter
        self.memoryStore = memoryStore
        self.habitsGenerator = habitsGenerator
    }

    // MARK: - Data Availability Check

    /// Check if the database has at least one full day of activity.
    func checkHasSufficientData() {
        guard hasSufficientData == nil else { return }
        guard let db = dbReader else {
            hasSufficientData = false
            return
        }
        Task { @MainActor in
            let dates = db.datesWithData()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let today = formatter.string(from: Date())
            let hasCompletedDay = dates.contains { $0 < today }
            self.hasSufficientData = hasCompletedDay
        }
    }

    // MARK: - Generation

    /// Generate cross-day habits analysis.
    /// Phase 1: local aggregation (immediate quick stats).
    /// Phase 2: AI analysis (cached, refreshes when new day of data appears).
    func generate() {
        guard let generator = habitsGenerator else {
            error = "Gemini API key not configured"
            return
        }
        guard let db = dbReader else {
            error = "Database unavailable"
            return
        }

        isGenerating = true
        error = nil

        generationTask?.cancel()
        generationTask = Task {
            // Phase 1: Local aggregation
            let aggregator = HabitsDataAggregator(dbReader: db)
            guard let snap = aggregator.aggregate() else {
                self.error = nil
                self.isGenerating = false
                return
            }
            self.snapshot = snap

            // Check cache
            let hash = aggregator.snapshotHash(snap)
            if let cached = db.latestHabitsAnalysis(),
               cached.snapshotHash == hash {
                if let decoded = Self.decodeAnalysis(cached.analysisJson) {
                    self.analysis = decoded
                    self.isGenerating = false
                    return
                }
            }

            guard !Task.isCancelled else { return }

            // Phase 2: AI analysis
            let memoryContext = memoryStore.contextString()
            let ocrDigest = dashboardViewModel?.loadOrBuildOCRDigest()

            do {
                let result = try await generator.generate(
                    snapshot: snap,
                    memoryContext: memoryContext,
                    ocrDigest: ocrDigest
                )
                guard !Task.isCancelled else { return }
                self.analysis = result
                self.isGenerating = false
                self.persistAnalysis(result, snapshotHash: hash)
            } catch {
                self.error = error.localizedDescription
                self.isGenerating = false
            }
        }
    }

    // MARK: - Persistence

    private func persistAnalysis(_ analysis: HabitsAnalysis, snapshotHash: String) {
        guard let writer = taskWriter else { return }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(analysis),
              let json = String(data: data, encoding: .utf8) else {
            Logger.error("Failed to encode habits analysis for caching")
            return
        }

        do {
            try writer.insertOrReplaceHabitsAnalysis(
                json: json,
                daysAnalyzed: analysis.daysAnalyzed,
                snapshotHash: snapshotHash
            )
        } catch {
            Logger.error("Failed to persist habits analysis: \(error.localizedDescription)")
        }
    }

    static func decodeAnalysis(_ json: String) -> HabitsAnalysis? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HabitsAnalysis.self, from: data)
    }

    // MARK: - Reset

    func reset() {
        analysis = nil
        snapshot = nil
        error = nil
        hasAttemptedGeneration = false
        hasSufficientData = nil
        generationTask?.cancel()
        generationTask = nil
    }
}
