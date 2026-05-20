import SwiftUI
import AppKit
import TaskMinerShared

/// A card showing a single AI tool with its connection status and setup instructions.
struct ConnectToolCard: View {
    let config: ConnectToolConfig
    let client: MCPClient?
    let apiKey: String?
    @Binding var expandedTool: String?
    @State private var configFileExists: Bool = false
    @State private var showCopiedFeedback: Bool = false

    private var isConnected: Bool {
        client?.isConnected ?? false
    }

    private var isExpanded: Bool {
        expandedTool == config.name
    }

    /// Load the tool icon from the bundle's ConnectIcons folder
    private var toolIcon: NSImage? {
        if let iconURL = Bundle.main.url(forResource: config.iconName, withExtension: "png", subdirectory: "ConnectIcons"),
           let image = NSImage(contentsOf: iconURL) {
            return image
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedTool = isExpanded ? nil : config.name
                }
                if config.configMethod == .configFile {
                    checkConfigFileExists()
                }
            } label: {
                HStack(spacing: 12) {
                    // Icon - use PNG from bundle, fallback to SF Symbol
                    if let nsImage = toolIcon {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.surfaceElevated)
                            )
                    } else {
                        Image(systemName: config.fallbackSFSymbol)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(iconColor)
                            .frame(width: 32, height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(iconBackgroundColor)
                            )
                    }

                    // Name and description
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(config.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)

                            if config.comingSoon {
                                Text("Coming Soon")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.8))
                                    .clipShape(Capsule())
                            }
                        }

                        Text(config.description)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }

                    Spacer()

                    // Status badge
                    if !config.comingSoon {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isConnected ? Theme.statusActive : Theme.textMuted.opacity(0.4))
                                .frame(width: 6, height: 6)

                            if isConnected {
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text("Connected")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Theme.statusActive)

                                    if let calls = client?.totalCalls, calls > 0 {
                                        Text("\(calls) API call\(calls == 1 ? "" : "s")")
                                            .font(.system(size: 9))
                                            .foregroundStyle(Theme.textMuted)
                                    }
                                }
                            } else {
                                Text("Not Connected")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }

                    // Chevron
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.textQuaternary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded instructions
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    if config.comingSoon {
                        comingSoonContent
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    } else {
                        setupInstructions
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeInOut(duration: 0.15).delay(0.05)),
                    removal: .opacity.animation(.easeInOut(duration: 0.1))
                ))
            }
        }
        .clipped()
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
        )
        .onAppear {
            if config.configMethod == .configFile {
                checkConfigFileExists()
            }
        }
    }

    private var iconColor: Color {
        if config.comingSoon {
            return Theme.textMuted
        }
        return isConnected ? Theme.statusActive : Theme.textMuted
    }

    private var iconBackgroundColor: Color {
        if config.comingSoon {
            return Theme.surfaceElevated
        }
        return isConnected ? Theme.statusActive.opacity(0.1) : Theme.surfaceElevated
    }

    // MARK: - Coming Soon Content

    @ViewBuilder
    private var comingSoonContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.bottom, 4)

            Text("Coming soon...")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)

            if let docsURL = config.docsURL {
                Button {
                    NSWorkspace.shared.open(docsURL)
                } label: {
                    HStack(spacing: 4) {
                        Text("Learn More")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Setup Instructions

    @ViewBuilder
    private var setupInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .padding(.bottom, 4)

            Text("Setup Instructions")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            switch config.configMethod {
            case .cliCommand:
                cliInstructions
            case .configFile:
                fileInstructions
            case .mcpbFile:
                mcpbInstructions
            }

            // Last seen info (if connected)
            if let client = client, isConnected {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.statusActive)
                    Text("Last seen: \(client.lastSeenDescription)")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.top, 4)
            }

            // Documentation link
            if let docsURL = config.docsURL {
                Button {
                    NSWorkspace.shared.open(docsURL)
                } label: {
                    HStack(spacing: 4) {
                        Text("View Documentation")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - CLI Instructions (Claude Code)

    @ViewBuilder
    private var cliInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Step 1: Run command
            HStack(alignment: .top, spacing: 8) {
                Text("1.")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 16, alignment: .leading)

                Text("Run this command in your terminal:")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
            }

            if let key = apiKey, let cliCommand = config.cliCommand {
                cliCodeBlock(cliCommand(key))
            } else {
                Text("Enable MCP access to see the command")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .italic()
                    .padding(.leading, 24)
            }

            // Step 2: Restart
            HStack(spacing: 8) {
                Text("2.")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 16, alignment: .leading)

                Text("Restart \(config.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
            }

            // Verify step
            HStack(alignment: .top, spacing: 8) {
                Text("3.")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 16, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Verify with:")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)

                    Text("claude mcp list")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - File Instructions (Claude Desktop, Cursor, etc.)

    @ViewBuilder
    private var fileInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let configPath = config.configPath {
                // Step 1: Config file
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("1.")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 16, alignment: .leading)

                        VStack(alignment: .leading, spacing: 4) {
                            if configFileExists {
                                Text("Open your config file:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textPrimary)
                            } else {
                                Text("Create the config file:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textPrimary)

                                Text("This file doesn't exist yet. Click below to create it.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.textMuted)
                                    .italic()
                            }

                            HStack(spacing: 8) {
                                Text(configPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)

                                if configFileExists {
                                    Button {
                                        openConfigFile(configPath)
                                    } label: {
                                        Text("Open")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    Button {
                                        createConfigFile(configPath)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 9, weight: .bold))
                                            Text("Create")
                                                .font(.system(size: 10, weight: .medium))
                                        }
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Theme.accent)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // Step 2: Configuration JSON
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("2.")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 16, alignment: .leading)

                        Text(configFileExists ? "Replace the contents with:" : "The file will contain:")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary)
                    }

                    if let key = apiKey, let template = config.configTemplate {
                        configCodeBlock(template(key))
                    } else {
                        Text("Enable MCP access to see configuration")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .italic()
                            .padding(.leading, 24)
                    }
                }

                // Step 3: Restart
                HStack(spacing: 8) {
                    Text("3.")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 16, alignment: .leading)

                    Text("Restart \(config.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
        }
    }

    // MARK: - MCPB Instructions (Claude Desktop)

    @State private var isDownloading = false
    @State private var downloadComplete = false
    @State private var isDownloadingSkill = false
    @State private var skillDownloadComplete = false

    @ViewBuilder
    private var mcpbInstructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Step 1: Download extension
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text("1.")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 16, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Download the Stubble extension:")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary)

                        Button {
                            downloadMCPBExtension()
                        } label: {
                            HStack(spacing: 6) {
                                if isDownloading {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 11, height: 11)
                                } else {
                                    Image(systemName: downloadComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                                        .font(.system(size: 11))
                                }
                                Text(downloadComplete ? "Downloaded!" : (isDownloading ? "Downloading..." : "Download Extension"))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(downloadComplete ? Theme.statusActive : Theme.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isDownloading)

                        if downloadComplete {
                            Text("Saved to Downloads folder")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.statusActive)
                        }
                    }
                }
            }

            // Step 2: Install in Claude Desktop
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text("2.")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 16, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("In Claude Desktop:")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("• Go to Settings → Extensions")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                            Text("• Click \"Advanced settings\"")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                            Text("• In Extension Developer, click \"Install Extension...\"")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                            Text("• Select Stubble.mcpb from Downloads")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }

            // Step 3: Enter API key
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text("3.")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 16, alignment: .leading)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Enter your API key when prompted:")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textPrimary)

                        if let key = apiKey {
                            HStack(spacing: 8) {
                                Text(maskedKey(key))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.surfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(key, forType: .string)
                                    showCopiedFeedback = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        showCopiedFeedback = false
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                                            .font(.system(size: 9))
                                        Text(showCopiedFeedback ? "Copied!" : "Copy")
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                    .foregroundStyle(showCopiedFeedback ? Theme.statusActive : Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        } else {
                            Text("Enable MCP access to see your API key")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textMuted)
                                .italic()
                        }
                    }
                }
            }

            // Step 4: Enable extension
            HStack(alignment: .top, spacing: 8) {
                Text("4.")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 16, alignment: .leading)

                Text("Confirm the installation and click \"Enable Extension\"")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
            }

            Divider()
                .padding(.vertical, 4)

            // Skill download section
            VStack(alignment: .leading, spacing: 8) {
                Text("Optional: Install /stubble Skill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)

                Text("Generate beautiful visual timesheets from your activity data. Type /stubble in Claude Desktop after installing.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)

                HStack(spacing: 12) {
                    Button {
                        downloadSkill()
                    } label: {
                        HStack(spacing: 6) {
                            if isDownloadingSkill {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 11, height: 11)
                            } else {
                                Image(systemName: skillDownloadComplete ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 11))
                            }
                            Text(skillDownloadComplete ? "Downloaded!" : (isDownloadingSkill ? "Downloading..." : "Download Skill"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(skillDownloadComplete ? Theme.statusActive : Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(skillDownloadComplete ? Theme.statusActive : Theme.accent, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDownloadingSkill)

                    if skillDownloadComplete {
                        Text("Install via Settings → Skills in Claude Desktop")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.textMuted)
                    }
                }
            }
        }
    }

    private func maskedKey(_ key: String) -> String {
        guard key.count > 16 else { return key }
        let prefix = String(key.prefix(12))
        let suffix = String(key.suffix(4))
        return "\(prefix)****\(suffix)"
    }

    private func downloadMCPBExtension() {
        isDownloading = true
        downloadComplete = false

        let mcpbURL = URL(string: "https://github.com/stubbleapp/stubble-mcpb/releases/latest/download/Stubble.mcpb")!
        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let destinationURL = downloadsURL.appendingPathComponent("Stubble.mcpb")

        // Download in background
        URLSession.shared.downloadTask(with: mcpbURL) { tempURL, response, error in
            DispatchQueue.main.async {
                isDownloading = false

                guard let tempURL = tempURL, error == nil else {
                    // Fallback: open in browser
                    NSWorkspace.shared.open(mcpbURL)
                    return
                }

                do {
                    // Remove existing file if present
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    downloadComplete = true

                    // Reset after a few seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        downloadComplete = false
                    }
                } catch {
                    // Fallback: open in browser
                    NSWorkspace.shared.open(mcpbURL)
                }
            }
        }.resume()
    }

    private func downloadSkill() {
        isDownloadingSkill = true
        skillDownloadComplete = false

        let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let destinationURL = downloadsURL.appendingPathComponent("stubble.skill")

        // Try to copy from app bundle first
        if let bundledSkillURL = Bundle.main.url(forResource: "stubble", withExtension: "skill", subdirectory: "Skills") {
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: bundledSkillURL, to: destinationURL)
                isDownloadingSkill = false
                skillDownloadComplete = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    skillDownloadComplete = false
                }
                return
            } catch {
                // Fall through to remote download
            }
        }

        // Fallback: download from GitHub
        let skillURL = URL(string: "https://github.com/stubbleapp/stubble-releases/releases/latest/download/stubble.skill")!

        URLSession.shared.downloadTask(with: skillURL) { tempURL, response, error in
            DispatchQueue.main.async {
                isDownloadingSkill = false

                guard let tempURL = tempURL, error == nil else {
                    // Fallback: open in browser
                    NSWorkspace.shared.open(skillURL)
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    skillDownloadComplete = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        skillDownloadComplete = false
                    }
                } catch {
                    NSWorkspace.shared.open(skillURL)
                }
            }
        }.resume()
    }

    // MARK: - Code Blocks

    @ViewBuilder
    private func cliCodeBlock(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    showCopiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedFeedback = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(showCopiedFeedback ? "Copied!" : "Copy Command")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(showCopiedFeedback ? Theme.statusActive : Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.leading, 24)
    }

    @ViewBuilder
    private func configCodeBlock(_ code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    showCopiedFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedFeedback = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showCopiedFeedback ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9))
                        Text(showCopiedFeedback ? "Copied!" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(showCopiedFeedback ? Theme.statusActive : Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.leading, 24)
    }

    // MARK: - File Helpers

    private func checkConfigFileExists() {
        guard let path = config.configPath else {
            configFileExists = false
            return
        }
        let expandedPath = NSString(string: path).expandingTildeInPath
        configFileExists = FileManager.default.fileExists(atPath: expandedPath)
    }

    private func openConfigFile(_ path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)

        if FileManager.default.fileExists(atPath: expandedPath) {
            NSWorkspace.shared.open(url)
        } else {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    private func createConfigFile(_ path: String) {
        let expandedPath = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let parentDir = url.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            if let key = apiKey, let template = config.configTemplate {
                let content = template(key)
                try content.write(to: url, atomically: true, encoding: .utf8)
            } else {
                try "{}".write(to: url, atomically: true, encoding: .utf8)
            }

            configFileExists = true
            NSWorkspace.shared.open(url)
        } catch {
            NSWorkspace.shared.open(parentDir)
        }
    }
}
