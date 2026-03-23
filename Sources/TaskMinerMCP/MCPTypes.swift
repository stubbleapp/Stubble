import Foundation

// MARK: - JSON-RPC 2.0 Types

/// JSON-RPC request envelope
public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let id: RequestID?
    public let method: String
    public let params: [String: JSONValue]?

    public init(method: String, params: [String: JSONValue]? = nil, id: RequestID? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// JSON-RPC response envelope
public struct JSONRPCResponse: Codable {
    public let jsonrpc: String
    public let id: RequestID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: RequestID?, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: RequestID?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

/// JSON-RPC error object
public struct JSONRPCError: Codable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC error codes
    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")

    // MCP-specific error codes
    public static let unauthorized = JSONRPCError(code: -32001, message: "Unauthorized")
    public static let rateLimited = JSONRPCError(code: -32002, message: "Rate limited")
}

/// Request ID can be string, number, or null
public enum RequestID: Codable, Equatable, Sendable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else {
            throw DecodingError.typeMismatch(
                RequestID.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected string or integer")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        }
    }
}

/// Generic JSON value for flexible params/results
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // Helper accessors
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// MARK: - MCP Protocol Types

/// MCP server capabilities
public struct MCPCapabilities: Codable {
    public let tools: ToolsCapability?

    public struct ToolsCapability: Codable {
        public let listChanged: Bool?
    }

    public static let standard = MCPCapabilities(tools: ToolsCapability(listChanged: false))
}

/// MCP server info returned on initialize
public struct MCPServerInfo: Codable {
    public let name: String
    public let version: String
}

/// MCP tool definition
public struct MCPTool: Codable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// MCP tool call result
public struct MCPToolResult: Codable {
    public let content: [MCPContent]
    public let isError: Bool?

    public init(text: String, isError: Bool = false) {
        self.content = [MCPContent(type: "text", text: text)]
        self.isError = isError ? true : nil
    }

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content
        self.isError = isError ? true : nil
    }
}

/// MCP content block
public struct MCPContent: Codable {
    public let type: String
    public let text: String?
    public let data: String?
    public let mimeType: String?

    public init(type: String, text: String) {
        self.type = type
        self.text = text
        self.data = nil
        self.mimeType = nil
    }
}

// MARK: - Tool Input Types

/// Input for query_tasks tool
struct QueryTasksInput: Codable {
    let date: String?
    let from: String?
    let to: String?
    let limit: Int?

    static func parse(from params: [String: JSONValue]?) -> QueryTasksInput {
        QueryTasksInput(
            date: params?["date"]?.stringValue,
            from: params?["from"]?.stringValue,
            to: params?["to"]?.stringValue,
            limit: params?["limit"]?.intValue
        )
    }
}

/// Input for get_activity_log tool
struct GetActivityLogInput: Codable {
    let date: String?
    let from: String?
    let to: String?
    let app: String?
    let includeIdle: Bool
    let limit: Int

    static func parse(from params: [String: JSONValue]?) -> GetActivityLogInput {
        GetActivityLogInput(
            date: params?["date"]?.stringValue,
            from: params?["from"]?.stringValue,
            to: params?["to"]?.stringValue,
            app: params?["app"]?.stringValue,
            includeIdle: params?["include_idle"]?.boolValue ?? true,
            limit: min(params?["limit"]?.intValue ?? 500, 2000)
        )
    }
}

/// Input for search_activities tool
struct SearchActivitiesInput: Codable {
    let query: String
    let app: String?
    let from: String?
    let to: String?
    let includeUrls: Bool

    static func parse(from params: [String: JSONValue]?) throws -> SearchActivitiesInput {
        guard let query = params?["query"]?.stringValue, !query.isEmpty else {
            throw MCPError.missingRequiredParam("query")
        }
        return SearchActivitiesInput(
            query: query,
            app: params?["app"]?.stringValue,
            from: params?["from"]?.stringValue,
            to: params?["to"]?.stringValue,
            includeUrls: params?["include_urls"]?.boolValue ?? false
        )
    }
}

/// Input for get_projects tool
struct GetProjectsInput: Codable {
    let date: String?
    let from: String?
    let to: String?

    static func parse(from params: [String: JSONValue]?) -> GetProjectsInput {
        GetProjectsInput(
            date: params?["date"]?.stringValue,
            from: params?["from"]?.stringValue,
            to: params?["to"]?.stringValue
        )
    }
}

/// Input for get_timeline tool
struct GetTimelineInput: Codable {
    let date: String?

    static func parse(from params: [String: JSONValue]?) -> GetTimelineInput {
        GetTimelineInput(date: params?["date"]?.stringValue)
    }
}

/// Input for get_day_summary tool
struct GetDaySummaryInput: Codable {
    let date: String?

    static func parse(from params: [String: JSONValue]?) -> GetDaySummaryInput {
        GetDaySummaryInput(date: params?["date"]?.stringValue)
    }
}

/// Input for get_ocr_digest tool
struct GetOCRDigestInput: Codable {
    let date: String?

    static func parse(from params: [String: JSONValue]?) -> GetOCRDigestInput {
        GetOCRDigestInput(date: params?["date"]?.stringValue)
    }
}

// MARK: - MCP Errors

public enum MCPError: Error, LocalizedError {
    case missingRequiredParam(String)
    case invalidDateFormat(String)
    case toolNotFound(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .missingRequiredParam(let param):
            return "Missing required parameter: \(param)"
        case .invalidDateFormat(let value):
            return "Invalid date format: \(value). Expected YYYY-MM-DD"
        case .toolNotFound(let name):
            return "Tool not found: \(name)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}
