import Foundation

/// Represents an item in the task timeline — either a task or an idle gap.
public enum TimelineItem: Identifiable {
    case task(TaskRecord, isFirst: Bool, isLast: Bool)
    case gap(id: String, startTime: Date, endTime: Date, duration: TimeInterval)

    public var id: String {
        switch self {
        case .task(let record, _, _):
            return "task-\(record.id ?? 0)"
        case .gap(let id, _, _, _):
            return id
        }
    }

    /// Build timeline items from tasks, inserting idle gaps between them.
    ///
    /// Away periods are the primary structure — idle detection (screen lock, sleep,
    /// HID inactivity) is ground truth and always takes precedence over AI-generated
    /// task boundaries. Tasks fill the spaces between away periods.
    ///
    /// Gap sources:
    /// 1. **Idle activity records** — ground truth from the daemon, always shown if
    ///    above the user's configured threshold.
    /// 2. **Task boundary inference** — fallback when no idle records match but a
    ///    significant time hole exists between consecutive tasks.
    public static func build(from tasks: [TaskRecord], idleActivities: [ActivityRecord] = [], minIdleDuration: TimeInterval = 120) -> [TimelineItem] {
        guard !tasks.isEmpty else { return [] }

        // 1. Consolidate idle records into merged gap periods (independent of tasks)
        let idleGaps = consolidateIdlePeriods(idleActivities, minDuration: minIdleDuration)

        // 2. Sort tasks by start time — AI regeneration can produce out-of-order tasks
        let sorted = tasks.sorted { $0.startTime < $1.startTime }

        // 3. Define the active work range — only show gaps between first and last task
        let dayStart = sorted.first!.startTime
        let dayEnd = sorted.last!.endTime

        // 4. Collect gaps within the work range, clipped to fit.
        //    No re-filter against minIdleDuration — the gap already passed the
        //    threshold during consolidation. Only skip trivially small slivers
        //    (< 60s) produced by clipping to avoid rendering artifacts.
        var relevantGaps: [(start: Date, end: Date)] = []
        for gap in idleGaps {
            guard gap.end > dayStart && gap.start < dayEnd else { continue }
            let clippedStart = max(gap.start, dayStart)
            let clippedEnd = min(gap.end, dayEnd)
            guard clippedEnd.timeIntervalSince(clippedStart) >= 60 else { continue }
            relevantGaps.append((start: clippedStart, end: clippedEnd))
        }

        // 5. Merge tasks and gaps into a unified chronological timeline
        enum Event {
            case task(TaskRecord)
            case gap(index: Int, start: Date, end: Date, duration: TimeInterval)
        }

        var events: [(sortKey: Date, event: Event)] = []
        for task in sorted {
            events.append((sortKey: task.startTime, event: .task(task)))
        }
        for (i, gap) in relevantGaps.enumerated() {
            let duration = gap.end.timeIntervalSince(gap.start)
            events.append((sortKey: gap.start, event: .gap(index: i, start: gap.start, end: gap.end, duration: duration)))
        }
        events.sort { $0.sortKey < $1.sortKey }

        // 6. Fallback: add inferred gaps for large time holes between tasks
        //    that have no idle records (daemon was paused or crashed)
        var inferredCount = 0
        for i in 0..<(sorted.count - 1) {
            let prevEnd = sorted[i].endTime
            let nextStart = sorted[i + 1].startTime
            let hole = nextStart.timeIntervalSince(prevEnd)
            guard hole >= minIdleDuration else { continue }

            // Check if any gap (real or already in relevantGaps) covers this hole
            let covered = relevantGaps.contains { gap in
                gap.end > prevEnd && gap.start < nextStart
            }
            guard !covered else { continue }

            // Insert inferred gap
            events.append((sortKey: prevEnd, event: .gap(
                index: 1000 + inferredCount,
                start: prevEnd,
                end: nextStart,
                duration: hole
            )))
            inferredCount += 1
        }
        // Re-sort after adding inferred gaps
        if inferredCount > 0 {
            events.sort { $0.sortKey < $1.sortKey }
        }

        // 7. Convert to TimelineItems
        var items: [TimelineItem] = []
        for entry in events {
            switch entry.event {
            case .task(let task):
                let isFirst = items.isEmpty
                items.append(.task(task, isFirst: isFirst, isLast: false))
            case .gap(let index, let start, let end, let duration):
                items.append(.gap(
                    id: "idle-\(index)",
                    startTime: start,
                    endTime: end,
                    duration: duration
                ))
            }
        }

        // 8. Merge consecutive gaps — multiple idle periods between the same
        //    pair of tasks should display as a single "Away" entry.
        items = mergeConsecutiveGaps(items)

        // Fix isLast on the final task
        if let lastTaskIndex = items.lastIndex(where: {
            if case .task = $0 { return true }
            return false
        }) {
            if case .task(let record, let isFirst, _) = items[lastTaskIndex] {
                items[lastTaskIndex] = .task(record, isFirst: isFirst, isLast: true)
            }
        }

        return items
    }

    /// Merge consecutive gap items into a single gap spanning the full range.
    /// When multiple idle periods fall between the same pair of tasks, they
    /// should render as one combined "Away" entry in the timeline.
    private static func mergeConsecutiveGaps(_ items: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return items }

        var result: [TimelineItem] = []
        var i = 0

        while i < items.count {
            guard case .gap(_, let start, var end, _) = items[i] else {
                result.append(items[i])
                i += 1
                continue
            }

            // Absorb all consecutive gaps
            var mergedStart = start
            var mergedEnd = end
            let baseIndex = i
            i += 1
            while i < items.count, case .gap(_, let nextStart, let nextEnd, _) = items[i] {
                mergedStart = min(mergedStart, nextStart)
                mergedEnd = max(mergedEnd, nextEnd)
                i += 1
            }

            let duration = mergedEnd.timeIntervalSince(mergedStart)
            result.append(.gap(
                id: "idle-merged-\(baseIndex)",
                startTime: mergedStart,
                endTime: mergedEnd,
                duration: duration
            ))
        }

        return result
    }

    /// Consolidate idle ActivityRecords into merged time ranges.
    /// Handles unfinalized idle records (no end_time) by estimating
    /// the end from the next activity record's timestamp.
    /// The minDuration filter is applied **after** merging so that
    /// adjacent short idles that combine into a long gap are kept.
    public static func consolidateIdlePeriods(_ activities: [ActivityRecord], minDuration: TimeInterval) -> [(start: Date, end: Date)] {
        let sorted = activities.sorted { $0.timestamp < $1.timestamp }

        // Collect ALL idle ranges — no duration filter yet
        var idles: [(start: Date, end: Date)] = []
        for (i, record) in sorted.enumerated() {
            guard record.isIdle else { continue }

            let end: Date
            if let endTime = record.endTime {
                end = endTime
            } else if let duration = record.duration, duration > 0 {
                end = record.timestamp.addingTimeInterval(duration)
            } else {
                // Unfinalized idle record (daemon died during sleep, etc.)
                // Estimate end from the next non-idle activity's start time.
                let nextNonIdle = sorted.dropFirst(i + 1).first { !$0.isIdle }
                end = nextNonIdle?.timestamp ?? record.timestamp
            }

            guard end > record.timestamp else { continue }  // skip zero/negative
            idles.append((start: record.timestamp, end: end))
        }

        guard !idles.isEmpty else { return [] }

        // Merge overlapping/adjacent idle periods
        var merged: [(start: Date, end: Date)] = [idles[0]]
        for idle in idles.dropFirst() {
            if idle.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, idle.end)
            } else {
                merged.append(idle)
            }
        }

        // Filter by minDuration AFTER merging — small adjacent idles that
        // combine into a longer gap are preserved.
        return merged.filter { $0.end.timeIntervalSince($0.start) >= minDuration }
    }
}
