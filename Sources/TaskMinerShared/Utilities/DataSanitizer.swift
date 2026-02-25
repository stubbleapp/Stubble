import Foundation

/// Strips sensitive patterns from text before it is sent to external AI APIs.
/// Targets common secret formats, credentials, PII, and financial data.
public enum DataSanitizer {

    // MARK: - Public API

    /// Sanitize a single string (OCR text, window title, etc.) by redacting sensitive patterns.
    public static func sanitize(_ text: String) -> String {
        var result = text
        for (pattern, label) in patterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: label
            )
        }
        return result
    }

    /// Sanitize an array of strings, returning only those that still carry useful content.
    public static func sanitizeAll(_ texts: [String]) -> [String] {
        texts.map { sanitize($0) }
    }

    // MARK: - Patterns

    /// Each entry is (compiled regex, replacement label).
    /// Order matters — more specific patterns should come first.
    private static let patterns: [(NSRegularExpression, String)] = {
        // (pattern, replacement)  — case-insensitive unless noted
        let defs: [(String, String, NSRegularExpression.Options)] = [
            // --- API keys & tokens ---
            // Generic long hex/base64 tokens (32+ chars of alnum/+/=/_/-)
            (#"(?<=[=:\s"'])[A-Za-z0-9+/=_\-]{32,}"#, "[REDACTED_TOKEN]", []),
            // Prefixed tokens: sk-, pk-, ghp_, gho_, xoxb-, xoxp-, etc.
            (#"\b(?:sk|pk|ghp|gho|ghu|ghs|xox[bpsa]|AKIA|AIza|hf_|sk-ant-)[A-Za-z0-9_\-]{10,}\b"#, "[REDACTED_KEY]", []),

            // --- Passwords in common UI patterns ---
            // "Password: ****" or "password = something" (captures value after separator)
            (#"(?i)(?:password|passwd|pwd|secret|token|api[_\s]?key)\s*[:=]\s*\S+"#, "[REDACTED_CREDENTIAL]", [.caseInsensitive]),

            // --- Financial ---
            // Credit card numbers (13-19 digits, possibly separated by spaces/dashes)
            (#"\b(?:\d[ \-]?){13,19}\b"#, "[REDACTED_CARD]", []),
            // SSN (US)
            (#"\b\d{3}[- ]?\d{2}[- ]?\d{4}\b"#, "[REDACTED_SSN]", []),

            // --- Email addresses ---
            (#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#, "[REDACTED_EMAIL]", []),

            // --- Bearer tokens in HTTP headers ---
            (#"(?i)Bearer\s+[A-Za-z0-9._~+/\-]+=*"#, "[REDACTED_BEARER]", [.caseInsensitive]),

            // --- Connection strings ---
            (#"(?i)(?:mongodb|postgres|mysql|redis|amqp)://[^\s]+"#, "[REDACTED_CONNSTRING]", [.caseInsensitive]),
        ]

        return defs.compactMap { (pat, repl, opts) in
            guard let regex = try? NSRegularExpression(pattern: pat, options: opts) else {
                Logger.warning("DataSanitizer: failed to compile pattern: \(pat)")
                return nil
            }
            return (regex, repl)
        }
    }()
}
