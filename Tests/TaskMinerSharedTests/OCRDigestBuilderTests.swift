import XCTest
@testable import TaskMinerShared

final class OCRDigestBuilderTests: XCTestCase {

    // MARK: - URL Extraction

    func testExtractsHTTPAndHTTPSURLs() {
        let texts = [
            "Visit https://github.com/user/repo and http://example.com/page for details"
        ]
        let urls = OCRDigestBuilder.extractURLs(from: texts)
        XCTAssertTrue(urls.contains(where: { $0.contains("github.com") }))
        XCTAssertTrue(urls.contains(where: { $0.contains("example.com") }))
    }

    func testURLExtractionStripsTrailingPunctuation() {
        let texts = ["Check https://example.com/page. And https://foo.com/bar)."]
        let urls = OCRDigestBuilder.extractURLs(from: texts)
        // URLs should not end with trailing . or )
        for url in urls {
            XCTAssertFalse(url.hasSuffix("."), "URL should not end with period: \(url)")
            XCTAssertFalse(url.hasSuffix(")"), "URL should not end with paren: \(url)")
        }
    }

    func testURLExtractionDeduplicatesSameDomainPath() {
        let texts = [
            "https://github.com/user/repo/blob/main/file1.swift",
            "https://github.com/user/repo/blob/main/file2.swift",
        ]
        let urls = OCRDigestBuilder.extractURLs(from: texts)
        // Both collapse to github.com/user/repo — should deduplicate
        let githubEntries = urls.filter { $0.contains("github.com") }
        XCTAssertEqual(githubEntries.count, 1, "Same domain+path prefix should be deduplicated")
    }

    func testURLExtractionFiltersShortURLs() {
        // After trailing-dot stripping, "http://a.b." becomes "http://a" (8 chars ≤ 10)
        let texts = ["http://a.b."]
        let urls = OCRDigestBuilder.extractURLs(from: texts)
        XCTAssertTrue(urls.isEmpty, "Very short URLs should be filtered out")
    }

    func testURLExtractionCapsAt30() {
        let texts = (1...40).map { "https://example\($0).com/path/page" }
        let urls = OCRDigestBuilder.extractURLs(from: texts)
        XCTAssertLessThanOrEqual(urls.count, 30)
    }

    // MARK: - File Path Extraction

    func testExtractsAbsoluteFilePaths() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "Editing /Users/sam/Projects/Stubble/Sources/main.swift in Xcode"
        ])
        XCTAssertFalse(digest.filePaths.isEmpty, "Should extract /Users/... path")
    }

    func testExtractsTildePaths() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "Config at ~/Library/Application Support/Stubble/settings.json"
        ])
        XCTAssertFalse(digest.filePaths.isEmpty, "Should extract ~/... path")
    }

    func testFilePathTruncatesLongPaths() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "/Users/sam/Projects/Stubble/Sources/TaskMinerShared/Processing/OCRDigestBuilder.swift"
        ])
        // Paths >4 components should be truncated to .../last3
        let truncated = digest.filePaths.filter { $0.hasPrefix("...") }
        XCTAssertFalse(truncated.isEmpty, "Long paths should be truncated with .../")
    }

    func testFilePathsCappedAt20() {
        let paths = (1...25).map { "/Users/sam/file\($0).swift" }
        let text = paths.joined(separator: "\n")
        let digest = OCRDigestBuilder.buildDigest(from: [text])
        XCTAssertLessThanOrEqual(digest.filePaths.count, 20)
    }

    // MARK: - Code Symbol Extraction

    func testExtractsFunctionSymbols() {
        let symbols = OCRDigestBuilder.extractCodeSymbols(from: [
            "func buildDigest(from texts: [String])"
        ])
        XCTAssertTrue(symbols.contains("buildDigest"))
    }

    func testExtractsClassAndStructSymbols() {
        let symbols = OCRDigestBuilder.extractCodeSymbols(from: [
            "class DashboardViewModel",
            "struct TaskRecord",
            "enum MemoryCategory",
            "protocol Sendable",
        ])
        XCTAssertTrue(symbols.contains("DashboardViewModel"))
        XCTAssertTrue(symbols.contains("TaskRecord"))
        XCTAssertTrue(symbols.contains("MemoryCategory"))
        XCTAssertTrue(symbols.contains("Sendable"))
    }

    func testExtractsImportSymbols() {
        let symbols = OCRDigestBuilder.extractCodeSymbols(from: [
            "import Foundation",
            "from collections import OrderedDict",
        ])
        XCTAssertTrue(symbols.contains("Foundation"))
        XCTAssertTrue(symbols.contains("collections"))
    }

    func testCodeSymbolsFilterShortNames() {
        let symbols = OCRDigestBuilder.extractCodeSymbols(from: [
            "func ab()",  // 2 chars — too short
            "class XY",   // 2 chars — too short
        ])
        XCTAssertFalse(symbols.contains("ab"))
        XCTAssertFalse(symbols.contains("XY"))
    }

    func testCodeSymbolsCappedAt30() {
        let lines = (1...40).map { "class VeryLongClassName\($0)" }
        let symbols = OCRDigestBuilder.extractCodeSymbols(from: [lines.joined(separator: "\n")])
        XCTAssertLessThanOrEqual(symbols.count, 30)
    }

    // MARK: - Document Title Extraction

    func testExtractsDocumentTitle() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "Getting Started with SwiftUI Development\nSome body text here"
        ])
        XCTAssertTrue(digest.docTitles.contains("Getting Started with SwiftUI Development"))
    }

    func testSkipsCodeLinesAsTitle() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "func viewDidLoad() {"
        ])
        XCTAssertTrue(digest.docTitles.isEmpty, "Code lines should not be treated as titles")
    }

    func testSkipsPathsAsTitle() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "/Users/sam/file.swift"
        ])
        XCTAssertTrue(digest.docTitles.isEmpty, "Paths should not be treated as titles")
    }

    func testSkipsShortLinesAsTitle() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "Hi"  // too short (< 8 chars)
        ])
        XCTAssertTrue(digest.docTitles.isEmpty)
    }

    func testDocTitlesCappedAt15() {
        let texts = (1...20).map { "Document Title Number \($0) Is Quite Long Enough" }
        let digest = OCRDigestBuilder.buildDigest(from: texts)
        XCTAssertLessThanOrEqual(digest.docTitles.count, 15)
    }

    // MARK: - Communication Extraction

    func testExtractsSlackChannels() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "Posted in #engineering-team and #product-updates"
        ])
        XCTAssertTrue(digest.communications.contains("#engineering-team"))
        XCTAssertTrue(digest.communications.contains("#product-updates"))
    }

    func testCommunicationsCappedAt15() {
        let channels = (1...20).map { "#channel-number-\($0)" }
        let digest = OCRDigestBuilder.buildDigest(from: [channels.joined(separator: " ")])
        XCTAssertLessThanOrEqual(digest.communications.count, 15)
    }

    // MARK: - Command Extraction

    func testExtractsTerminalCommands() {
        let digest = OCRDigestBuilder.buildDigest(from: [
            "$ swift build -c release\n$ git status\n% brew install sqlite"
        ])
        XCTAssertFalse(digest.commands.isEmpty, "Should extract terminal commands")
        XCTAssertTrue(digest.commands.contains(where: { $0.contains("swift build") }))
    }

    func testCommandsCappedAt10() {
        let cmds = (1...15).map { "$ some-command-number-\($0) --flag" }
        let digest = OCRDigestBuilder.buildDigest(from: [cmds.joined(separator: "\n")])
        XCTAssertLessThanOrEqual(digest.commands.count, 10)
    }

    // MARK: - buildDigest Integration

    func testBuildDigestWithMixedContent() {
        let ocrText = """
        Getting Started with Stubble
        Editing /Users/sam/Projects/Stubble/Sources/main.swift
        Visit https://github.com/samattias/stubble for more info
        class DashboardViewModel: ObservableObject {
        import SwiftUI
        #engineering-team discussion
        $ swift build -c release
        """
        let digest = OCRDigestBuilder.buildDigest(from: [ocrText])
        XCTAssertFalse(digest.urls.isEmpty)
        XCTAssertFalse(digest.filePaths.isEmpty)
        XCTAssertFalse(digest.codeSymbols.isEmpty)
        XCTAssertFalse(digest.docTitles.isEmpty)
        XCTAssertFalse(digest.communications.isEmpty)
        XCTAssertFalse(digest.commands.isEmpty)
    }

    func testBuildDigestWithEmptyInput() {
        let digest = OCRDigestBuilder.buildDigest(from: [])
        XCTAssertTrue(digest.urls.isEmpty)
        XCTAssertTrue(digest.filePaths.isEmpty)
        XCTAssertTrue(digest.codeSymbols.isEmpty)
        XCTAssertTrue(digest.docTitles.isEmpty)
        XCTAssertTrue(digest.communications.isEmpty)
        XCTAssertTrue(digest.commands.isEmpty)
    }

    func testBuildDigestFromOCRColumnFiltersNils() {
        let digest = OCRDigestBuilder.buildDigest(fromOCRColumn: [
            nil,
            "class TestClass in https://example.com/page",
            nil,
        ])
        XCTAssertFalse(digest.urls.isEmpty, "Non-nil entries should be processed")
    }

    // MARK: - asPromptSection

    func testAsPromptSectionWithAllFields() {
        let digest = OCRDigestBuilder.OCRDigest(
            urls: ["github.com/user/repo"],
            filePaths: [".../Sources/main.swift"],
            codeSymbols: ["DashboardViewModel"],
            docTitles: ["Getting Started"],
            communications: ["#engineering"],
            commands: ["swift build"]
        )
        let section = digest.asPromptSection()
        XCTAssertNotNil(section)
        XCTAssertTrue(section!.contains("URLs visited:"))
        XCTAssertTrue(section!.contains("Files/paths:"))
        XCTAssertTrue(section!.contains("Code symbols:"))
        XCTAssertTrue(section!.contains("Documents/pages:"))
        XCTAssertTrue(section!.contains("Communications:"))
        XCTAssertTrue(section!.contains("Terminal commands:"))
    }

    func testAsPromptSectionEmptyDigestReturnsNil() {
        let digest = OCRDigestBuilder.OCRDigest(
            urls: [], filePaths: [], codeSymbols: [],
            docTitles: [], communications: [], commands: []
        )
        XCTAssertNil(digest.asPromptSection())
    }

    func testAsPromptSectionPartialFields() {
        let digest = OCRDigestBuilder.OCRDigest(
            urls: ["example.com"],
            filePaths: [],
            codeSymbols: ["MyClass"],
            docTitles: [],
            communications: [],
            commands: []
        )
        let section = digest.asPromptSection()!
        XCTAssertTrue(section.contains("URLs visited:"))
        XCTAssertTrue(section.contains("Code symbols:"))
        XCTAssertFalse(section.contains("Files/paths:"))
        XCTAssertFalse(section.contains("Documents/pages:"))
    }
}
