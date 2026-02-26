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
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var synthesizedProfile: String = ""
    @State private var showMemorySection = false
    @State private var newMemoryContent: String = ""
    @State private var newMemoryCategory: MemoryCategory = .workflow

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

                // Memory / Learned Context
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showMemorySection.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Learned Context")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text("\(memoryEntries.count) facts")
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                            Image(systemName: showMemorySection ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    .buttonStyle(.plain)

                    if showMemorySection {
                        memoryManagementContent
                    } else {
                        Text("Facts Stubble has learned about you from activity and chat. Used to personalize AI responses.")
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
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
            loadMemoryEntries()
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

    // MARK: - Memory Management

    private var memoryManagementContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Synthesized profile
            if !synthesizedProfile.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Synthesized Profile")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(synthesizedProfile)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Entries grouped by category
            let grouped = Dictionary(grouping: memoryEntries, by: \.category)
            let categoryOrder: [MemoryCategory] = [.identity, .project, .technology, .workflow, .interest]

            ForEach(categoryOrder, id: \.self) { category in
                if let items = grouped[category], !items.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(categoryLabel(category))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)

                        ForEach(items) { entry in
                            HStack(alignment: .top, spacing: 6) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.content)
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textPrimary)
                                    HStack(spacing: 8) {
                                        Text(sourceLabel(entry.source))
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.textMuted)
                                        if entry.reinforcementCount > 1 {
                                            Text("seen \(entry.reinforcementCount)x")
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.textMuted)
                                        }
                                        Text(relativeDate(entry.lastSeen))
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                                Spacer()
                                Button {
                                    deleteMemoryEntry(id: entry.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.textMuted)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }

            // Add manual entry
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a fact")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    Picker("", selection: $newMemoryCategory) {
                        ForEach(MemoryCategory.allCases, id: \.self) { cat in
                            Text(categoryLabel(cat)).tag(cat)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)

                    TextField("e.g. Works as a product manager at Acme", text: $newMemoryContent)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .padding(6)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                    Button {
                        addManualEntry()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 24, height: 24)
                            .background(Theme.surfaceElevated)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func loadMemoryEntries() {
        memoryEntries = viewModel.memoryStore.load()
        synthesizedProfile = viewModel.memoryStore.loadProfile() ?? ""
    }

    private func deleteMemoryEntry(id: UUID) {
        viewModel.memoryStore.delete(id: id)
        loadMemoryEntries()
    }

    private func addManualEntry() {
        let trimmed = newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = MemoryEntry(
            category: newMemoryCategory,
            content: trimmed,
            confidence: 1.0,
            source: .userExplicit
        )
        viewModel.memoryStore.mergeStructured(newEntries: [entry])
        newMemoryContent = ""
        loadMemoryEntries()
    }

    private func categoryLabel(_ category: MemoryCategory) -> String {
        switch category {
        case .identity: return "Identity"
        case .project: return "Projects"
        case .technology: return "Technology"
        case .workflow: return "Workflow"
        case .interest: return "Interests"
        }
    }

    private func sourceLabel(_ source: MemorySource) -> String {
        switch source {
        case .activityInference: return "observed"
        case .chatInteraction: return "from chat"
        case .userExplicit: return "manual"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let days = Int(-date.timeIntervalSinceNow / 86400)
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }

    private func hideSavedAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }
}
