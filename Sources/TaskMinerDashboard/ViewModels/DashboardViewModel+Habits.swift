import Foundation
import TaskMinerShared

// MARK: - Habits

extension DashboardViewModel {

    /// Generate cross-day habits analysis.
    /// Phase 1: local aggregation (immediate quick stats).
    /// Phase 2: AI analysis (cached, refreshes when new day of data appears).
    func generateHabits() {
        guard let generator = habitsGenerator else {
            habitsError = "Gemini API key not configured"
            return
        }
        guard let db = dbReader else {
            habitsError = "Database unavailable"
            return
        }

        isGeneratingHabits = true
        habitsError = nil

        habitsTask?.cancel()
        habitsTask = Task {
            // Phase 1: Local aggregation
            let aggregator = HabitsDataAggregator(dbReader: db)
            guard let snapshot = aggregator.aggregate() else {
                self.habitsError = nil
                self.isGeneratingHabits = false
                return
            }
            self.habitsSnapshot = snapshot

            // Check cache
            let hash = aggregator.snapshotHash(snapshot)
            if let cached = db.latestHabitsAnalysis(),
               cached.snapshotHash == hash {
                // Cache hit — use cached analysis
                if let analysis = Self.decodeHabitsAnalysis(cached.analysisJson) {
                    self.habitsAnalysis = analysis
                    self.isGeneratingHabits = false
                    return
                }
            }

            guard !Task.isCancelled else { return }

            // Phase 2: AI analysis
            let memoryContext = memoryStore.contextString()
            let ocrDigest = loadOrBuildOCRDigest()

            do {
                let analysis = try await generator.generate(
                    snapshot: snapshot,
                    memoryContext: memoryContext,
                    ocrDigest: ocrDigest
                )
                guard !Task.isCancelled else { return }
                self.habitsAnalysis = analysis
                self.isGeneratingHabits = false

                // Cache the result
                self.persistHabitsAnalysis(analysis, snapshotHash: hash)
            } catch {
                self.habitsError = error.localizedDescription
                self.isGeneratingHabits = false
            }
        }
    }

    // MARK: - Persistence

    private func persistHabitsAnalysis(_ analysis: HabitsAnalysis, snapshotHash: String) {
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

    static func decodeHabitsAnalysis(_ json: String) -> HabitsAnalysis? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HabitsAnalysis.self, from: data)
    }
}
