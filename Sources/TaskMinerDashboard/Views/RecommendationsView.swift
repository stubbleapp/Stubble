import SwiftUI
import AppKit
import TaskMinerShared

struct RecommendationsView: View {
    @Environment(DashboardViewModel.self) var viewModel

    /// The user's first name from macOS account, used for the greeting.
    private var firstName: String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — greeting + refresh
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hey, \(firstName)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)

                    if let context = viewModel.greetingContext {
                        Text(context)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textMuted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                if !viewModel.recommendations.isEmpty {
                    Button(action: { viewModel.generateRecommendations() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .symbolEffect(.bounce, value: viewModel.isGeneratingRecommendations)
                            .frame(width: 32, height: 32)
                            .background(Theme.accent.opacity(0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isGeneratingRecommendations)
                    .help("Regenerate stubs")
                    .accessibilityLabel("Regenerate stubs")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            // Error banner
            if let error = viewModel.recommendationsError {
                HStack(spacing: 8) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Spacer()
                    Button {
                        viewModel.recommendationsError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.statusError.opacity(0.2), lineWidth: 0.5)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            // Content states
            if viewModel.isGeneratingRecommendations {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing your recent activity\u{2026}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else if viewModel.recommendations.isEmpty {
                // Empty state
                Spacer()
                VStack(spacing: 14) {
                    Text("Generate stubs to get personalized\ninsights based on your recent work.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Button(action: { viewModel.generateRecommendations() }) {
                        Text("Generate Stubs")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Theme.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                    .disabled(!viewModel.hasGeminiKey)
                    .opacity(viewModel.hasGeminiKey ? 1 : 0.4)

                    if !viewModel.hasGeminiKey {
                        Text("Requires a Gemini API key")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
                Spacer()
            } else {
                // Cards + suggested questions
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.recommendations) { tip in
                            TipCardView(
                                tip: tip,
                                onDismiss: { viewModel.dismissRecommendation(id: tip.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    // Suggested questions
                    if !viewModel.suggestedQuestions.isEmpty {
                        suggestedQuestionsSection
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    }

                    Spacer().frame(height: 64)
                }
            }
        }
    }

    // MARK: - Suggested Questions

    private var suggestedQuestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUESTIONS TO EXPLORE")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textMuted)
                .tracking(0.5)

            ForEach(viewModel.suggestedQuestions, id: \.self) { question in
                Button {
                    viewModel.pendingChatQuestion = question
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bubble.left.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accent.opacity(0.6))

                        Text(question)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(2)

                        Spacer()

                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.textQuaternary, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Tip Card

private struct TipCardView: View {
    let tip: Recommendation
    let onDismiss: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Category + dismiss
            HStack {
                Text(tip.category.displayName.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.5)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textMuted.opacity(0.6))
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0)
            }
            .padding(.bottom, 8)

            // Title
            Text(tip.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)

            // Description
            Text(tip.description)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
                .padding(.bottom, 10)

            // Reason — subtle, inline
            Text(tip.reason)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(2)
                .padding(.bottom, 12)

            // Action link — understated text button, not a pill
            if let urlStr = tip.actionURL,
               let url = URL(string: urlStr) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 3) {
                        Text(tip.actionLabel)
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.cardBackground)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.surfaceElevated.opacity(0.3), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
