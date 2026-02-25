import SwiftUI
import TaskMinerShared

struct SettingsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) var dismiss
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false
    @State private var customPrompt: String = ""
    @State private var granularity: TaskGranularity = .medium
    @State private var showClearConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // API Key
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gemini API Key")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

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
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .accessibilityIdentifier("settings-api-key")

                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 28, height: 28)
                                .background(Theme.surfaceElevated)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text("Get a key from Google AI Studio.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                // Custom Prompt
                VStack(alignment: .leading, spacing: 8) {
                    Text("Custom Instructions")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    TextEditor(text: $customPrompt)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 60, maxHeight: 100)
                        .padding(8)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Text("e.g. Ignore all YouTube and social media activity. Focus only on coding and design work.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                        .italic()
                }

                // Task Granularity
                VStack(alignment: .leading, spacing: 8) {
                    Text("Task Granularity")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    HStack(spacing: 0) {
                        ForEach(TaskGranularity.allCases, id: \.self) { level in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    granularity = level
                                }
                            } label: {
                                Text(level.displayName)
                                    .font(.system(size: 12, weight: granularity == level ? .semibold : .regular))
                                    .foregroundStyle(granularity == level ? Theme.textPrimary : Theme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(granularity == level ? Theme.selectedSurface : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.surfaceElevated)
                    )
                    .accessibilityIdentifier("settings-granularity")

                    Text(granularity.description)
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                // Data
                VStack(alignment: .leading, spacing: 8) {
                    Text("Data")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)

                    Button {
                        showClearConfirmation = true
                    } label: {
                        Text("Clear All Data")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.statusError)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings-clear-data")

                    Text("Permanently deletes all tasks, activities, screenshots, and memory. Your settings and API key are kept.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                }

                // Save
                HStack(spacing: 12) {
                    Spacer()

                    Button {
                        viewModel.updateGeminiKey(apiKey)
                        let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        SettingsManager.shared.customPrompt = trimmed.isEmpty ? nil : trimmed
                        SettingsManager.shared.granularity = granularity
                        Analytics.settingChanged("granularity", value: granularity.displayName)
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
                    .accessibilityIdentifier("settings-save")
                    .animation(.easeInOut(duration: 0.2), value: saved)
                }
            }
            .padding(20)
        }
        .frame(width: 460, height: 560)
        .background(Theme.primaryBackground)
        .toolbarBackground(Theme.secondaryBackground, for: .automatic)
        .onAppear {
            apiKey = SettingsManager.shared.geminiApiKey ?? ""
            showKey = !apiKey.isEmpty
            customPrompt = SettingsManager.shared.customPrompt ?? ""
            granularity = SettingsManager.shared.granularity
        }
        .alert("Clear All Data?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Everything", role: .destructive) {
                viewModel.clearAllData()
                dismiss()
            }
        } message: {
            Text("This will permanently delete all tasks, activities, screenshots, and learned memory. Your settings and API key will be kept. This cannot be undone.")
        }
    }

    private func hideSavedAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }
}
