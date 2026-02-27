import Foundation

/// A consolidated idle/away period merged from one or more idle ActivityRecords.
public struct IdlePeriod: Identifiable, Sendable {
    public let id: String
    public let startTime: Date
    public let endTime: Date
    public let duration: TimeInterval
    public let recordCount: Int  // how many raw idle records were merged

    public init(id: String, startTime: Date, endTime: Date, duration: TimeInterval, recordCount: Int) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.duration = duration
        self.recordCount = recordCount
    }

    /// Consolidate idle ActivityRecords into merged periods.
    /// Uses the same logic as the Day timeline gap detection.
    /// The minDuration filter is applied **after** merging so that
    /// adjacent short idles that combine into a long gap are kept.
    public static func consolidate(from activities: [ActivityRecord], minDuration: TimeInterval) -> [IdlePeriod] {
        let sorted = activities.sorted { $0.timestamp < $1.timestamp }

        // Collect ALL idle ranges — no duration filter yet
        var idles: [(start: Date, end: Date)] = []
        for (i, record) in sorted.enumerated() {
            guard record.isIdle else { continue }

            let end: Date
            if let endTime = record.endTime {
                end = endTime
            } else if let dur = record.duration, dur > 0 {
                end = record.timestamp.addingTimeInterval(dur)
            } else {
                // Unfinalized — estimate from next non-idle activity
                let nextNonIdle = sorted.dropFirst(i + 1).first { !$0.isIdle }
                end = nextNonIdle?.timestamp ?? record.timestamp
            }

            guard end > record.timestamp else { continue }  // skip zero/negative
            idles.append((start: record.timestamp, end: end))
        }

        guard !idles.isEmpty else { return [] }

        // Merge overlapping/adjacent
        var merged: [(start: Date, end: Date)] = [idles[0]]
        for idle in idles.dropFirst() {
            if idle.start <= merged[merged.count - 1].end {
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, idle.end)
            } else {
                merged.append(idle)
            }
        }

        // Filter by minDuration AFTER merging
        let filtered = merged.filter { $0.end.timeIntervalSince($0.start) >= minDuration }

        // Count raw records per merged period
        let idleRecords = sorted.filter { $0.isIdle }
        return filtered.enumerated().map { (index, period) in
            let count = idleRecords.filter { r in
                r.timestamp >= period.start && r.timestamp < period.end
            }.count
            return IdlePeriod(
                id: "idle-\(index)",
                startTime: period.start,
                endTime: period.end,
                duration: period.end.timeIntervalSince(period.start),
                recordCount: max(count, 1)
            )
        }
    }
}
