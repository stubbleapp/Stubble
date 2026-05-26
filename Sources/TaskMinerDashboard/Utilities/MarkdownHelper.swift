import SwiftUI

/// Shared markdown rendering utilities for day summaries and timeline narrative text.
enum MarkdownHelper {

    // Precompiled regex patterns (avoid recompilation on every render)
    private static let nestedListRegex: NSRegularExpression? = {
        do {
            return try NSRegularExpression(pattern: #"^(\s{2,}|\t)[\-\*]\s"#)
        } catch {
            assertionFailure("Invalid nested list regex: \(error)")
            return nil
        }
    }()
    private static let topListRegex: NSRegularExpression? = {
        do {
            return try NSRegularExpression(pattern: #"^[\-\*]\s"#)
        } catch {
            assertionFailure("Invalid top list regex: \(error)")
            return nil
        }
    }()

    /// Render a markdown string into an AttributedString suitable for SwiftUI `Text`.
    static func renderMarkdown(_ source: String) -> AttributedString? {
        let processed = preprocessMarkdown(source)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attributed = try? AttributedString(markdown: processed, options: options) else {
            return nil
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                let range = run.range
                attributed[range].font = .system(size: 13, design: .monospaced)
            }
        }
        return attributed
    }

    /// Pre-process markdown source for inline rendering:
    /// converts list markers to unicode bullets, headings to bold.
    static func preprocessMarkdown(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let str = String(line)
                let range = NSRange(str.startIndex..., in: str)

                if let nestedListRegex,
                   let match = nestedListRegex.firstMatch(in: str, range: range),
                   let matchRange = Range(match.range, in: str) {
                    let indent = str[str.startIndex..<str.index(before: matchRange.upperBound)]
                    let rest = str[matchRange.upperBound...]
                    let indentStr = String(indent)
                        .replacingOccurrences(of: "-", with: "\u{25E6}")
                        .replacingOccurrences(of: "*", with: "\u{25E6}")
                    return "\(indentStr) \(rest)"
                }
                if let topListRegex,
                   let match = topListRegex.firstMatch(in: str, range: range),
                   let matchRange = Range(match.range, in: str) {
                    return "\u{2022}\u{2002}" + str[matchRange.upperBound...]
                }
                if str.hasPrefix("## ") {
                    return "**" + str.dropFirst(3) + "**"
                }
                if str.hasPrefix("### ") {
                    return "**" + str.dropFirst(4) + "**"
                }
                return str
            }
            .joined(separator: "\n")
    }
}
