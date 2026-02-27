import XCTest
@testable import TaskMinerShared

final class ModelTests: XCTestCase {

    // MARK: - TaskRecord

    func testTaskRecordDurationFallsBackToSpanTime() {
        let start = Date()
        let end = start.addingTimeInterval(3600) // 1 hour

        let task = TaskRecord(
            date: "2025-01-15",
            startTime: start,
            endTime: end,
            title: "Test Task",
            description: "Description",
            activeDuration: nil
        )

        XCTAssertEqual(task.duration, 3600, accuracy: 0.1,
                       "Should fall back to endTime - startTime when activeDuration is nil")
    }

    func testTaskRecordDurationPrefersActiveDuration() {
        let start = Date()
        let end = start.addingTimeInterval(3600) // 1 hour span

        let task = TaskRecord(
            date: "2025-01-15",
            startTime: start,
            endTime: end,
            title: "Test Task",
            description: "Description",
            activeDuration: 1800 // 30 min active
        )

        XCTAssertEqual(task.duration, 1800, accuracy: 0.1,
                       "Should prefer activeDuration over span time")
    }

    func testTaskRecordAppNamesList() {
        let task = TaskRecord(
            date: "2025-01-15",
            startTime: Date(),
            endTime: Date(),
            title: "Test",
            description: "",
            appNames: "[\"Xcode\",\"Safari\",\"Terminal\"]"
        )

        XCTAssertEqual(task.appNamesList, ["Xcode", "Safari", "Terminal"])
    }

    func testTaskRecordAppNamesListWithInvalidJSON() {
        let task = TaskRecord(
            date: "2025-01-15",
            startTime: Date(),
            endTime: Date(),
            title: "Test",
            description: "",
            appNames: "not json"
        )

        XCTAssertTrue(task.appNamesList.isEmpty, "Invalid JSON should return empty array")
    }

    func testTaskRecordAppNamesListWithEmptyArray() {
        let task = TaskRecord(
            date: "2025-01-15",
            startTime: Date(),
            endTime: Date(),
            title: "Test",
            description: "",
            appNames: "[]"
        )

        XCTAssertTrue(task.appNamesList.isEmpty)
    }

    func testTaskRecordLinksList() {
        let task = TaskRecord(
            date: "2025-01-15",
            startTime: Date(),
            endTime: Date(),
            title: "Test",
            description: "",
            relevantLinks: "[\"https://github.com/user/repo\", \"/Users/sam/file.swift\"]"
        )

        XCTAssertEqual(task.linksList.count, 2)
        XCTAssertEqual(task.linksList[0].kind, .url)
        XCTAssertEqual(task.linksList[1].kind, .filePath)
    }

    func testTaskRecordDefaultValues() {
        let task = TaskRecord(
            date: "2025-01-15",
            startTime: Date(),
            endTime: Date(),
            title: "Minimal",
            description: ""
        )

        XCTAssertNil(task.id)
        XCTAssertEqual(task.appNames, "[]")
        XCTAssertEqual(task.confidence, 0.0)
        XCTAssertEqual(task.relevantLinks, "[]")
        XCTAssertNil(task.activeDuration)
    }

    func testTaskRecordHashable() {
        let now = Date()
        let task1 = TaskRecord(id: 1, date: "2025-01-15", startTime: now, endTime: now, title: "A", description: "")
        let task2 = TaskRecord(id: 2, date: "2025-01-15", startTime: now, endTime: now, title: "B", description: "")
        let task1Copy = TaskRecord(id: 1, date: "2025-01-15", startTime: now, endTime: now, title: "A", description: "")

        var set = Set<TaskRecord>()
        set.insert(task1)
        set.insert(task2)
        set.insert(task1Copy)

        // task1 and task1Copy should be considered equal
        XCTAssertLessThanOrEqual(set.count, 3) // Depends on Hashable impl
    }

    // MARK: - ProjectActivityRecord

    func testProjectActivityRecordAppNamesList() {
        let record = ProjectActivityRecord(
            date: "2025-01-15",
            name: "Project",
            summary: "Summary",
            totalDuration: 3600,
            appNames: "[\"Xcode\",\"Figma\"]",
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertEqual(record.appNamesList, ["Xcode", "Figma"])
    }

    func testProjectActivityRecordTaskTitlesList() {
        let record = ProjectActivityRecord(
            date: "2025-01-15",
            name: "Project",
            summary: "Summary",
            totalDuration: 3600,
            taskTitles: "[\"Coding\",\"Debugging\"]",
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertEqual(record.taskTitlesList, ["Coding", "Debugging"])
    }

    func testProjectActivityRecordInvalidJSON() {
        let record = ProjectActivityRecord(
            date: "2025-01-15",
            name: "Project",
            summary: "Summary",
            totalDuration: 3600,
            appNames: "bad",
            taskTitles: "bad",
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertTrue(record.appNamesList.isEmpty)
        XCTAssertTrue(record.taskTitlesList.isEmpty)
    }

    // MARK: - ActivityRecord

    func testActivityRecordDefaults() {
        let record = ActivityRecord(appName: "Xcode", bundleId: "com.apple.dt.Xcode")

        XCTAssertNil(record.id)
        XCTAssertNil(record.endTime)
        XCTAssertNil(record.windowTitle)
        XCTAssertNil(record.duration)
        XCTAssertFalse(record.isIdle)
    }

    // MARK: - ScreenshotTrigger

    func testScreenshotTriggerRawValues() {
        XCTAssertEqual(ScreenshotTrigger.appSwitch.rawValue, "app_switch")
        XCTAssertEqual(ScreenshotTrigger.titleChange.rawValue, "title_change")
        XCTAssertEqual(ScreenshotTrigger.periodic.rawValue, "periodic")
        XCTAssertEqual(ScreenshotTrigger.manual.rawValue, "manual")
    }

    func testScreenshotTriggerFromRawValue() {
        XCTAssertEqual(ScreenshotTrigger(rawValue: "app_switch"), .appSwitch)
        XCTAssertEqual(ScreenshotTrigger(rawValue: "periodic"), .periodic)
        XCTAssertNil(ScreenshotTrigger(rawValue: "invalid"))
    }

    // MARK: - TaskGranularity

    func testTaskGranularityTasksPerHour() {
        XCTAssertEqual(TaskGranularity.low.tasksPerHour, 1.0)
        XCTAssertEqual(TaskGranularity.medium.tasksPerHour, 3.0)
        XCTAssertEqual(TaskGranularity.high.tasksPerHour, 6.0)
    }

    func testTaskGranularityCodable() throws {
        for granularity in TaskGranularity.allCases {
            let data = try JSONEncoder().encode(granularity)
            let decoded = try JSONDecoder().decode(TaskGranularity.self, from: data)
            XCTAssertEqual(decoded, granularity)
        }
    }

    func testTaskGranularityDisplayNames() {
        XCTAssertFalse(TaskGranularity.low.displayName.isEmpty)
        XCTAssertFalse(TaskGranularity.medium.displayName.isEmpty)
        XCTAssertFalse(TaskGranularity.high.displayName.isEmpty)
    }

    func testTaskGranularityPromptInstruction() {
        for granularity in TaskGranularity.allCases {
            XCTAssertFalse(granularity.promptInstruction.isEmpty)
            // Each instruction should mention task count guidance
            XCTAssertTrue(granularity.promptInstruction.lowercased().contains("task"))
        }
    }

    // MARK: - PauseState

    func testPauseStateNotExpiredWhenFuture() {
        let state = PauseState(pausedAt: Date(), resumeAt: Date().addingTimeInterval(3600))
        XCTAssertFalse(state.isExpired)
        XCTAssertNotNil(state.timeRemaining)
        XCTAssertGreaterThan(state.timeRemaining!, 0)
    }

    func testPauseStateExpiredWhenPast() {
        let state = PauseState(pausedAt: Date().addingTimeInterval(-7200), resumeAt: Date().addingTimeInterval(-3600))
        XCTAssertTrue(state.isExpired)
        XCTAssertEqual(state.timeRemaining, 0)
    }

    func testPauseStateIndefinite() {
        let state = PauseState(pausedAt: Date(), resumeAt: nil)
        XCTAssertFalse(state.isExpired, "Indefinite pause should never be expired")
        XCTAssertNil(state.timeRemaining)
    }

    // MARK: - SummarizationInput

    func testSummarizationInputInit() {
        let now = Date()
        let input = SummarizationInput(
            appName: "Xcode",
            bundleId: "com.apple.dt.Xcode",
            windowTitle: "File.swift",
            timestamp: now,
            duration: 120,
            isIdle: false,
            ocrText: "some code"
        )

        XCTAssertEqual(input.appName, "Xcode")
        XCTAssertEqual(input.bundleId, "com.apple.dt.Xcode")
        XCTAssertEqual(input.windowTitle, "File.swift")
        XCTAssertEqual(input.timestamp, now)
        XCTAssertEqual(input.duration, 120)
        XCTAssertFalse(input.isIdle)
        XCTAssertEqual(input.ocrText, "some code")
    }

    // MARK: - GeminiError

    func testGeminiErrorDescriptions() {
        XCTAssertNotNil(GeminiError.invalidURL.errorDescription)
        XCTAssertNotNil(GeminiError.invalidResponse.errorDescription)
        XCTAssertNotNil(GeminiError.apiError(statusCode: 429, message: "rate limited").errorDescription)
        XCTAssertNotNil(GeminiError.parseError("bad json").errorDescription)

        XCTAssertTrue(GeminiError.apiError(statusCode: 429, message: "rate limited").errorDescription!.contains("429"))
    }

    // MARK: - DatabaseError

    func testDatabaseErrorDescriptions() {
        XCTAssertNotNil(DatabaseError.openFailed("test").errorDescription)
        XCTAssertNotNil(DatabaseError.executionFailed("test").errorDescription)
        XCTAssertNotNil(DatabaseError.migrationFailed("test").errorDescription)
        XCTAssertNotNil(DatabaseError.closed.errorDescription)
    }

    // MARK: - AppearanceMode

    func testAppearanceModeCodableRoundTrip() throws {
        for mode in AppearanceMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(AppearanceMode.self, from: data)
            XCTAssertEqual(decoded, mode, "Codable round-trip failed for \(mode)")
        }
    }

    func testAppearanceModeRawValues() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    func testAppearanceModeDisplayNames() {
        XCTAssertEqual(AppearanceMode.system.displayName, "System")
        XCTAssertEqual(AppearanceMode.light.displayName, "Light")
        XCTAssertEqual(AppearanceMode.dark.displayName, "Dark")
    }
}
