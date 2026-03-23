import Foundation

/// Record for cached OCR digest data.
public struct OCRDigestRecord: Sendable {
    public let date: String         // "yyyy-MM-dd"
    public let digest: String       // Extracted URLs, paths, symbols, etc.
    public let generatedAt: Date

    public init(date: String, digest: String, generatedAt: Date) {
        self.date = date
        self.digest = digest
        self.generatedAt = generatedAt
    }
}
