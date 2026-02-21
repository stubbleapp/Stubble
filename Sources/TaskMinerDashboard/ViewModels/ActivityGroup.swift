import Foundation
import TaskMinerShared

struct ActivityGroup: Identifiable {
    let id = UUID()
    let appName: String
    let bundleId: String?
    var activities: [ActivityRecord]

    var totalDuration: TimeInterval {
        activities.compactMap(\.duration).reduce(0, +)
    }

    var startTime: Date? { activities.first?.timestamp }
    var endTime: Date? { activities.last?.endTime ?? activities.last?.timestamp }

    var windowTitles: [String] {
        activities.compactMap(\.windowTitle)
            .reduce(into: [String]()) { result, title in
                if result.last != title { result.append(title) }
            }
    }

    static func group(_ activities: [ActivityRecord]) -> [ActivityGroup] {
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
