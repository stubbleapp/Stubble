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
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing your recent activity\u{2026}")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
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
                                .padding(.bottom, 16)
                        }

                        // Past chats
                        if !viewModel.chatThreads.isEmpty {
                            pastChatsSection
                                .padding(.bottom, 16)
                        }

                        Spacer().frame(height: 100)
                    }
                }
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

    // MARK: - Recommendation Cards

    private var recommendationCardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recommended")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.recommendations) { tip in
                        RecommendationCard(tip: tip, onDismiss: {
                            viewModel.dismissRecommendation(id: tip.id)
                        })
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollClipDisabled(true)
        }
    }

    // MARK: - Past Chats

    private var pastChatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Chats")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 24)

            VStack(spacing: 6) {
                ForEach(viewModel.chatThreads.prefix(5)) { thread in
                    Button {
                        viewModel.switchToThread(thread.id)
                        viewModel.shouldExpandChatPanel = true
                    } label: {
                        HStack(spacing: 10) {
                            ActivityHaloDot(color: Theme.accent, size: 10)

                            Text(threadTitle(thread))
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)

                            Spacer()

                            Text(threadDate(thread))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textQuaternary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.primaryBackground.opacity(0.5))
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func threadTitle(_ thread: ChatThread) -> String {
        let summary = thread.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }

        let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.hasPrefix("Chat ") || title == "New Chat" || title.isEmpty {
            return "Untitled Chat"
        }
        return title
    }

    private func threadDate(_ thread: ChatThread) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: thread.updatedAt, relativeTo: Date())
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
