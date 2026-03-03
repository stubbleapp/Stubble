import Foundation

/// Groups consecutive activities by app into logical chunks for display.
public struct ActivityGroup: Identifiable {
    public let id = UUID()
    public let appName: String
    public let bundleId: String?
    public var activities: [ActivityRecord]

    public var totalDuration: TimeInterval {
        activities.compactMap(\.duration).reduce(0, +)
    }

    public var startTime: Date? { activities.first?.timestamp }
    public var endTime: Date? { activities.last?.endTime ?? activities.last?.timestamp }

    public var windowTitles: [String] {
        activities.compactMap(\.windowTitle)
            .reduce(into: [String]()) { result, title in
                if result.last != title { result.append(title) }
            }
    }

    public init(appName: String, bundleId: String?, activities: [ActivityRecord]) {
        self.appName = appName
        self.bundleId = bundleId
        self.activities = activities
    }

    /// Group consecutive activities by app bundle ID.
    /// Idle activities are filtered out.
    public static func group(_ activities: [ActivityRecord]) -> [ActivityGroup] {
        var groups: [ActivityGroup] = []
        var current: ActivityGroup?

        for activity in activities where !activity.isIdle {
            if var group = current, group.bundleId == activity.bundleId {
                group.activities.append(activity)
                current = group
            } else {
                if let group = current { groups.append(group) }
                current = ActivityGroup(
                    appName: activity.appName,
                    bundleId: activity.bundleId,
                    activities: [activity]
                )
            }
        }
        if let group = current { groups.append(group) }
        return groups
    }
}
