import Foundation

/// The full output from the Stubs page AI generation: greeting, questions, and recommendations.
/// For past days, `daySummary` contains a retrospective narrative; for today it's nil.
struct StubsContent {
    let greetingContext: String
    let daySummary: String?
    let suggestedQuestions: [String]
    var recommendations: [Recommendation]
}

/// A single AI-generated recommendation based on the user's recent work activity.
/// Recommendations are ephemeral (not persisted to the database).
struct Recommendation: Identifiable {
    let id: UUID
    let category: Category
    let title: String
    let description: String
    let reason: String          // Why this is relevant to the user's recent work
    var actionLabel: String     // e.g. "Read Article", "Try It", "Learn More"
    var actionURL: String?      // Optional URL to open
    let iconName: String        // SF Symbol name

    enum Category: String, CaseIterable {
        case article = "article"
        case tool = "tool"
        case bestPractice = "best_practice"
        case workflow = "workflow"
        case learning = "learning"
        case exploration = "exploration"

        var displayName: String {
            switch self {
            case .article: return "Article"
            case .tool: return "Tool"
            case .bestPractice: return "Best Practice"
            case .workflow: return "Workflow"
            case .learning: return "Learning"
            case .exploration: return "Exploration"
            }
        }

        var defaultIcon: String {
            switch self {
            case .article: return "doc.text"
            case .tool: return "wrench.and.screwdriver"
            case .bestPractice: return "lightbulb"
            case .workflow: return "arrow.triangle.branch"
            case .learning: return "book"
            case .exploration: return "sparkle.magnifyingglass"
            }
        }

        var defaultActionLabel: String {
            switch self {
            case .article: return "Read Article"
            case .tool: return "Try It"
            case .bestPractice: return "Learn More"
            case .workflow: return "Learn More"
            case .learning: return "Explore"
            case .exploration: return "Explore"
            }
        }
    }
}
