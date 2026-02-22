import Foundation
import TaskMinerShared

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60

    if hours > 0 {
        return "\(hours)h \(minutes)m"
    } else if minutes > 0 {
        return "\(minutes)m"
    } else {
        return "\(total)s"
    }
}

func formatTimeRange(start: Date?, end: Date?) -> String {
    guard let start else { return "" }
    let startStr = SharedFormatters.timeFormatter.string(from: start)
    if let end {
        return "\(startStr) – \(SharedFormatters.timeFormatter.string(from: end))"
    }
    return startStr
}
