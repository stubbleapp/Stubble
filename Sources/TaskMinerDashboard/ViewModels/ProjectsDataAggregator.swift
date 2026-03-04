import Foundation
import TaskMinerShared

/// Aggregates project activities across multiple days into aggregated projects
/// with work pattern analysis (hourly distribution, weekday patterns, etc.).
@MainActor
final class ProjectsDataAggregator {
    private let dbReader: DatabaseReader

    init(dbReader: DatabaseReader) {
        self.dbReader = dbReader
    }

    // MARK: - Public API

    /// Aggregate project activities for the given time period.
    /// Returns projects sorted by total duration (descending).
    func aggregate(period: ProjectTimePeriod, referenceDate: Date = Date()) -> [AggregatedProject] {
        let calendar = Calendar.current
        let endDate = calendar.startOfDay(for: referenceDate)
        guard let startDate = calendar.date(byAdding: .day, value: -(period.days - 1), to: endDate) else {
            return []
        }

        // Get all dates in the range
        let dates = datesInRange(from: startDate, to: endDate, calendar: calendar)
        guard !dates.isEmpty else { return [] }

        // Collect project activities from each date
        var projectMap: [String: ProjectAccumulator] = [:]

        for date in dates {
            let records = dbReader.projectActivities(for: date)
            let weekday = calendar.component(.weekday, from: date) // 1=Sun, 7=Sat

            for record in records {
                let key = record.name.lowercased().trimmingCharacters(in: .whitespaces)
                var accumulator = projectMap[key] ?? ProjectAccumulator(
                    name: record.name,
                    colorIndex: AggregatedProject.stableColorIndex(for: record.name, paletteSize: Theme.barPalette.count)
                )

                accumulator.totalDuration += record.totalDuration
                accumulator.activeDates.insert(calendar.startOfDay(for: date))
                accumulator.appNames.formUnion(record.appNamesList)
                accumulator.taskTitles.append(contentsOf: record.taskTitlesList)

                // Track most recent summary
                if record.startTime > (accumulator.lastActivityTime ?? .distantPast) {
                    accumulator.summary = record.summary
                    accumulator.lastActivityTime = record.startTime
                }

                // Update date range
                if accumulator.firstActiveDate == nil || date < accumulator.firstActiveDate! {
                    accumulator.firstActiveDate = date
                }
                if accumulator.lastActiveDate == nil || date > accumulator.lastActiveDate! {
                    accumulator.lastActiveDate = date
                }

                // Weekday distribution
                accumulator.weekdayDurations[weekday, default: 0] += record.totalDuration

                // Daily durations
                let dayStart = calendar.startOfDay(for: date)
                accumulator.dailyDurations[dayStart, default: 0] += record.totalDuration

                // Hourly distribution (approximate from start time)
                let hour = calendar.component(.hour, from: record.startTime)
                accumulator.hourlyDurations[hour, default: 0] += record.totalDuration

                projectMap[key] = accumulator
            }
        }

        // Convert accumulators to AggregatedProject
        let projects = projectMap.values.map { acc -> AggregatedProject in
            AggregatedProject(
                id: AggregatedProject.stableID(for: acc.name),
                name: acc.name,
                summary: acc.summary,
                totalDuration: acc.totalDuration,
                daysActive: acc.activeDates.count,
                appNames: acc.appNames,
                taskTitles: Array(acc.taskTitles.prefix(50)), // Cap for memory
                colorIndex: acc.colorIndex,
                weekdayDistribution: acc.weekdayDurations,
                hourlyDistribution: acc.hourlyDurations,
                dailyDurations: acc.dailyDurations,
                firstActiveDate: acc.firstActiveDate ?? referenceDate,
                lastActiveDate: acc.lastActiveDate ?? referenceDate
            )
        }

        // Sort by total duration descending
        return projects.sorted { $0.totalDuration > $1.totalDuration }
    }

    // MARK: - Private Helpers

    private func datesInRange(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var dates: [Date] = []
        var current = start

        while current <= end {
            dates.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }

        return dates
    }
}

// MARK: - Accumulator

private struct ProjectAccumulator {
    let name: String
    let colorIndex: Int

    var summary: String = ""
    var totalDuration: TimeInterval = 0
    var activeDates: Set<Date> = []
    var appNames: Set<String> = []
    var taskTitles: [String] = []
    var lastActivityTime: Date?
    var firstActiveDate: Date?
    var lastActiveDate: Date?
    var weekdayDurations: [Int: TimeInterval] = [:]
    var hourlyDurations: [Int: TimeInterval] = [:]
    var dailyDurations: [Date: TimeInterval] = [:]
}
