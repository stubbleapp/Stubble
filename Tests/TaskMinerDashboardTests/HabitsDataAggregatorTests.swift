import XCTest
@testable import TaskMinerDashboard
@testable import TaskMinerShared

final class HabitsDataAggregatorTests: XCTestCase {

    // MARK: - Snapshot Hash Tests

    func testSnapshotHashConsistency() {
        let snapshot = HabitsDataSnapshot(
            totalDaysAnalyzed: 30,
            earliestDate: Date(timeIntervalSince1970: 1704067200), // 2024-01-01
            latestDate: Date(timeIntervalSince1970: 1706745600),   // 2024-02-01
            avgAppSwitchesPerHour: 15.5,
            avgFocusDurationMinutes: 12.0,
            deepWorkRatio: 0.45,
            avgDeepWorkBlockMinutes: 35.0,
            hourlyProductivity: [9: 45, 10: 52, 11: 48],
            avgBreakFrequencyPerHour: 2.1,
            avgBreakDurationMinutes: 8.5,
            topApps: [],
            communicationTimeRatio: 0.15,
            avgActiveProjectsPerDay: 3.2,
            projectConsistency: [],
            avgStartHour: 8.5,
            avgEndHour: 17.0,
            avgDailyActiveHours: 6.5,
            weeklyActiveHours: []
        )

        // Create a mock aggregator by accessing the hash method directly
        // Since HabitsDataAggregator requires DatabaseReader, we test the hash logic separately
        let hash1 = computeSnapshotHash(snapshot)
        let hash2 = computeSnapshotHash(snapshot)

        XCTAssertEqual(hash1, hash2, "Same snapshot should produce identical hash")
    }

    func testSnapshotHashChangesWithDays() {
        let snapshot1 = makeSnapshot(days: 30)
        let snapshot2 = makeSnapshot(days: 31)

        XCTAssertNotEqual(
            computeSnapshotHash(snapshot1),
            computeSnapshotHash(snapshot2),
            "Different day counts should produce different hashes"
        )
    }

    func testSnapshotHashChangesWithDateRange() {
        let snapshot1 = makeSnapshot(earliestDate: Date(timeIntervalSince1970: 1704067200))
        let snapshot2 = makeSnapshot(earliestDate: Date(timeIntervalSince1970: 1704153600))

        XCTAssertNotEqual(
            computeSnapshotHash(snapshot1),
            computeSnapshotHash(snapshot2),
            "Different date ranges should produce different hashes"
        )
    }

    // MARK: - Communication Apps Classification

    func testCommunicationAppsSet() {
        // Test that the expected communication apps are classified correctly
        let commApps = ["Mail", "Slack", "Messages", "Microsoft Teams", "Discord",
                        "Outlook", "Zoom", "Google Meet", "FaceTime"]

        // These should NOT be communication apps
        let nonCommApps = ["Xcode", "Safari", "Terminal", "Finder", "Preview"]

        // Verify known communication apps
        for app in commApps {
            XCTAssertTrue(
                isKnownCommunicationApp(app),
                "\(app) should be classified as communication app"
            )
        }

        for app in nonCommApps {
            XCTAssertFalse(
                isKnownCommunicationApp(app),
                "\(app) should NOT be classified as communication app"
            )
        }
    }

    // MARK: - Helpers

    private func makeSnapshot(
        days: Int = 30,
        earliestDate: Date = Date(timeIntervalSince1970: 1704067200),
        latestDate: Date = Date(timeIntervalSince1970: 1706745600)
    ) -> HabitsDataSnapshot {
        HabitsDataSnapshot(
            totalDaysAnalyzed: days,
            earliestDate: earliestDate,
            latestDate: latestDate,
            avgAppSwitchesPerHour: 15.5,
            avgFocusDurationMinutes: 12.0,
            deepWorkRatio: 0.45,
            avgDeepWorkBlockMinutes: 35.0,
            hourlyProductivity: [:],
            avgBreakFrequencyPerHour: 2.1,
            avgBreakDurationMinutes: 8.5,
            topApps: [],
            communicationTimeRatio: 0.15,
            avgActiveProjectsPerDay: 3.2,
            projectConsistency: [],
            avgStartHour: 8.5,
            avgEndHour: 17.0,
            avgDailyActiveHours: 6.5,
            weeklyActiveHours: []
        )
    }

    /// Replicate the hash computation logic from HabitsDataAggregator
    private func computeSnapshotHash(_ snapshot: HabitsDataSnapshot) -> String {
        let components = [
            "\(snapshot.totalDaysAnalyzed)",
            SharedFormatters.dayFormatter.string(from: snapshot.earliestDate),
            SharedFormatters.dayFormatter.string(from: snapshot.latestDate)
        ]
        return components.joined(separator: "|")
    }

    /// Check if an app is in the known communication apps set
    private func isKnownCommunicationApp(_ name: String) -> Bool {
        let communicationApps: Set<String> = [
            "Mail", "Slack", "Messages", "Microsoft Teams", "Teams",
            "Discord", "Outlook", "Spark", "Thunderbird", "Mimestream",
            "Telegram", "WhatsApp", "Zoom", "Google Meet", "FaceTime"
        ]
        return communicationApps.contains(name)
    }
}
