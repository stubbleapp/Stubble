import Foundation
import CoreGraphics

class IdleDetector {
    private let threshold: TimeInterval
    private(set) var wasIdle: Bool = false

    init(threshold: TimeInterval) {
        self.threshold = threshold
    }

    var isIdle: Bool {
        idleTime >= threshold
    }

    var idleTime: TimeInterval {
        let mouseMove = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .mouseMoved
        )
        let keyDown = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .keyDown
        )
        let leftClick = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .leftMouseDown
        )
        let scrollWheel = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: .scrollWheel
        )
        // User is idle only when ALL input types exceed threshold
        return min(mouseMove, keyDown, leftClick, scrollWheel)
    }

    /// Returns true if idle state transitioned since last check
    func checkTransition() -> IdleTransition {
        let currentlyIdle = isIdle
        defer { wasIdle = currentlyIdle }

        if !wasIdle && currentlyIdle {
            return .becameIdle
        } else if wasIdle && !currentlyIdle {
            return .becameActive
        }
        return .noChange
    }

    enum IdleTransition {
        case becameIdle
        case becameActive
        case noChange
    }
}
