import Foundation

/// How to configure MCP for this tool.
enum MCPConfigMethod {
    case cliCommand      // Use CLI command (Claude Code)
    case configFile      // Edit config file (Cursor, Windsurf, etc.)
    case mcpbFile        // Install via MCPB extension file (Claude Desktop)
}

/// Configuration for a known MCP-compatible AI tool.
struct ConnectToolConfig: Identifiable {
    var id: String { name }
    let name: String
    let iconName: String          // Name of PNG in ConnectIcons folder (without extension)
    let fallbackSFSymbol: String  // SF Symbol fallback if image not found
    let description: String
    let configMethod: MCPConfigMethod
    let configPath: String?
    let cliCommand: ((String) -> String)?
    let configTemplate: ((String) -> String)?
    let docsURL: URL?
    let comingSoon: Bool

    /// Claude Code (CLI) configuration - uses `claude mcp add-json` command
    static let claudeCode = ConnectToolConfig(
        name: "Claude Code",
        iconName: "claude",
        fallbackSFSymbol: "terminal",
        description: "Anthropic's CLI for developers",
        configMethod: .cliCommand,
        configPath: nil,
        cliCommand: { apiKey in
            """
            claude mcp add-json stubble '{"type":"stdio","command":"/Applications/Stubble.app/Contents/MacOS/stubble-mcp","env":{"STUBBLE_MCP_KEY":"\(apiKey)"}}' --scope user
            """
        },
        configTemplate: { apiKey in
            """
            {"type":"stdio","command":"/Applications/Stubble.app/Contents/MacOS/stubble-mcp","env":{"STUBBLE_MCP_KEY":"\(apiKey)"}}
            """
        },
        docsURL: URL(string: "https://code.claude.com/docs/en/mcp"),
        comingSoon: false
    )

    /// Claude Desktop - uses MCPB extension file for easy installation
    static let claudeDesktop = ConnectToolConfig(
        name: "Claude Desktop",
        iconName: "claude",
        fallbackSFSymbol: "message",
        description: "Anthropic's desktop app",
        configMethod: .mcpbFile,
        configPath: nil,
        cliCommand: nil,
        configTemplate: nil,
        docsURL: URL(string: "https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop"),
        comingSoon: false
    )

    /// Cursor IDE configuration - uses config file
    static let cursor = ConnectToolConfig(
        name: "Cursor",
        iconName: "cursor",
        fallbackSFSymbol: "cursorarrow.and.square.on.square.dashed",
        description: "AI-powered code editor",
        configMethod: .configFile,
        configPath: "~/.cursor/mcp.json",
        cliCommand: nil,
        configTemplate: { apiKey in
            """
            {
              "mcpServers": {
                "stubble": {
                  "command": "/Applications/Stubble.app/Contents/MacOS/stubble-mcp",
                  "env": {
                    "STUBBLE_MCP_KEY": "\(apiKey)"
                  }
                }
              }
            }
            """
        },
        docsURL: URL(string: "https://docs.cursor.com/context/model-context-protocol"),
        comingSoon: false
    )

    /// Windsurf IDE configuration - uses config file
    static let windsurf = ConnectToolConfig(
        name: "Windsurf",
        iconName: "windsurf",
        fallbackSFSymbol: "wind",
        description: "Codeium's AI IDE",
        configMethod: .configFile,
        configPath: "~/.codeium/windsurf/mcp_config.json",
        cliCommand: nil,
        configTemplate: { apiKey in
            """
            {
              "mcpServers": {
                "stubble": {
                  "command": "/Applications/Stubble.app/Contents/MacOS/stubble-mcp",
                  "env": {
                    "STUBBLE_MCP_KEY": "\(apiKey)"
                  }
                }
              }
            }
            """
        },
        docsURL: URL(string: "https://docs.codeium.com/windsurf/mcp"),
        comingSoon: false
    )

    /// GitHub Copilot (VS Code) configuration - uses .vscode/mcp.json
    static let githubCopilot = ConnectToolConfig(
        name: "GitHub Copilot",
        iconName: "github-copilot",
        fallbackSFSymbol: "chevron.left.forwardslash.chevron.right",
        description: "AI pair programmer in VS Code",
        configMethod: .configFile,
        configPath: ".vscode/mcp.json",
        cliCommand: nil,
        configTemplate: { apiKey in
            """
            {
              "servers": {
                "stubble": {
                  "type": "stdio",
                  "command": "/Applications/Stubble.app/Contents/MacOS/stubble-mcp",
                  "env": {
                    "STUBBLE_MCP_KEY": "\(apiKey)"
                  }
                }
              }
            }
            """
        },
        docsURL: URL(string: "https://code.visualstudio.com/docs/copilot/customization/mcp-servers"),
        comingSoon: false
    )

    /// All known tools
    static let allTools: [ConnectToolConfig] = [claudeCode, claudeDesktop, githubCopilot, cursor, windsurf]

    /// Generic MCP configuration for other stdio-based clients
    static func genericConfig(apiKey: String) -> String {
        """
        {
          "type": "stdio",
          "command": "/Applications/Stubble.app/Contents/MacOS/stubble-mcp",
          "env": {
            "STUBBLE_MCP_KEY": "\(apiKey)"
          }
        }
        """
    }

    /// Match a client name to a known tool config.
    static func match(clientName: String) -> ConnectToolConfig? {
        let normalized = clientName.lowercased()

        if normalized.contains("claude") && normalized.contains("code") {
            return .claudeCode
        }
        if normalized.contains("claude") && normalized.contains("desktop") {
            return .claudeDesktop
        }
        if normalized.contains("claude") {
            return .claudeDesktop
        }
        if normalized.contains("cursor") {
            return .cursor
        }
        if normalized.contains("windsurf") || normalized.contains("codeium") {
            return .windsurf
        }
        if normalized.contains("github") || normalized.contains("copilot") || normalized.contains("vscode") || normalized.contains("vs code") {
            return .githubCopilot
        }

        return nil
    }
}
