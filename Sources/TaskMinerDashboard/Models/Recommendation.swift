import Foundation

/// A single AI-generated recommendation based on the user's recent work activity.
/// Recommendations are ephemeral (not persisted to the database).
struct Recommendation: Identifiable {
    let id: UUID
    let category: Category
    let title: String
    let description: String
    let reason: String          // Why this is relevant to the user's recent work
    let actionLabel: String     // e.g. "Read Article", "Try It", "Learn More"
    let actionURL: String?      // Optional URL to open
    let iconName: String        // SF Symbol name

    enum Category: String, CaseIterable {
        case article = "article"
        case tool = "tool"
        case bestPractice = "best_practice"
        case workflow = "workflow"

        var displayName: String {
            switch self {
            case .article: return "Article"
            case .tool: return "Tool"
            case .bestPractice: return "Best Practice"
            case .workflow: return "Workflow"
            }
        }

        var defaultIcon: String {
            switch self {
            case .article: return "doc.text"
            case .tool: return "wrench.and.screwdriver"
            case .bestPractice: return "lightbulb"
            case .workflow: return "arrow.triangle.branch"
            }
        }

        var defaultActionLabel: String {
            switch self {
            case .article: return "Read Article"
            case .tool: return "Try It"
            case .bestPractice: return "Learn More"
            case .workflow: return "Learn More"
            }
        }
    }
}
