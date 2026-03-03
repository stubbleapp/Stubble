import Foundation
import SwiftUI

// MARK: - Local Aggregation Output

/// Aggregated statistics from all captured data (up to 90 days).
/// Computed locally without AI — used to show quick stats immediately
/// and as input to the AI habits analysis.
struct HabitsDataSnapshot {
    let totalDaysAnalyzed: Int
    let earliestDate: Date
    let latestDate: Date

    // Context switching
    let avgAppSwitchesPerHour: Double
    let avgFocusDurationMinutes: Double

    // Deep work (sustained blocks > 25min on a single task)
    let deepWorkRatio: Double              // 0-1, fraction of active time
    let avgDeepWorkBlockMinutes: Double

    // Hourly productivity curve (hour 0-23 → average active minutes)
    let hourlyProductivity: [Int: Double]

    // Break patterns
    let avgBreakFrequencyPerHour: Double
    let avgBreakDurationMinutes: Double

    // App usage
    let topApps: [AppUsageStat]
    let communicationTimeRatio: Double     // 0-1, fraction of active time

    // Project patterns
    let avgActiveProjectsPerDay: Double
    let projectConsistency: [ProjectConsistencyStat]

    // Work hours
    let avgStartHour: Double               // e.g. 9.25 = 9:15am
    let avgEndHour: Double                 // e.g. 17.5 = 5:30pm
    let avgDailyActiveHours: Double

    // Weekly trends (last 4 weeks)
    let weeklyActiveHours: [WeeklyHoursStat]
}

struct AppUsageStat {
    let name: String
    let totalMinutes: Double
    let avgDailyMinutes: Double
}

struct ProjectConsistencyStat {
    let name: String
    let daysActive: Int
    let avgDailyMinutes: Double
}

struct WeeklyHoursStat {
    let weekLabel: String      // e.g. "Feb 17"
    let hours: Double
}

// MARK: - AI Analysis Output

/// Full AI-generated habits analysis — cached in the database.
struct HabitsAnalysis: Codable {
    let generatedAt: Date
    let daysAnalyzed: Int
    let headline: String?                  // Single punchy insight (max 80 chars) for Focus Score card
    let summary: String                    // 2-3 sentence overview
    let habits: [HabitInsight]
    let improvements: [ImprovementSuggestion]
}

/// A single detected work habit or pattern.
struct HabitInsight: Identifiable, Codable {
    let id: UUID
    let category: HabitCategory
    let title: String
    let description: String
    let dataPoint: String                  // e.g. "12 app switches/hour"
    let trend: Trend?
    let iconName: String

    enum Trend: String, Codable {
        case improving, declining, stable
    }
}

/// Categories for habit classification.
enum HabitCategory: String, Codable, CaseIterable {
    case focus = "focus"
    case energy = "energy"
    case communication = "communication"
    case breaks = "breaks"
    case projects = "projects"
    case workLife = "work_life"

    var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .energy: return "Energy"
        case .communication: return "Communication"
        case .breaks: return "Breaks"
        case .projects: return "Projects"
        case .workLife: return "Work-Life"
        }
    }

    var defaultIcon: String {
        switch self {
        case .focus: return "brain.head.profile"
        case .energy: return "bolt.fill"
        case .communication: return "bubble.left.and.bubble.right"
        case .breaks: return "cup.and.saucer"
        case .projects: return "folder"
        case .workLife: return "clock"
        }
    }

    var color: Color {
        switch self {
        case .focus: return .purple
        case .energy: return .orange
        case .communication: return .blue
        case .breaks: return .green
        case .projects: return .indigo
        case .workLife: return .teal
        }
    }
}

/// An actionable improvement suggestion.
struct ImprovementSuggestion: Identifiable, Codable {
    let id: UUID
    let category: HabitCategory
    let title: String
    let description: String
    let impact: Impact
    let relatedHabit: String?
    let iconName: String

    enum Impact: String, Codable {
        case high, medium, low

        var displayName: String {
            rawValue.uppercased()
        }

        var color: Color {
            switch self {
            case .high: return Theme.accent
            case .medium: return .yellow
            case .low: return Color(white: 0.5)
            }
        }
    }
}

// MARK: - Focus Score (Simplified Main Metric)

/// Composite focus score for the simplified HabitsView.
/// Combines deep work ratio, focus duration, and context switching into a single 0-100% score.
struct FocusScore {
    let value: Double           // 0-1
    let percentage: Int         // 0-100
    let trend: Trend
    let trendDelta: Int         // e.g., +8 or -3 (percentage points)
    let insight: String         // Single sentence insight

    enum Trend: String {
        case up, down, stable

        var icon: String {
            switch self {
            case .up: return "arrow.up.right"
            case .down: return "arrow.down.right"
            case .stable: return "minus"
            }
        }

        var color: Color {
            switch self {
            case .up: return .green
            case .down: return .red
            case .stable: return Color(white: 0.5)
            }
        }
    }

    var scoreColor: Color {
        if value > 0.7 { return .green }
        if value > 0.5 { return .yellow }
        return .orange
    }

    /// Compute focus score from snapshot data.
    /// Formula: 40% deep work ratio + 30% focus duration (normalized) + 30% inverse app switches
    static func compute(
        from snapshot: HabitsDataSnapshot,
        previousSnapshot: HabitsDataSnapshot?,
        headline: String?
    ) -> FocusScore {
        // Deep work ratio already 0-1
        let deepWorkComponent = snapshot.deepWorkRatio * 0.4

        // Focus duration: normalize to 0-1 (45 min = perfect score)
        let focusNormalized = min(snapshot.avgFocusDurationMinutes / 45.0, 1.0)
        let focusComponent = focusNormalized * 0.3

        // App switches: lower is better (20 switches/hr = 0 score, 0 = perfect)
        let switchesNormalized = max(1.0 - snapshot.avgAppSwitchesPerHour / 20.0, 0.0)
        let switchesComponent = switchesNormalized * 0.3

        let score = deepWorkComponent + focusComponent + switchesComponent
        let percentage = Int(score * 100)

        // Compute trend if we have previous data
        var trend: Trend = .stable
        var trendDelta = 0

        if let previous = previousSnapshot {
            let previousDeep = previous.deepWorkRatio * 0.4
            let previousFocus = min(previous.avgFocusDurationMinutes / 45.0, 1.0) * 0.3
            let previousSwitches = max(1.0 - previous.avgAppSwitchesPerHour / 20.0, 0.0) * 0.3
            let previousScore = previousDeep + previousFocus + previousSwitches

            let delta = score - previousScore
            trendDelta = Int(delta * 100)

            if trendDelta > 3 {
                trend = .up
            } else if trendDelta < -3 {
                trend = .down
            }
        }

        // Use headline if provided, otherwise generate a simple insight
        let insight = headline ?? generateDefaultInsight(score: score, snapshot: snapshot)

        return FocusScore(
            value: score,
            percentage: percentage,
            trend: trend,
            trendDelta: trendDelta,
            insight: insight
        )
    }

    private static func generateDefaultInsight(score: Double, snapshot: HabitsDataSnapshot) -> String {
        if score > 0.7 {
            return "Strong focus this week with \(Int(snapshot.deepWorkRatio * 100))% deep work"
        } else if score > 0.5 {
            return "Moderate focus — try reducing app switches"
        } else {
            return "Focus needs attention — averaging \(Int(snapshot.avgAppSwitchesPerHour)) switches/hr"
        }
    }
}

// MARK: - Daily Activity Bar (Weekly Sparkline)

/// Single day's activity for the weekly sparkline visualization.
struct DailyActivityBar: Identifiable {
    let id: Date
    let dayLabel: String        // "M", "T", "W", etc.
    let hours: Double
    let isToday: Bool

    /// Generate 7 days of activity bars from a date range.
    static func generateWeek(
        dailyHours: [Date: Double],
        referenceDate: Date = Date()
    ) -> [DailyActivityBar] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)

        // Get the start of the week (Monday)
        var weekStart = today
        while calendar.component(.weekday, from: weekStart) != 2 { // 2 = Monday
            weekStart = calendar.date(byAdding: .day, value: -1, to: weekStart)!
        }

        let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

        return (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: weekStart)!
            let startOfDate = calendar.startOfDay(for: date)
            let hours = dailyHours[startOfDate] ?? 0
            let isToday = calendar.isDate(date, inSameDayAs: today)

            return DailyActivityBar(
                id: date,
                dayLabel: dayLabels[offset],
                hours: hours,
                isToday: isToday
            )
        }
    }
}
