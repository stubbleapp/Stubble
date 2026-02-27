import SwiftUI
import TaskMinerShared

// MARK: - Settings Category

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case exclusions
    case personalisation
    case data

    var id: Self { self }

    var label: String {
        switch self {
        case .general: return "General"
        case .exclusions: return "Exclusions"
        case .personalisation: return "Personalisation"
        case .data: return "Data"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .exclusions: return "eye.slash"
        case .personalisation: return "person"
        case .data: return "externaldrive"
        }
    }
}

// MARK: - Away Duration Options

private enum AwayDuration: Int, CaseIterable, Identifiable {
    case five = 5
    case fifteen = 15
    case thirty = 30
    case fortyFive = 45
    case sixty = 60

    var id: Int { rawValue }

    var label: String { "\(rawValue) min" }
}

// MARK: - Settings View

struct SettingsView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedCategory: SettingsCategory? = .general

    // General
    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var customPrompt: String = ""
    @State private var granularity: TaskGranularity = .medium
    @State private var minAwayMinutes: Int = 15
    @State private var appearanceMode: AppearanceMode = .system

    // Exclusions
    @State private var exclusions: [String] = []
    @State private var newExclusion: String = ""

    // Personalisation
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var synthesizedProfile: String = ""
    @State private var newMemoryContent: String = ""
    @State private var newMemoryCategory: MemoryCategory = .workflow

    // Data
    @State private var showClearConfirmation = false

    // Save
    @State private var saved = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsCategory.allCases) { category in
                    let isSelected = (selectedCategory ?? .general) == category
                    Button {
                        selectedCategory = category
                    } label: {
                        Label(category.label, systemImage: category.icon)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Theme.selectedSurface : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 170)

            Divider()

            // Detail pane
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch selectedCategory ?? .general {
                    case .general:
                        generalPane
                    case .exclusions:
                        exclusionsPane
                    case .personalisation:
                        personalisationPane
                    case .data:
                        dataPane
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                HStack(spacing: 8) {
                    if saved {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("Saved")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Theme.statusActive)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }

                    Button {
                        saveAll()
                    } label: {
                        Text("Save")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .modifier(LiquidGlassPillModifier())
                }
                .animation(.easeInOut(duration: 0.2), value: saved)
            }
        }
        .background(Theme.primaryBackground)
        .frame(width: 620, height: 480)
        .onAppear { loadAll() }
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

    // MARK: - Load & Save

    private func loadAll() {
        apiKey = SettingsManager.shared.geminiApiKey ?? ""
        customPrompt = SettingsManager.shared.customPrompt ?? ""
        granularity = SettingsManager.shared.granularity
        minAwayMinutes = SettingsManager.shared.minAwayMinutes
        appearanceMode = SettingsManager.shared.appearanceMode
        exclusions = SettingsManager.shared.exclusions
        loadMemoryEntries()
    }

    private func saveAll() {
        viewModel.updateGeminiKey(apiKey)
        let trimmedPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        SettingsManager.shared.customPrompt = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        SettingsManager.shared.granularity = granularity
        SettingsManager.shared.minAwayMinutes = minAwayMinutes
        SettingsManager.shared.appearanceMode = appearanceMode
        SettingsManager.shared.exclusions = exclusions
        NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
        showSavedIndicator()
    }

    private func showSavedIndicator() {
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }

    // MARK: - General Pane

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Appearance
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                appearanceMode = mode
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: appearanceIcon(mode))
                                    .font(.system(size: 10))
                                Text(mode.displayName)
                                    .font(.system(size: 12, weight: appearanceMode == mode ? .semibold : .regular))
                            }
                            .foregroundStyle(appearanceMode == mode ? Theme.textPrimary : Theme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(appearanceMode == mode ? Theme.selectedSurface : Color.clear)
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
            }

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

            // Minimum Away Duration
            VStack(alignment: .leading, spacing: 8) {
                Text("Minimum Away Duration")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)

                HStack(spacing: 0) {
                    ForEach(AwayDuration.allCases) { duration in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                minAwayMinutes = duration.rawValue
                            }
                        } label: {
                            Text(duration.label)
                                .font(.system(size: 12, weight: minAwayMinutes == duration.rawValue ? .semibold : .regular))
                                .foregroundStyle(minAwayMinutes == duration.rawValue ? Theme.textPrimary : Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(minAwayMinutes == duration.rawValue ? Theme.selectedSurface : Color.clear)
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
                .accessibilityIdentifier("settings-min-away")

                Text("Away periods shorter than this are hidden in the timeline. Tasks are generated per work session separated by these breaks.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textMuted)
            }

            // Custom Instructions
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
        }
    }

    // MARK: - Exclusions Pane

    private var exclusionsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Content Exclusions")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            Text("Activity matching these rules will be silently excluded from tasks and summaries.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            // Current exclusion rules
            VStack(spacing: 6) {
                ForEach(Array(exclusions.enumerated()), id: \.offset) { index, rule in
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 20)

                        Text(rule)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                _ = exclusions.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textMuted)
                                .frame(width: 20, height: 20)
                                .background(Theme.surfaceElevated)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }

            // Add new exclusion
            HStack(spacing: 8) {
                TextField("e.g. Exclude social media browsing", text: $newExclusion)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onSubmit { addExclusion() }

                Button {
                    addExclusion()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.surfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(newExclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            exclusions.append(trimmed)
        }
        newExclusion = ""
    }

    // MARK: - Personalisation Pane

    private var personalisationPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Learned Context")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(memoryEntries.count) facts")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }

            Text("Facts Stubble has learned about you from activity and chat. Used to personalize AI responses.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            memoryManagementContent
        }
    }

    // MARK: - Data Pane

    private var dataPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Data Management")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Memory Helpers

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

    private func appearanceIcon(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}
