import Foundation

/// Represents a segment of parsed summary text
enum SummarySegment: Identifiable {
    case text(String)
    case project(name: String)

    var id: String {
        switch self {
        case .text(let str): return "text:\(str.hashValue)"
        case .project(let name): return "project:\(name)"
        }
    }
}

/// Parses summary text containing {{project:Name}} markers into segments
struct InteractiveSummaryParser {

    /// Parse text with {{project:Name}} markers AND **bold** text into segments
    /// Bold text is matched against project names for chip conversion
    static func parse(_ input: String, projectNames: [String] = []) -> [SummarySegment] {
        // First parse {{project:Name}} markers
        var segments = parseMarkers(input)

        // Then parse **bold** text in any text segments (for backward compatibility and mixed content)
        if !projectNames.isEmpty {
            segments = parseBoldInTextSegments(segments, projectNames: projectNames)
        }

        return segments
    }

    /// Parse {{project:Name}} markers
    private static func parseMarkers(_ input: String) -> [SummarySegment] {
        let pattern = #"\{\{project:([^}]+)\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(input)]
        }

        var segments: [SummarySegment] = []
        var lastEnd = input.startIndex

        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: nsRange)

        for match in matches {
            guard let fullRange = Range(match.range, in: input),
                  let nameRange = Range(match.range(at: 1), in: input) else { continue }

            // Add text before this marker
            if lastEnd < fullRange.lowerBound {
                let textBefore = String(input[lastEnd..<fullRange.lowerBound])
                if !textBefore.isEmpty {
                    segments.append(.text(textBefore))
                }
            }

            // Add project marker
            let projectName = String(input[nameRange]).trimmingCharacters(in: .whitespaces)
            segments.append(.project(name: projectName))

            lastEnd = fullRange.upperBound
        }

        // Add remaining text
        if lastEnd < input.endIndex {
            let remaining = String(input[lastEnd...])
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return segments.isEmpty ? [.text(input)] : segments
    }

    /// Parse **bold** text within text segments, converting matches to project chips
    private static func parseBoldInTextSegments(_ segments: [SummarySegment], projectNames: [String]) -> [SummarySegment] {
        var result: [SummarySegment] = []

        for segment in segments {
            switch segment {
            case .project:
                // Keep project segments as-is
                result.append(segment)
            case .text(let str):
                // Parse bold text in this text segment
                let parsed = parseBoldText(str, projectNames: projectNames)
                result.append(contentsOf: parsed)
            }
        }

        return result
    }

    /// Parse **bold** text, converting matches to project chips
    private static func parseBoldText(_ input: String, projectNames: [String]) -> [SummarySegment] {
        let pattern = #"\*\*([^*]+)\*\*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(input)]
        }

        var segments: [SummarySegment] = []
        var lastEnd = input.startIndex

        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: nsRange)

        if matches.isEmpty {
            return input.isEmpty ? [] : [.text(input)]
        }

        for match in matches {
            guard let fullRange = Range(match.range, in: input),
                  let textRange = Range(match.range(at: 1), in: input) else { continue }

            let boldText = String(input[textRange]).trimmingCharacters(in: .whitespaces)

            // Find matching project using fuzzy matching
            let matchedProject = findMatchingProject(boldText, in: projectNames)

            // Add text before this marker
            if lastEnd < fullRange.lowerBound {
                let textBefore = String(input[lastEnd..<fullRange.lowerBound])
                if !textBefore.isEmpty {
                    segments.append(.text(textBefore))
                }
            }

            if let projectName = matchedProject {
                // Matched a project - add as project chip (use the actual project name)
                segments.append(.project(name: projectName))
            } else {
                // Not a project - keep as plain text (strip the bold markers)
                segments.append(.text(boldText))
            }

            lastEnd = fullRange.upperBound
        }

        // Add remaining text
        if lastEnd < input.endIndex {
            let remaining = String(input[lastEnd...])
            if !remaining.isEmpty {
                segments.append(.text(remaining))
            }
        }

        return segments
    }

    /// Find a project name that matches the bold text (fuzzy matching)
    /// Matches if: bold text equals project name, or bold text is contained in project name,
    /// or project name starts with bold text
    private static func findMatchingProject(_ boldText: String, in projectNames: [String]) -> String? {
        let lowercasedBold = boldText.lowercased()

        // Priority 1: Exact match
        if let exact = projectNames.first(where: { $0.lowercased() == lowercasedBold }) {
            return exact
        }

        // Priority 2: Project name starts with bold text (e.g., "Stubble" matches "Stubble Application Development")
        if let startsWith = projectNames.first(where: { $0.lowercased().hasPrefix(lowercasedBold) }) {
            return startsWith
        }

        // Priority 3: Bold text is contained in project name
        if let contains = projectNames.first(where: { $0.lowercased().contains(lowercasedBold) }) {
            return contains
        }

        return nil
    }
}
