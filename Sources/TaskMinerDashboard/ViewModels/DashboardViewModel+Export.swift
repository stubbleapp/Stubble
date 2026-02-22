import Foundation
import SwiftUI
import UniformTypeIdentifiers
import TaskMinerShared

// MARK: - Export

extension DashboardViewModel {

    /// Build CSV content from the current task list.
    func tasksCSV() -> String {
        var lines: [String] = []
        lines.append("Date,Start,End,Duration,Title,Description,Apps,Confidence")

        for task in tasks {
            let date = task.date
            let start = SharedFormatters.timeSecondsFormatter.string(from: task.startTime)
            let end = SharedFormatters.timeSecondsFormatter.string(from: task.endTime)
            let duration = Int(task.endTime.timeIntervalSince(task.startTime))
            let mins = duration / 60
            let secs = duration % 60
            let durStr = String(format: "%d:%02d", mins, secs)
            let title = csvEscape(task.title)
            let desc = csvEscape(task.description)
            let apps = csvEscape(task.appNamesList.joined(separator: ", "))
            let conf = String(format: "%.0f%%", task.confidence * 100)
            lines.append("\(date),\(start),\(end),\(durStr),\(title),\(desc),\(apps),\(conf)")
        }

        return lines.joined(separator: "\n")
    }

    /// Export tasks as CSV via NSSavePanel.
    func exportTasksCSV() {
        guard !tasks.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "tasks-\(tasks.first?.date ?? "export").csv"
        panel.title = "Export Tasks"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try tasksCSV().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            summaryError = "Export failed: \(error.localizedDescription)"
        }
    }

    func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
