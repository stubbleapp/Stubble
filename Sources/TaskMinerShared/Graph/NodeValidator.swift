import Foundation

/// Validates knowledge graph node names to prevent garbage data.
/// Filters out short abbreviations, common first names, generic words, and invalid patterns.
public struct NodeValidator {
    public static let minNameLength = 4

    /// Blocked terms (lowercase for comparison).
    /// These are either too short, too generic, or commonly extracted by mistake.
    public static let blockedTerms: Set<String> = [
        // Short abbreviations
        "api", "ide", "cli", "gui", "sdk", "sql", "url", "xml", "css", "html",
        "pdf", "doc", "txt", "png", "jpg", "gif", "svg", "csv", "json", "yaml",
        "npm", "git", "ssh", "ftp", "tcp", "udp", "dns", "vpn", "cdn", "ssl",
        // Common first names (often extracted from window titles)
        "sam", "tom", "bob", "joe", "dan", "max", "ben", "tim", "jim", "jon",
        "mike", "dave", "john", "paul", "mark", "ryan", "adam", "alex", "eric",
        "matt", "nick", "tony", "steve", "chris", "jason", "kevin", "brian",
        "amy", "kate", "lisa", "mary", "anna", "emma", "sara", "jane",
        // Generic programming terms
        "code", "file", "data", "test", "user", "task", "item", "list", "view",
        "app", "web", "dev", "ops", "bug", "fix", "new", "old", "get", "set",
        "add", "edit", "save", "load", "run", "stop", "main", "base", "core",
        "util", "help", "info", "docs", "home", "page", "form", "menu", "link",
        "text", "type", "name", "path", "node", "tree", "root", "leaf", "edge",
        // Common words
        "the", "and", "for", "with", "from", "this", "that", "using", "working",
        "about", "into", "over", "just", "also", "more", "some", "such", "each",
        "then", "than", "when", "what", "which", "where", "while", "after",
        "before", "between", "through", "during", "without", "within",
        // App names (should not be skills/topics)
        "xcode", "slack", "zoom", "chrome", "safari", "firefox", "terminal",
        "finder", "mail", "notes", "preview", "messages"
    ]

    /// Validate a node name based on its type.
    /// Returns true if the name is valid, false if it should be rejected.
    public static func isValidName(_ name: String, type: NodeType) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        // Identity nodes can be sentence-form facts, so allow longer content
        // and skip most validation (they're personal facts like "Senior engineer at Acme")
        if type == .identity {
            // Just require non-empty and at least 4 chars
            return trimmed.count >= minNameLength
        }

        // Min length check
        guard trimmed.count >= minNameLength else { return false }

        // Blocked terms check
        guard !blockedTerms.contains(lowercased) else { return false }

        // All-caps short acronym check (<=4 chars, all uppercase letters)
        // This catches things like "SAM", "API", "IDE" that slip through
        if trimmed.count <= 4 && trimmed == trimmed.uppercased() {
            // Only reject if it's all letters (allow "iOS" style mixed case)
            let allUpperLetters = trimmed.allSatisfy { $0.isUppercase || !$0.isLetter }
            let hasLetter = trimmed.contains { $0.isLetter }
            if allUpperLetters && hasLetter {
                return false
            }
        }

        // Skills must be 2+ words OR at least 6 chars (to allow "Design", "Testing")
        if type == .skill {
            let wordCount = trimmed.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .count
            if wordCount == 1 && trimmed.count < 6 {
                return false
            }
        }

        // Topics should also have some substance
        if type == .topic {
            let wordCount = trimmed.components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .count
            if wordCount == 1 && trimmed.count < 5 {
                return false
            }
        }

        // Reject pure numbers or single letters
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }) {
            return false
        }

        return true
    }
}
