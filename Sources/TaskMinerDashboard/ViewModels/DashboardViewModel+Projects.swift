import Foundation
import TaskMinerShared

// MARK: - Projects

extension DashboardViewModel {

    // MARK: - Load Projects

    /// Load aggregated projects for the current time period.
    func loadProjects() {
        guard let db = dbReader else {
            projectsError = "Database unavailable"
            return
        }

        isLoadingProjects = true
        projectsError = nil

        let aggregator = ProjectsDataAggregator(dbReader: db)
        aggregatedProjects = aggregator.aggregate(period: projectsTimePeriod)

        // Resolve colors for all aggregated projects (collision-free)
        resolveAggregatedProjectColors()

        // Synthesize summaries for multi-day periods in background
        if projectsTimePeriod != .day && hasAIAccess {
            Task {
                await synthesizeProjectSummaries()
            }
        }

        isLoadingProjects = false
    }

    /// Synthesize comprehensive summaries for projects that need them.
    private func synthesizeProjectSummaries() async {
        guard let client = geminiClient else { return }
        guard !aggregatedProjects.isEmpty else { return }

        // Find projects that need better summaries
        let projectsNeedingSummary = aggregatedProjects.filter { project in
            // Skip if we already have a synthesized summary cached
            if synthesizedProjectSummaries[project.id] != nil { return false }
            // Check if existing summary is good enough
            return !hasGoodSummary(project.summary)
        }

        guard !projectsNeedingSummary.isEmpty else { return }

        let synthesizer = ProjectSummarySynthesizer(geminiClient: client)
        let memoryContext = memoryStore.contextString()

        let summaries = await synthesizer.synthesizeBatch(
            projects: projectsNeedingSummary,
            memoryContext: memoryContext
        )

        // Merge into cache
        await MainActor.run {
            for (id, summary) in summaries {
                synthesizedProjectSummaries[id] = summary
            }
        }
    }

    /// Get the best available summary for a project.
    /// Returns synthesized summary if available, otherwise the original.
    func projectSummary(for project: AggregatedProject) -> String {
        if let synthesized = synthesizedProjectSummaries[project.id] {
            return synthesized
        }
        return project.summary
    }

    /// Check if a summary is already good (describes what the project IS).
    private func hasGoodSummary(_ summary: String) -> Bool {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 20 { return false }

        let lowercased = trimmed.lowercased()

        // Good summaries describe what something IS
        let projectIndicators = [
            "app for", "tool for", "system for", "platform for",
            "built with", "using swift", "using react",
            "macOS app", "iOS app", "web app"
        ]

        for indicator in projectIndicators {
            if lowercased.contains(indicator) { return true }
        }

        // Activity-focused summaries need improvement
        let activityStarters = [
            "working on", "developing", "building", "implementing",
            "debugging", "testing", "reviewing"
        ]

        for starter in activityStarters {
            if lowercased.hasPrefix(starter) { return false }
        }

        return trimmed.count >= 50
    }

    /// Change the time period and reload projects.
    func setProjectsTimePeriod(_ period: ProjectTimePeriod) {
        guard period != projectsTimePeriod else { return }
        projectsTimePeriod = period
        // Clear caches when period changes
        projectAnalysisCache.removeAll()
        synthesizedProjectSummaries.removeAll()
        loadProjects()
    }

    // MARK: - Project Analysis (AI)

    /// Generate AI analysis for a specific project.
    /// Caches the result so subsequent calls return immediately.
    func generateProjectAnalysis(for project: AggregatedProject) async {
        // Check cache first
        if projectAnalysisCache[project.id] != nil {
            return
        }

        guard let client = geminiClient else {
            projectsError = "Sign in required for AI features"
            return
        }

        isGeneratingProjectAnalysis = true

        let generator = ProjectAnalysisGenerator(geminiClient: client)
        let memoryContext = memoryStore.contextString()

        do {
            let analysis = try await generator.generate(
                project: project,
                memoryContext: memoryContext,
                timePeriod: projectsTimePeriod,
                synthesizedSummary: synthesizedProjectSummaries[project.id]
            )
            projectAnalysisCache[project.id] = analysis
        } catch is CancellationError {
            // Task was cancelled (e.g. user navigated away) — don't show error
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Network request cancelled — don't show error
        } catch {
            // Skip showing "cancelled" errors from other sources
            let desc = error.localizedDescription.lowercased()
            if desc.contains("cancel") { return }
            projectsError = "Failed to generate analysis: \(error.localizedDescription)"
        }

        isGeneratingProjectAnalysis = false
    }

    /// Get cached analysis for a project, if available.
    func cachedProjectAnalysis(for project: AggregatedProject) -> ProjectAnalysis? {
        projectAnalysisCache[project.id]
    }

    /// Clear the project analysis cache.
    func clearProjectAnalysisCache() {
        projectAnalysisCache.removeAll()
    }

    // MARK: - Computed Properties

    /// Total time across all projects in the current period.
    var totalProjectsTime: TimeInterval {
        aggregatedProjects.reduce(0) { $0 + $1.totalDuration }
    }

    /// Check if there's any project data for the current period.
    var hasProjectData: Bool {
        !aggregatedProjects.isEmpty
    }
}
