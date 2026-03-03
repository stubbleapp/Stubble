import XCTest
@testable import TaskMinerShared

final class ActivityGroupTests: XCTestCase {

    // MARK: - Helpers

    private func makeActivity(
        appName: String,
        bundleId: String? = nil,
        windowTitle: String? = nil,
        timestamp: Date = Date(),
        duration: TimeInterval = 60,
        isIdle: Bool = false
    ) -> ActivityRecord {
        ActivityRecord(
            id: nil,
            timestamp: timestamp,
            endTime: timestamp.addingTimeInterval(duration),
            appName: appName,
            bundleId: bundleId ?? "com.test.\(appName.lowercased())",
            windowTitle: windowTitle,
            duration: duration,
            isIdle: isIdle,
            browserURL: nil,
            documentPath: nil,
            focusedElementRole: nil
        )
    }

    // MARK: - Group Function Tests

    func testGroupEmptyActivities() {
        let groups = ActivityGroup.group([])
        XCTAssertTrue(groups.isEmpty)
    }

    func testGroupSingleActivity() {
        let activity = makeActivity(appName: "Safari")
        let groups = ActivityGroup.group([activity])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].appName, "Safari")
        XCTAssertEqual(groups[0].activities.count, 1)
    }

    func testGroupConsecutiveSameApp() {
        let now = Date()
        let activities = [
            makeActivity(appName: "Xcode", bundleId: "com.apple.dt.Xcode", timestamp: now),
            makeActivity(appName: "Xcode", bundleId: "com.apple.dt.Xcode", timestamp: now.addingTimeInterval(60)),
            makeActivity(appName: "Xcode", bundleId: "com.apple.dt.Xcode", timestamp: now.addingTimeInterval(120)),
        ]

        let groups = ActivityGroup.group(activities)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].appName, "Xcode")
        XCTAssertEqual(groups[0].activities.count, 3)
    }

    func testGroupDifferentApps() {
        let now = Date()
        let activities = [
            makeActivity(appName: "Safari", bundleId: "com.apple.Safari", timestamp: now),
            makeActivity(appName: "Xcode", bundleId: "com.apple.dt.Xcode", timestamp: now.addingTimeInterval(60)),
            makeActivity(appName: "Terminal", bundleId: "com.apple.Terminal", timestamp: now.addingTimeInterval(120)),
        ]

        let groups = ActivityGroup.group(activities)

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].appName, "Safari")
        XCTAssertEqual(groups[1].appName, "Xcode")
        XCTAssertEqual(groups[2].appName, "Terminal")
    }

    func testGroupAlternatingApps() {
        let now = Date()
        let activities = [
            makeActivity(appName: "Safari", bundleId: "com.apple.Safari", timestamp: now),
            makeActivity(appName: "Xcode", bundleId: "com.apple.dt.Xcode", timestamp: now.addingTimeInterval(60)),
            makeActivity(appName: "Safari", bundleId: "com.apple.Safari", timestamp: now.addingTimeInterval(120)),
        ]

        let groups = ActivityGroup.group(activities)

        XCTAssertEqual(groups.count, 3, "Alternating apps should create separate groups")
        XCTAssertEqual(groups[0].appName, "Safari")
        XCTAssertEqual(groups[1].appName, "Xcode")
        XCTAssertEqual(groups[2].appName, "Safari")
    }

    func testGroupFiltersIdleActivities() {
        let now = Date()
        let activities = [
            makeActivity(appName: "Safari", timestamp: now),
            makeActivity(appName: "Idle", timestamp: now.addingTimeInterval(60), isIdle: true),
            makeActivity(appName: "Safari", timestamp: now.addingTimeInterval(120)),
        ]

        let groups = ActivityGroup.group(activities)

        // Idle should be filtered, but Safari activities are not consecutive
        // (there's an idle between them), so they might still be separate groups
        // Actually looking at the code, idle is filtered before grouping logic
        // so consecutive Safari activities should be grouped
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].activities.count, 2)
    }

    func testGroupOnlyIdleActivities() {
        let activities = [
            makeActivity(appName: "Idle", isIdle: true),
            makeActivity(appName: "Idle", isIdle: true),
        ]

        let groups = ActivityGroup.group(activities)
        XCTAssertTrue(groups.isEmpty, "All idle activities should result in empty groups")
    }

    // MARK: - Total Duration Tests

    func testTotalDuration() {
        let activities = [
            makeActivity(appName: "Safari", duration: 60),
            makeActivity(appName: "Safari", duration: 120),
            makeActivity(appName: "Safari", duration: 30),
        ]

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: activities)
        XCTAssertEqual(group.totalDuration, 210)
    }

    func testTotalDurationWithNilDurations() {
        let activity1 = makeActivity(appName: "Safari", duration: 60)

        // Create activity with nil duration by setting it explicitly
        let activity3 = ActivityRecord(
            id: nil,
            timestamp: Date(),
            endTime: nil,
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: nil,
            duration: nil,
            isIdle: false,
            browserURL: nil,
            documentPath: nil,
            focusedElementRole: nil
        )

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: [activity1, activity3])
        XCTAssertEqual(group.totalDuration, 60, "Nil durations should be skipped")
    }

    // MARK: - Window Titles Tests

    func testWindowTitles() {
        let activities = [
            makeActivity(appName: "Safari", windowTitle: "Google"),
            makeActivity(appName: "Safari", windowTitle: "GitHub"),
            makeActivity(appName: "Safari", windowTitle: "Stack Overflow"),
        ]

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: activities)
        XCTAssertEqual(group.windowTitles, ["Google", "GitHub", "Stack Overflow"])
    }

    func testWindowTitlesDeduplicatesConsecutive() {
        let activities = [
            makeActivity(appName: "Safari", windowTitle: "Google"),
            makeActivity(appName: "Safari", windowTitle: "Google"),
            makeActivity(appName: "Safari", windowTitle: "GitHub"),
            makeActivity(appName: "Safari", windowTitle: "GitHub"),
        ]

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: activities)
        XCTAssertEqual(group.windowTitles, ["Google", "GitHub"])
    }

    func testWindowTitlesFiltersNil() {
        let activities = [
            makeActivity(appName: "Safari", windowTitle: "Google"),
            makeActivity(appName: "Safari", windowTitle: nil),
            makeActivity(appName: "Safari", windowTitle: "GitHub"),
        ]

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: activities)
        XCTAssertEqual(group.windowTitles, ["Google", "GitHub"])
    }

    // MARK: - Start/End Time Tests

    func testStartTime() {
        let now = Date()
        let activities = [
            makeActivity(appName: "Safari", timestamp: now),
            makeActivity(appName: "Safari", timestamp: now.addingTimeInterval(60)),
        ]

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: activities)
        XCTAssertEqual(group.startTime, now)
    }

    func testEndTime() {
        let now = Date()
        let activity1 = makeActivity(appName: "Safari", timestamp: now, duration: 60)
        let activity2 = makeActivity(appName: "Safari", timestamp: now.addingTimeInterval(60), duration: 30)

        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: [activity1, activity2])

        // endTime should be the last activity's endTime
        let expectedEnd = now.addingTimeInterval(90)
        XCTAssertEqual(group.endTime?.timeIntervalSinceReferenceDate ?? 0, expectedEnd.timeIntervalSinceReferenceDate, accuracy: 1)
    }

    func testStartTimeEmpty() {
        let group = ActivityGroup(appName: "Safari", bundleId: "com.apple.Safari", activities: [])
        XCTAssertNil(group.startTime)
        XCTAssertNil(group.endTime)
    }

    // MARK: - Bundle ID Matching Tests

    func testGroupMatchesByBundleIdNotAppName() {
        let now = Date()
        // Same app name but different bundle IDs (e.g., different versions or wrapper apps)
        let activities = [
            makeActivity(appName: "Terminal", bundleId: "com.apple.Terminal", timestamp: now),
            makeActivity(appName: "Terminal", bundleId: "com.googlecode.iterm2", timestamp: now.addingTimeInterval(60)),
        ]

        let groups = ActivityGroup.group(activities)

        XCTAssertEqual(groups.count, 2, "Different bundle IDs should create separate groups")
    }

    func testGroupHandlesNilBundleId() {
        let now = Date()
        // Create activities directly to ensure bundleId is actually nil
        let activity1 = ActivityRecord(
            timestamp: now,
            appName: "App1",
            bundleId: nil,
            duration: 60
        )
        let activity2 = ActivityRecord(
            timestamp: now.addingTimeInterval(60),
            appName: "App2",
            bundleId: nil,
            duration: 60
        )

        let groups = ActivityGroup.group([activity1, activity2])

        // nil == nil in Swift, so these would be grouped together
        XCTAssertEqual(groups.count, 1, "Nil bundle IDs should match each other")
    }
}
