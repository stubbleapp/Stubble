import XCTest
@testable import TaskMinerShared

final class TimelineBuilderTests: XCTestCase {

    // MARK: - Helpers

    /// Create a date at the given hour and minute on a fixed day.
    private func date(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 2
        comps.day = 15
        comps.hour = hour
        comps.minute = minute
        comps.second = second
        return Calendar.current.date(from: comps)!
    }

    private func makeTask(id: Int64, start: Date, end: Date, title: String = "Task") -> TaskRecord {
        TaskRecord(
            id: id,
            date: "2025-02-15",
            startTime: start,
            endTime: end,
            title: title,
            description: ""
        )
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

    private func makeActiveActivity(start: Date, duration: TimeInterval, app: String = "Xcode") -> ActivityRecord {
        ActivityRecord(
            timestamp: start,
            appName: app,
            bundleId: nil,
            duration: duration,
            isIdle: false
        )
    }

    // MARK: - build() tests

    func testEmptyTasksReturnsEmpty() {
        let result = TimelineItem.build(from: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleTaskReturnsSingleItem() {
        let task = makeTask(id: 1, start: date(9, 0), end: date(10, 0))
        let result = TimelineItem.build(from: [task])

        XCTAssertEqual(result.count, 1)
        if case .task(let r, let isFirst, let isLast) = result[0] {
            XCTAssertEqual(r.id, 1)
            XCTAssertTrue(isFirst)
            XCTAssertTrue(isLast)
        } else {
            XCTFail("Expected .task")
        }
    }

    func testTwoAdjacentTasksNoGap() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(10, 0))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))
        let result = TimelineItem.build(from: [t1, t2])

        // Two tasks, no gap (0 time between them, below minIdleDuration)
        XCTAssertEqual(result.count, 2)
        if case .task(_, let isFirst, let isLast) = result[0] {
            XCTAssertTrue(isFirst)
            XCTAssertFalse(isLast)
        } else { XCTFail("Expected .task at 0") }
        if case .task(_, let isFirst, let isLast) = result[1] {
            XCTAssertFalse(isFirst)
            XCTAssertTrue(isLast)
        } else { XCTFail("Expected .task at 1") }
    }

    func testInferredGapBetweenTasks() {
        // Two tasks with a 30-min gap, no idle records → inferred gap
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))
        let result = TimelineItem.build(from: [t1, t2], minIdleDuration: 120)

        XCTAssertEqual(result.count, 3, "Should have task, gap, task")
        if case .gap(_, let start, let end, let duration) = result[1] {
            XCTAssertEqual(start, date(9, 30))
            XCTAssertEqual(end, date(10, 0))
            XCTAssertEqual(duration, 1800, accuracy: 1)
        } else {
            XCTFail("Expected .gap at index 1")
        }
    }

    func testIdleRecordsConsolidateIntoGap() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))

        // Idle record covering the gap
        let idle = makeIdleActivity(start: date(9, 30), end: date(10, 0))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle], minIdleDuration: 120)

        XCTAssertEqual(result.count, 3)
        if case .gap(_, let start, let end, _) = result[1] {
            XCTAssertEqual(start, date(9, 30))
            XCTAssertEqual(end, date(10, 0))
        } else {
            XCTFail("Expected idle gap between tasks")
        }
    }

    func testShortIdleBelowThresholdIsFiltered() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(9, 31), end: date(10, 0))

        // 1-minute idle — below 2-min threshold
        let idle = makeIdleActivity(start: date(9, 30), end: date(9, 31))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle], minIdleDuration: 120)

        // No gap should appear (1 min < 2 min threshold, and hole is also < threshold)
        let gapCount = result.filter { if case .gap = $0 { return true }; return false }.count
        XCTAssertEqual(gapCount, 0, "Short idle below threshold should not produce a gap")
    }

    func testAdjacentShortIdlesMergeAboveThreshold() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))

        // Two 8-minute idle records that are adjacent — merge into 16 min
        let idle1 = makeIdleActivity(start: date(9, 32), end: date(9, 40))
        let idle2 = makeIdleActivity(start: date(9, 40), end: date(9, 48))

        // Threshold is 15 minutes
        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle1, idle2], minIdleDuration: 900)

        let gaps = result.compactMap { item -> (Date, Date)? in
            if case .gap(_, let s, let e, _) = item { return (s, e) }
            return nil
        }

        XCTAssertTrue(gaps.count >= 1, "Adjacent short idles that merge above threshold should appear as gap")
    }

    func testGapClippedToWorkRange() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(10, 0))
        let t2 = makeTask(id: 2, start: date(11, 0), end: date(12, 0))

        // Idle starts before first task and extends into work range
        let idle = makeIdleActivity(start: date(8, 30), end: date(9, 30))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle], minIdleDuration: 120)

        // The gap should be clipped to start at 9:00 (first task start) not 8:30
        let gaps = result.compactMap { item -> (Date, Date)? in
            if case .gap(_, let s, let e, _) = item { return (s, e) }
            return nil
        }

        // The clipped gap from 9:00 would overlap with task 1 (which starts at 9:00)
        // Since the gap is clipped to dayStart (9:00) and dayEnd (12:00), the clipped
        // portion would be from 9:00 to 9:30. Let's check no gap extends before 9:00
        for (start, _) in gaps {
            XCTAssertGreaterThanOrEqual(start, date(9, 0), "Gap should not extend before first task")
        }
    }

    func testGapAfterWorkRangeIsExcluded() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(10, 0))
        let t2 = makeTask(id: 2, start: date(11, 0), end: date(12, 0))

        // Idle entirely after last task
        let idle = makeIdleActivity(start: date(12, 30), end: date(13, 0))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle], minIdleDuration: 120)

        let gaps = result.compactMap { item -> (Date, Date)? in
            if case .gap(_, let s, let e, _) = item { return (s, e) }
            return nil
        }

        for (_, end) in gaps {
            XCTAssertLessThanOrEqual(end, date(12, 0), "Gap should not extend after last task")
        }
    }

    func testUnfinalizedIdleRecordEstimatesEndFromNextActivity() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 30), end: date(11, 0))

        // Unfinalized idle (no endTime, no duration) + a follow-up active record
        let idle = makeIdleActivity(start: date(9, 30), end: nil, duration: nil)
        let active = makeActiveActivity(start: date(10, 15), duration: 60)

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle, active], minIdleDuration: 120)

        let gaps = result.compactMap { item -> (Date, Date)? in
            if case .gap(_, let s, let e, _) = item { return (s, e) }
            return nil
        }

        // The idle should have been estimated to end at the next non-idle activity (10:15)
        XCTAssertTrue(gaps.contains { $0.0 == date(9, 30) && $0.1 == date(10, 15) },
                       "Unfinalized idle should use next non-idle timestamp as end")
    }

    func testInferredGapNotAddedWhenRealGapCoversHole() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 30), end: date(11, 0))

        // Real idle gap that covers the hole
        let idle = makeIdleActivity(start: date(9, 35), end: date(10, 25))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle], minIdleDuration: 120)

        let gaps = result.compactMap { item -> (Date, Date)? in
            if case .gap(_, let s, let e, _) = item { return (s, e) }
            return nil
        }

        // Should only have the real gap, no inferred gap
        XCTAssertEqual(gaps.count, 1, "Should not add inferred gap when real gap already covers the hole")
    }

    func testTasksSortedByStartTime() {
        // Provide tasks out of order
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(10, 0))

        let result = TimelineItem.build(from: [t2, t1])

        if case .task(let r, _, _) = result[0] {
            XCTAssertEqual(r.id, 1, "First item should be the earlier task")
        } else { XCTFail("Expected .task at 0") }
    }

    func testMultipleGapsAndTasksInterleaved() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(10, 30))
        let t3 = makeTask(id: 3, start: date(11, 0), end: date(12, 0))

        let idle1 = makeIdleActivity(start: date(9, 30), end: date(10, 0))
        let idle2 = makeIdleActivity(start: date(10, 30), end: date(11, 0))

        let result = TimelineItem.build(from: [t1, t2, t3], idleActivities: [idle1, idle2], minIdleDuration: 120)

        // Expected: task, gap, task, gap, task = 5 items
        XCTAssertEqual(result.count, 5)

        // Verify interleaving pattern
        let pattern = result.map { item -> String in
            switch item {
            case .task: return "T"
            case .gap: return "G"
            }
        }
        XCTAssertEqual(pattern, ["T", "G", "T", "G", "T"])
    }

    func testGapInsideTaskTimeSpanIsNotRemoved() {
        // This tests the critical fix: away periods are ground truth,
        // they should NOT be removed even if they fall within a task's time span
        let task = makeTask(id: 1, start: date(9, 0), end: date(10, 30))

        // User was away 9:45–10:15 (30 min)
        let idle = makeIdleActivity(start: date(9, 45), end: date(10, 15))

        let result = TimelineItem.build(from: [task], idleActivities: [idle], minIdleDuration: 120)

        let gapCount = result.filter { if case .gap = $0 { return true }; return false }.count
        XCTAssertEqual(gapCount, 1, "Away period within a task's time span must still be shown (idle detection is ground truth)")
    }

    func testIsFirstAndIsLastFlags() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(10, 0))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))
        let t3 = makeTask(id: 3, start: date(11, 0), end: date(12, 0))

        let result = TimelineItem.build(from: [t1, t2, t3])

        if case .task(_, let isFirst, let isLast) = result[0] {
            XCTAssertTrue(isFirst); XCTAssertFalse(isLast)
        } else { XCTFail("Expected task at 0") }
        if case .task(_, let isFirst, let isLast) = result[1] {
            XCTAssertFalse(isFirst); XCTAssertFalse(isLast)
        } else { XCTFail("Expected task at 1") }
        if case .task(_, let isFirst, let isLast) = result[2] {
            XCTAssertFalse(isFirst); XCTAssertTrue(isLast)
        } else { XCTFail("Expected task at 2") }
    }

    func testIsLastFlagOnTaskBeforeTrailingGap() {
        // If the last event in the timeline is a gap, the last task
        // (which precedes the gap) should still have isLast = true
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(10, 0), end: date(11, 0))

        // Idle at the very end of the range
        let idle = makeIdleActivity(start: date(10, 30), end: date(10, 55))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle], minIdleDuration: 120)

        // Find the last task
        let lastTask = result.last(where: { if case .task = $0 { return true }; return false })
        if case .task(_, _, let isLast) = lastTask {
            XCTAssertTrue(isLast, "Last task should have isLast = true even if a gap follows")
        } else {
            XCTFail("Expected a task in results")
        }
    }

    func testConsecutiveGapsMergedIntoOne() {
        // Two tasks with two separate idle periods between them (not overlapping,
        // so consolidateIdlePeriods keeps them separate). They should still
        // render as a single "Away" in the timeline.
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(9, 30))
        let t2 = makeTask(id: 2, start: date(11, 0), end: date(12, 0))

        // Two non-overlapping idle periods between the tasks
        let idle1 = makeIdleActivity(start: date(9, 30), end: date(10, 0))
        let idle2 = makeIdleActivity(start: date(10, 15), end: date(10, 45))

        let result = TimelineItem.build(from: [t1, t2], idleActivities: [idle1, idle2], minIdleDuration: 120)

        let gaps = result.compactMap { item -> (Date, Date, TimeInterval)? in
            if case .gap(_, let s, let e, let d) = item { return (s, e, d) }
            return nil
        }

        XCTAssertEqual(gaps.count, 1, "Consecutive gaps with no task between them should be merged into one")
        // Merged gap should span from earliest start to latest end
        XCTAssertEqual(gaps[0].0, date(9, 30))
        XCTAssertEqual(gaps[0].1, date(10, 45))
        XCTAssertEqual(gaps[0].2, date(10, 45).timeIntervalSince(date(9, 30)), accuracy: 1)
    }

    func testClippedSliverUnder60sIsDiscarded() {
        let t1 = makeTask(id: 1, start: date(9, 0), end: date(10, 0))

        // Idle that barely overlaps the work range — only 30s inside
        let idle = makeIdleActivity(start: date(8, 55), end: date(9, 0, 30))

        let result = TimelineItem.build(from: [t1], idleActivities: [idle], minIdleDuration: 10)

        let gapCount = result.filter { if case .gap = $0 { return true }; return false }.count
        XCTAssertEqual(gapCount, 0, "Clipped sliver under 60s should be discarded")
    }

    // MARK: - consolidateIdlePeriods() tests

    func testConsolidateEmptyReturnsEmpty() {
        let result = TimelineItem.consolidateIdlePeriods([], minDuration: 120)
        XCTAssertTrue(result.isEmpty)
    }

    func testConsolidateSingleIdleRecord() {
        let idle = makeIdleActivity(start: date(9, 0), end: date(9, 30))
        let result = TimelineItem.consolidateIdlePeriods([idle], minDuration: 120)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, date(9, 0))
        XCTAssertEqual(result[0].end, date(9, 30))
    }

    func testConsolidateOverlappingIdlesMerge() {
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 20))
        let idle2 = makeIdleActivity(start: date(9, 15), end: date(9, 45))

        let result = TimelineItem.consolidateIdlePeriods([idle1, idle2], minDuration: 120)

        XCTAssertEqual(result.count, 1, "Overlapping idles should merge into one")
        XCTAssertEqual(result[0].start, date(9, 0))
        XCTAssertEqual(result[0].end, date(9, 45))
    }

    func testConsolidateAdjacentIdlesMerge() {
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 15))
        let idle2 = makeIdleActivity(start: date(9, 15), end: date(9, 30))

        let result = TimelineItem.consolidateIdlePeriods([idle1, idle2], minDuration: 120)

        XCTAssertEqual(result.count, 1, "Adjacent idles should merge")
        XCTAssertEqual(result[0].start, date(9, 0))
        XCTAssertEqual(result[0].end, date(9, 30))
    }

    func testConsolidateNonOverlappingStaySeparate() {
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 10))
        let idle2 = makeIdleActivity(start: date(10, 0), end: date(10, 10))

        let result = TimelineItem.consolidateIdlePeriods([idle1, idle2], minDuration: 120)

        XCTAssertEqual(result.count, 2, "Non-overlapping idles should stay separate")
    }

    func testConsolidateZeroDurationRecordSkipped() {
        // Record with same start and end (via nil endTime + nil duration + no next activity)
        let idle = ActivityRecord(
            timestamp: date(9, 0),
            endTime: nil,
            appName: "idle",
            bundleId: nil,
            duration: nil,
            isIdle: true
        )
        let result = TimelineItem.consolidateIdlePeriods([idle], minDuration: 0)

        XCTAssertTrue(result.isEmpty, "Zero-duration idle should be skipped")
    }

    func testConsolidateMinDurationFilterAppliedAfterMerge() {
        // Two 8-minute idles adjacent → merge into 16 minutes
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 8))
        let idle2 = makeIdleActivity(start: date(9, 8), end: date(9, 16))

        // Threshold is 15 minutes (900s)
        let result = TimelineItem.consolidateIdlePeriods([idle1, idle2], minDuration: 900)

        XCTAssertEqual(result.count, 1, "Two 8-min idles merging into 16-min should pass 15-min threshold")
        XCTAssertEqual(result[0].end.timeIntervalSince(result[0].start), 960, accuracy: 1) // 16 min
    }

    func testConsolidateMinDurationFilterRejectsAfterMerge() {
        // Two 5-minute idles adjacent → merge into 10 minutes, below 15-min threshold
        let idle1 = makeIdleActivity(start: date(9, 0), end: date(9, 5))
        let idle2 = makeIdleActivity(start: date(9, 5), end: date(9, 10))

        let result = TimelineItem.consolidateIdlePeriods([idle1, idle2], minDuration: 900)

        XCTAssertTrue(result.isEmpty, "10-min merged idle should be rejected by 15-min threshold")
    }

    func testConsolidateUnfinalizedIdleUsesNextNonIdleTimestamp() {
        let idle = makeIdleActivity(start: date(9, 0), end: nil, duration: nil)
        let active = makeActiveActivity(start: date(9, 45), duration: 60)

        let result = TimelineItem.consolidateIdlePeriods([idle, active], minDuration: 120)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].end, date(9, 45),
                        "Unfinalized idle should use next non-idle timestamp as end")
    }

    func testConsolidateIdleWithDurationField() {
        // Idle has no endTime but has a duration field
        let idle = makeIdleActivity(start: date(9, 0), end: nil, duration: 1800)

        let result = TimelineItem.consolidateIdlePeriods([idle], minDuration: 120)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].end, date(9, 30),
                        "Should compute end from start + duration")
    }

    func testConsolidateNonIdleRecordsIgnored() {
        let active = makeActiveActivity(start: date(9, 0), duration: 3600)
        let result = TimelineItem.consolidateIdlePeriods([active], minDuration: 0)

        XCTAssertTrue(result.isEmpty, "Non-idle records should be ignored")
    }
}
