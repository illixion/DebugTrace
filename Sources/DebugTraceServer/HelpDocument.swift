import DebugTrace
import Foundation

/// `GET /` — everything a model needs to use this server cold.
///
/// Written for a reader with no prior knowledge of the app: conventions
/// first, then each endpoint with typed parameters and a runnable example.
/// `?endpoint=<name>` narrows it to one entry, so a model can re-read a
/// signature without paying for the whole catalog again.
@MainActor
enum HelpDocument {
    static func build(surface: DebugSurface, baseURL: String, tokenRequired: Bool, only: String?) -> JSONValue {
        let endpoints = surface.catalog.filter { only == nil || $0.name == only }
        let auth = tokenRequired ? " -H \"Authorization: Bearer $DEBUG_TOKEN\"" : ""
        let described: [JSONValue] = endpoints.map { describe($0, baseURL: baseURL, auth: auth) }
        if only != nil { return ["endpoints": .array(described)] }

        let info = DebugAppInfo.current()
        return [
            "service": "debugtrace/1",
            "app": [
                "name": .string(info.app.name),
                "bundleId": .string(info.app.bundleId),
                "version": .string(info.app.version),
                "build": .string(info.app.build),
                "platform": .string(info.app.platform),
            ],
            "baseUrl": .string(baseURL),
            "auth": tokenRequired
                ? ["required": true, "header": "Authorization: Bearer <token>",
                   "note": "the token is per build; the app store server's ledger has it for this bundle id and build"]
                : ["required": false],
            "conventions": [
                "Queries read state and change nothing: GET /<name>?arg=value (or POST with a JSON body).",
                "Commands change app state: POST /<name> with a JSON object body; GET on a command is refused.",
                "Every JSON reply is {ok: true, endpoint, elapsedMs, data} or {ok: false, error: {code, message, hint}}. Read the hint: it says how to fix the call.",
                "Arguments are validated: unknown names, wrong types and out-of-range values are rejected, never ignored.",
                "Keys are camelCase; units are in the name (elapsedMs, footprintBytes, uptimeSeconds). Times are ISO 8601 UTC.",
                "Start with _info (identity, build SHA, health), then _features (what is in use) and _logs.",
                "_snapshot is everything a debug trace captures; POST /_trace builds one, downloadable from the returned path.",
                "MCP: POST /mcp speaks streamable HTTP with JSON responses; the same endpoints are its tools.",
                "Add ?pretty=1 to indent a reply. Values that look like secrets are replaced with <redacted>.",
            ],
            "mcp": .string("claude mcp add --transport http \(mcpName(info.app.name)) \(baseURL)/mcp\(tokenRequired ? " --header \"Authorization: Bearer $DEBUG_TOKEN\"" : "")"),
            "endpoints": .array(described),
        ]
    }

    private static func describe(_ endpoint: DebugEndpoint, baseURL: String, auth: String) -> JSONValue {
        var entry: [String: JSONValue] = [
            "name": .string(endpoint.name),
            "kind": .string(endpoint.kind.rawValue),
            "method": .string(endpoint.kind == .query ? "GET" : "POST"),
            "description": .string(endpoint.description),
            "example": .string(example(endpoint, baseURL: baseURL, auth: auth)),
        ]
        if !endpoint.parameters.isEmpty {
            entry["parameters"] = .array(endpoint.parameters.map { parameter in
                var object: [String: JSONValue] = [
                    "name": .string(parameter.name),
                    "type": .string(parameter.kind.rawValue),
                    "required": .bool(parameter.required),
                    "description": .string(parameter.description),
                ]
                if let value = parameter.defaultValue { object["default"] = value }
                if let choices = parameter.choices { object["choices"] = .array(choices.map(JSONValue.string)) }
                if let minimum = parameter.minimum { object["min"] = .double(minimum) }
                if let maximum = parameter.maximum { object["max"] = .double(maximum) }
                return .object(object)
            })
        }
        if endpoint.destructive { entry["destructive"] = true }
        if endpoint.version != 1 { entry["version"] = .int(endpoint.version) }
        if endpoint.traceArguments != nil { entry["inTrace"] = true }
        return .object(entry)
    }

    static func example(_ endpoint: DebugEndpoint, baseURL: String, auth: String) -> String {
        let required = endpoint.parameters.filter(\.required)
        switch endpoint.kind {
        case .query:
            let query = required.map { "\($0.name)=\(queryText($0.exampleValue))" }.joined(separator: "&")
            return "curl -s\(auth) '\(baseURL)/\(endpoint.name)\(query.isEmpty ? "" : "?\(query)")'"
        case .command:
            return "curl -s\(auth) -X POST \(baseURL)/\(endpoint.name) -H 'Content-Type: application/json' -d '\(exampleBody(endpoint))'"
        }
    }

    static func exampleBody(_ endpoint: DebugEndpoint) -> String {
        var body: [String: JSONValue] = [:]
        for parameter in endpoint.parameters where parameter.required {
            body[parameter.name] = parameter.exampleValue
        }
        return JSONValue.object(body).serializedString()
    }

    private static func queryText(_ value: JSONValue) -> String {
        value.stringValue ?? value.serializedString()
    }

    /// `Hypnos` → `hypnos`, `Half-Life visionOS` → `half-life-visionos`.
    private static func mcpName(_ name: String) -> String {
        let lowered = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(lowered).split(separator: "-").joined(separator: "-")
    }
}
