import Foundation

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
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    let startStr = f.string(from: start)
    if let end {
        return "\(startStr) – \(f.string(from: end))"
    }
    return startStr
}

let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()
