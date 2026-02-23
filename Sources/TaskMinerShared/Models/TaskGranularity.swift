import Foundation

/// Controls how many tasks the AI generates per hour of activity.
/// Stored in settings.json and used by both the dashboard and CLI daemon.
public enum TaskGranularity: String, Codable, CaseIterable, Sendable {
    case low = "low"        // ~1 task per hour (very coarse, big blocks)
    case medium = "medium"  // ~3 tasks per hour (default, balanced)
    case high = "high"      // ~6 tasks per hour (fine-grained, detailed)

    public var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    public var description: String {
        switch self {
        case .low: return "~1 task per hour — broad overview"
        case .medium: return "~3 tasks per hour — balanced detail"
        case .high: return "~6 tasks per hour — fine-grained"
        }
    }

    /// Target tasks per hour of activity — used to calculate a hard target in the prompt.
    public var tasksPerHour: Double {
        switch self {
        case .low: return 1.0
        case .medium: return 3.0
        case .high: return 6.0
        }
    }

    /// The prompt fragment that tells the AI how many tasks to produce.
    public var promptInstruction: String {
        switch self {
        case .low:
            return "Aggressively merge related activity into very coarse tasks — aim for roughly 1 task per hour of activity, or about 3–5 tasks for a full work day. Prioritise broad groupings over detail. NEVER produce more tasks than the target count above."
        case .medium:
            return "Merge related activity into balanced tasks — aim for roughly 3 tasks per hour of activity. Group closely-related work but keep distinct efforts separate. NEVER produce more tasks than the target count above."
        case .high:
            return "Create detailed, fine-grained tasks — aim for roughly 6 tasks per hour of activity. Keep individual efforts and subtasks separate rather than merging. NEVER produce more tasks than the target count above."
        }
    }
}
