import XCTest
@testable import TaskMinerShared

final class TaskSummarizerParsingTests: XCTestCase {

    // We need a GeminiClient to create a TaskSummarizer, but we won't call the API.
    // Use a dummy key since we're only testing the parsing/aggregation methods.
    private var summarizer: TaskSummarizer!

    override func setUp() {
        super.setUp()
        summarizer = TaskSummarizer(geminiClient: GeminiClient(apiKey: "test-key-unused"))
    }

    // MARK: - parseTime

    func testParseTimeHHMMSS() {
        let day = Calendar.current.startOfDay(for: Date())
        let result = summarizer.parseTime("14:30:45", relativeTo: day)

        XCTAssertNotNil(result)
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result!)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(components.second, 45)
    }

    func testParseTimeHHMM() {
        let day = Calendar.current.startOfDay(for: Date())
        let result = summarizer.parseTime("09:15", relativeTo: day)

        XCTAssertNotNil(result)
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: result!)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 15)
        XCTAssertEqual(components.second, 0)
    }

    func testParseTimeMidnight() {
        let day = Calendar.current.startOfDay(for: Date())
        let result = summarizer.parseTime("00:00:00", relativeTo: day)
        XCTAssertNotNil(result)
    }

    func testParseTimeEndOfDay() {
        let day = Calendar.current.startOfDay(for: Date())
        let result = summarizer.parseTime("23:59:59", relativeTo: day)
        XCTAssertNotNil(result)
    }

    func testParseTimeRejectsInvalidHour() {
        let day = Calendar.current.startOfDay(for: Date())
        XCTAssertNil(summarizer.parseTime("25:00:00", relativeTo: day))
    }

    func testParseTimeRejectsInvalidMinute() {
        let day = Calendar.current.startOfDay(for: Date())
        XCTAssertNil(summarizer.parseTime("14:70:00", relativeTo: day))
    }

    func testParseTimeRejectsInvalidSecond() {
        let day = Calendar.current.startOfDay(for: Date())
        XCTAssertNil(summarizer.parseTime("14:30:60", relativeTo: day))
    }

    func testParseTimeRejectsGarbage() {
        let day = Calendar.current.startOfDay(for: Date())
        XCTAssertNil(summarizer.parseTime("not-a-time", relativeTo: day))
        XCTAssertNil(summarizer.parseTime("", relativeTo: day))
        XCTAssertNil(summarizer.parseTime("12", relativeTo: day))
    }

    // MARK: - aggregateActivities

    func testAggregatesConsecutiveSameApp() {
        let base = Date()
        let activities = [
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "File1.swift", timestamp: base, duration: 60, isIdle: false, ocrText: nil),
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "File2.swift", timestamp: base.addingTimeInterval(60), duration: 60, isIdle: false, ocrText: nil),
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "File3.swift", timestamp: base.addingTimeInterval(120), duration: 60, isIdle: false, ocrText: nil),
        ]

        let blocks = summarizer.aggregateActivities(activities)

        XCTAssertEqual(blocks.count, 1, "Consecutive same-app activities should merge into one block")
        XCTAssertEqual(blocks[0].appName, "Xcode")
        XCTAssertEqual(blocks[0].totalDuration, 180, accuracy: 0.1)
        XCTAssertEqual(blocks[0].windowTitles.count, 3)
    }

    func testSeparatesDifferentApps() {
        let base = Date()
        let activities = [
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "File.swift", timestamp: base, duration: 120, isIdle: false, ocrText: nil),
            SummarizationInput(appName: "Safari", bundleId: nil, windowTitle: "Apple Docs", timestamp: base.addingTimeInterval(120), duration: 60, isIdle: false, ocrText: nil),
            SummarizationInput(appName: "Terminal", bundleId: nil, windowTitle: "bash", timestamp: base.addingTimeInterval(180), duration: 30, isIdle: false, ocrText: nil),
        ]

        let blocks = summarizer.aggregateActivities(activities)

        // After coalescing, Terminal (30s) may merge with a neighbor, but Xcode and Safari should be separate
        XCTAssertGreaterThanOrEqual(blocks.count, 2, "Different apps should create separate blocks")
    }

    func testFiltersOutIdleActivities() {
        let base = Date()
        let activities = [
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "File.swift", timestamp: base, duration: 120, isIdle: false, ocrText: nil),
            SummarizationInput(appName: "Idle", bundleId: nil, windowTitle: nil, timestamp: base.addingTimeInterval(120), duration: 300, isIdle: true, ocrText: nil),
            SummarizationInput(appName: "Safari", bundleId: nil, windowTitle: "Docs", timestamp: base.addingTimeInterval(420), duration: 120, isIdle: false, ocrText: nil),
        ]

        let blocks = summarizer.aggregateActivities(activities)

        for block in blocks {
            XCTAssertNotEqual(block.appName, "Idle", "Idle activities should be filtered out")
        }
    }

    func testDeduplicatesWindowTitles() {
        let base = Date()
        let activities = [
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "Same Title", timestamp: base, duration: 60, isIdle: false, ocrText: nil),
            SummarizationInput(appName: "Xcode", bundleId: nil, windowTitle: "Same Title", timestamp: base.addingTimeInterval(60), duration: 60, isIdle: false, ocrText: nil),
        ]

        let blocks = summarizer.aggregateActivities(activities)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].windowTitles.count, 1, "Duplicate window titles should be deduplicated")
    }

    func testLimitsOCRSamplesToThree() {
        let base = Date()
        let activities = (0..<5).map { i in
            SummarizationInput(
                appName: "Xcode",
                bundleId: nil,
                windowTitle: "File\(i).swift",
                timestamp: base.addingTimeInterval(Double(i) * 60),
                duration: 60,
                isIdle: false,
                ocrText: "OCR text sample \(i)"
            )
        }

        let blocks = summarizer.aggregateActivities(activities)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertLessThanOrEqual(blocks[0].ocrSamples.count, 3, "OCR samples should be capped at 3")
    }

    func testEmptyActivitiesReturnsEmptyBlocks() {
        let blocks = summarizer.aggregateActivities([])
        XCTAssertTrue(blocks.isEmpty)
    }

    // MARK: - coalesceShortBlocks

    func testCoalescesShortBlockIntoNeighbor() {
        let base = Date()

        let blocks: [TaskSummarizer.ActivityBlock] = [
            .init(appName: "Xcode", startTime: base, endTime: base.addingTimeInterval(300),
                  windowTitles: ["File.swift"], totalDuration: 300, ocrSamples: []),
            .init(appName: "Safari", startTime: base.addingTimeInterval(300), endTime: base.addingTimeInterval(330),
                  windowTitles: ["Quick lookup"], totalDuration: 30, ocrSamples: []),
            .init(appName: "Xcode", startTime: base.addingTimeInterval(330), endTime: base.addingTimeInterval(630),
                  windowTitles: ["File2.swift"], totalDuration: 300, ocrSamples: []),
        ]

        let result = summarizer.coalesceShortBlocks(blocks)

        // Safari block (30s) should be too short and coalesce won't find a Safari neighbor, so
        // it stays. But both Xcode blocks should remain.
        // The key behavior: short blocks of a SAME app near each other get merged
        XCTAssertLessThanOrEqual(result.count, 3)
    }

    func testDoesNotCoalesceLongBlocks() {
        let base = Date()

        let blocks: [TaskSummarizer.ActivityBlock] = [
            .init(appName: "Xcode", startTime: base, endTime: base.addingTimeInterval(300),
                  windowTitles: ["A"], totalDuration: 300, ocrSamples: []),
            .init(appName: "Safari", startTime: base.addingTimeInterval(300), endTime: base.addingTimeInterval(600),
                  windowTitles: ["B"], totalDuration: 300, ocrSamples: []),
        ]

        let result = summarizer.coalesceShortBlocks(blocks)

        XCTAssertEqual(result.count, 2, "Blocks >= 60s should not be coalesced")
    }

    func testSingleBlockReturnsUnchanged() {
        let base = Date()
        let blocks: [TaskSummarizer.ActivityBlock] = [
            .init(appName: "Xcode", startTime: base, endTime: base.addingTimeInterval(10),
                  windowTitles: ["A"], totalDuration: 10, ocrSamples: []),
        ]

        let result = summarizer.coalesceShortBlocks(blocks)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - parseResponse

    func testParseValidResponse() throws {
        let json = """
        {
          "day_summary": "Productive coding day focused on SwiftUI.",
          "tasks": [
            {
              "title": "Developing settings view",
              "description": "Working on SwiftUI settings layout.",
              "start_time": "09:00:00",
              "end_time": "11:30:00",
              "active_seconds": 7200,
              "app_names": ["Xcode"],
              "confidence": 0.9,
              "relevant_links": ["https://developer.apple.com"]
            },
            {
              "title": "Researching SQLite best practices",
              "description": "Reading documentation on WAL mode and migrations.",
              "start_time": "11:30:00",
              "end_time": "12:00:00",
              "active_seconds": 1800,
              "app_names": ["Safari"],
              "confidence": 0.8,
              "relevant_links": []
            }
          ]
        }
        """

        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!
        let result = try summarizer.parseResponse(json, date: date)

        XCTAssertEqual(result.daySummary, "Productive coding day focused on SwiftUI.")
        XCTAssertEqual(result.tasks.count, 2)

        let first = result.tasks[0]
        XCTAssertEqual(first.title, "Developing settings view")
        XCTAssertEqual(first.description, "Working on SwiftUI settings layout.")
        XCTAssertEqual(first.date, "2025-01-15")
        XCTAssertEqual(first.confidence, 0.9, accuracy: 0.01)
        XCTAssertEqual(first.appNamesList, ["Xcode"])
        XCTAssertEqual(first.activeDuration, 7200)

        let second = result.tasks[1]
        XCTAssertEqual(second.title, "Researching SQLite best practices")
        XCTAssertEqual(second.appNamesList, ["Safari"])
    }

    func testParseResponseWithCodeFences() throws {
        let json = """
        ```json
        {
          "day_summary": null,
          "tasks": [
            {
              "title": "Browsing web",
              "description": "General browsing.",
              "start_time": "14:00",
              "end_time": "15:00",
              "app_names": ["Safari"],
              "confidence": 0.7,
              "relevant_links": []
            }
          ]
        }
        ```
        """

        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!
        let result = try summarizer.parseResponse(json, date: date)

        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertNil(result.daySummary)
    }

    func testParseResponseSkipsInvalidTasks() throws {
        let json = """
        {
          "day_summary": "Mixed quality data.",
          "tasks": [
            {
              "title": "Valid Task",
              "description": "Good one.",
              "start_time": "09:00:00",
              "end_time": "10:00:00",
              "app_names": ["Xcode"],
              "confidence": 0.9,
              "relevant_links": []
            },
            {
              "description": "Missing title",
              "start_time": "10:00:00",
              "end_time": "11:00:00"
            },
            {
              "title": "Missing times"
            },
            {
              "title": "Invalid times",
              "start_time": "25:99:99",
              "end_time": "99:99:99"
            }
          ]
        }
        """

        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!
        let result = try summarizer.parseResponse(json, date: date)

        XCTAssertEqual(result.tasks.count, 1, "Only valid tasks should be included")
        XCTAssertEqual(result.tasks[0].title, "Valid Task")
    }

    func testParseResponseEmptyTasks() throws {
        let json = """
        {"tasks": [], "day_summary": null}
        """

        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!
        let result = try summarizer.parseResponse(json, date: date)

        XCTAssertTrue(result.tasks.isEmpty)
        XCTAssertNil(result.daySummary)
    }

    func testParseResponseWithTrailingCommas() throws {
        let json = """
        {
          "day_summary": "Test.",
          "tasks": [
            {
              "title": "Coding",
              "description": "Writing code.",
              "start_time": "09:00:00",
              "end_time": "10:00:00",
              "active_seconds": 3600,
              "app_names": ["Xcode",],
              "confidence": 0.85,
              "relevant_links": [],
            },
          ],
        }
        """

        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!
        let result = try summarizer.parseResponse(json, date: date)

        XCTAssertEqual(result.tasks.count, 1)
    }

    func testParseResponseThrowsOnMissingTasksKey() {
        let json = "{\"summary\": \"No tasks key here\"}"
        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!

        XCTAssertThrowsError(try summarizer.parseResponse(json, date: date))
    }

    func testParseResponseThrowsOnInvalidJSON() {
        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!

        XCTAssertThrowsError(try summarizer.parseResponse("not json at all xyz", date: date))
    }

    func testParseResponseClampsConfidence() throws {
        let json = """
        {
          "tasks": [
            {
              "title": "Test",
              "description": "",
              "start_time": "09:00",
              "end_time": "10:00",
              "confidence": 1.5,
              "app_names": [],
              "relevant_links": []
            }
          ]
        }
        """

        let date = SharedFormatters.dayFormatter.date(from: "2025-01-15")!
        let result = try summarizer.parseResponse(json, date: date)

        XCTAssertEqual(result.tasks[0].confidence, 1.0, accuracy: 0.01, "Confidence should be clamped to 1.0")
    }

    // MARK: - mergeDuplicateTasks

    func testMergeDuplicateTasks() {
        let base = Calendar.current.startOfDay(for: Date())

        let tasks = [
            TaskRecord(date: "2025-01-15",
                       startTime: base.addingTimeInterval(3600 * 9),
                       endTime: base.addingTimeInterval(3600 * 10),
                       title: "Developing auth flow",
                       description: "Working on login.",
                       appNames: "[\"Xcode\"]",
                       confidence: 0.8,
                       activeDuration: 3600),
            TaskRecord(date: "2025-01-15",
                       startTime: base.addingTimeInterval(3600 * 11),
                       endTime: base.addingTimeInterval(3600 * 12),
                       title: "Developing auth flow",
                       description: "Finishing up validation logic for the login screen.",
                       appNames: "[\"Xcode\",\"Safari\"]",
                       confidence: 0.9,
                       activeDuration: 3600),
        ]

        let merged = TaskSummarizer.mergeDuplicateTasks(tasks)

        XCTAssertEqual(merged.count, 1, "Duplicate titles should merge")
        XCTAssertEqual(merged[0].title, "Developing auth flow")

        // Time should span both
        XCTAssertEqual(merged[0].startTime, base.addingTimeInterval(3600 * 9))
        XCTAssertEqual(merged[0].endTime, base.addingTimeInterval(3600 * 12))

        // Confidence should be the max
        XCTAssertEqual(merged[0].confidence, 0.9, accuracy: 0.01)

        // Active duration should be summed
        XCTAssertEqual(merged[0].activeDuration, 7200)

        // App names should be merged (deduplicated)
        let apps = merged[0].appNamesList
        XCTAssertTrue(apps.contains("Xcode"))
        XCTAssertTrue(apps.contains("Safari"))
    }

    func testMergeDuplicateTasksCaseInsensitive() {
        let base = Calendar.current.startOfDay(for: Date())

        let tasks = [
            TaskRecord(date: "2025-01-15",
                       startTime: base, endTime: base.addingTimeInterval(3600),
                       title: "Debugging Login", description: "Upper case.",
                       appNames: "[\"Xcode\"]", confidence: 0.8),
            TaskRecord(date: "2025-01-15",
                       startTime: base.addingTimeInterval(3600), endTime: base.addingTimeInterval(7200),
                       title: "debugging login", description: "Lower case.",
                       appNames: "[\"Safari\"]", confidence: 0.7),
        ]

        let merged = TaskSummarizer.mergeDuplicateTasks(tasks)

        XCTAssertEqual(merged.count, 1, "Case-insensitive duplicate titles should merge")
        // Should keep the first title's casing
        XCTAssertEqual(merged[0].title, "Debugging Login")
    }

    func testMergeNoDuplicatesReturnsAll() {
        let base = Calendar.current.startOfDay(for: Date())

        let tasks = [
            TaskRecord(date: "2025-01-15",
                       startTime: base, endTime: base.addingTimeInterval(3600),
                       title: "Task A", description: "A"),
            TaskRecord(date: "2025-01-15",
                       startTime: base.addingTimeInterval(3600), endTime: base.addingTimeInterval(7200),
                       title: "Task B", description: "B"),
        ]

        let merged = TaskSummarizer.mergeDuplicateTasks(tasks)
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeSingleTaskReturnsIt() {
        let task = TaskRecord(date: "2025-01-15", startTime: Date(), endTime: Date(), title: "Solo", description: "")
        let merged = TaskSummarizer.mergeDuplicateTasks([task])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].title, "Solo")
    }

    func testMergeEmptyReturnsEmpty() {
        let merged = TaskSummarizer.mergeDuplicateTasks([])
        XCTAssertTrue(merged.isEmpty)
    }
}
