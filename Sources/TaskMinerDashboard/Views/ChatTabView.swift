import SwiftUI
import AppKit
import TaskMinerShared

struct ChatTabView: View {
    @Environment(DashboardViewModel.self) var viewModel

    private var firstName: String {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    private var hasRecommendations: Bool {
        !viewModel.recommendations.isEmpty
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isGeneratingRecommendations && !hasRecommendations {
                // Skeleton loading state
                skeletonContent
            } else if !hasRecommendations {
                Spacer()
                VStack(spacing: 14) {
                    Text("Hey, \(firstName)")
                        .font(Theme.headerFont(size: 24))
                        .foregroundStyle(Theme.textPrimary)

                    Text("Ask me anything about your day,\nor generate stubs for personalized insights.")
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Greeting
                        greetingSection
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .padding(.bottom, 16)

                        if let error = viewModel.recommendationsError {
                            errorBanner(error)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 12)
                        }

                        // Recommendation cards
                        if !viewModel.recommendations.isEmpty {
                            recommendationCardsSection
                                .redacted(reason: viewModel.isGeneratingRecommendations ? .placeholder : [])
                                .shimmer(active: viewModel.isGeneratingRecommendations)
                                .padding(.bottom, 16)
                        }

                        Spacer().frame(height: 100)
                    }
                }
                .allowsHitTesting(!viewModel.isGeneratingRecommendations)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chatBackground)
        .onAppear {
            // Auto-generate stubs on first visit (same logic as RecommendationsView)
            if !hasRecommendations
                && !viewModel.isGeneratingRecommendations
                && !viewModel.hasAttemptedStubsGeneration
                && viewModel.hasGeminiKey
                && !viewModel.tasks.isEmpty {
                viewModel.hasAttemptedStubsGeneration = true
                viewModel.generateRecommendations()
            }
        }
    }

    // MARK: - Greeting

    private var greetingSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hey, \(firstName)")
                    .font(Theme.headerFont(size: 24))
                    .foregroundStyle(Theme.textPrimary)

                if let context = viewModel.greetingContext {
                    Text(context)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

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
        }
    }

    // MARK: - Recommendation List

    private var recommendationCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)

            VStack(spacing: 8) {
                ForEach(viewModel.recommendations) { tip in
                    RecommendationRow(tip: tip, onDismiss: {
                        viewModel.dismissRecommendation(id: tip.id)
                    })
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Skeleton Loading

    private var skeletonContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Skeleton greeting
                skeletonGreeting
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                // Skeleton recommendation cards
                skeletonRecommendations
                    .padding(.bottom, 16)

                Spacer().frame(height: 100)
            }
        }
        .redacted(reason: .placeholder)
        .shimmer(active: true)
        .allowsHitTesting(false)
    }

    private var skeletonGreeting: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Hey, \(firstName)")
                    .font(Theme.headerFont(size: 24))
                    .foregroundStyle(Theme.textPrimary)

                Text("Here's what I noticed about your day so far and some suggestions.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2)
            }

            Spacer()

            Circle()
                .fill(Theme.accent.opacity(0.08))
                .frame(width: 32, height: 32)
        }
    }

    private var skeletonRecommendations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)

            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonRecommendationRow()
                }
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Theme.statusError.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Skeleton Recommendation Row

private struct SkeletonRecommendationRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon placeholder
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.accent.opacity(0.1))
                .frame(width: 28, height: 28)

            // Content placeholder
            VStack(alignment: .leading, spacing: 4) {
                // Category
                Text("CATEGORY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)

                // Title
                Text("Recommendation title placeholder")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                // Description
                Text("This is placeholder text for the recommendation description.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                // Reason
                HStack(spacing: 4) {
                    Circle()
                        .fill(Theme.accent.opacity(0.3))
                        .frame(width: 9, height: 9)
                    Text("Reason placeholder text")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.top, 2)

                // Action button
                Text("Learn more")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
    }
}
