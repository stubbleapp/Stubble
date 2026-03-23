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
            // --- JWT tokens ---
            // JSON Web Tokens (eyJ... header.payload.signature)
            (#"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, "[REDACTED_JWT]", []),

            // --- AWS access keys ---
            (#"\bAKIA[A-Z0-9]{16}\b"#, "[REDACTED_AWS_KEY]", []),

            // --- Private keys ---
            (#"-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]", []),

            // --- API keys & tokens ---
            // Prefixed tokens: sk-, pk-, ghp_, gho_, xoxb-, xoxp-, etc. (MUST come before generic pattern)
            (#"\b(?:sk-|pk-|ghp_|gho_|ghu_|ghs_|xox[bpsa]-|AKIA|AIza|hf_|sk-ant-|api-|key-|token-|secret-)[A-Za-z0-9_\-]{10,}\b"#, "[REDACTED_KEY]", []),
            // Generic long tokens ONLY after specific markers (=, :, " followed by token-like context)
            // Require at least one digit AND one letter to avoid matching plain base64 text
            (#"(?<=[=:]\s{0,2}["']?)[A-Za-z0-9+/=_\-]{32,}(?=["']?(?:\s|$|,|\)))"#, "[REDACTED_TOKEN]", []),

            // --- Passwords in common UI patterns ---
            // "Password: ****" or "password = something" (captures value after separator)
            (#"(?i)(?:password|passwd|pwd|secret|token|api[_\s]?key)\s*[:=]\s*\S+"#, "[REDACTED_CREDENTIAL]", [.caseInsensitive]),

            // --- Financial ---
            // Credit card numbers in typical formats (4-4-4-4 or 4-6-5 groupings, or 16 consecutive digits)
            // Avoids matching phone numbers (10-11 digits) and other numeric sequences
            (#"\b(?:\d{4}[- ]?){3}\d{4}\b"#, "[REDACTED_CARD]", []),  // 16-digit: XXXX-XXXX-XXXX-XXXX
            (#"\b\d{4}[- ]?\d{6}[- ]?\d{5}\b"#, "[REDACTED_CARD]", []),  // 15-digit Amex: XXXX-XXXXXX-XXXXX
            (#"\b(?<!\d)\d{15,16}(?!\d)\b"#, "[REDACTED_CARD]", []),  // 15-16 consecutive digits (not part of longer number)
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
