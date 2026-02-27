import SwiftUI

/// Shared markdown rendering utilities for day summaries and stubs content.
enum MarkdownHelper {

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
                if let match = str.range(of: #"^(\s{2,}|\t)[\-\*]\s"#, options: .regularExpression) {
                    let indent = str[str.startIndex..<str.index(before: match.upperBound)]
                    let rest = str[match.upperBound...]
                    let indentStr = String(indent)
                        .replacingOccurrences(of: "-", with: "\u{25E6}")
                        .replacingOccurrences(of: "*", with: "\u{25E6}")
                    return "\(indentStr) \(rest)"
                }
                if let range = str.range(of: #"^[\-\*]\s"#, options: .regularExpression) {
                    return "\u{2022}\u{2002}" + str[range.upperBound...]
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
