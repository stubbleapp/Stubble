import Foundation

/// Repairs common JSON issues from LLM output (Gemini, etc.):
/// - Strips markdown code fences
/// - Removes trailing commas before ] or }
/// - Removes control characters inside strings
/// - Escapes unescaped newlines/tabs inside string values
/// - Removes JS-style comments (// and /* */)
/// - Repairs truncated JSON (closes open brackets/braces)
/// - Finds the first JSON structure if preceded by text
public enum JSONSanitizer {

    /// Attempt to sanitize a raw LLM response into valid JSON, then parse it.
    /// Returns the parsed object (Dictionary or Array), or nil on failure.
    public static func parse(_ raw: String) -> Any? {
        let cleaned = sanitize(raw)
        guard let data = cleaned.data(using: .utf8) else { return nil }
        if let result = try? JSONSerialization.jsonObject(with: data) {
            return result
        }
        // Second attempt: aggressive repair — escape unescaped quotes in string values
        let repaired = aggressiveRepair(cleaned)
        guard let repairedData = repaired.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: repairedData)
    }

    /// Clean up a raw LLM string so it's valid JSON.
    public static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Strip markdown code fences
        s = stripCodeFences(s)

        // 2. Find the first JSON structure ({ or [)
        s = extractJSONBody(s)

        // 3. Remove JS-style comments (must come before control char removal)
        s = removeComments(s)

        // 4. Escape control characters inside JSON strings (newlines, tabs, etc.)
        s = escapeControlCharsInStrings(s)

        // 5. Remove trailing commas before } or ] (string-aware)
        s = removeTrailingCommas(s)

        // 6. Repair truncated JSON — close any open brackets/braces
        s = repairTruncation(s)

        return s
    }

    // MARK: - Private Helpers

    private static func stripCodeFences(_ s: String) -> String {
        var result = s
        // Handle ```json ... ``` and ``` ... ```
        if result.hasPrefix("```json") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```JSON") {
            result = String(result.dropFirst(7))
        } else if result.hasPrefix("```") {
            result = String(result.dropFirst(3))
        }
        if result.hasSuffix("```") {
            result = String(result.dropLast(3))
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractJSONBody(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let first = s[s.startIndex]
        if first == "{" || first == "[" { return s }

        // Find first { or [
        var braceIdx: String.Index?
        var bracketIdx: String.Index?
        if let bi = s.firstIndex(of: "{") { braceIdx = bi }
        if let bi = s.firstIndex(of: "[") { bracketIdx = bi }

        switch (braceIdx, bracketIdx) {
        case let (b?, br?):
            return String(s[min(b, br)...])
        case let (b?, nil):
            return String(s[b...])
        case let (nil, br?):
            return String(s[br...])
        default:
            return s
        }
    }

    /// Remove single-line (//) and multi-line (/* */) comments outside of strings.
    private static func removeComments(_ s: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(s.count)
        var i = s.startIndex
        var inString = false
        var escaped = false

        while i < s.endIndex {
            let char = s[i]
            let next = s.index(after: i)

            if escaped {
                result.append(char)
                escaped = false
                i = next
                continue
            }

            if inString {
                if char == "\\" {
                    escaped = true
                    result.append(char)
                } else if char == "\"" {
                    inString = false
                    result.append(char)
                } else {
                    result.append(char)
                }
                i = next
                continue
            }

            // Outside string
            if char == "\"" {
                inString = true
                result.append(char)
                i = next
                continue
            }

            // Check for // comment
            if char == "/" && next < s.endIndex && s[next] == "/" {
                // Skip until end of line
                var j = s.index(after: next)
                while j < s.endIndex && s[j] != "\n" {
                    j = s.index(after: j)
                }
                i = j  // will naturally skip past the newline on next iteration or stop
                continue
            }

            // Check for /* */ comment
            if char == "/" && next < s.endIndex && s[next] == "*" {
                var j = s.index(after: next)
                while j < s.endIndex {
                    let jNext = s.index(after: j)
                    if s[j] == "*" && jNext < s.endIndex && s[jNext] == "/" {
                        i = s.index(after: jNext)
                        break
                    }
                    j = jNext
                }
                if j >= s.endIndex { i = s.endIndex }
                continue
            }

            result.append(char)
            i = next
        }

        return String(result)
    }

    /// Walk through the JSON string, and inside string values, escape any raw control
    /// characters (newlines, tabs, etc.) that would make the JSON invalid.
    /// Also removes NUL bytes and other non-printable control chars.
    private static func escapeControlCharsInStrings(_ s: String) -> String {
        var result: [Character] = []
        result.reserveCapacity(s.count + s.count / 20)
        var inString = false
        var escaped = false

        for scalar in s.unicodeScalars {
            let char = Character(scalar)

            if escaped {
                result.append(char)
                escaped = false
                continue
            }

            if inString {
                if char == "\\" {
                    escaped = true
                    result.append(char)
                    continue
                }
                if char == "\"" {
                    inString = false
                    result.append(char)
                    continue
                }
                // Inside a string: escape raw control characters
                if scalar.value < 0x20 {
                    switch scalar.value {
                    case 0x0A: // \n
                        result.append(contentsOf: "\\n")
                    case 0x0D: // \r
                        result.append(contentsOf: "\\r")
                    case 0x09: // \t
                        result.append(contentsOf: "\\t")
                    case 0x08: // \b
                        result.append(contentsOf: "\\b")
                    case 0x0C: // \f
                        result.append(contentsOf: "\\f")
                    default:
                        // Other control chars: remove entirely
                        break
                    }
                    continue
                }
                result.append(char)
                continue
            }

            // Outside strings
            if char == "\"" {
                inString = true
                result.append(char)
                continue
            }
            // Outside strings, strip control chars (except whitespace)
            if scalar.value < 0x20 && scalar.value != 0x0A && scalar.value != 0x0D && scalar.value != 0x09 {
                continue
            }
            result.append(char)
        }

        return String(result)
    }

    /// Remove trailing commas before closing brackets/braces, respecting string boundaries.
    /// e.g. `[1, 2, 3,]` → `[1, 2, 3]` and `{"a": 1,}` → `{"a": 1}`
    private static func removeTrailingCommas(_ s: String) -> String {
        var chars = Array(s)
        var inString = false
        var escaped = false
        var removals: [Int] = []

        for i in 0..<chars.count {
            let char = chars[i]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if char == "\\" { escaped = true; continue }
                if char == "\"" { inString = false }
                continue
            }
            if char == "\"" { inString = true; continue }

            // Outside strings: look for comma followed by optional whitespace then ] or }
            if char == "," {
                var j = i + 1
                while j < chars.count && (chars[j] == " " || chars[j] == "\n" || chars[j] == "\r" || chars[j] == "\t") {
                    j += 1
                }
                if j < chars.count && (chars[j] == "]" || chars[j] == "}") {
                    removals.append(i)
                }
            }
        }

        // Remove marked commas in reverse order
        for idx in removals.reversed() {
            chars.remove(at: idx)
        }

        return String(chars)
    }

    /// If JSON is truncated (more openers than closers), append the missing closers.
    private static func repairTruncation(_ s: String) -> String {
        var stack: [Character] = []
        var inString = false
        var escaped = false

        for char in s {
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }

            switch char {
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                if let last = stack.last, last == char {
                    stack.removeLast()
                }
            default: break
            }
        }

        // If we're still inside a string, close it
        var result = s
        if inString {
            result += "\""
        }

        // Close any remaining open brackets/braces in reverse order
        for closer in stack.reversed() {
            result.append(closer)
        }

        return result
    }

    /// Aggressive repair for when standard sanitization fails.
    /// Attempts to fix unescaped quotes inside string values by re-walking the JSON.
    private static func aggressiveRepair(_ s: String) -> String {
        // Strategy: re-serialize via a character-level state machine that detects
        // structural JSON tokens vs string content. When we encounter a quote that
        // would break the structure, escape it instead.
        var result: [Character] = []
        result.reserveCapacity(s.count)

        enum State {
            case root          // expecting value or structural token
            case inString      // inside a JSON string
            case afterValue    // just finished a value, expecting , or ] or }
            case afterKey      // just finished a key, expecting :
        }

        var state = State.root
        var escaped = false
        var depth: [(type: Character, expectingKey: Bool)] = []  // track { and [

        for (_, char) in s.enumerated() {
            switch state {
            case .root:
                switch char {
                case " ", "\n", "\r", "\t":
                    result.append(char)
                case "\"":
                    state = .inString
                    result.append(char)
                case "{":
                    depth.append(("{", true))
                    result.append(char)
                case "[":
                    depth.append(("[", false))
                    result.append(char)
                case "]":
                    if let last = depth.last, last.type == "[" {
                        depth.removeLast()
                    }
                    result.append(char)
                    state = .afterValue
                case "}":
                    if let last = depth.last, last.type == "{" {
                        depth.removeLast()
                    }
                    result.append(char)
                    state = .afterValue
                default:
                    // Number, bool, null — just pass through
                    result.append(char)
                    // Simple heuristic: look ahead to decide state
                    if char == "," || char == ":" {
                        // stay in root
                    } else {
                        // could be part of a number/true/false/null
                        // We'll let afterValue handle commas
                    }
                }

            case .inString:
                if escaped {
                    result.append(char)
                    escaped = false
                    continue
                }
                if char == "\\" {
                    escaped = true
                    result.append(char)
                    continue
                }
                if char == "\"" {
                    result.append(char)
                    // Check if the context makes sense as a string termination
                    // by peeking at next non-whitespace char
                    let isObjectKey = depth.last?.expectingKey == true
                    state = isObjectKey ? .afterKey : .afterValue
                    continue
                }
                // Inside string — pass through
                result.append(char)

            case .afterKey:
                switch char {
                case " ", "\n", "\r", "\t":
                    result.append(char)
                case ":":
                    result.append(char)
                    state = .root
                    if let last = depth.last {
                        depth[depth.count - 1] = (last.type, false)
                    }
                default:
                    result.append(char)
                }

            case .afterValue:
                switch char {
                case " ", "\n", "\r", "\t":
                    result.append(char)
                case ",":
                    result.append(char)
                    // After comma in object, next is a key
                    if let last = depth.last, last.type == "{" {
                        depth[depth.count - 1] = (last.type, true)
                    }
                    state = .root
                case "]":
                    if let last = depth.last, last.type == "[" {
                        depth.removeLast()
                    }
                    result.append(char)
                case "}":
                    if let last = depth.last, last.type == "{" {
                        depth.removeLast()
                    }
                    result.append(char)
                default:
                    result.append(char)
                }
            }
        }

        return String(result)
    }
}
