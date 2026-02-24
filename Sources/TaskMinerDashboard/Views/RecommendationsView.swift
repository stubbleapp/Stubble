import SwiftUI
import AppKit
import TaskMinerShared

struct RecommendationsView: View {
    @Environment(DashboardViewModel.self) var viewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .firstTextBaseline) {
                Text("Tips")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                if !viewModel.recommendations.isEmpty {
                    Button(action: { viewModel.generateRecommendations() }) {
                        Text("Refresh")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isGeneratingRecommendations)
                    .opacity(viewModel.isGeneratingRecommendations ? 0.4 : 1)
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
                .background(Color.white.opacity(0.45))
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
                    Text("Analyzing your recent activity...")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            } else if viewModel.recommendations.isEmpty {
                // Empty state — minimal, clean
                Spacer()
                VStack(spacing: 14) {
                    Text("No tips yet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)

                    Text("Generate personalized tips based on\nyour recent work activity.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)

                    Button(action: { viewModel.generateRecommendations() }) {
                        Text("Generate Tips")
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
                // Tip cards
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

                    Spacer().frame(height: 64)
                }
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
                    .foregroundStyle(categoryColor.opacity(0.8))
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
                // Base: translucent white layer
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.45))
                // Top edge highlight for glass feel
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        .overlay(alignment: .topLeading) {
            // Subtle accent bar on the left edge
            RoundedRectangle(cornerRadius: 1)
                .fill(categoryColor.opacity(0.35))
                .frame(width: 2.5)
                .padding(.vertical, 14)
                .padding(.leading, 2)
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var categoryColor: Color {
        switch tip.category {
        case .article:
            return Color(nsColor: NSColor(red: 0.25, green: 0.52, blue: 0.85, alpha: 1))
        case .tool:
            return Color(nsColor: NSColor(red: 0.58, green: 0.35, blue: 0.75, alpha: 1))
        case .bestPractice:
            return Color(nsColor: NSColor(red: 0.25, green: 0.65, blue: 0.42, alpha: 1))
        case .workflow:
            return Color(nsColor: NSColor(red: 0.80, green: 0.52, blue: 0.20, alpha: 1))
        }
    }
}
