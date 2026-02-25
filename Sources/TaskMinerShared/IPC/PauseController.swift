import Foundation

public struct PauseState: Codable, Sendable {
    public let pausedAt: Date
    public let resumeAt: Date?

    public var isExpired: Bool {
        guard let resumeAt else { return false }
        return Date() >= resumeAt
    }

    public var timeRemaining: TimeInterval? {
        guard let resumeAt else { return nil }
        return max(0, resumeAt.timeIntervalSinceNow)
    }

    public init(pausedAt: Date, resumeAt: Date?) {
        self.pausedAt = pausedAt
        self.resumeAt = resumeAt
    }
}

public class PauseController {
    private let pauseFileURL: URL

    public init(dataDirectory: URL) {
        self.pauseFileURL = dataDirectory.appendingPathComponent(".pause")
    }

    public func currentState() -> PauseState? {
        guard FileManager.default.fileExists(atPath: pauseFileURL.path),
              let data = try? Data(contentsOf: pauseFileURL),
              let state = try? JSONDecoder().decode(PauseState.self, from: data)
        else { return nil }

        if state.isExpired {
            resume()
            return nil
        }
        return state
    }

    public func pause(for duration: TimeInterval?) {
        let state = PauseState(
            pausedAt: Date(),
            resumeAt: duration.map { Date().addingTimeInterval($0) }
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: pauseFileURL, options: .atomic)
            // Restrict pause file to owner-only access (0600) — IPC state file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pauseFileURL.path)
        } catch {
            Logger.warning("PauseController: failed to write pause state: \(error.localizedDescription)")
        }
    }

    public func resume() {
        do {
            try FileManager.default.removeItem(at: pauseFileURL)
        } catch {
            // File may not exist if already resumed — only warn for unexpected errors
            if (error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != NSFileNoSuchFileError {
                Logger.warning("PauseController: failed to remove pause file: \(error.localizedDescription)")
            }
        }
    }

    public var isPaused: Bool {
        currentState() != nil
    }
}
