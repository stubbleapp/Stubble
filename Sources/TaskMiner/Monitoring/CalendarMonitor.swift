import Foundation
import EventKit
import TaskMinerShared

/// Lightweight calendar context provider using EventKit.
/// Queries upcoming/recent events to provide meeting context for AI summarization.
/// Requires Calendars permission (prompts on first access).
class CalendarMonitor {
    private let eventStore = EKEventStore()
    private var hasAccess = false

    /// Request calendar access. Call once at startup.
    func requestAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.hasAccess = granted
                    if granted {
                        Logger.info("CalendarMonitor: calendar access granted")
                    } else {
                        Logger.info("CalendarMonitor: calendar access denied — meeting context unavailable")
                        if let error { Logger.debug("CalendarMonitor: \(error.localizedDescription)") }
                    }
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.hasAccess = granted
                    if granted {
                        Logger.info("CalendarMonitor: calendar access granted")
                    } else {
                        Logger.info("CalendarMonitor: calendar access denied — meeting context unavailable")
                    }
                }
            }
        }
    }

    /// Fetch calendar events for a time range. Returns a summary string suitable
    /// for inclusion in the AI summarization prompt.
    func eventsContext(from start: Date, to end: Date) -> String? {
        guard hasAccess else { return nil }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }  // Skip all-day events (holidays, birthdays, etc.)
            .sorted { $0.startDate < $1.startDate }

        guard !events.isEmpty else { return nil }

        var lines: [String] = []
        for event in events.prefix(20) {
            let startTime = SharedFormatters.timeFormatter.string(from: event.startDate)
            let endTime = SharedFormatters.timeFormatter.string(from: event.endDate)
            let duration = Int(event.endDate.timeIntervalSince(event.startDate) / 60)
            var line = "[\(startTime)–\(endTime)] \(event.title ?? "Untitled") (\(duration)m)"

            // Include organizer if available and not self
            if let organizer = event.organizer, !organizer.isCurrentUser,
               let name = organizer.name {
                line += " — organized by \(name)"
            }

            // Include attendee count for multi-person meetings
            let attendeeCount = (event.attendees ?? []).count
            if attendeeCount > 1 {
                line += " (\(attendeeCount) attendees)"
            }

            // Detect video meeting URLs (Zoom, Google Meet, Teams, etc.)
            if let notes = event.notes {
                if notes.contains("zoom.us") || notes.contains("meet.google.com")
                    || notes.contains("teams.microsoft.com") || notes.contains("webex") {
                    line += " [video call]"
                }
            }
            if let url = event.url?.absoluteString {
                if url.contains("zoom.us") || url.contains("meet.google.com")
                    || url.contains("teams.microsoft.com") {
                    line += " [video call]"
                }
            }

            lines.append(line)
        }

        return lines.joined(separator: "\n")
    }
}
