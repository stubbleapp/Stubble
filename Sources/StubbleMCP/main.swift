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
        if let newKey = MCPAuth.shared.rotateKey() {
            print("New API Key: \(newKey)")
            print("\nAll existing agent connections have been invalidated.")
            print("Update your MCP client config with the new key.")
        } else {
            print("Error: Could not rotate API key")
        }
    }
}
