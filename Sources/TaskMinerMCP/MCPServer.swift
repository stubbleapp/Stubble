import Foundation
import TaskMinerShared

/// MCP server that exposes Stubble data to AI agents via JSON-RPC over stdio.
public final class MCPServer: @unchecked Sendable {

    private let auth: MCPAuth
    private let rateLimiter: MCPRateLimiter
    private let auditLog: MCPAuditLog
    private var tools: MCPTools?
    private var isInitialized = false
    private var clientInfo: [String: String] = [:]

    // Protocol version
    private static let protocolVersion = "2024-11-05"
    private static let serverName = "stubble"
    private static let serverVersion = "1.0.0"

    public init(
        auth: MCPAuth = .shared,
        rateLimiter: MCPRateLimiter = .shared,
        auditLog: MCPAuditLog = .shared
    ) {
        self.auth = auth
        self.rateLimiter = rateLimiter
        self.auditLog = auditLog
    }

    /// Start the MCP server with stdio transport
    public func runStdio() async {
        // Initialize database reader and memory store
        guard let dbReader = await initializeDatabaseReader() else {
            await sendError(id: nil, error: .internalError)
            return
        }

        let memoryStore = initializeMemoryStore()
        self.tools = MCPTools(dbReader: dbReader, memoryStore: memoryStore)

        // Read from stdin, write to stdout
        let output = FileHandle.standardOutput

        while true {
            guard let line = readLine() else {
                // EOF - client disconnected
                break
            }

            guard !line.isEmpty else { continue }

            do {
                let response = try await handleRequest(line)
                if let response = response {
                    let jsonData = try JSONEncoder().encode(response)
                    output.write(jsonData)
                    output.write("\n".data(using: .utf8)!)
                }
            } catch {
                let errorResponse = JSONRPCResponse(
                    id: nil,
                    error: JSONRPCError(code: -32603, message: error.localizedDescription)
                )
                if let jsonData = try? JSONEncoder().encode(errorResponse) {
                    output.write(jsonData)
                    output.write("\n".data(using: .utf8)!)
                }
            }
        }
    }

    /// Handle a single JSON-RPC request
    private func handleRequest(_ jsonString: String) async throws -> JSONRPCResponse? {
        guard let data = jsonString.data(using: .utf8) else {
            return JSONRPCResponse(id: nil, error: .parseError)
        }

        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            return JSONRPCResponse(id: nil, error: .parseError)
        }

        // Check rate limit (except for initialize)
        if request.method != "initialize" && !rateLimiter.checkAndRecord() {
            auditLog.logRateLimited()
            return JSONRPCResponse(id: request.id, error: .rateLimited)
        }

        // Route request
        switch request.method {
        case "initialize":
            return handleInitialize(request)

        case "initialized":
            // Notification, no response
            return nil

        case "tools/list":
            return handleToolsList(request)

        case "tools/call":
            return await handleToolsCall(request)

        case "ping":
            return JSONRPCResponse(id: request.id, result: .object([:]))

        default:
            return JSONRPCResponse(id: request.id, error: .methodNotFound)
        }
    }

    // MARK: - MCP Method Handlers

    private func handleInitialize(_ request: JSONRPCRequest) -> JSONRPCResponse {
        // Validate API key from params
        if let params = request.params,
           let meta = params["_meta"]?.objectValue,
           let authHeader = meta["authorization"]?.stringValue {
            let key = authHeader.replacingOccurrences(of: "Bearer ", with: "")
            if !auth.validateKey(key) {
                auditLog.logAuthFailure(reason: "invalid_key")
                return JSONRPCResponse(id: request.id, error: .unauthorized)
            }
        } else {
            // Check environment variable as fallback
            if let envKey = ProcessInfo.processInfo.environment["STUBBLE_MCP_KEY"] {
                if !auth.validateKey(envKey) {
                    auditLog.logAuthFailure(reason: "invalid_env_key")
                    return JSONRPCResponse(id: request.id, error: .unauthorized)
                }
            }
            // If no key provided and no env var, we allow it for local development
            // In production, this should require a key
        }

        // Store client info
        if let params = request.params {
            if let clientInfo = params["clientInfo"]?.objectValue {
                if let name = clientInfo["name"]?.stringValue {
                    self.clientInfo["name"] = name
                }
                if let version = clientInfo["version"]?.stringValue {
                    self.clientInfo["version"] = version
                }
            }
        }

        isInitialized = true

        let result: [String: JSONValue] = [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": .object([
                "tools": .object([
                    "listChanged": .bool(false)
                ])
            ]),
            "serverInfo": .object([
                "name": .string(Self.serverName),
                "version": .string(Self.serverVersion)
            ])
        ]

        return JSONRPCResponse(id: request.id, result: .object(result))
    }

    private func handleToolsList(_ request: JSONRPCRequest) -> JSONRPCResponse {
        guard isInitialized else {
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32002, message: "Server not initialized"))
        }

        var toolsArray: [JSONValue] = []
        for tool in MCPTools.toolDefinitions {
            toolsArray.append(.object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "inputSchema": tool.inputSchema
            ]))
        }

        let result: [String: JSONValue] = [
            "tools": .array(toolsArray)
        ]

        return JSONRPCResponse(id: request.id, result: .object(result))
    }

    private func handleToolsCall(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        guard isInitialized else {
            return JSONRPCResponse(id: request.id, error: JSONRPCError(code: -32002, message: "Server not initialized"))
        }

        guard let tools = self.tools else {
            return JSONRPCResponse(id: request.id, error: .internalError)
        }

        guard let params = request.params,
              let toolName = params["name"]?.stringValue else {
            return JSONRPCResponse(id: request.id, error: .invalidParams)
        }

        let toolParams = params["arguments"]?.objectValue

        let startTime = Date()

        do {
            let result = try await tools.execute(tool: toolName, params: toolParams)

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

            // Count result rows (approximate from JSON)
            var rowCount: Int? = nil
            if let text = result.content.first?.text,
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let count = json["count"] as? Int {
                    rowCount = count
                }
            }

            auditLog.logToolCall(
                tool: toolName,
                params: toolParams,
                resultRows: rowCount,
                durationMs: durationMs
            )

            // Format MCP response
            var contentArray: [JSONValue] = []
            for content in result.content {
                contentArray.append(.object([
                    "type": .string(content.type),
                    "text": .string(content.text ?? "")
                ]))
            }

            let resultValue: [String: JSONValue] = [
                "content": .array(contentArray)
            ]

            return JSONRPCResponse(id: request.id, result: .object(resultValue))

        } catch let error as MCPError {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            auditLog.logToolCall(
                tool: toolName,
                params: toolParams,
                resultRows: nil,
                durationMs: durationMs,
                error: error.localizedDescription
            )

            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(code: -32602, message: error.localizedDescription)
            )

        } catch {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            auditLog.logToolCall(
                tool: toolName,
                params: toolParams,
                resultRows: nil,
                durationMs: durationMs,
                error: error.localizedDescription
            )

            return JSONRPCResponse(
                id: request.id,
                error: JSONRPCError(code: -32603, message: "Internal error: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - Initialization

    @MainActor
    private func initializeDatabaseReader() -> DatabaseReader? {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stubbleDir = supportDir.appendingPathComponent("Stubble")
        let dbPath = stubbleDir.appendingPathComponent("stubble.db")

        do {
            return try DatabaseReader(path: dbPath)
        } catch {
            Logger.error("MCPServer: Failed to open database: \(error)")
            return nil
        }
    }

    private func initializeMemoryStore() -> UserMemoryStore {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let stubbleDir = supportDir.appendingPathComponent("Stubble")
        let memoryPath = stubbleDir.appendingPathComponent("memory.json")
        return UserMemoryStore(filePath: memoryPath)
    }

    private func sendError(id: RequestID?, error: JSONRPCError) async {
        let response = JSONRPCResponse(id: id, error: error)
        if let data = try? JSONEncoder().encode(response) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        }
    }
}
