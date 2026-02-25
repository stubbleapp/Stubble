import XCTest
@testable import TaskMinerShared

final class PauseControllerTests: XCTestCase {

    private var tempDir: URL!
    private var controller: PauseController!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubblePauseTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        controller = PauseController(dataDirectory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStateIsNotPaused() {
        XCTAssertFalse(controller.isPaused)
        XCTAssertNil(controller.currentState())
    }

    // MARK: - Pause

    func testPauseWithDuration() {
        controller.pause(for: 3600) // 1 hour

        XCTAssertTrue(controller.isPaused)

        let state = controller.currentState()
        XCTAssertNotNil(state)
        XCTAssertNotNil(state?.resumeAt)
        XCTAssertFalse(state!.isExpired)
        XCTAssertGreaterThan(state!.timeRemaining ?? 0, 3500)
    }

    func testPauseIndefinitely() {
        controller.pause(for: nil)

        XCTAssertTrue(controller.isPaused)

        let state = controller.currentState()
        XCTAssertNotNil(state)
        XCTAssertNil(state?.resumeAt, "Indefinite pause should have nil resumeAt")
        XCTAssertFalse(state!.isExpired)
        XCTAssertNil(state?.timeRemaining)
    }

    // MARK: - Resume

    func testResume() {
        controller.pause(for: 3600)
        XCTAssertTrue(controller.isPaused)

        controller.resume()
        XCTAssertFalse(controller.isPaused)
        XCTAssertNil(controller.currentState())
    }

    func testResumeWhenNotPausedIsNoOp() {
        // Should not crash
        controller.resume()
        XCTAssertFalse(controller.isPaused)
    }

    // MARK: - Expiration

    func testExpiredPauseAutoResumes() {
        // Create a pause that's already expired
        let state = PauseState(
            pausedAt: Date().addingTimeInterval(-7200),
            resumeAt: Date().addingTimeInterval(-3600)
        )
        let data = try! JSONEncoder().encode(state)
        let pauseFile = tempDir.appendingPathComponent(".pause")
        try! data.write(to: pauseFile)

        // currentState() should detect expiration and auto-resume
        XCTAssertNil(controller.currentState(), "Expired pause should return nil and auto-resume")
        XCTAssertFalse(controller.isPaused)
    }

    // MARK: - Overwrite

    func testPauseOverwritesPreviousPause() {
        controller.pause(for: 3600) // 1 hour
        controller.pause(for: 60)   // 1 minute

        let state = controller.currentState()
        XCTAssertNotNil(state)
        // The remaining time should be close to 60, not 3600
        XCTAssertLessThan(state!.timeRemaining ?? 9999, 120)
    }

    // MARK: - Persistence

    func testPausePersistsToDisk() {
        controller.pause(for: 3600)

        // Create a new controller pointing to the same directory
        let controller2 = PauseController(dataDirectory: tempDir)
        XCTAssertTrue(controller2.isPaused, "New controller should read persisted pause state")
    }

    func testResumeCleansUpFile() {
        controller.pause(for: 3600)
        controller.resume()

        let pauseFile = tempDir.appendingPathComponent(".pause")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pauseFile.path),
                       "Resume should delete the pause file")
    }
}
