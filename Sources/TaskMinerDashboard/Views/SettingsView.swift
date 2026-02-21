import SwiftUI
import TaskMinerShared

struct SettingsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) var dismiss
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(Theme.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding()

            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // AI Configuration
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.subheadline)
                                .foregroundStyle(Theme.accent)
                            Text("AI Configuration")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Gemini API Key")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)

                            HStack(spacing: 8) {
                                Group {
                                    if showKey {
                                        TextField("Enter your Gemini API key", text: $apiKey)
                                    } else {
                                        SecureField("Enter your Gemini API key", text: $apiKey)
                                    }
                                }
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                                .background(Theme.primaryBackground)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Theme.cardBorder, lineWidth: 1)
                                )

                                Button {
                                    showKey.toggle()
                                } label: {
                                    Image(systemName: showKey ? "eye.slash" : "eye")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.textMuted)
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                            }

                            Text("Used for AI-powered task summarization. Get a key from Google AI Studio.")
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                        }
                        .padding(12)
                        .background(Theme.cardBackground)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.cardBorder, lineWidth: 0.5)
                        )
                    }

                    // Status + actions
                    HStack(spacing: 12) {
                        // Status indicator
                        HStack(spacing: 6) {
                            Circle()
                                .fill(viewModel.hasGeminiKey ? Theme.statusActive : Theme.textQuaternary)
                                .frame(width: 6, height: 6)
                            Text(viewModel.hasGeminiKey ? "API key configured" : "No API key set")
                                .font(.caption)
                                .foregroundStyle(viewModel.hasGeminiKey ? Theme.textSecondary : Theme.textMuted)
                        }

                        Spacer()

                        if !apiKey.isEmpty {
                            Button("Clear") {
                                apiKey = ""
                                viewModel.updateGeminiKey(nil)
                                saved = true
                                hideSavedAfterDelay()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textMuted)
                        }

                        Button {
                            viewModel.updateGeminiKey(apiKey)
                            saved = true
                            hideSavedAfterDelay()
                        } label: {
                            HStack(spacing: 4) {
                                if saved {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                Text(saved ? "Saved" : "Save")
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(saved ? Theme.statusActive : Theme.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.2), value: saved)
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 280)
        .background(Theme.secondaryBackground)
        .onAppear {
            let stored = GeminiKeychain.get() ?? ""
            apiKey = stored
            showKey = !stored.isEmpty
        }
    }

    private func hideSavedAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }
}
