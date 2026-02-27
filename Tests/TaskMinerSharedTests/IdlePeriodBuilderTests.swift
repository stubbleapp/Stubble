import XCTest
@testable import TaskMinerShared

final class IdlePeriodBuilderTests: XCTestCase {

    // MARK: - Helpers

    private func date(_ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 2
        comps.day = 15
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)!
    }

    private func makeIdleActivity(start: Date, end: Date? = nil, duration: TimeInterval? = nil) -> ActivityRecord {
        ActivityRecord(
            timestamp: start,
            endTime: end,
            appName: "idle",
            bundleId: nil,
            duration: duration,
            isIdle: true
        )
    }

    private func makeActiveActivity(start: Date, duration: TimeInterval) -> ActivityRecord {
        ActivityRecord(
            timestamp: start,
            appName: "Xcode",
            bundleId: nil,
            duration: duration,
            isIdle: false
        )
    }

    // MARK: - Tests

    func testConsolidateEmptyReturnsEmpty() {
        let result = IdlePeriod.consolidate(from: [], minDuration: 120)
        XCTAssertTrue(result.isEmpty)
    }

    func testConsolidateBasicPeriod() {
        let idle = makeIdleActivity(start: date(9, 0), end: date(9, 30))
        let result = IdlePeriod.consolidate(from: [idle], minDuration: 120)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].startTime, date(9, 0))
        XCTAssertEqual(result[0].endTime, date(9, 30))
        XCTAssertEqual(result[0].duration, 1800, accuracy: 1)
        XCTAssertEqual(result[0].recordCount, 1)
    }

    func testConsolidateMergesThenFilters() {
        // Two 8-minute idles → merge into 16 min, above 15-min threshold
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 8))
        let idle2 = makeIdleActivity(start: date(9, 8), end: date(9, 16))

        let result = IdlePeriod.consolidate(from: [idle1, idle2], minDuration: 900)

        XCTAssertEqual(result.count, 1, "Merged 16-min idle should pass 15-min threshold")
        XCTAssertEqual(result[0].recordCount, 2, "Should count both original records")
    }

    func testConsolidateFiltersBelowThreshold() {
        // Single 5-minute idle, below 15-min threshold
        let idle = makeIdleActivity(start: date(9, 0), end: date(9, 5))

        let result = IdlePeriod.consolidate(from: [idle], minDuration: 900)

        XCTAssertTrue(result.isEmpty, "5-min idle should be filtered by 15-min threshold")
    }

    func testConsolidateMultiplePeriods() {
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 30))
        let idle2 = makeIdleActivity(start: date(11, 0), end: date(11, 45))

        let result = IdlePeriod.consolidate(from: [idle1, idle2], minDuration: 120)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, "idle-0")
        XCTAssertEqual(result[1].id, "idle-1")
    }

    func testConsolidateCountsRecordsPerPeriod() {
        // Three overlapping idle records merge into one period
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 10))
        let idle2 = makeIdleActivity(start: date(9, 5), end: date(9, 20))
        let idle3 = makeIdleActivity(start: date(9, 15), end: date(9, 30))

        let result = IdlePeriod.consolidate(from: [idle1, idle2, idle3], minDuration: 120)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].recordCount, 3, "All three records fall within the merged period")
    }

    func testConsolidateIgnoresNonIdleRecords() {
        let active = makeActiveActivity(start: date(9, 0), duration: 3600)
        let idle = makeIdleActivity(start: date(10, 0), end: date(10, 30))

        let result = IdlePeriod.consolidate(from: [active, idle], minDuration: 120)

        XCTAssertEqual(result.count, 1, "Only idle records should produce periods")
        XCTAssertEqual(result[0].startTime, date(10, 0))
    }

    func testConsolidateIdWithDuration() {
        let idle = makeIdleActivity(start: date(9, 0), end: nil, duration: 1800)
        let result = IdlePeriod.consolidate(from: [idle], minDuration: 120)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].endTime, date(9, 30))
    }
}
