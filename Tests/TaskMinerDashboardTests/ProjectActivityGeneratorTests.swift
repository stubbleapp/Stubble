import XCTest
@testable import TaskMinerDashboard
@testable import TaskMinerShared

final class ProjectActivityGeneratorTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(
        title: String,
        description: String = "",
        startTime: Date = Date(),
        duration: TimeInterval = 3600,
        appNames: [String] = ["Xcode"]
    ) -> TaskRecord {
        let appNamesJSON = (try? JSONEncoder().encode(appNames)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return TaskRecord(
            id: nil,
            date: SharedFormatters.dayFormatter.string(from: startTime),
            startTime: startTime,
            endTime: startTime.addingTimeInterval(duration),
            title: title,
            description: description,
            appNames: appNamesJSON,
            confidence: 1.0,
            relevantLinks: "[]",
            activeDuration: duration,
            websites: "[]"
        )
    }

    // MARK: - Fallback Activities Tests

    func testFallbackActivitiesEmpty() {
        let result = ProjectActivityGenerator.fallbackActivities(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testFallbackActivitiesSingleTask() {
        let task = makeTask(title: "Build login UI", duration: 3600)
        let result = ProjectActivityGenerator.fallbackActivities(from: [task])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Build login UI")
        XCTAssertEqual(result[0].summary, "")
        XCTAssertEqual(result[0].totalDuration, 3600)
        XCTAssertEqual(result[0].taskTitles, ["Build login UI"])
    }

    func testFallbackActivitiesMultipleTasks() {
        let now = Date()
        let tasks = [
            makeTask(title: "Task A", startTime: now, duration: 1800),
            makeTask(title: "Task B", startTime: now.addingTimeInterval(1800), duration: 3600),
            makeTask(title: "Task C", startTime: now.addingTimeInterval(5400), duration: 900),
        ]

        let result = ProjectActivityGenerator.fallbackActivities(from: tasks)

        XCTAssertEqual(result.count, 3)
        // Should be sorted by duration descending
        XCTAssertEqual(result[0].name, "Task B") // 3600s
        XCTAssertEqual(result[1].name, "Task A") // 1800s
        XCTAssertEqual(result[2].name, "Task C") // 900s
    }

    func testFallbackActivitiesPreservesAppNames() {
        let task = makeTask(title: "Coding", appNames: ["Xcode", "Terminal", "Safari"])
        let result = ProjectActivityGenerator.fallbackActivities(from: [task])

        XCTAssertEqual(result[0].appNames, ["Xcode", "Terminal", "Safari"])
    }

    func testFallbackActivitiesPreservesTimeRange() {
        let start = Date()
        let task = makeTask(title: "Work", startTime: start, duration: 7200)
        let result = ProjectActivityGenerator.fallbackActivities(from: [task])

        XCTAssertEqual(result[0].startTime, start)
        XCTAssertEqual(result[0].endTime, start.addingTimeInterval(7200))
    }

    func testFallbackActivitiesAssignsStableColorIndex() {
        let task1 = makeTask(title: "Project Alpha")
        let task2 = makeTask(title: "Project Beta")

        let result1a = ProjectActivityGenerator.fallbackActivities(from: [task1])
        let result1b = ProjectActivityGenerator.fallbackActivities(from: [task1])
        let result2 = ProjectActivityGenerator.fallbackActivities(from: [task2])

        // Same title should get same color index
        XCTAssertEqual(result1a[0].colorIndex, result1b[0].colorIndex)
        // Different titles likely get different indices (not guaranteed but usually true)
        // We just verify they have valid indices
        XCTAssertGreaterThanOrEqual(result1a[0].colorIndex, 0)
        XCTAssertGreaterThanOrEqual(result2[0].colorIndex, 0)
    }

    // MARK: - Stable Color Index Tests

    func testStableColorIndexConsistency() {
        let paletteSize = 8

        // Same name should always produce same index
        let index1 = ProjectActivity.stableColorIndex(for: "My Project", paletteSize: paletteSize)
        let index2 = ProjectActivity.stableColorIndex(for: "My Project", paletteSize: paletteSize)

        XCTAssertEqual(index1, index2)
    }

    func testStableColorIndexDifferentNames() {
        let paletteSize = 8

        let indexA = ProjectActivity.stableColorIndex(for: "Alpha", paletteSize: paletteSize)
        let indexB = ProjectActivity.stableColorIndex(for: "Beta", paletteSize: paletteSize)

        // Both should be valid indices
        XCTAssertTrue(indexA >= 0 && indexA < paletteSize)
        XCTAssertTrue(indexB >= 0 && indexB < paletteSize)
    }

    func testStableColorIndexWithinBounds() {
        let paletteSize = 5

        // Test many names to ensure all are within bounds
        let names = ["Project 1", "Another Project", "Test", "Development", "API Work",
                     "Documentation", "Meetings", "Email", "Research", "Planning"]

        for name in names {
            let index = ProjectActivity.stableColorIndex(for: name, paletteSize: paletteSize)
            XCTAssertTrue(index >= 0 && index < paletteSize, "Index \(index) out of bounds for '\(name)'")
        }
    }
}
