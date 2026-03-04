import Foundation
import TaskMinerShared

/// Monitors Granola's local cache file for meeting data (notes, transcripts, attendees).
/// Polls the cache file for changes and extracts new/updated meetings.
final class GranolaMeetingMonitor {

    /// Called with new or updated meetings to persist into the database.
    var onMeetingsUpdated: (([GranolaMeetingRecord]) -> Void)?

    private let cacheFileURL: URL
    private var lastKnownModDate: Date?
    private var knownUpdatedAts: [String: String] = [:]  // granolaId → source updated_at

    /// ISO 8601 date formatter matching Granola's timestamp format (fractional seconds + Z).
    private static let granolaISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Day formatter for meeting_date column (yyyy-MM-dd).
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Time-only formatter for transcript lines.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init() {
        let home = NSHomeDirectory()
        cacheFileURL = URL(fileURLWithPath: "\(home)/Library/Application Support/Granola/cache-v4.json")
    }

    // MARK: - Polling

    /// Check for new or updated meetings. Safe to call frequently — uses file mod-date
    /// gating to avoid re-parsing an unchanged file.
    func poll() {
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return }

        // Check file modification date to skip unchanged files
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFileURL.path),
              let modDate = attrs[.modificationDate] as? Date else { return }

        if let last = lastKnownModDate, modDate <= last { return }
        lastKnownModDate = modDate

        // Parse the cache file
        guard let data = try? Data(contentsOf: cacheFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = json["cache"] as? [String: Any],
              let state = cache["state"] as? [String: Any],
              let documents = state["documents"] as? [String: [String: Any]]
        else {
            Logger.debug("GranolaMeetingMonitor: failed to parse cache file")
            return
        }

        let transcripts = state["transcripts"] as? [String: [[String: Any]]] ?? [:]
        var changedMeetings: [GranolaMeetingRecord] = []

        for (docId, doc) in documents {
            // Only process valid meetings
            guard let updatedAt = doc["updated_at"] as? String else { continue }

            // Skip if unchanged since last poll
            if knownUpdatedAts[docId] == updatedAt { continue }
            knownUpdatedAts[docId] = updatedAt

            // Parse the meeting
            if let record = parseMeeting(docId: docId, doc: doc, transcripts: transcripts) {
                changedMeetings.append(record)
            }
        }

        if !changedMeetings.isEmpty {
            onMeetingsUpdated?(changedMeetings)
        }
    }

    // MARK: - Parsing

    private func parseMeeting(docId: String, doc: [String: Any], transcripts: [String: [[String: Any]]]) -> GranolaMeetingRecord? {
        guard let title = doc["title"] as? String, !title.isEmpty else { return nil }
        // Field size guards to prevent memory issues from crafted Granola data
        guard title.count < 500 else {
            Logger.warning("GranolaMeetingMonitor: skipping meeting with oversized title (\(title.count) chars)")
            return nil
        }
        guard let updatedAt = doc["updated_at"] as? String else { return nil }

        // Extract times from google_calendar_event, or fall back to created_at/updated_at
        let startTime: Date
        let endTime: Date
        let meetingDate: String
        let meetingURL: String?

        if let calEvent = doc["google_calendar_event"] as? [String: Any],
           let startObj = calEvent["start"] as? [String: Any],
           let endObj = calEvent["end"] as? [String: Any],
           let startDT = startObj["dateTime"] as? String,
           let endDT = endObj["dateTime"] as? String,
           let sDate = Self.granolaISO.date(from: startDT),
           let eDate = Self.granolaISO.date(from: endDT) {
            startTime = sDate
            endTime = eDate
            meetingDate = Self.dayFormatter.string(from: sDate)

            // Extract video call URL from conferenceData (validate HTTPS + known video domains)
            if let confData = calEvent["conferenceData"] as? [String: Any],
               let entryPoints = confData["entryPoints"] as? [[String: Any]],
               let videoEntry = entryPoints.first(where: { ($0["entryPointType"] as? String) == "video" }),
               let uri = videoEntry["uri"] as? String,
               Self.isValidMeetingURL(uri) {
                meetingURL = uri
            } else {
                meetingURL = nil
            }
        } else if let createdStr = doc["created_at"] as? String,
                  let createdDate = Self.granolaISO.date(from: createdStr) {
            // Fallback: use created_at as start, estimate 30 min duration
            startTime = createdDate
            endTime = createdDate.addingTimeInterval(30 * 60)
            meetingDate = Self.dayFormatter.string(from: createdDate)
            meetingURL = nil
        } else {
            return nil
        }

        let duration = endTime.timeIntervalSince(startTime)

        // Extract organizer
        let organizer: String?
        if let people = doc["people"] as? [String: Any],
           let creator = people["creator"] as? [String: Any] {
            organizer = (creator["name"] as? String) ?? (creator["email"] as? String)
        } else {
            organizer = nil
        }

        // Extract attendees as JSON array of {name, email}
        let attendeesJson = buildAttendeesJson(from: doc)

        // Extract notes (plain text preferred), capped to prevent memory issues
        let notesPlain = (doc["notes_plain"] as? String).map { String($0.prefix(100_000)) }

        // Extract and format transcript
        let transcriptText = buildTranscriptText(docId: docId, transcripts: transcripts)

        // Extract summary, capped to prevent memory issues
        let summary = (doc["summary"] as? String).map { String($0.prefix(10_000)) }

        return GranolaMeetingRecord(
            granolaId: docId,
            title: title,
            meetingDate: meetingDate,
            startTime: startTime,
            endTime: endTime,
            duration: duration,
            attendeesJson: attendeesJson,
            organizer: organizer,
            notesPlain: notesPlain,
            transcriptText: transcriptText,
            summary: summary,
            meetingURL: meetingURL,
            sourceUpdatedAt: updatedAt
        )
    }

    private func buildAttendeesJson(from doc: [String: Any]) -> String {
        var attendees: [[String: String]] = []

        // Try people.attendees (richer data with names)
        if let people = doc["people"] as? [String: Any],
           let atts = people["attendees"] as? [[String: Any]] {
            for att in atts.prefix(100) {
                var entry: [String: String] = [:]
                if let email = att["email"] as? String { entry["email"] = email }
                if let details = att["details"] as? [String: Any],
                   let person = details["person"] as? [String: Any],
                   let nameObj = person["name"] as? [String: Any],
                   let fullName = nameObj["fullName"] as? String {
                    entry["name"] = fullName
                }
                if !entry.isEmpty { attendees.append(entry) }
            }
        }
        // Fallback: try google_calendar_event.attendees (email only)
        else if let calEvent = doc["google_calendar_event"] as? [String: Any],
                let calAtts = calEvent["attendees"] as? [[String: Any]] {
            for att in calAtts {
                if let email = att["email"] as? String {
                    attendees.append(["email": email])
                }
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: attendees),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return jsonStr
    }

    private func buildTranscriptText(docId: String, transcripts: [String: [[String: Any]]]) -> String? {
        guard let segments = transcripts[docId], !segments.isEmpty else { return nil }

        var lines: [String] = []
        let maxChars = 50_000  // Storage cap matching OCR text cap

        for segment in segments {
            guard let text = segment["text"] as? String, !text.isEmpty else { continue }
            guard let isFinal = segment["is_final"] as? Bool, isFinal else { continue }

            let source = segment["source"] as? String ?? "unknown"
            let speaker = source == "microphone" ? "You" : "Other"

            // Format timestamp
            let timeStr: String
            if let tsStr = segment["start_timestamp"] as? String,
               let date = Self.granolaISO.date(from: tsStr) {
                timeStr = Self.timeFormatter.string(from: date)
            } else {
                timeStr = "??:??:??"
            }

            let line = "[\(timeStr)] \(speaker): \(text)"
            lines.append(line)

            // Check cumulative size
            let total = lines.joined(separator: "\n").count
            if total > maxChars {
                lines.append("[...transcript truncated at \(maxChars) characters]")
                break
            }
        }

        let result = lines.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }

    // MARK: - URL Validation

    /// Known video conferencing domains for meeting URL validation.
    private static let allowedMeetingDomains: Set<String> = [
        "zoom.us",
        "meet.google.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "around.co",
        "cal.com",
        "riverside.fm",
        "loom.com",
        "grain.com",
        "meetingbird.com",
        "descript.com",
        "tuple.app",
        "pop.com",
        "tandem.chat",
        "gather.town",
        "spatial.chat",
    ]

    /// Validates that a meeting URL is HTTPS and from a known video conferencing domain.
    private static func isValidMeetingURL(_ urlString: String) -> Bool {
        guard urlString.hasPrefix("https://"),
              let url = URL(string: urlString),
              let host = url.host?.lowercased() else {
            return false
        }
        // Check if host matches or is a subdomain of an allowed domain
        for domain in allowedMeetingDomains {
            if host == domain || host.hasSuffix(".\(domain)") {
                return true
            }
        }
        return false
    }
}
