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
