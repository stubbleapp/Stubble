import XCTest
@testable import TaskMinerShared

final class LinkExtractorTests: XCTestCase {

    // MARK: - linksFromOCRText

    func testExtractHTTPURLsFromOCR() {
        let text = "Visit https://github.com/user/repo for the code and https://docs.swift.org for docs."
        let links = LinkExtractor.linksFromOCRText(text)

        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].kind, .url)
        XCTAssertEqual(links[0].value, "https://github.com/user/repo")
        XCTAssertEqual(links[0].source, "ocr")
        XCTAssertEqual(links[1].value, "https://docs.swift.org")
    }

    func testExtractFilePathsFromOCR() {
        let text = "Editing /Users/sam/Projects/Stubble/Sources/main.swift in Xcode"
        let links = LinkExtractor.linksFromOCRText(text)

        let filePaths = links.filter { $0.kind == .filePath }
        XCTAssertGreaterThanOrEqual(filePaths.count, 1)
        XCTAssertTrue(filePaths[0].value.contains("/Users/sam/Projects/Stubble"))
        XCTAssertEqual(filePaths[0].source, "ocr")
    }

    func testTrimsTrailingPunctuationFromURLs() {
        let text = "See https://example.com/page. Also https://example.com/other, and done."
        let links = LinkExtractor.linksFromOCRText(text)
        let urls = links.filter { $0.kind == .url }

        for link in urls {
            XCTAssertFalse(link.value.hasSuffix("."), "URL should not end with period: \(link.value)")
            XCTAssertFalse(link.value.hasSuffix(","), "URL should not end with comma: \(link.value)")
        }
    }

    func testDeduplicatesURLsInOCR() {
        let text = "Visit https://example.com and also https://example.com again"
        let links = LinkExtractor.linksFromOCRText(text)
        let urls = links.filter { $0.kind == .url }

        XCTAssertEqual(urls.count, 1, "Duplicate URLs should be deduplicated")
    }

    func testLimitsURLsTo10() {
        var lines: [String] = []
        for i in 0..<15 {
            lines.append("https://example\(i).com/page")
        }
        let text = lines.joined(separator: "\n")
        let links = LinkExtractor.linksFromOCRText(text)
        let urls = links.filter { $0.kind == .url }

        XCTAssertLessThanOrEqual(urls.count, 10)
    }

    func testEmptyOCRReturnsNoLinks() {
        XCTAssertTrue(LinkExtractor.linksFromOCRText("").isEmpty)
        XCTAssertTrue(LinkExtractor.linksFromOCRText("just plain text with no links").isEmpty)
    }

    // MARK: - linksFromWindowTitle

    func testVSCodeWindowTitleWithFullPath() {
        let links = LinkExtractor.linksFromWindowTitle(
            "/Users/sam/project/main.swift — project",
            appName: "Visual Studio Code",
            bundleId: "com.microsoft.VSCode"
        )

        let filePaths = links.filter { $0.kind == .filePath }
        XCTAssertEqual(filePaths.count, 1)
        XCTAssertEqual(filePaths[0].value, "/Users/sam/project/main.swift")
    }

    func testTerminalWithPathInTitle() {
        let links = LinkExtractor.linksFromWindowTitle(
            "sam@mac: /Users/sam/Projects/Stubble",
            appName: "Terminal",
            bundleId: "com.apple.Terminal"
        )

        let filePaths = links.filter { $0.kind == .filePath }
        XCTAssertGreaterThanOrEqual(filePaths.count, 1)
        XCTAssertTrue(filePaths[0].value.hasPrefix("/Users/sam"))
    }

    func testBrowserTitleWithURL() {
        let links = LinkExtractor.linksFromWindowTitle(
            "GitHub - https://github.com/user/repo",
            appName: "Google Chrome",
            bundleId: "com.google.Chrome"
        )

        let urls = links.filter { $0.kind == .url }
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].value, "https://github.com/user/repo")
    }

    func testXcodeReturnsNoFilePath() {
        // Xcode titles don't contain full paths — should return nil
        let links = LinkExtractor.linksFromWindowTitle(
            "ContentView.swift — Stubble",
            appName: "Xcode",
            bundleId: "com.apple.dt.Xcode"
        )

        let filePaths = links.filter { $0.kind == .filePath }
        XCTAssertTrue(filePaths.isEmpty, "Xcode titles don't contain full paths")
    }

    func testFinderReturnsNoFilePath() {
        let links = LinkExtractor.linksFromWindowTitle(
            "Downloads",
            appName: "Finder",
            bundleId: "com.apple.finder"
        )

        let filePaths = links.filter { $0.kind == .filePath }
        XCTAssertTrue(filePaths.isEmpty)
    }

    func testNonBrowserNonIDEWithPathTitle() {
        let links = LinkExtractor.linksFromWindowTitle(
            "/Users/sam/document.pdf",
            appName: "SomeApp",
            bundleId: "com.example.someapp"
        )

        let filePaths = links.filter { $0.kind == .filePath }
        XCTAssertEqual(filePaths.count, 1)
    }

    // MARK: - linksFromJSON

    func testLinksFromJSONWithMixedTypes() {
        let json = #"["https://github.com/user/repo", "/Users/sam/file.swift", "~/Documents/notes.md"]"#
        let links = LinkExtractor.linksFromJSON(json)

        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].kind, .url)
        XCTAssertEqual(links[0].source, "ai")
        XCTAssertEqual(links[1].kind, .filePath)
        XCTAssertEqual(links[2].kind, .filePath)
    }

    func testLinksFromJSONWithInvalidJSON() {
        XCTAssertTrue(LinkExtractor.linksFromJSON("not json").isEmpty)
        XCTAssertTrue(LinkExtractor.linksFromJSON("").isEmpty)
        XCTAssertTrue(LinkExtractor.linksFromJSON("{}").isEmpty)
    }

    func testLinksFromJSONWithEmptyArray() {
        XCTAssertTrue(LinkExtractor.linksFromJSON("[]").isEmpty)
    }

    func testLinksFromJSONIgnoresInvalidEntries() {
        let json = #"["https://valid.com", "no-protocol.com", "", "  ", "/valid/path.txt"]"#
        let links = LinkExtractor.linksFromJSON(json)

        // "no-protocol.com" and empty/whitespace strings should be skipped
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].value, "https://valid.com")
        XCTAssertEqual(links[1].value, "/valid/path.txt")
    }

    // MARK: - Short Labels

    func testGitHubShortLabel() {
        let links = LinkExtractor.linksFromOCRText("https://github.com/samattias/stubble-releases")
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links[0].label, "samattias/stubble-releases")
    }

    func testGitHubPRLabel() {
        let links = LinkExtractor.linksFromOCRText("https://github.com/owner/repo/pull/42")
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links[0].label, "owner/repo #42")
    }

    func testGoogleDocsLabel() {
        let links = LinkExtractor.linksFromOCRText("https://docs.google.com/document/d/abc123/edit")
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links[0].label, "Google Docs")
    }

    func testYouTubeLabel() {
        let links = LinkExtractor.linksFromOCRText("https://youtube.com/watch?v=abc123")
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links[0].label, "YouTube")
    }

    func testStackOverflowLabel() {
        let links = LinkExtractor.linksFromOCRText("https://stackoverflow.com/questions/12345")
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links[0].label, "Stack Overflow")
    }

    func testGenericHostLabel() {
        let links = LinkExtractor.linksFromOCRText("https://www.example.com/some/page")
        XCTAssertGreaterThanOrEqual(links.count, 1)
        XCTAssertEqual(links[0].label, "example.com")
    }

    // MARK: - openableURL

    func testOpenableURLForHTTP() {
        let link = ExtractedLink(kind: .url, value: "https://example.com", label: "example", source: "test")
        XCTAssertEqual(link.openableURL?.absoluteString, "https://example.com")
    }

    func testOpenableURLForFilePath() {
        let link = ExtractedLink(kind: .filePath, value: "/Users/sam/file.txt", label: "file.txt", source: "test")
        XCTAssertNotNil(link.openableURL)
        XCTAssertTrue(link.openableURL?.isFileURL ?? false)
    }

    func testOpenableURLForTildePath() {
        let link = ExtractedLink(kind: .filePath, value: "~/Documents/file.txt", label: "file.txt", source: "test")
        let url = link.openableURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.isFileURL ?? false)
        XCTAssertFalse(url?.path.contains("~") ?? true, "Tilde should be expanded")
    }
}
