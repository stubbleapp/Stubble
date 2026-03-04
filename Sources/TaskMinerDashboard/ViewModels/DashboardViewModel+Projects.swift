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
        isLoadingProjects = false
    }

    /// Change the time period and reload projects.
    func setProjectsTimePeriod(_ period: ProjectTimePeriod) {
        guard period != projectsTimePeriod else { return }
        projectsTimePeriod = period
        // Clear any cached analysis when period changes
        projectAnalysisCache.removeAll()
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
            projectsError = "Gemini API key not configured"
            return
        }

        isGeneratingProjectAnalysis = true

        let generator = ProjectRecommendationGenerator(geminiClient: client)
        let memoryContext = memoryStore.contextString()

        do {
            let analysis = try await generator.generate(
                project: project,
                memoryContext: memoryContext,
                timePeriod: projectsTimePeriod
            )
            projectAnalysisCache[project.id] = analysis
        } catch {
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
