import Foundation
import TaskMinerMCP

/// Entry point for the stubble-mcp executable.
/// Runs the MCP server with stdio transport for AI agent connections.
@main
struct StubbleMCPMain {
    static func main() async {
        // Parse command line arguments
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return
        }

        if args.contains("--version") || args.contains("-v") {
            print("stubble-mcp 1.0.0")
            return
        }

        if args.contains("--show-key") {
            showKey()
            return
        }

        if args.contains("--rotate-key") {
            rotateKey()
            return
        }

        // Check if MCP is enabled before starting server
        guard isMCPEnabled() else {
            printDisabledMessage()
            return
        }

        // Default: run MCP server with stdio
        let server = MCPServer()
        await server.runStdio()
    }

    static func printUsage() {
        print("""
        stubble-mcp - MCP server for Stubble data access

        USAGE:
            stubble-mcp [OPTIONS]

        OPTIONS:
            --help, -h        Show this help message
            --version, -v     Show version
            --show-key        Display the current API key
            --rotate-key      Generate a new API key (invalidates existing)

        ENVIRONMENT:
            STUBBLE_MCP_KEY   API key for authentication (optional in stdio mode)

        STDIO MODE:
            By default, stubble-mcp runs in stdio mode for use with AI agents.
            Connect via MCP client configuration:

            {
              "stubble": {
                "command": "/path/to/stubble-mcp",
                "args": []
              }
            }

        AVAILABLE TOOLS:
            query_tasks         Get AI-generated task summaries
            get_activity_log    Get raw activity records
            search_activities   Search activities by content
            get_projects        Get project summaries
            get_timeline        Get day timeline (tasks + away periods)
            get_day_summary     Get day summary and stats
            get_user_profile    Get user's learned profile
        """)
    }

    static func showKey() {
        guard isMCPEnabled() else {
            printDisabledMessage()
            return
        }

        if let key = MCPAuth.shared.getKey() {
            print("API Key: \(key)")
            print("\nAdd to your MCP client config:")
            print("""
            {
              "stubble": {
                "command": "/path/to/stubble-mcp",
                "env": {
                  "STUBBLE_MCP_KEY": "\(key)"
                }
              }
            }
            """)
        } else {
            print("Error: Could not generate API key")
        }
    }

    static func rotateKey() {
        guard isMCPEnabled() else {
            printDisabledMessage()
            return
        }

        if let newKey = MCPAuth.shared.rotateKey() {
            print("New API Key: \(newKey)")
            print("\nAll existing agent connections have been invalidated.")
            print("Update your MCP client config with the new key.")
        } else {
            print("Error: Could not rotate API key")
        }
    }

    /// Check if MCP is enabled in settings.
    static func isMCPEnabled() -> Bool {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let settingsPath = supportDir.appendingPathComponent("Stubble/settings.json")

        guard FileManager.default.fileExists(atPath: settingsPath.path) else {
            return false
        }

        do {
            let data = try Data(contentsOf: settingsPath)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mcpEnabled = json["mcpEnabled"] as? Bool {
                return mcpEnabled
            }
            return false
        } catch {
            return false
        }
    }

    static func printDisabledMessage() {
        print("""
        MCP access is disabled.

        To enable AI agent access to your Stubble data:
        1. Open Stubble
        2. Go to Settings → Data
        3. Enable "Allow AI agents to access activity data"

        Then run this command again to get your API key.
        """)
    }
}
