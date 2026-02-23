import SwiftUI
import ServiceManagement
import TaskMinerShared

struct SettingsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @EnvironmentObject var updater: SoftwareUpdater
    @Environment(\.dismiss) var dismiss
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false
    @State private var customPrompt: String = ""
    @State private var granularity: TaskGranularity = .medium
    @State private var showScreensTab: Bool = false
    @State private var launchAtLogin: Bool = false

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
                        .background(.ultraThinMaterial)
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
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)

                            Button {
                                showKey.toggle()
                            } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textMuted)
                                    .frame(width: 28, height: 28)
                                    .background(.ultraThinMaterial)
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
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)

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
                                .fill(.ultraThinMaterial)
                        )

                        Text(granularity.description)
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }

                    // General
                    VStack(alignment: .leading, spacing: 8) {
                        Text("General")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)

                        Toggle(isOn: $launchAtLogin) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Launch at login")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Start Stubble automatically when you log in.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .onChange(of: launchAtLogin) { _, enabled in
                            SettingsManager.shared.launchAtLogin = enabled
                            if #available(macOS 13.0, *) {
                                do {
                                    if enabled {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    Logger.error("Failed to update login item: \(error.localizedDescription)")
                                }
                            }
                        }

                        CheckForUpdatesView(updater: updater)
                    }

                    // Views
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Views")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.textPrimary)

                        Toggle(isOn: $showScreensTab) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Show Screens tab")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                Text("Browse captured screenshots in a separate tab.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                    }

                    // Status + Save
                    HStack(spacing: 12) {
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
                            Button("Clear Key") {
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
                            let trimmed = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                            SettingsManager.shared.customPrompt = trimmed.isEmpty ? nil : trimmed
                            SettingsManager.shared.granularity = granularity
                            SettingsManager.shared.showScreensTab = showScreensTab
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
        .frame(width: 480, height: 600)
        .background(.ultraThinMaterial)
        .onAppear {
            apiKey = GeminiKeychain.get() ?? ""
            showKey = !apiKey.isEmpty
            customPrompt = SettingsManager.shared.customPrompt ?? ""
            granularity = SettingsManager.shared.granularity
            showScreensTab = SettingsManager.shared.showScreensTab
            launchAtLogin = SettingsManager.shared.launchAtLogin
        }
    }

    private func hideSavedAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }
}
