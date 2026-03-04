import Foundation
import SwiftUI
import CryptoKit

// MARK: - Time Period Enum

/// Time period for project aggregation.
enum ProjectTimePeriod: String, CaseIterable {
    case day = "Day"
    case week = "Week"
    case month = "Month"

    var days: Int {
        switch self {
        case .day: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    var displayName: String { rawValue }
}

// MARK: - Aggregated Project

/// A project aggregated across multiple days with work pattern analysis.
struct AggregatedProject: Identifiable {
    let id: UUID
    let name: String
    let summary: String                         // Most recent day's summary
    let totalDuration: TimeInterval
    let daysActive: Int
    let appNames: Set<String>
    let taskTitles: [String]
    let colorIndex: Int                         // DJB2 hash of name

    // Work patterns
    let weekdayDistribution: [Int: TimeInterval]  // 1-7 (Sun-Sat)
    let hourlyDistribution: [Int: TimeInterval]   // 0-23
    let dailyDurations: [Date: TimeInterval]
    let firstActiveDate: Date
    let lastActiveDate: Date

    // MARK: - Computed Properties

    var averageDailyDuration: TimeInterval {
        guard daysActive > 0 else { return 0 }
        return totalDuration / Double(daysActive)
    }

    /// Top 3 peak hours (0-23) by total time spent.
    var peakHours: [Int] {
        hourlyDistribution
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    /// Top 3 peak weekdays (1=Sun, 7=Sat) by total time spent.
    var peakWeekdays: [Int] {
        weekdayDistribution
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    /// Stable color from Theme.barPalette.
    var color: Color {
        Theme.barPalette[colorIndex % Theme.barPalette.count]
    }

    // MARK: - Stable ID from Name

    /// Create a stable UUID from the project name so the same project keeps its identity.
    static func stableID(for name: String) -> UUID {
        let data = Data(name.lowercased().utf8)
        let hash = SHA256.hash(data: data)
        let bytes = Array(hash)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Create a stable color index from the project name (DJB2 hash).
    static func stableColorIndex(for name: String, paletteSize: Int) -> Int {
        var hash: UInt64 = 5381
        for byte in name.lowercased().utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return Int(hash % UInt64(paletteSize))
    }
}

extension AggregatedProject: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AggregatedProject, rhs: AggregatedProject) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Project Analysis (AI-Generated)

/// AI-generated analysis for a specific project.
struct ProjectAnalysis: Codable {
    let projectName: String
    let generatedAt: Date
    let insights: String                        // 2-3 sentences
    let recommendations: [ProjectRecommendation]
    let nextSteps: [String]                     // 2-3 actionable items
}

/// A single recommendation for a project.
struct ProjectRecommendation: Codable, Identifiable {
    let id: UUID
    let category: String                        // article, tool, best_practice, etc.
    let title: String
    let description: String
    let reason: String
    let actionURL: String?
    let iconName: String

    /// SF Symbol icon for the category.
    var icon: String {
        iconName.isEmpty ? defaultIcon : iconName
    }

    private var defaultIcon: String {
        switch category {
        case "article": return "doc.text"
        case "tool": return "wrench.and.screwdriver"
        case "best_practice": return "lightbulb"
        case "workflow": return "arrow.triangle.branch"
        case "learning": return "book"
        default: return "star"
        }
    }
}
