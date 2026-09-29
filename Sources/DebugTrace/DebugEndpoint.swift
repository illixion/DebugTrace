import Foundation

/// One named entry in a `DebugSurface`: a query or a command.
///
/// **Queries** read state and change nothing. They are served over GET, marked
/// `readOnlyHint` for MCP, and the ones that need no arguments are captured
/// into every debug trace automatically — that is the "additional routes the
/// trace auto-includes" seam. **Commands** change app state (teleport, set a
/// flag, exit). They need POST, are never run by a trace, and a registry
/// created with `allowCommands: false` refuses them outright.
public struct DebugEndpoint: Sendable {
    public enum Kind: String, Sendable, Codable {
        case query, command
    }

    /// Whether a debug trace captures this endpoint.
    public enum TracePolicy: Sendable, Equatable {
        /// Queries whose required parameters all have defaults: yes, called
        /// with no arguments. Everything else: no.
        case automatic
        case never
        /// Captured, called with these arguments.
        case arguments([String: JSONValue])
    }

    public typealias Handler = @MainActor @Sendable (DebugArguments) async throws -> DebugResult

    public let name: String
    public let kind: Kind
    public let description: String
    public let parameters: [DebugParameter]
    /// Bump when the shape of `data` changes incompatibly, so a model or a
    /// script comparing two traces knows not to diff across it.
    public let version: Int
    /// Destroys or discards something (`exit`, `resetWorld`). MCP clients
    /// ask before calling these.
    public let destructive: Bool
    public let trace: TracePolicy
    public let timeout: Duration
    let handler: Handler

    public init(
        name: String,
        kind: Kind,
        description: String,
        parameters: [DebugParameter] = [],
        version: Int = 1,
        destructive: Bool = false,
        trace: TracePolicy = .automatic,
        timeout: Duration = .seconds(30),
        handler: @escaping Handler
    ) {
        self.name = name
        self.kind = kind
        self.description = description
        self.parameters = parameters
        self.version = version
        self.destructive = destructive
        self.trace = kind == .command ? .never : trace
        self.timeout = timeout
        self.handler = handler
    }

    /// The arguments a trace calls this with, or nil if it is not traced.
    public var traceArguments: [String: JSONValue]? {
        guard kind == .query else { return nil }
        switch trace {
        case .never: return nil
        case .arguments(let arguments): return arguments
        case .automatic:
            return parameters.contains { $0.required && $0.defaultValue == nil } ? nil : [:]
        }
    }

    public var isBuiltin: Bool { name.hasPrefix("_") }

    /// MCP `inputSchema`.
    public var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters { properties[parameter.name] = parameter.jsonSchema }
        let required = parameters.filter(\.required).map { JSONValue.string($0.name) }
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required) }
        return .object(schema)
    }
}

// MARK: - Factories

extension DebugEndpoint {
    /// A typed read. The handler returns any `Encodable`; its property names
    /// become the JSON keys. Use camelCase and put the unit in the name
    /// (`elapsedMs`, `footprintBytes`) — a bare `elapsed` makes a model guess.
    public static func query<Output: Encodable>(
        _ name: String,
        _ description: String,
        parameters: [DebugParameter] = [],
        version: Int = 1,
        trace: TracePolicy = .automatic,
        timeout: Duration = .seconds(30),
        handler: @escaping @MainActor @Sendable (DebugArguments) async throws -> Output
    ) -> DebugEndpoint {
        DebugEndpoint(name: name, kind: .query, description: description, parameters: parameters,
                      version: version, trace: trace, timeout: timeout) { arguments in
            try DebugResult.json(try await handler(arguments))
        }
    }

    /// A typed action. Return the state the command produced (the new
    /// position, the flag's value now), not just `ok` — a model that has to
    /// issue a second query to find out whether its command worked usually
    /// doesn't.
    public static func command<Output: Encodable>(
        _ name: String,
        _ description: String,
        parameters: [DebugParameter] = [],
        version: Int = 1,
        destructive: Bool = false,
        timeout: Duration = .seconds(30),
        handler: @escaping @MainActor @Sendable (DebugArguments) async throws -> Output
    ) -> DebugEndpoint {
        DebugEndpoint(name: name, kind: .command, description: description, parameters: parameters,
                      version: version, destructive: destructive, timeout: timeout) { arguments in
            try DebugResult.json(try await handler(arguments))
        }
    }

    /// Full control over the result: binary payloads (a PNG frame) and
    /// actions deferred until the reply is delivered (`exit`, whose side
    /// effect stops the listener that owes the reply).
    public static func raw(
        _ name: String,
        kind: Kind,
        _ description: String,
        parameters: [DebugParameter] = [],
        version: Int = 1,
        destructive: Bool = false,
        trace: TracePolicy = .automatic,
        timeout: Duration = .seconds(30),
        handler: @escaping Handler
    ) -> DebugEndpoint {
        DebugEndpoint(name: name, kind: kind, description: description, parameters: parameters,
                      version: version, destructive: destructive, trace: trace, timeout: timeout,
                      handler: handler)
    }

    /// The migration path for route tables written against the old
    /// `RAVEDebugServer`, whose handlers built `[String: Any]` by hand. It
    /// keeps them running unchanged; convert to `query`/`command` with a
    /// typed result when a route is next touched.
    public static func untyped(
        _ name: String,
        kind: Kind,
        _ description: String,
        parameters: [DebugParameter] = [],
        destructive: Bool = false,
        trace: TracePolicy = .automatic,
        timeout: Duration = .seconds(30),
        handler: @escaping @MainActor @Sendable (DebugArguments) async throws -> [String: Any]
    ) -> DebugEndpoint {
        DebugEndpoint(name: name, kind: kind, description: description, parameters: parameters,
                      destructive: destructive, trace: trace, timeout: timeout) { arguments in
            DebugResult(body: .json(JSONValue(any: try await handler(arguments))))
        }
    }
}

// MARK: - Results

/// A binary payload: a frame, a file.
public struct DebugBinary: Sendable {
    public let data: Data
    public let contentType: String
    /// Name for a trace attachment or a download. Extension included.
    public let filename: String?

    public init(data: Data, contentType: String, filename: String? = nil) {
        self.data = data
        self.contentType = contentType
        self.filename = filename
    }
}

/// What a handler produced.
public struct DebugResult: Sendable {
    public enum Body: Sendable {
        case json(JSONValue)
        case binary(DebugBinary)
    }

    public var body: Body
    /// Runs after the reply has been handed to the transport. For commands
    /// whose effect would prevent the reply (stopping the server, leaving
    /// the immersive space). Callers that don't deliver anything (a trace)
    /// run it right away.
    public var afterDelivery: (@MainActor @Sendable () -> Void)?

    public init(body: Body, afterDelivery: (@MainActor @Sendable () -> Void)? = nil) {
        self.body = body
        self.afterDelivery = afterDelivery
    }

    public static func json<T: Encodable>(_ value: T) throws -> DebugResult {
        DebugResult(body: .json(try JSONValue(encoding: value)))
    }

    public static func binary(_ data: Data, contentType: String, filename: String? = nil) -> DebugResult {
        DebugResult(body: .binary(DebugBinary(data: data, contentType: contentType, filename: filename)))
    }

    public func then(_ action: @escaping @MainActor @Sendable () -> Void) -> DebugResult {
        DebugResult(body: body, afterDelivery: action)
    }

    public var json: JSONValue? {
        if case .json(let value) = body { return value }
        return nil
    }
}
