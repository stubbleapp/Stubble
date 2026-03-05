import SwiftUI
import TaskMinerShared

// IdlePeriod is defined in TaskMinerShared/Processing/IdlePeriodBuilder.swift

// MARK: - LogEntry

/// Unified log entry wrapping all event types for reverse-chronological display.
enum LogEntry: Identifiable {
    case activity(ActivityRecord)
    case screenshot(ScreenshotRecord)
    case fileEvent(FileEventRecord)
    case task(TaskRecord)
    case idlePeriod(IdlePeriod)
    case granolaMeeting(GranolaMeetingRecord)

    var id: String {
        switch self {
        case .activity(let r):       return "act-\(r.id ?? 0)"
        case .screenshot(let r):     return "ss-\(r.id ?? 0)"
        case .fileEvent(let r):      return "fe-\(r.id)"
        case .task(let r):           return "task-\(r.id ?? 0)"
        case .idlePeriod(let p):     return p.id
        case .granolaMeeting(let m): return "meeting-\(m.id)"
        }
    }

    var timestamp: Date {
        switch self {
        case .activity(let r):       return r.timestamp
        case .screenshot(let r):     return r.timestamp
        case .fileEvent(let r):      return r.timestamp
        case .task(let r):           return r.startTime
        case .idlePeriod(let p):     return p.startTime
        case .granolaMeeting(let m): return m.startTime
        }
    }
}

// MARK: - Filter

enum LogFilterType: String, CaseIterable {
    case all = "All"
    case activities = "Activities"
    case screenshots = "Screenshots"
    case fileEvents = "Files"
    case tasks = "Tasks"
    case meetings = "Meetings"
    case away = "Away"
}

// MARK: - ActivityLogView

struct ActivityLogView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var expandedEntryId: String?
    @State private var filterType: LogFilterType = .all

    private var idlePeriods: [IdlePeriod] {
        let minDuration = TimeInterval(SettingsManager.shared.minAwayMinutes * 60)
        return IdlePeriod.consolidate(from: viewModel.activities, minDuration: minDuration)
    }

    private var logEntries: [LogEntry] {
        var entries: [LogEntry] = []
        entries.reserveCapacity(
            viewModel.activities.count + viewModel.screenshots.count +
            viewModel.fileEvents.count + viewModel.tasks.count
        )

        // Exclude raw idle records from the main list — they're replaced by consolidated IdlePeriods
        for a in viewModel.activities where !a.isIdle { entries.append(.activity(a)) }
        for s in viewModel.screenshots { entries.append(.screenshot(s)) }
        for f in viewModel.fileEvents { entries.append(.fileEvent(f)) }
        for t in viewModel.tasks { entries.append(.task(t)) }
        for p in idlePeriods { entries.append(.idlePeriod(p)) }
        for m in viewModel.granolaMeetings { entries.append(.granolaMeeting(m)) }

        entries.sort { $0.timestamp > $1.timestamp }
        return entries
    }

    private var filteredEntries: [LogEntry] {
        switch filterType {
        case .all: return logEntries
        case .activities: return logEntries.filter { if case .activity = $0 { return true }; return false }
        case .screenshots: return logEntries.filter { if case .screenshot = $0 { return true }; return false }
        case .fileEvents: return logEntries.filter { if case .fileEvent = $0 { return true }; return false }
        case .tasks: return logEntries.filter { if case .task = $0 { return true }; return false }
        case .meetings: return logEntries.filter { if case .granolaMeeting = $0 { return true }; return false }
        case .away: return logEntries.filter { if case .idlePeriod = $0 { return true }; return false }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if filteredEntries.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(
                                entry: entry,
                                isExpanded: expandedEntryId == entry.id,
                                screenshotDir: viewModel.config?.screenshotDirectory
                                    ?? FileManager.default.temporaryDirectory
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedEntryId = expandedEntryId == entry.id ? nil : entry.id
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
            }
        }
        .onAppear {
            // Lazy-load heavy data only when Log view is accessed
            viewModel.loadLogViewDataIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.title2.bold())
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Text("\(filteredEntries.count) entries")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(spacing: 6) {
                ForEach(LogFilterType.allCases, id: \.self) { type in
                    FilterPill(
                        title: type.rawValue,
                        isSelected: filterType == type,
                        count: count(for: type)
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            filterType = type
                        }
                    }
                }
            }
        }
    }

    private func count(for type: LogFilterType) -> Int {
        switch type {
        case .all: return logEntries.count
        case .activities: return viewModel.activities.filter({ !$0.isIdle }).count
        case .screenshots: return viewModel.screenshots.count
        case .fileEvents: return viewModel.fileEvents.count
        case .tasks: return viewModel.tasks.count
        case .meetings: return viewModel.granolaMeetings.count
        case .away: return idlePeriods.count
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textQuaternary)
            Text("No log entries for this day")
                .font(.title3.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - FilterPill

private struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? Theme.textSecondary : Theme.textMuted)
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Theme.selectedSurface : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Theme.cardBorder : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - LogEntryRow

private struct LogEntryRow: View {
    let entry: LogEntry
    let isExpanded: Bool
    let screenshotDir: URL

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let timeRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row
            HStack(spacing: 8) {
                typeIcon
                    .frame(width: 16, alignment: .center)

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 62, alignment: .leading)

                summaryText
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textQuaternary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            // Expanded detail
            if isExpanded {
                detailView
                    .padding(.leading, 86)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(isExpanded ? Theme.cardBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Type Icon

    @ViewBuilder
    private var typeIcon: some View {
        switch entry {
        case .activity(let r):
            Circle()
                .fill(r.isIdle ? Color.orange : Theme.statusActive)
                .frame(width: 8, height: 8)
        case .screenshot(let r):
            Image(systemName: "camera.fill")
                .font(.system(size: 10))
                .foregroundStyle(triggerColor(for: r.trigger))
        case .fileEvent(let r):
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(fileEventColor(for: r.eventType))
        case .task:
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
        case .idlePeriod:
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.statusPaused)
        case .granolaMeeting:
            Image(systemName: "person.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.purple)
        }
    }

    private func triggerColor(for trigger: ScreenshotTrigger) -> Color {
        switch trigger {
        case .appSwitch: return Theme.triggerAppSwitch
        case .titleChange: return Theme.triggerTitleChange
        case .periodic: return Theme.triggerPeriodic
        case .manual: return Theme.triggerManual
        }
    }

    private func fileEventColor(for eventType: String) -> Color {
        switch eventType {
        case "created": return Theme.statusActive
        case "removed": return Theme.statusError
        case "renamed": return Theme.statusPaused
        default: return Color.blue
        }
    }

    // MARK: - Summary Text

    @ViewBuilder
    private var summaryText: some View {
        switch entry {
        case .activity(let r):
            HStack(spacing: 4) {
                if r.isIdle {
                    Text("Idle")
                        .foregroundStyle(.orange)
                } else {
                    Text(r.appName)
                        .foregroundStyle(Theme.textPrimary)
                }
                if let title = r.windowTitle, !title.isEmpty, !r.isIdle {
                    Text("—")
                        .foregroundStyle(Theme.textMuted)
                    Text(title)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

        case .screenshot(let r):
            HStack(spacing: 4) {
                Text("Screenshot")
                    .foregroundStyle(Theme.textPrimary)
                Text("(\(r.trigger.rawValue))")
                    .foregroundStyle(Theme.textMuted)
                if let ocr = r.ocrText, !ocr.isEmpty {
                    Text(String(ocr.prefix(60)).replacingOccurrences(of: "\n", with: " "))
                        .foregroundStyle(Theme.textQuaternary)
                }
            }

        case .fileEvent(let r):
            HStack(spacing: 4) {
                Text(r.eventType)
                    .foregroundStyle(fileEventColor(for: r.eventType))
                Text(r.fileName)
                    .foregroundStyle(Theme.textPrimary)
            }

        case .task(let r):
            HStack(spacing: 4) {
                Text("Task")
                    .foregroundStyle(Theme.accent)
                Text(r.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("(\(Self.timeRangeFormatter.string(from: r.startTime))–\(Self.timeRangeFormatter.string(from: r.endTime)))")
                    .foregroundStyle(Theme.textMuted)
            }

        case .idlePeriod(let p):
            HStack(spacing: 4) {
                Text("Away")
                    .foregroundStyle(Theme.statusPaused)
                Text("\(Self.timeRangeFormatter.string(from: p.startTime))–\(Self.timeRangeFormatter.string(from: p.endTime))")
                    .foregroundStyle(Theme.textPrimary)
                Text("(\(Self.formatDuration(p.duration)))")
                    .foregroundStyle(Theme.textMuted)
            }

        case .granolaMeeting(let m):
            HStack(spacing: 4) {
                Text("Meeting")
                    .foregroundStyle(.purple)
                Text(m.title)
                    .foregroundStyle(Theme.textPrimary)
                Text("(\(Self.timeRangeFormatter.string(from: m.startTime))–\(Self.timeRangeFormatter.string(from: m.endTime)))")
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval / 60)
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch entry {
        case .activity(let r):
            activityDetail(r)
        case .screenshot(let r):
            screenshotDetail(r)
        case .fileEvent(let r):
            fileEventDetail(r)
        case .task(let r):
            taskDetail(r)
        case .idlePeriod(let p):
            idlePeriodDetail(p)
        case .granolaMeeting(let m):
            granolaMeetingDetail(m)
        }
    }

    // MARK: Activity Detail

    private func activityDetail(_ r: ActivityRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let duration = r.duration {
                detailRow("Duration", "\(Int(duration))s")
            }
            if let bundleId = r.bundleId {
                detailRow("Bundle", bundleId)
            }
            if let url = r.browserURL, !url.isEmpty {
                detailRow("URL", url)
            }
            if let docPath = r.documentPath, !docPath.isEmpty {
                detailRow("Document", docPath)
            }
            if let role = r.focusedElementRole, !role.isEmpty {
                detailRow("AX Role", role)
            }
            if let title = r.windowTitle, !title.isEmpty {
                detailRow("Window", title)
            }
        }
    }

    // MARK: Screenshot Detail

    private func screenshotDetail(_ r: ScreenshotRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Trigger", r.trigger.rawValue)
            detailRow("Path", r.filePath)
            if let size = r.fileSize {
                detailRow("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }

            // Thumbnail
            let fullPath = screenshotDir.appendingPathComponent(r.filePath).path
            if FileManager.default.fileExists(atPath: fullPath),
               let nsImage = NSImage(contentsOfFile: fullPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.top, 4)
            }

            // OCR text
            if let ocr = r.ocrText, !ocr.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("OCR Text")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(String(ocr.prefix(500)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: File Event Detail

    private func fileEventDetail(_ r: FileEventRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Type", r.eventType)
            detailRow("Path", r.filePath)
        }
    }

    // MARK: Task Detail

    private func taskDetail(_ r: TaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Time", "\(Self.timeRangeFormatter.string(from: r.startTime)) – \(Self.timeRangeFormatter.string(from: r.endTime))")
            detailRow("Confidence", String(format: "%.0f%%", r.confidence * 100))

            if let activeDuration = r.activeDuration {
                detailRow("Active", "\(Int(activeDuration / 60))m")
            }

            let apps = parseAppNames(r.appNames)
            if !apps.isEmpty {
                detailRow("Apps", apps.joined(separator: ", "))
            }

            if !r.description.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Description")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(r.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Idle Period Detail

    private func idlePeriodDetail(_ p: IdlePeriod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Start", Self.timeFormatter.string(from: p.startTime))
            detailRow("End", Self.timeFormatter.string(from: p.endTime))
            detailRow("Duration", Self.formatDuration(p.duration))
            if p.recordCount > 1 {
                detailRow("Records", "\(p.recordCount) idle events merged")
            }
        }
    }

    // MARK: Granola Meeting Detail

    private func granolaMeetingDetail(_ m: GranolaMeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            detailRow("Time", "\(Self.timeRangeFormatter.string(from: m.startTime)) – \(Self.timeRangeFormatter.string(from: m.endTime))")
            detailRow("Duration", m.formattedDuration)
            if let organizer = m.organizer, !organizer.isEmpty {
                detailRow("Organizer", organizer)
            }
            if m.attendeeCount > 0 {
                detailRow("Attendees", m.attendeeNames.joined(separator: ", "))
            }
            if let url = m.meetingURL, !url.isEmpty {
                detailRow("URL", url)
            }
            if let summary = m.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summary")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(String(summary.prefix(500)))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(8)
                }
                .padding(.top, 2)
            }
            if let notes = m.notesPlain, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(String(notes.prefix(800)))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                }
                .padding(.top, 2)
            }
            if let transcript = m.transcriptText, !transcript.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(String(transcript.prefix(1000)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(15)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }

    private func parseAppNames(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return arr
    }
}
