import SwiftUI
import TaskMinerShared

struct SettingsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) var dismiss
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var saved = false
    @State private var customPrompt: String = ""
    @State private var memoryEntries: [MemoryEntry] = []

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

                    // Memory
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Memory")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)

                            Spacer()

                            if !memoryEntries.isEmpty {
                                Text("\(memoryEntries.count) items")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }

                        if memoryEntries.isEmpty {
                            Text("No memories yet. The AI will learn about your projects and habits as you generate summaries.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                                .cornerRadius(6)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(memoryEntries) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.content)
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                viewModel.memoryStore.delete(id: entry.id)
                                                memoryEntries.removeAll { $0.id == entry.id }
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .medium))
                                                .foregroundStyle(Theme.textMuted)
                                                .frame(width: 18, height: 18)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)

                                    if entry.id != memoryEntries.last?.id {
                                        Rectangle()
                                            .fill(Theme.separator.opacity(0.5))
                                            .frame(height: 0.5)
                                            .padding(.leading, 10)
                                    }
                                }
                            }
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)

                            Button {
                                viewModel.memoryStore.save([])
                                withAnimation { memoryEntries = [] }
                            } label: {
                                Text("Clear All")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.statusError.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }

                        Text("Learned automatically from your activity. Used to improve task accuracy and consistency across sessions.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
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
        .frame(width: 480, height: 520)
        .background(.ultraThinMaterial)
        .onAppear {
            apiKey = GeminiKeychain.get() ?? ""
            showKey = !apiKey.isEmpty
            customPrompt = SettingsManager.shared.customPrompt ?? ""
            memoryEntries = viewModel.memoryStore.load()
        }
    }

    private func hideSavedAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }
}
