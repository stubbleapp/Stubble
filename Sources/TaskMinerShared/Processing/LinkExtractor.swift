import Foundation

/// A link extracted from activity data — either a URL or a local file path.
public struct ExtractedLink: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case url        // https://... or http://...
        case filePath   // /Users/... or ~/...
    }

    public let kind: Kind
    public let value: String        // The raw URL or path string
    public let label: String        // Short display label
    public let source: String       // Where it was extracted from (e.g. "window_title", "ocr")

    public init(kind: Kind, value: String, label: String, source: String) {
        self.kind = kind
        self.value = value
        self.label = label
        self.source = source
    }

    /// Returns an openable URL — for file paths, wraps in file://
    /// For app-specific URLs (granola://, etc.), returns as-is for the system to handle.
    public var openableURL: URL? {
        switch kind {
        case .url:
            return URL(string: value)
        case .filePath:
            let expanded = (value as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
    }
}

/// Extracts actionable links from window titles and OCR text.
public enum LinkExtractor {

    // MARK: - Cached Regex Patterns (compiled once, reused on every call)

    private static let urlRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://[^\s<>\"\)\]\}]+"#, options: [])
    }()
    private static let filePathRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(?:^|\s)(/(?:Users|home|tmp|var|opt|etc)/[^\s:\"]+)"#, options: .anchorsMatchLines)
    }()
    private static let browserURLRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"https?://[^\s]+"#, options: [])
    }()

    // MARK: - Public API

    /// Extract links from a window title for a given app.
    public static func linksFromWindowTitle(_ title: String, appName: String, bundleId: String?) -> [ExtractedLink] {
        var links: [ExtractedLink] = []

        // File path from IDE/editor window titles
        if let path = extractFilePath(from: title, appName: appName, bundleId: bundleId) {
            let filename = (path as NSString).lastPathComponent
            links.append(ExtractedLink(kind: .filePath, value: path, label: filename, source: "window_title"))
        }

        // URL from browser tab titles (heuristic — browsers often show "Page Title - Domain")
        if isBrowser(bundleId: bundleId), let url = extractURLFromBrowserTitle(title) {
            links.append(url)
        }

        return links
    }

    /// Extract URLs from OCR text.
    public static func linksFromOCRText(_ text: String) -> [ExtractedLink] {
        var links: [ExtractedLink] = []
        var seen = Set<String>()

        // HTTP(S) URLs
        guard let urlRegex else { return links }
        let matches = urlRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.prefix(10) {
            guard let range = Range(match.range, in: text) else { continue }
            var urlStr = String(text[range])
            // Trim trailing punctuation that's likely not part of the URL
            while urlStr.last == "." || urlStr.last == "," || urlStr.last == ";" || urlStr.last == ":" {
                urlStr.removeLast()
            }
            guard seen.insert(urlStr).inserted else { continue }
            let label = shortLabel(for: urlStr)
            links.append(ExtractedLink(kind: .url, value: urlStr, label: label, source: "ocr"))
        }

        // Absolute file paths
        guard let filePathRegex else { return links }
        let pathMatches = filePathRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in pathMatches.prefix(5) {
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { continue }
            let path = String(text[range])
            guard seen.insert(path).inserted else { continue }
            let filename = (path as NSString).lastPathComponent
            links.append(ExtractedLink(kind: .filePath, value: path, label: filename, source: "ocr"))
        }

        return links
    }

    /// Extract links from a JSON array of URL strings (as returned by Gemini).
    public static func linksFromJSON(_ jsonString: String) -> [ExtractedLink] {
        guard let data = jsonString.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }

        return array.compactMap { str -> ExtractedLink? in
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                return ExtractedLink(kind: .url, value: trimmed, label: shortLabel(for: trimmed), source: "ai")
            } else if trimmed.hasPrefix("granola://") {
                // Granola deep links to meeting notes
                return ExtractedLink(kind: .url, value: trimmed, label: "Granola Meeting", source: "ai")
            } else if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                let filename = (trimmed as NSString).lastPathComponent
                return ExtractedLink(kind: .filePath, value: trimmed, label: filename, source: "ai")
            }
            return nil
        }
    }

    // MARK: - Private helpers

    /// Extract file path from an IDE/editor window title.
    private static func extractFilePath(from title: String, appName: String, bundleId: String?) -> String? {
        let bid = bundleId ?? ""

        // Xcode: "filename.swift — ProjectName" or "ProjectName — filename.swift"
        // The actual path isn't in the title, but we can try to find it via the project name
        if bid == "com.apple.dt.Xcode" {
            // Xcode titles: "File.swift — ProjectName" — not a full path
            // We can't reliably extract a full file path from Xcode titles alone
            return nil
        }

        // VS Code: "filename — ProjectFolder" or full path
        if bid.contains("com.microsoft.VSCode") || bid.contains("com.visualstudio") || appName.lowercased().contains("code") {
            // VS Code sometimes shows the full path
            let parts = title.components(separatedBy: " — ")
            if let first = parts.first?.trimmingCharacters(in: .whitespaces) {
                if first.hasPrefix("/") { return first }
                if first.contains(".") && parts.count > 1 {
                    // "file.swift — /path/to/project" pattern
                    let folder = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
                    if folder.hasPrefix("/") || folder.hasPrefix("~") {
                        return "\(folder)/\(first)"
                    }
                }
            }
            return nil
        }

        // Terminal/iTerm: often shows PWD in title
        if bid == "com.apple.Terminal" || bid.contains("iterm") || bid.contains("alacritty") || bid.contains("warp") {
            // Titles often include "user@host: /path/to/dir"
            if let colonIdx = title.range(of: ": ") {
                let path = String(title[colonIdx.upperBound...]).trimmingCharacters(in: .whitespaces)
                if path.hasPrefix("/") || path.hasPrefix("~") {
                    return path
                }
            }
            // Or just the path directly
            if title.hasPrefix("/") || title.hasPrefix("~") {
                return title.components(separatedBy: " ").first
            }
            return nil
        }

        // Finder: shows folder path
        if bid == "com.apple.finder" {
            return nil // Finder titles are just folder names, not full paths
        }

        // Generic: check if the title itself looks like a file path
        if title.hasPrefix("/") && title.contains(".") {
            return title.components(separatedBy: " ").first
        }

        return nil
    }

    private static func isBrowser(bundleId: String?) -> Bool {
        guard let bid = bundleId?.lowercased() else { return false }
        return bid.contains("chrome") || bid.contains("safari") || bid.contains("firefox")
            || bid.contains("brave") || bid.contains("arc") || bid.contains("edge")
            || bid.contains("opera") || bid.contains("webkit")
    }

    /// Try to extract a meaningful URL from a browser tab title.
    /// Browser titles typically look like "Page Title - SiteName" or "Page Title"
    /// We can't get the actual URL, but if the title contains a URL, we grab it.
    private static func extractURLFromBrowserTitle(_ title: String) -> ExtractedLink? {
        // Some browser titles literally contain URLs
        if let regex = browserURLRegex,
           let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let range = Range(match.range, in: title) {
            let url = String(title[range])
            return ExtractedLink(kind: .url, value: url, label: shortLabel(for: url), source: "window_title")
        }
        return nil
    }

    /// Create a short display label from a URL.
    private static func shortLabel(for urlString: String) -> String {
        guard let url = URL(string: urlString) else {
            return String(urlString.prefix(40))
        }

        let host = url.host ?? ""
        let path = url.path

        // GitHub: show owner/repo or PR/issue
        if host.contains("github.com") {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2 {
                let repo = "\(parts[0])/\(parts[1])"
                if parts.count >= 4 {
                    let type = parts[2] // "pull", "issues", "blob", etc.
                    let num = parts[3]
                    if type == "pull" { return "\(repo) #\(num)" }
                    if type == "issues" { return "\(repo) #\(num)" }
                    if type == "blob" || type == "tree" {
                        let file = parts.last ?? num
                        return "\(repo)/\(file)"
                    }
                }
                return repo
            }
        }

        // Google Docs
        if host.contains("docs.google.com") { return "Google Docs" }
        if host.contains("sheets.google.com") { return "Google Sheets" }
        if host.contains("slides.google.com") { return "Google Slides" }

        // Figma
        if host.contains("figma.com") { return "Figma" }

        // Notion
        if host.contains("notion.so") || host.contains("notion.site") { return "Notion" }

        // Stack Overflow
        if host.contains("stackoverflow.com") { return "Stack Overflow" }

        // YouTube
        if host.contains("youtube.com") || host.contains("youtu.be") { return "YouTube" }

        // LinkedIn
        if host.contains("linkedin.com") { return "LinkedIn" }

        // Generic: just show the host
        if !host.isEmpty {
            let shortHost = host.replacingOccurrences(of: "www.", with: "")
            return shortHost
        }

        return String(urlString.prefix(40))
    }
}
