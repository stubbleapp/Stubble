import Foundation
import TaskMinerShared

// MARK: - Project Activities

extension DashboardViewModel {

    /// Generate project activities by clustering tasks via AI.
    /// Results are persisted to the database. Only regenerates when explicitly requested.
    func generateProjectActivities(forceRegenerate: Bool = false) {
        let dateStr = SharedFormatters.dayFormatter.string(from: selectedDate)

        // Need tasks to cluster
        guard !tasks.isEmpty else {
            projectActivities = []
            return
        }

        guard let generator = activityGenerator, taskWriter != nil else {
            // No AI available — fallback: one project per task, persist
            let fallback = ProjectActivityGenerator.fallbackActivities(from: tasks)
            projectActivities = fallback
            persistProjectActivities(fallback, dateStr: dateStr)
            return
        }

        isGeneratingActivities = true
        activitiesError = nil

        let todayTasks = tasks
        let recentTasks = loadRecentTasks(excluding: selectedDate, days: 7)
        let recentProjectNames = loadRecentProjectNames(excluding: selectedDate, days: 7)
        let memoryContext = memoryStore.contextString()

        Task {
            do {
                let activities = try await generator.cluster(
                    todayTasks: todayTasks,
                    recentHistory: recentTasks,
                    recentProjectNames: recentProjectNames,
                    memoryContext: memoryContext
                )
                self.projectActivities = activities
                self.persistProjectActivities(activities, dateStr: dateStr)
                self.isGeneratingActivities = false
                Analytics.activitiesGenerated(projectCount: activities.count)
            } catch {
                self.activitiesError = error.localizedDescription
                // Fallback to ungrouped
                let fallback = ProjectActivityGenerator.fallbackActivities(from: todayTasks)
                self.projectActivities = fallback
                self.persistProjectActivities(fallback, dateStr: dateStr)
                self.isGeneratingActivities = false
            }
        }
    }

    /// Persist project activities to the database (delete + re-insert).
    func persistProjectActivities(_ activities: [ProjectActivity], dateStr: String) {
        guard let writer = taskWriter else { return }
        do {
            try writer.deleteProjectActivities(for: dateStr)
            let records = activities.map { $0.toRecord(date: dateStr) }
            try writer.insertProjectActivities(records)
        } catch {
            Logger.error("Failed to persist project activities: \(error.localizedDescription)")
        }
    }

    /// Load tasks for the past N days (used as multi-day context for project clustering).
    func loadRecentTasks(excluding currentDate: Date, days: Int) -> [String: [TaskRecord]] {
        guard let db = dbReader else { return [:] }
        let cal = Calendar.current
        var result: [String: [TaskRecord]] = [:]
        for offset in 1...days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: currentDate) else { continue }
            let tasks = db.tasks(for: date)
            if !tasks.isEmpty {
                let dateStr = SharedFormatters.dayFormatter.string(from: date)
                result[dateStr] = tasks
            }
        }
        return result
    }

    /// Load project activity names from recent days (for consistent naming across days).
    func loadRecentProjectNames(excluding currentDate: Date, days: Int) -> [String] {
        guard let db = dbReader else { return [] }
        let cal = Calendar.current
        var names = Set<String>()
        for offset in 1...days {
            guard let date = cal.date(byAdding: .day, value: -offset, to: currentDate) else { continue }
            let records = db.projectActivities(for: date)
            for record in records {
                names.insert(record.name)
            }
        }
        return Array(names).sorted()
    }

    /// Reload project activities from the database.
    func reloadProjectActivities() {
        guard let db = dbReader else { return }
        let records = db.projectActivities(for: selectedDate)
        projectActivities = records.map { ProjectActivity(from: $0) }
    }
}
