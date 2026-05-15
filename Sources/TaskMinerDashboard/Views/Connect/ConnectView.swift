import SwiftUI
import TaskMinerShared
import TaskMinerMCP

/// The Connect tab allowing users to connect AI tools to Stubble via MCP.
struct ConnectView: View {
    @Environment(DashboardViewModel.self) var viewModel
    @State private var mcpEnabled: Bool = false
    @State private var mcpKey: String? = nil
    @State private var connectedClients: [MCPClient] = []
    @State private var expandedTool: String? = nil
    @State private var pollTimer: Timer? = nil
    @State private var showCopiedKeyFeedback: Bool = false
    @State private var showCopiedConfigFeedback: Bool = false
    @State private var otherClientsExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                    .padding(.horizontal, 24)
                    .padding(.top, 20)

                if mcpEnabled {
                    toolsSection
                        .padding(.horizontal, 24)

                    otherClientsSection
                        .padding(.horizontal, 24)
                } else {
                    disabledState
                        .padding(.horizontal, 24)
                }

                Spacer().frame(height: 100)
            }
        }
        .background(Theme.primaryBackground)
        .onAppear {
            loadState()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect")
                    .font(Theme.headerFont(size: 24))
                    .foregroundStyle(Theme.textPrimary)

                Text("Connect AI tools to access your activity data")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $mcpEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .onChange(of: mcpEnabled) { _, newValue in
                    SettingsManager.shared.mcpEnabled = newValue
                    if newValue {
                        loadMCPKey()
                    } else {
                        mcpKey = nil
                    }
                }
        }
    }

    // MARK: - Tools Section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AI Tools")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            ForEach(ConnectToolConfig.allTools) { config in
                let matchingClient = findMatchingClient(for: config)
                ConnectToolCard(
                    config: config,
                    client: matchingClient,
                    apiKey: mcpKey,
                    expandedTool: $expandedTool
                )
            }
        }
    }

    // MARK: - Other Clients Section

    private var otherClientsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Collapsible header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    otherClientsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: otherClientsExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 12)

                    Text("Other MCP Clients")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if otherClientsExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    // API Key display
                    if let key = mcpKey {
                        HStack(spacing: 12) {
                            Text("Your API Key:")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)

                            Text(maskedKey(key))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary)
                                .textSelection(.enabled)

                            Spacer()

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(key, forType: .string)
                                showCopiedKeyFeedback = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    showCopiedKeyFeedback = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showCopiedKeyFeedback ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10))
                                    Text(showCopiedKeyFeedback ? "Copied!" : "Copy Key")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(showCopiedKeyFeedback ? Theme.statusActive : Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }

                        Divider()

                        // Generic config
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Generic MCP configuration (for stdio-based clients):")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)

                                Spacer()

                                Button {
                                    let config = ConnectToolConfig.genericConfig(apiKey: key)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(config, forType: .string)
                                    showCopiedConfigFeedback = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        showCopiedConfigFeedback = false
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: showCopiedConfigFeedback ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 10))
                                        Text(showCopiedConfigFeedback ? "Copied!" : "Copy Config")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(showCopiedConfigFeedback ? Theme.statusActive : Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }

                            ScrollView(.horizontal, showsIndicators: false) {
                                Text(ConnectToolConfig.genericConfig(apiKey: key))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .background(Theme.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }

                        // Unknown connected clients
                        let unknownClients = connectedClients.filter { client in
                            ConnectToolConfig.match(clientName: client.name) == nil
                        }

                        if !unknownClients.isEmpty {
                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Other Connected Clients:")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)

                                ForEach(unknownClients, id: \.name) { client in
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(client.isConnected ? Theme.statusActive : Theme.textMuted.opacity(0.4))
                                            .frame(width: 6, height: 6)

                                        Text(client.name)
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.textPrimary)

                                        if let version = client.version {
                                            Text("v\(version)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(Theme.textMuted)
                                        }

                                        Spacer()

                                        Text("\(client.totalCalls) calls")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textMuted)

                                        Text(client.lastSeenDescription)
                                            .font(.system(size: 10))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                            }
                        }

                        Divider()

                        // Documentation link
                        Link(destination: URL(string: "https://stubble.ai/mcp")!) {
                            HStack(spacing: 6) {
                                Image(systemName: "book")
                                    .font(.system(size: 11))
                                Text("View Documentation")
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.cardBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Disabled State

    private var disabledState: some View {
        VStack(spacing: 16) {
            Image(systemName: "link.circle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textMuted)

            VStack(spacing: 8) {
                Text("AI Agent Access Disabled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Enable AI agent access to connect tools like Claude Code and Cursor to your Stubble activity data via the MCP protocol.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            Button {
                withAnimation {
                    mcpEnabled = true
                    SettingsManager.shared.mcpEnabled = true
                    loadMCPKey()
                }
            } label: {
                Text("Enable AI Access")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Privacy note
            HStack(spacing: 6) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                Text("All data is sanitized before sharing. Secrets and sensitive info are redacted.")
                    .font(.system(size: 11))
            }
            .foregroundStyle(Theme.textMuted)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Helpers

    private func loadState() {
        mcpEnabled = SettingsManager.shared.mcpEnabled
        if mcpEnabled {
            loadMCPKey()
            loadConnectedClients()
        }
    }

    private func loadMCPKey() {
        mcpKey = MCPAuth.shared.getKey()
    }

    private func loadConnectedClients() {
        connectedClients = MCPAuditLog.shared.loadConnectedClients()
    }

    private func startPolling() {
        // Poll every 30 seconds for updated client info
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            if mcpEnabled {
                loadConnectedClients()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func findMatchingClient(for config: ConnectToolConfig) -> MCPClient? {
        // Don't match clients for coming-soon tools
        guard !config.comingSoon else { return nil }

        return connectedClients.first { client in
            ConnectToolConfig.match(clientName: client.name)?.name == config.name
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 16 else { return key }
        let prefix = String(key.prefix(12))
        let suffix = String(key.suffix(4))
        return "\(prefix)****\(suffix)"
    }
}
