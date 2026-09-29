import DebugTrace
import Foundation
import Network
import os

/// Serves a `DebugSurface` over HTTP, to `curl` and to MCP clients.
///
/// Replaces RAVEEngine's `RAVEDebugServer`. What changed, and why — the main
/// client is now a language model:
///
/// - **Self-describing.** `GET /` returns every endpoint with its parameter
///   types, defaults, ranges and a ready-to-run `curl` line, so a model needs
///   no prior knowledge of the app.
/// - **One envelope.** Every JSON reply is `{ok: true, endpoint, data}` or
///   `{ok: false, error: {code, message, hint}}`, whatever the app.
/// - **Validated arguments.** An unknown or mistyped argument is a 400 with a
///   "did you mean", not a silently ignored query key.
/// - **MCP.** `POST /mcp` speaks the streamable-HTTP transport with JSON
///   replies: `claude mcp add --transport http <name> http://<device>:<port>/mcp`
///   gives an agent every endpoint as a tool.
/// - **Reads vs writes.** Queries answer GET; commands need POST.
/// - **Auth.** A bearer token when the build carries one (build-and-sign
///   embeds a per-build token; the store's ledger has it). Requests carrying
///   an `Origin` header on anything but GET are refused, so a web page can't
///   drive commands through the browser.
///
/// Binding a listener triggers the Local Network privacy prompt: the host app
/// needs `NSLocalNetworkUsageDescription`, or it hears nothing.
@MainActor
public final class DebugTraceServer {
    public enum Binding: Sendable {
        /// Only this device. On iOS other apps can reach it too, which is why
        /// loopback is not exempt from the token.
        case loopback
        /// Wi-Fi, Ethernet and VPN interfaces (Tailscale); never cellular.
        case network
    }

    public enum Authentication: Sendable {
        /// The bundle credential's `CommandToken` when present, else open.
        case credential
        case token(String)
        case none
    }

    public struct Configuration: Sendable {
        public var port: UInt16
        public var binding: Binding
        public var authentication: Authentication
        public var maxBodyBytes: Int
        /// Apply the trace redactor to replies. On by default: the reader's
        /// transcript is a leak path too.
        public var redactsResponses: Bool
        /// Whether `start()` may run in release privacy mode (App Store and
        /// TestFlight builds). Off: a debug server reads and drives app state,
        /// which a user's installed app must not expose by accident.
        public var allowedInRelease: Bool

        /// Port 0 picks a free one; read it back from `start()`.
        public init(port: UInt16 = 8642, binding: Binding = .network, authentication: Authentication = .credential,
                    maxBodyBytes: Int = 1 << 20, redactsResponses: Bool = true, allowedInRelease: Bool = false) {
            self.port = port
            self.binding = binding
            self.authentication = authentication
            self.maxBodyBytes = maxBodyBytes
            self.redactsResponses = redactsResponses
            self.allowedInRelease = allowedInRelease
        }
    }

    public let surface: DebugSurface
    public let configuration: Configuration
    public private(set) var port: UInt16?
    public var isRunning: Bool { listener != nil }

    let token: String?
    /// Lifecycle lines go to the app's log like any other, with the port
    /// public and the device's addresses private.
    private let log: DebugLogger
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "DebugTraceServer")
    private lazy var mcp = MCPHandler(server: self)

    public init(surface: DebugSurface = .shared, configuration: Configuration = Configuration(),
) {
        self.surface = surface
        self.configuration = configuration
        self.log = DebugLogger(subsystem: DebugTrace.configuration.subsystems.first ?? "DebugTrace",
                               category: "DebugServer")
        switch configuration.authentication {
        case .credential: token = DebugTrace.credential?.commandToken
        case .token(let value): token = value
        case .none: token = nil
        }
    }

    // MARK: Lifecycle

    /// True when the launch environment sets `DEBUGTRACE_SERVER=1` in a
    /// development build. `build-and-sign --log` does, so an LLM working from
    /// the console log can also query the app live. Apps start their server
    /// when this is set, whatever their own developer toggle says.
    public nonisolated static var requestedAtLaunch: Bool {
        ProcessInfo.processInfo.environment["DEBUGTRACE_SERVER"] == "1" && DebugTrace.privacy == .development
    }

    /// How long a client has to finish sending its request.
    nonisolated static let requestReadTimeoutSeconds: Double = 60

    /// Starts listening and returns the bound port.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port, listener != nil { return port }
        if DebugTrace.privacy == .release && !configuration.allowedInRelease {
            throw DebugError(.forbidden, "the debug server does not run in release builds",
                             hint: "set Configuration.allowedInRelease, or capture a trace from the app instead")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        switch configuration.binding {
        case .loopback: parameters.requiredInterfaceType = .loopback
        case .network: parameters.prohibitedInterfaceTypes = [.cellular]
        }
        let requested: NWEndpoint.Port = configuration.port == 0 ? .any : (NWEndpoint.Port(rawValue: configuration.port) ?? .any)
        let listener = try NWListener(using: parameters, on: requested)
        self.listener = listener
        let maxBody = configuration.maxBodyBytes
        let queue = queue
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: queue)
            // A client that connects and never finishes sending a request
            // would otherwise hold the connection forever. The deadline
            // covers only that phase: once a request is in, the endpoint's
            // own `timeout` bounds the handler, however long it is.
            let received = OSAllocatedUnfairLock(initialState: false)
            queue.asyncAfter(deadline: .now() + Self.requestReadTimeoutSeconds) {
                if !received.withLock({ $0 }) { connection.cancel() }
            }
            Self.receive(on: connection, buffer: Data(), maxBodyBytes: maxBody) { result in
                received.withLock { $0 = true }
                Task { @MainActor in self?.dispatch(result, on: connection) }
            }
        }
        do {
            let bound: UInt16 = try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { state in
                    let outcome: Result<UInt16, any Error>?
                    switch state {
                    case .ready: outcome = .success(listener.port?.rawValue ?? 0)
                    case .failed(let error): outcome = .failure(error)
                    case .cancelled: outcome = .failure(CancellationError())
                    default: outcome = nil
                    }
                    guard let outcome, once.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    continuation.resume(with: outcome)
                }
                listener.start(queue: queue)
            }
            port = bound
            let auth = token == nil ? "no token" : "bearer token required"
            log.notice("listening on port \(bound, privacy: .public) (\(auth, privacy: .public)) — \(Self.localAddresses().joined(separator: ", "))")
            return bound
        } catch {
            listener.cancel()
            self.listener = nil
            log.error("failed to start: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Fire-and-forget start for call sites that are not async.
    public func startInBackground() {
        Task { try? await start() }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: Connections

    private nonisolated static func receive(
        on connection: NWConnection, buffer: Data, maxBodyBytes: Int,
        completion: @escaping @Sendable (HTTPParseResult) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let parsed = HTTPParser.parse(buffer, maxBodyBytes: maxBodyBytes)
            if case .needMore = parsed {
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    receive(on: connection, buffer: buffer, maxBodyBytes: maxBodyBytes, completion: completion)
                }
                return
            }
            completion(parsed)
        }
    }

    private func dispatch(_ parsed: HTTPParseResult, on connection: NWConnection) {
        switch parsed {
        case .needMore:
            connection.cancel()
        case .invalid(let status, let message):
            send(errorResponse(DebugError(.invalidArgument, message), status: status), on: connection)
        case .complete(let request):
            Task { @MainActor in
                let (response, after) = await self.respond(to: request)
                self.send(response, on: connection, then: after)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection,
                      then after: (@MainActor @Sendable () -> Void)? = nil) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
            if let after { Task { @MainActor in after() } }
        })
    }

    // MARK: Routing

    typealias Reply = (HTTPResponse, (@MainActor @Sendable () -> Void)?)

    func respond(to request: HTTPRequest) async -> Reply {
        let path = request.path.count > 1 && request.path.hasSuffix("/") ? String(request.path.dropLast()) : request.path

        if request.method != "GET", request.method != "HEAD", request.header("origin") != nil {
            return (errorResponse(DebugError(.forbidden, "requests from a web page are refused",
                                             hint: "call this from curl or an MCP client, which send no Origin header")), nil)
        }

        // Discovery stays open so a model can learn how to authenticate.
        if request.method == "GET", path == "/" || path == "/_help" {
            return (help(request), nil)
        }

        if let failure = authenticate(request) {
            return (errorResponse(failure), nil)
        }

        switch path {
        case "/mcp":
            guard request.method == "POST" else {
                return (errorResponse(DebugError(.methodNotAllowed, "the MCP endpoint takes POST only (no SSE stream is offered)",
                                                 hint: "POST a JSON-RPC message with Content-Type: application/json")), nil)
            }
            return await mcp.handle(request)
        case "/_tools":
            return (jsonResponse(200, ["tools": .array(surface.catalog.map(MCPHandler.toolDefinition))]), nil)
        case "/_call":
            guard request.method == "POST" else {
                return (errorResponse(DebugError(.methodNotAllowed, "/_call takes POST",
                                                 hint: #"POST {"name": "<endpoint>", "arguments": {...}}"#)), nil)
            }
            guard let body = try? JSONValue.parse(request.body), let name = body["name"]?.stringValue else {
                return (errorResponse(.invalidArgument(#"body must be {"name": "<endpoint>", "arguments": {...}}"#)), nil)
            }
            return await invoke(name, arguments: body["arguments"]?.objectValue ?? [:], pretty: false)
        default:
            break
        }

        if path.hasPrefix("/_traces/"), request.method == "GET" {
            return (traceDownload(String(path.dropFirst("/_traces/".count))), nil)
        }

        let name = String(path.dropFirst())
        guard let endpoint = surface.endpoint(named: name) else {
            return (errorResponse(surface.notFound(name), endpoint: name), nil)
        }

        var arguments: [String: JSONValue] = request.query.mapValues(JSONValue.string)
        let declaresPretty = endpoint.parameters.contains { $0.name == "pretty" }
        let pretty = !declaresPretty && (arguments.removeValue(forKey: "pretty").map { $0 != .string("0") && $0 != .string("false") } ?? false)

        switch (request.method, endpoint.kind) {
        case ("GET", .query), ("POST", _):
            break
        case ("GET", .command):
            return (errorResponse(DebugError(
                .methodNotAllowed, "'\(name)' is a command and changes app state; it needs POST",
                hint: "curl -s -X POST \(baseURL(request))/\(name) -H 'Content-Type: application/json' -d '\(HelpDocument.exampleBody(endpoint))'"),
                endpoint: name), nil)
        default:
            return (errorResponse(DebugError(.methodNotAllowed, "\(request.method) is not supported", hint: "use GET for queries, POST for commands"),
                                  endpoint: name), nil)
        }

        if request.method == "POST", !request.body.isEmpty {
            guard let body = try? JSONValue.parse(request.body), case .object(let object) = body else {
                return (errorResponse(.invalidArgument("POST body must be a JSON object of arguments",
                                                       hint: "send -d '{\"name\": value}' with Content-Type: application/json, or pass query parameters"),
                                      endpoint: name), nil)
            }
            arguments.merge(object) { _, fromBody in fromBody }
        }
        return await invoke(name, arguments: arguments, pretty: pretty)
    }

    private func invoke(_ name: String, arguments: [String: JSONValue], pretty: Bool) async -> Reply {
        let start = ContinuousClock.now
        switch await surface.call(name, arguments: arguments) {
        case .failure(let error):
            return (errorResponse(error, endpoint: name), nil)
        case .success(let result):
            switch result.body {
            case .binary(let binary):
                var response = HTTPResponse(status: 200, contentType: binary.contentType, body: binary.data)
                if let filename = binary.filename {
                    response.extraHeaders.append(("Content-Disposition", "inline; filename=\"\(filename)\""))
                }
                return (response, result.afterDelivery)
            case .json(let data):
                let elapsed = ContinuousClock.now - start
                let envelope: JSONValue = [
                    "ok": true,
                    "endpoint": .string(name),
                    "elapsedMs": .double(Self.milliseconds(elapsed)),
                    "data": redact(data),
                ]
                return (.json(200, envelope.serialized(pretty: pretty)), result.afterDelivery)
            }
        }
    }

    private func authenticate(_ request: HTTPRequest) -> DebugError? {
        guard let token else { return nil }
        let presented: String? = {
            if let authorization = request.header("authorization"), authorization.lowercased().hasPrefix("bearer ") {
                return String(authorization.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
            }
            return request.header("x-debug-token")
        }()
        guard let presented else {
            return DebugError(.unauthenticated, "this build requires its debug token",
                              hint: "send Authorization: Bearer <token>; the token is per build — look it up in the app store server's ledger for this bundle id and build")
        }
        guard Self.constantTimeEqual(presented, token) else {
            return DebugError(.unauthenticated, "wrong debug token",
                              hint: "tokens change with every build; fetch the one for the build now installed (see _help → app.build)")
        }
        return nil
    }

    private func traceDownload(_ file: String) -> HTTPResponse {
        let id = file.hasSuffix(".zip") ? String(file.dropLast(4)) : file
        guard let archive = DebugTrace.archive(id: id), let data = try? Data(contentsOf: archive.url) else {
            return errorResponse(DebugError(.notFound, "no recent trace '\(id)'",
                                            hint: "only the last few traces are kept; make one with POST /_trace"))
        }
        var response = HTTPResponse(status: 200, contentType: "application/zip", body: data)
        response.extraHeaders.append(("Content-Disposition", "attachment; filename=\"\(archive.filename)\""))
        return response
    }

    private func help(_ request: HTTPRequest) -> HTTPResponse {
        let only = request.query["endpoint"]
        if let only, surface.endpoint(named: only) == nil {
            return errorResponse(surface.notFound(only))
        }
        let document = HelpDocument.build(surface: surface, baseURL: baseURL(request),
                                          tokenRequired: token != nil, only: only)
        return .json(200, document.serialized(pretty: request.query["pretty"] != "0"))
    }

    // MARK: Encoding

    func redact(_ value: JSONValue) -> JSONValue {
        configuration.redactsResponses ? DebugTrace.configuration.redactor.redact(value) : value
    }

    func jsonResponse(_ status: Int, _ value: JSONValue) -> HTTPResponse {
        .json(status, value.serialized())
    }

    func errorResponse(_ error: DebugError, endpoint: String? = nil, status: Int? = nil) -> HTTPResponse {
        var envelope: [String: JSONValue] = ["ok": false, "error": error.json]
        if let endpoint { envelope["endpoint"] = .string(endpoint) }
        return .json(status ?? error.httpStatus, JSONValue.object(envelope).serialized())
    }

    func baseURL(_ request: HTTPRequest) -> String {
        "http://\(request.header("host") ?? "127.0.0.1:\(port ?? configuration.port)")"
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return ((Double(seconds) * 1000 + Double(attoseconds) / 1e15) * 10).rounded() / 10
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// `en0 192.168.1.20`-style pairs, loopback excluded, logged on start so
    /// the device's address doesn't have to be hunted down in Settings.
    public nonisolated static func localAddresses() -> [String] {
        var results: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return results }
        defer { freeifaddrs(list) }
        var pointer = list
        while let entry = pointer {
            let ifa = entry.pointee
            if let address = ifa.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if !text.hasPrefix("127.") { results.append("\(String(cString: ifa.ifa_name)) \(text)") }
                }
            }
            pointer = ifa.ifa_next
        }
        return results
    }
}
