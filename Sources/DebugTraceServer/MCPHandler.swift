import DebugTrace
import Foundation

/// The MCP half: JSON-RPC 2.0 over the streamable-HTTP transport, answering
/// every request with a single JSON body (the transport allows that in place
/// of an SSE stream). Stateless — no `Mcp-Session-Id`; every tool call is
/// independent, which is true of the endpoints anyway.
///
/// Tool errors come back as `isError: true` results, not JSON-RPC errors, so
/// the model sees the message and the hint and can correct its call. Only
/// malformed JSON-RPC gets a protocol error.
@MainActor
final class MCPHandler {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private unowned let server: DebugTraceServer

    init(server: DebugTraceServer) {
        self.server = server
    }

    func handle(_ request: HTTPRequest) async -> DebugTraceServer.Reply {
        guard let message = try? JSONValue.parse(request.body) else {
            return (rpcError(id: .null, code: -32700, message: "parse error: body is not JSON"), nil)
        }
        if case .array = message {
            return (rpcError(id: .null, code: -32600, message: "batched JSON-RPC is not supported; send one message per request"), nil)
        }
        guard let method = message["method"]?.stringValue else {
            // A response or something unrecognised; nothing to answer.
            return (.empty(202), nil)
        }
        // Notifications (no id) get no reply body.
        guard let id = message["id"] else { return (.empty(202), nil) }
        let params = message["params"]

        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil } ?? Self.supportedVersions[0]
            let info = DebugAppInfo.current()
            return (result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string("\(info.app.name) debug"), "version": .string(info.app.build)],
                "instructions": .string(instructions(info)),
            ]), nil)
        case "ping":
            return (result(id: id, [:]), nil)
        case "tools/list":
            return (result(id: id, ["tools": .array(server.surface.catalog.map(Self.toolDefinition))]), nil)
        case "tools/call":
            guard let name = params?["name"]?.stringValue else {
                return (rpcError(id: id, code: -32602, message: "tools/call needs params.name"), nil)
            }
            let arguments = params?["arguments"]?.objectValue ?? [:]
            return await call(name, arguments: arguments, id: id)
        default:
            return (rpcError(id: id, code: -32601, message: "method '\(method)' is not supported; this server offers tools only"), nil)
        }
    }

    private func call(_ name: String, arguments: [String: JSONValue], id: JSONValue) async -> DebugTraceServer.Reply {
        switch await server.surface.call(name, arguments: arguments) {
        case .failure(let error):
            let payload: JSONValue = ["ok": false, "error": error.json]
            return (result(id: id, [
                "content": [["type": "text", "text": .string(payload.serializedString())]],
                "isError": true,
            ]), nil)
        case .success(let output):
            switch output.body {
            case .json(let data):
                let redacted = server.redact(data)
                var body: [String: JSONValue] = [
                    "content": [["type": "text", "text": .string(redacted.serializedString())]],
                    "isError": false,
                ]
                // structuredContent must be an object.
                if case .object = redacted { body["structuredContent"] = redacted }
                return (result(id: id, .object(body)), output.afterDelivery)
            case .binary(let binary):
                let content: JSONValue = binary.contentType.hasPrefix("image/")
                    ? ["type": "image", "data": .string(binary.data.base64EncodedString()), "mimeType": .string(binary.contentType)]
                    : ["type": "resource", "resource": [
                        "uri": .string("debugtrace://\(name)/\(binary.filename ?? "result")"),
                        "mimeType": .string(binary.contentType),
                        "blob": .string(binary.data.base64EncodedString()),
                    ]]
                return (result(id: id, ["content": [content], "isError": false]), output.afterDelivery)
            }
        }
    }

    static func toolDefinition(_ endpoint: DebugEndpoint) -> JSONValue {
        let prefix = endpoint.kind == .query ? "Query (read-only). " : "Command (changes app state). "
        return [
            "name": .string(endpoint.name),
            "description": .string(prefix + endpoint.description),
            "inputSchema": endpoint.inputSchema,
            "annotations": [
                "readOnlyHint": .bool(endpoint.kind == .query),
                "destructiveHint": .bool(endpoint.destructive),
                "openWorldHint": false,
            ],
        ]
    }

    private func instructions(_ info: DebugAppInfo) -> String {
        """
        Live debug surface of \(info.app.name) (\(info.app.bundleId), build \(info.app.build)) on \(info.device.model), \(info.device.os). \
        Query tools read state and are safe; command tools change the running app. \
        Start with _info, then _features and _logs. _snapshot is what a debug trace captures; _trace builds one. \
        Errors carry a hint describing the fix. Values that look like secrets are replaced with <redacted>.
        """
    }

    private func result(id: JSONValue, _ value: JSONValue) -> HTTPResponse {
        .json(200, JSONValue.object(["jsonrpc": "2.0", "id": id, "result": value]).serialized())
    }

    private func rpcError(id: JSONValue, code: Int, message: String) -> HTTPResponse {
        .json(200, JSONValue.object([
            "jsonrpc": "2.0", "id": id,
            "error": ["code": .int(code), "message": .string(message)],
        ]).serialized())
    }
}
