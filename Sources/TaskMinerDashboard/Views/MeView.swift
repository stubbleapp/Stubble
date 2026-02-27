import SwiftUI
import TaskMinerShared

struct MeView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var memoryEntries: [MemoryEntry] = []
    @State private var synthesizedProfile: String = ""
    @State private var newMemoryContent: String = ""
    @State private var newMemoryCategory: MemoryCategory = .workflow

    private let categoryOrder: [MemoryCategory] = [.identity, .project, .technology, .workflow, .interest]

    private var grouped: [MemoryCategory: [MemoryEntry]] {
        Dictionary(grouping: memoryEntries, by: \.category)
    }

    var body: some View {
        if memoryEntries.isEmpty && synthesizedProfile.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    headerSection
                        .padding(.horizontal, 24)
                        .padding(.top, 20)
                        .padding(.bottom, 16)

                    // Profile card
                    if !synthesizedProfile.isEmpty {
                        profileCard
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }

                    // Category sections
                    ForEach(categoryOrder, id: \.self) { category in
                        if let items = grouped[category], !items.isEmpty {
                            categorySection(category: category, entries: items)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }
                    }

                    // Add a fact
                    addFactSection
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)

                    // Stats footer
                    if !memoryEntries.isEmpty {
                        statsFooter
                            .padding(.horizontal, 24)
                            .padding(.bottom, 16)
                    }

                    Spacer().frame(height: 80)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                Text("Stubble hasn\u{2019}t learned anything yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)

                Text("Use the app for a while and it will pick up\non your projects, tools, and workflows.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textQuaternary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }
            Spacer()
        }
        .onAppear { loadMemory() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Profile")
                .font(Theme.headerFont(size: 24))
                .foregroundStyle(Theme.textPrimary)

            Text("Here\u{2019}s what Stubble knows about you")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
        }
        .onAppear { loadMemory() }
    }

    // MARK: - Profile Card

    private var profileCard: some View {
        Text(synthesizedProfile)
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
            )
    }

    // MARK: - Category Section

    private func categorySection(category: MemoryCategory, entries: [MemoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(categoryLabel(category))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 2)

            ForEach(entries) { entry in
                MemoryEntryRow(entry: entry) {
                    deleteEntry(id: entry.id)
                }
            }
        }
    }

    // MARK: - Add Fact

    private var addFactSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add a fact")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            HStack(spacing: 8) {
                Picker("", selection: $newMemoryCategory) {
                    ForEach(MemoryCategory.allCases, id: \.self) { cat in
                        Text(categoryLabel(cat)).tag(cat)
                    }
                }
                .labelsHidden()
                .frame(width: 110)

                TextField("e.g. Works as a product manager at Acme", text: $newMemoryContent)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Theme.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button(action: addManualEntry) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 28, height: 28)
                        .background(Theme.accent.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(newMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Stats Footer

    private var statsFooter: some View {
        HStack {
            Spacer()
            Text("\(memoryEntries.count) facts learned")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer()
        }
    }

    // MARK: - Actions

    private func loadMemory() {
        memoryEntries = viewModel.memoryStore.load()
        synthesizedProfile = Self.cleanProfileText(viewModel.memoryStore.loadProfile() ?? "")
    }

    /// Strip common AI artifacts: wrapping quotes, brackets, markdown fences.
    private static func cleanProfileText(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove wrapping quotes
        if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("\u{201C}") && s.hasSuffix("\u{201D}")) {
            s = String(s.dropFirst().dropLast())
        }
        // Remove wrapping brackets
        if (s.hasPrefix("[") && s.hasSuffix("]")) || (s.hasPrefix("{") && s.hasSuffix("}")) {
            s = String(s.dropFirst().dropLast())
        }
        // Remove markdown code fences
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```", with: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deleteEntry(id: UUID) {
        viewModel.memoryStore.delete(id: id)
        loadMemory()
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
        loadMemory()
    }

    // MARK: - Helpers

    private func categoryLabel(_ category: MemoryCategory) -> String {
        switch category {
        case .identity: return "Identity"
        case .project: return "Projects"
        case .technology: return "Technology"
        case .workflow: return "Workflow"
        case .interest: return "Interests"
        }
    }
}

// MARK: - Memory Entry Row

private struct MemoryEntryRow: View {
    let entry: MemoryEntry
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(sourceLabel(entry.source))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)

                    if entry.reinforcementCount > 1 {
                        Text("seen \(entry.reinforcementCount)x")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }

                    Text(relativeDate(entry.lastSeen))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textQuaternary)
                }
            }

            Spacer()

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.textMuted.opacity(0.6))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func sourceLabel(_ source: MemorySource) -> String {
        switch source {
        case .activityInference: return "Observed"
        case .chatInteraction: return "From chat"
        case .userExplicit: return "Added by you"
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let days = Int(-date.timeIntervalSinceNow / 86400)
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}
