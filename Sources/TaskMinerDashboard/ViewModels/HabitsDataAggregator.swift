import Foundation
import TaskMinerShared

/// Aggregates activity data across all captured dates into a compact snapshot
/// for display as quick stats and as input to the AI habits generator.
@MainActor
final class HabitsDataAggregator {
    private let dbReader: DatabaseReader

    /// Maximum number of days to analyze (prevents unbounded computation).
    private static let maxDays = 90

    /// Communication apps for classifying comm-time ratio.
    private static let communicationApps: Set<String> = [
        "Mail", "Slack", "Messages", "Microsoft Teams", "Teams",
        "Discord", "Outlook", "Spark", "Thunderbird", "Mimestream",
        "Telegram", "WhatsApp", "Zoom", "Google Meet", "FaceTime"
    ]

    /// Minimum idle gap (seconds) to count as a break.
    private static let minBreakSeconds: TimeInterval = 120      // 2 min
    /// Maximum idle gap (seconds) to count as a break (vs. away).
    private static let maxBreakSeconds: TimeInterval = 1800     // 30 min

    init(dbReader: DatabaseReader) {
        self.dbReader = dbReader
    }

    // MARK: - Public API

    func aggregate() -> HabitsDataSnapshot? {
        let allDateStrings = dbReader.datesWithData()
        guard !allDateStrings.isEmpty else { return nil }

        // Parse date strings and sort descending, cap at maxDays
        let cal = Calendar.current
        let formatter = SharedFormatters.dayFormatter
        let parsedDates = allDateStrings
            .compactMap { formatter.date(from: $0) }
            .sorted(by: >)
            .prefix(Self.maxDays)

        guard let earliest = parsedDates.last,
              let latest = parsedDates.first else { return nil }

        let totalDays = parsedDates.count

        // Per-day accumulators
        var allAppSwitchesPerHour: [Double] = []
        var allFocusDurations: [Double] = []     // minutes
        var deepWorkSeconds: Double = 0
        var totalActiveSeconds: Double = 0
        var deepWorkBlockDurations: [Double] = []
        var hourlyBuckets: [Int: [Double]] = [:]  // hour → [active minutes per day]
        var breakCounts: [Double] = []            // per-hour per day
        var breakDurations: [Double] = []         // minutes
        var appTotalSeconds: [String: Double] = [:]
        var commSeconds: Double = 0
        var projectsPerDay: [Double] = []
        var projectDayMap: [String: Int] = [:]
        var projectDailyMinutes: [String: [Double]] = [:]
        var startHours: [Double] = []
        var endHours: [Double] = []
        var dailyActiveHours: [Double] = []
        var weeklyHoursMap: [String: Double] = [:]

        for date in parsedDates {
            let activities = dbReader.activities(for: date)
            let tasks = dbReader.tasks(for: date)
            let paRecords = dbReader.projectActivities(for: date)

            let nonIdle = activities.filter { !$0.isIdle }
            guard !nonIdle.isEmpty else { continue }

            let sorted = nonIdle.sorted { $0.timestamp < $1.timestamp }

            // --- Active time for the day ---
            let dayActive = sorted.reduce(0.0) { $0 + ($1.duration ?? 0) }
            totalActiveSeconds += dayActive
            let dayActiveHours = dayActive / 3600
            dailyActiveHours.append(dayActiveHours)

            // --- Weekly bucket ---
            let weekStart = cal.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            let weekLabel = SharedFormatters.shortDateFormatter.string(from: weekStart)
            weeklyHoursMap[weekLabel, default: 0] += dayActiveHours

            // --- Work hours ---
            if let first = sorted.first, let last = sorted.last {
                let startComps = cal.dateComponents([.hour, .minute], from: first.timestamp)
                let endComps = cal.dateComponents([.hour, .minute], from: last.timestamp)
                startHours.append(Double(startComps.hour ?? 9) + Double(startComps.minute ?? 0) / 60)
                endHours.append(Double(endComps.hour ?? 17) + Double(endComps.minute ?? 0) / 60)
            }

            // --- Context switching ---
            var switchCount = 0
            var focusSpans: [Double] = []
            var currentApp = sorted.first?.appName ?? ""
            var currentSpanStart = sorted.first?.timestamp ?? Date()

            for activity in sorted.dropFirst() {
                if activity.appName != currentApp {
                    switchCount += 1
                    let spanSeconds = activity.timestamp.timeIntervalSince(currentSpanStart)
                    if spanSeconds > 0 { focusSpans.append(spanSeconds / 60) }
                    currentApp = activity.appName
                    currentSpanStart = activity.timestamp
                }
            }
            // Last span
            if let lastEnd = sorted.last?.endTime ?? sorted.last?.timestamp.addingTimeInterval(sorted.last?.duration ?? 0) {
                let spanSeconds = lastEnd.timeIntervalSince(currentSpanStart)
                if spanSeconds > 0 { focusSpans.append(spanSeconds / 60) }
            }

            if dayActiveHours > 0 {
                allAppSwitchesPerHour.append(Double(switchCount) / dayActiveHours)
            }
            allFocusDurations.append(contentsOf: focusSpans)

            // --- Deep work (tasks > 25min) ---
            for task in tasks {
                let durMin = task.duration / 60
                if durMin >= 25 {
                    deepWorkSeconds += task.duration
                    deepWorkBlockDurations.append(durMin)
                }
            }

            // --- Hourly productivity ---
            for activity in sorted {
                let hour = cal.component(.hour, from: activity.timestamp)
                let durMin = (activity.duration ?? 0) / 60
                hourlyBuckets[hour, default: []].append(durMin)
            }

            // --- Break patterns ---
            let allActivities = activities.sorted { $0.timestamp < $1.timestamp }
            var dayBreakCount = 0
            var dayBreakDurations: [Double] = []
            for activity in allActivities {
                guard activity.isIdle, let dur = activity.duration else { continue }
                if dur >= Self.minBreakSeconds && dur <= Self.maxBreakSeconds {
                    dayBreakCount += 1
                    dayBreakDurations.append(dur / 60)
                }
            }
            if dayActiveHours > 0 {
                breakCounts.append(Double(dayBreakCount) / dayActiveHours)
            }
            breakDurations.append(contentsOf: dayBreakDurations)

            // --- App usage ---
            for activity in sorted {
                let dur = activity.duration ?? 0
                appTotalSeconds[activity.appName, default: 0] += dur
                if Self.communicationApps.contains(activity.appName) {
                    commSeconds += dur
                }
            }

            // --- Project patterns ---
            let projects = paRecords.map { ProjectActivity(from: $0) }
            projectsPerDay.append(Double(projects.count))
            for pa in projects {
                projectDayMap[pa.name, default: 0] += 1
                projectDailyMinutes[pa.name, default: []].append(pa.totalDuration / 60)
            }
        }

        // --- Compute averages ---

        let avgSwitches = allAppSwitchesPerHour.isEmpty ? 0 : allAppSwitchesPerHour.reduce(0, +) / Double(allAppSwitchesPerHour.count)
        let avgFocus = allFocusDurations.isEmpty ? 0 : allFocusDurations.reduce(0, +) / Double(allFocusDurations.count)
        let dwRatio = totalActiveSeconds > 0 ? deepWorkSeconds / totalActiveSeconds : 0
        let avgDWBlock = deepWorkBlockDurations.isEmpty ? 0 : deepWorkBlockDurations.reduce(0, +) / Double(deepWorkBlockDurations.count)

        // Hourly productivity: average active minutes per hour across all days
        var hourlyProd: [Int: Double] = [:]
        for (hour, values) in hourlyBuckets {
            hourlyProd[hour] = values.reduce(0, +) / Double(totalDays)
        }

        let avgBreakFreq = breakCounts.isEmpty ? 0 : breakCounts.reduce(0, +) / Double(breakCounts.count)
        let avgBreakDur = breakDurations.isEmpty ? 0 : breakDurations.reduce(0, +) / Double(breakDurations.count)

        // Top apps by total time
        let sortedApps = appTotalSeconds.sorted { $0.value > $1.value }.prefix(15)
        let topApps = sortedApps.map { app in
            AppUsageStat(
                name: app.key,
                totalMinutes: app.value / 60,
                avgDailyMinutes: app.value / 60 / Double(totalDays)
            )
        }

        let commRatio = totalActiveSeconds > 0 ? commSeconds / totalActiveSeconds : 0

        let avgProjects = projectsPerDay.isEmpty ? 0 : projectsPerDay.reduce(0, +) / Double(projectsPerDay.count)

        let projectConsistency = projectDayMap.sorted { $0.value > $1.value }.prefix(10).map { entry in
            let dailyMins = projectDailyMinutes[entry.key] ?? []
            let avgDaily = dailyMins.isEmpty ? 0 : dailyMins.reduce(0, +) / Double(dailyMins.count)
            return ProjectConsistencyStat(
                name: entry.key,
                daysActive: entry.value,
                avgDailyMinutes: avgDaily
            )
        }

        let avgStart = startHours.isEmpty ? 9.0 : startHours.reduce(0, +) / Double(startHours.count)
        let avgEnd = endHours.isEmpty ? 17.0 : endHours.reduce(0, +) / Double(endHours.count)
        let avgDailyHrs = dailyActiveHours.isEmpty ? 0 : dailyActiveHours.reduce(0, +) / Double(dailyActiveHours.count)

        // Weekly trends — last 4 weeks sorted chronologically
        let weeklyHours = weeklyHoursMap
            .sorted { $0.key < $1.key }
            .suffix(4)
            .map { WeeklyHoursStat(weekLabel: $0.key, hours: $0.value) }

        return HabitsDataSnapshot(
            totalDaysAnalyzed: totalDays,
            earliestDate: earliest,
            latestDate: latest,
            avgAppSwitchesPerHour: avgSwitches,
            avgFocusDurationMinutes: avgFocus,
            deepWorkRatio: dwRatio,
            avgDeepWorkBlockMinutes: avgDWBlock,
            hourlyProductivity: hourlyProd,
            avgBreakFrequencyPerHour: avgBreakFreq,
            avgBreakDurationMinutes: avgBreakDur,
            topApps: topApps,
            communicationTimeRatio: commRatio,
            avgActiveProjectsPerDay: avgProjects,
            projectConsistency: Array(projectConsistency),
            avgStartHour: avgStart,
            avgEndHour: avgEnd,
            avgDailyActiveHours: avgDailyHrs,
            weeklyActiveHours: weeklyHours
        )
    }

    /// Compute a stable hash for cache invalidation.
    /// Changes when new days are added or the date range shifts.
    func snapshotHash(_ snapshot: HabitsDataSnapshot) -> String {
        let components = [
            "\(snapshot.totalDaysAnalyzed)",
            SharedFormatters.dayFormatter.string(from: snapshot.earliestDate),
            SharedFormatters.dayFormatter.string(from: snapshot.latestDate)
        ]
        return components.joined(separator: "|")
    }
}

// MARK: - Formatter Extension

extension SharedFormatters {
    /// Short date formatter for weekly labels (e.g. "Feb 17").
    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
