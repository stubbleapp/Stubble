import Foundation

/// Extracts structured signals from raw OCR text — URLs, file paths, code symbols,
/// document titles, communication channels, and terminal commands.
/// Pure local text processing; no AI calls. Designed to efficiently process
/// thousands of OCR texts from a full day's screenshots.
public enum OCRDigestBuilder {

    // MARK: - Public API

    public struct OCRDigest: Sendable {
        public let urls: [String]
        public let filePaths: [String]
        public let codeSymbols: [String]
        public let docTitles: [String]
        public let communications: [String]
        public let commands: [String]

        /// Format the digest as a prompt-friendly string (~2-3k chars).
        /// Returns nil if the digest is empty.
        public func asPromptSection() -> String? {
            var sections: [String] = []

            if !urls.isEmpty {
                sections.append("URLs visited: \(urls.joined(separator: ", "))")
            }
            if !filePaths.isEmpty {
                sections.append("Files/paths: \(filePaths.joined(separator: ", "))")
            }
            if !codeSymbols.isEmpty {
                sections.append("Code symbols: \(codeSymbols.joined(separator: ", "))")
            }
            if !docTitles.isEmpty {
                sections.append("Documents/pages: \(docTitles.joined(separator: " | "))")
            }
            if !communications.isEmpty {
                sections.append("Communications: \(communications.joined(separator: ", "))")
            }
            if !commands.isEmpty {
                sections.append("Terminal commands: \(commands.joined(separator: " | "))")
            }

            guard !sections.isEmpty else { return nil }
            return sections.joined(separator: "\n")
        }
    }

    /// Build a digest from an array of raw OCR strings (one per screenshot).
    public static func buildDigest(from ocrTexts: [String]) -> OCRDigest {
        var urlSet = Set<String>()
        var pathSet = Set<String>()
        var symbolSet = Set<String>()
        var titleSet = Set<String>()
        var commSet = Set<String>()
        var cmdSet = Set<String>()

        for text in ocrTexts {
            guard !text.isEmpty else { continue }
            extractURLs(from: text, into: &urlSet)
            extractFilePaths(from: text, into: &pathSet)
            extractCodeSymbols(from: text, into: &symbolSet)
            extractDocTitle(from: text, into: &titleSet)
            extractCommunications(from: text, into: &commSet)
            extractCommands(from: text, into: &cmdSet)
        }

        return OCRDigest(
            urls: dominantItems(from: urlSet, limit: 30),
            filePaths: Array(pathSet.prefix(20)),
            codeSymbols: Array(symbolSet.prefix(30)),
            docTitles: Array(titleSet.prefix(15)),
            communications: Array(commSet.prefix(15)),
            commands: Array(cmdSet.prefix(10))
        )
    }

    /// Convenience: build from ScreenshotRecord array (extracts ocrText from each).
    public static func buildDigest(fromOCRColumn ocrTexts: [String?]) -> OCRDigest {
        buildDigest(from: ocrTexts.compactMap { $0 })
    }

    // MARK: - Individual Extractors (public for use by memory extraction)

    /// Extract deduplicated URLs from raw OCR text.
    public static func extractURLs(from texts: [String]) -> [String] {
        var set = Set<String>()
        for text in texts { extractURLs(from: text, into: &set) }
        return dominantItems(from: set, limit: 30)
    }

    /// Extract deduplicated code symbols from raw OCR text.
    public static func extractCodeSymbols(from texts: [String]) -> [String] {
        var set = Set<String>()
        for text in texts { extractCodeSymbols(from: text, into: &set) }
        return Array(set.prefix(30))
    }

    // MARK: - Private Extraction

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s"'<>\]\)}{,]+"#
    )

    private static func extractURLs(from text: String, into set: inout Set<String>) {
        let range = NSRange(text.startIndex..., in: text)
        for match in urlPattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            var url = String(text[r])
            // Strip trailing punctuation that OCR often appends
            while url.last == "." || url.last == ")" || url.last == ";" { url.removeLast() }
            guard url.count > 10 else { continue }
            // Collapse to domain + first path component for dedup
            if let comps = URLComponents(string: url), let host = comps.host {
                let pathParts = comps.path.split(separator: "/").prefix(2)
                let key = pathParts.isEmpty ? host : "\(host)/\(pathParts.joined(separator: "/"))"
                set.insert(key)
            }
        }
    }

    private static let filePathPattern = try! NSRegularExpression(
        pattern: #"(?:/Users/[^\s:;,"']+|~/[^\s:;,"']+)"#
    )

    private static func extractFilePaths(from text: String, into set: inout Set<String>) {
        let range = NSRange(text.startIndex..., in: text)
        for match in filePathPattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            var path = String(text[r])
            while path.last == "." || path.last == ")" || path.last == ":" { path.removeLast() }
            guard path.count > 5 else { continue }
            // Keep just the last 3 path components for readability
            let parts = path.split(separator: "/")
            if parts.count > 4 {
                set.insert(".../" + parts.suffix(3).joined(separator: "/"))
            } else {
                set.insert(path)
            }
        }
    }

    private static let codeSymbolPatterns: [(NSRegularExpression, Int)] = {
        let defs: [(String, Int)] = [
            (#"(?:func|def|function)\s+([A-Za-z_]\w{2,})"#, 1),
            (#"(?:class|struct|enum|protocol|interface)\s+([A-Z]\w{2,})"#, 1),
            (#"(?:import|from)\s+([A-Za-z_][\w.]{2,})"#, 1),
        ]
        return defs.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    }()

    private static func extractCodeSymbols(from text: String, into set: inout Set<String>) {
        let range = NSRange(text.startIndex..., in: text)
        for (regex, groupIdx) in codeSymbolPatterns {
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > groupIdx,
                      let r = Range(match.range(at: groupIdx), in: text) else { continue }
                let symbol = String(text[r])
                guard symbol.count >= 3, symbol.count <= 60 else { continue }
                set.insert(symbol)
            }
        }
    }

    private static func extractDocTitle(from text: String, into set: inout Set<String>) {
        // Heuristic: first non-empty, non-code line is often the page/document title
        let lines = text.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: true)
        guard let firstLine = lines.first else { return }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        // Skip if it looks like code, a path, or is too short/long
        guard trimmed.count >= 8, trimmed.count <= 120,
              !trimmed.hasPrefix("/"), !trimmed.hasPrefix("http"),
              !trimmed.hasPrefix("{"), !trimmed.hasPrefix("func "),
              !trimmed.hasPrefix("import "), !trimmed.hasPrefix("//"),
              !trimmed.contains("  ") || trimmed.count < 60 // likely not code with lots of spaces
        else { return }
        set.insert(trimmed)
    }

    private static let channelPattern = try! NSRegularExpression(
        pattern: #"#[a-z][a-z0-9_-]{2,30}"#
    )

    private static func extractCommunications(from text: String, into set: inout Set<String>) {
        let range = NSRange(text.startIndex..., in: text)
        for match in channelPattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            set.insert(String(text[r]))
        }
    }

    private static let commandPattern = try! NSRegularExpression(
        pattern: #"(?:^|\n)\s*[$%>]\s+(.{5,80})"#
    )

    private static func extractCommands(from text: String, into set: inout Set<String>) {
        let range = NSRange(text.startIndex..., in: text)
        for match in commandPattern.matches(in: text, range: range) {
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { continue }
            let cmd = String(text[r]).trimmingCharacters(in: .whitespaces)
            guard !cmd.isEmpty else { continue }
            set.insert(cmd)
        }
    }

    // MARK: - Helpers

    /// Sort by frequency-like heuristic: shorter domain paths appear more often.
    /// Just returns the set contents capped at limit for now.
    private static func dominantItems(from set: Set<String>, limit: Int) -> [String] {
        Array(set.sorted().prefix(limit))
    }
}
