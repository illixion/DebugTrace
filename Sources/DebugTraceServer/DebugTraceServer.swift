import DebugTrace
import Foundation
import CryptoKit
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
/// needs `NSLocalNetworkUsageDescription`, or it hears nothing. build-and-sign
/// adds that key, and `NSBonjourServices` for the advertisement, to the
/// Info.plist of the dev builds it signs, so an app's own plist (and with it
/// the App Store build) never has to carry them.
///
/// **When it runs.** `startIfRequested()` starts it in a development build
/// that build-and-sign signed (its credential carries a `CommandToken`), on
/// every launch, so a client can attach to an app that is already running.
/// It also starts for an explicit `DEBUGTRACE_SERVER=1`. An App Store or
/// TestFlight build is `release` and has no credential, so it never listens
/// and never shows the Local Network prompt.
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
        /// The token `build-and-sign --mcp` passes at launch
        /// (`DEBUGTRACE_TOKEN`), else the bundle credential's `CommandToken`,
        /// else open.
        case automatic
        case token(String)
        case none
    }

    public struct Configuration: Sendable {
        /// Tried in order until one binds, so several apps can serve at once.
        /// Clients never need to know which port an app got: `bas --mcp` reads
        /// it from the "listening on port N" line and records it with the
        /// session, and the Mac-side `apps` MCP server routes by app name.
        public var ports: ClosedRange<UInt16>
        public var binding: Binding
        public var authentication: Authentication
        public var maxBodyBytes: Int
        /// Apply the trace redactor to replies. On by default: the reader's
        /// transcript is a leak path too.
        public var redactsResponses: Bool
        /// Whether `start()` may run in release privacy mode (App Store and
        /// TestFlight builds). Off: the server only ever starts from a
        /// development launch, and this keeps it that way even if a caller
        /// forgets to check.
        public var allowedInRelease: Bool
        /// Advertise over Bonjour as `_debugtrace._tcp`, with the bundle id,
        /// build and key id in the TXT record, so clients find the app
        /// without knowing its port. Only when the Info.plist declares the
        /// type in `NSBonjourServices`: iOS refuses undeclared types.
        public var advertises: Bool
        /// Whether a client must be allowed on the device first. `.ask` by
        /// default: the token proves the caller has this build's ledger, the
        /// prompt that the person holding the device agrees.
        public var approval: DebugApproval
        /// How long a request waits for that answer before it gets a 403
        /// saying the prompt is still open.
        public var approvalTimeout: Duration
        /// Chime when a prompt is shown, and again every few seconds while it
        /// waits: the prompt is easy to miss on a headset. On by default.
        public var approvalSound: Bool
        /// Load the live-patching runtime if a development build embeds one
        /// (`build-and-sign --inject`). Set false in an app that must never
        /// run patched code, such as a confidential one; it is also never
        /// loaded in release mode.
        public var loadsPatchRuntime: Bool
        /// For apps that carry private content (a messenger). Serves only
        /// queries marked `releaseSafe` and no command at all, so a leaked token
        /// reads a status page and nothing else; `_logs`, `_snapshot`, `_trace`
        /// and every `_inject`-style command are refused, and the patch
        /// runtime never loads. An app still keeps its own content out of
        /// those replies: this limits what can be asked, not what a safe
        /// endpoint returns, so test them (see RegentChat's privacy tests).
        public var confidential: Bool

        public static let defaultPorts: ClosedRange<UInt16> = 8642...8691

        /// `ports: 0...0` picks any free port (tests); read it back from `start()`.
        public init(ports: ClosedRange<UInt16> = Configuration.defaultPorts, binding: Binding = .network,
                    authentication: Authentication = .automatic, maxBodyBytes: Int = 1 << 20,
                    redactsResponses: Bool = true, allowedInRelease: Bool = false, advertises: Bool = true,
                    approval: DebugApproval = .ask, approvalTimeout: Duration = .seconds(60),
                    approvalSound: Bool = true, loadsPatchRuntime: Bool = true, confidential: Bool = false) {
            self.ports = ports
            self.binding = binding
            self.authentication = authentication
            self.maxBodyBytes = maxBodyBytes
            self.redactsResponses = redactsResponses
            self.allowedInRelease = allowedInRelease
            self.advertises = advertises
            self.approval = approval
            self.approvalTimeout = approvalTimeout
            self.approvalSound = approvalSound
            self.loadsPatchRuntime = loadsPatchRuntime && !confidential
            self.confidential = confidential
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
    /// The port the last listener held, tried first on a restart so clients'
    /// recorded URLs keep working.
    private var lastPort: UInt16?
    private let queue = DispatchQueue(label: "DebugTraceServer")
    private lazy var mcp = MCPHandler(server: self)
    private lazy var approvals = DebugApprovals(mode: configuration.approval, playsSound: configuration.approvalSound)

    public init(surface: DebugSurface = .shared, configuration: Configuration = Configuration()) {
        self.surface = surface
        self.configuration = configuration
        self.log = DebugLogger(subsystem: DebugTrace.configuration.subsystems.first ?? "DebugTrace",
                               category: "DebugServer")
        switch configuration.authentication {
        case .automatic:
            token = ProcessInfo.processInfo.environment["DEBUGTRACE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
                ?? DebugTrace.credential?.commandToken
        case .token(let value): token = value
        case .none: token = nil
        }
    }

    // MARK: Lifecycle

    /// True in a development build that either build-and-sign signed (its
    /// credential carries a `CommandToken`) or whose launch environment sets
    /// `DEBUGTRACE_SERVER=1`. `DEBUGTRACE_SERVER=0` turns it off for one
    /// launch. Never in release: App Store and TestFlight builds stay silent.
    public nonisolated static var requestedAtLaunch: Bool {
        requested(environment: ProcessInfo.processInfo.environment["DEBUGTRACE_SERVER"],
                  privacy: DebugTrace.privacy, hasCommandToken: DebugTrace.credential?.commandToken != nil)
    }

    nonisolated static func requested(environment: String?, privacy: DebugPrivacyMode, hasCommandToken: Bool) -> Bool {
        guard privacy == .development else { return false }
        switch environment {
        case "1": return true
        case "0": return false
        default: return hasCommandToken
        }
    }

    public nonisolated static let serviceType = "_debugtrace._tcp"

    /// Whether this app's Info.plist lets it advertise `serviceType`.
    nonisolated static func declaresBonjourService(_ info: [String: Any]?) -> Bool {
        (info?["NSBonjourServices"] as? [String])?.contains(serviceType) == true
    }

    /// The TXT record, built so a passer-by on the network learns nothing:
    /// no app name, bundle id or version, and nothing stable to recognise the
    /// device by on the next network. `n` is a fresh random nonce per
    /// listener and `t` a tag over it under this build's token, so only a Mac
    /// whose key ledger holds the token can tell which app this is
    /// (`debugtrace-mcp` tries each ledger token). A build without a token
    /// advertises a bare record, which nobody can attach to anyway.
    nonisolated static func txtRecord(token: String?, nonce: String) -> [String: String] {
        guard let token else { return ["txtvers": "2"] }
        return ["txtvers": "2", "n": nonce, "t": advertisementTag(token: token, nonce: nonce)]
    }

    /// base64url(HMAC-SHA256(token, "debugtrace-advert|" + nonce)), first 12
    /// bytes. Truncated: it identifies, it doesn't authenticate.
    nonisolated static func advertisementTag(token: String, nonce: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("debugtrace-advert|\(nonce)".utf8),
                                                  using: SymmetricKey(data: Data(token.utf8)))
        return Data(mac.prefix(12)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func randomNonce() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// The server `startIfRequested()` started, if any.
    public private(set) static var shared: DebugTraceServer?

    /// Call once at launch, after `DebugTrace.configure`. Starts a server over
    /// `DebugSurface.shared` when this launch asked for one
    /// (`requestedAtLaunch`), and does nothing otherwise. Endpoints can be
    /// registered before or after: the server reads the surface per request.
    public static func startIfRequested(configuration: Configuration = Configuration()) {
        guard requestedAtLaunch, shared == nil else { return }
        let server = DebugTraceServer(configuration: configuration)
        shared = server
        server.startInBackground()
    }

    /// How long a client has to finish sending its request.
    nonisolated static let requestReadTimeoutSeconds: Double = 60

    /// Starts listening on the first free port in `configuration.ports` and
    /// returns it.
    @discardableResult
    public func start() async throws -> UInt16 {
        if let port, listener != nil { return port }
        if DebugTrace.privacy == .release && !configuration.allowedInRelease {
            throw DebugError(.forbidden, "the debug server does not run in release builds",
                             hint: "set Configuration.allowedInRelease, or capture a trace from the app instead")
        }
        if configuration.loadsPatchRuntime { DebugPatchRuntimeLoader.loadIfEmbedded(log: log) }
        let candidates = (lastPort.map { [$0] } ?? []) + configuration.ports.filter { $0 != lastPort }
        for candidate in candidates {
            do {
                let bound = try await listen(on: candidate)
                port = bound
                lastPort = bound
                let auth = token == nil ? "no token" : "bearer token required"
                log.notice("listening on port \(bound, privacy: .public) (\(auth, privacy: .public)) — \(Self.localAddresses().joined(separator: ", "))")
                return bound
            } catch NWError.posix(.EADDRINUSE) {
                continue
            } catch {
                log.error("failed to start: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        let range = "\(configuration.ports.lowerBound)-\(configuration.ports.upperBound)"
        log.error("failed to start: every port in \(range, privacy: .public) is in use")
        throw DebugError(.unavailable, "every port in \(range) is in use",
                         hint: "other apps' debug servers hold them; stop one (each bas --mcp launch runs one)")
    }

    private func listen(on candidate: UInt16) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        // Rebinding right after a stop must not trip over connections still
        // closing. A port another listener holds is still refused.
        parameters.allowLocalEndpointReuse = true
        switch configuration.binding {
        case .loopback: parameters.requiredInterfaceType = .loopback
        case .network: parameters.prohibitedInterfaceTypes = [.cellular]
        }
        let requested: NWEndpoint.Port = candidate == 0 ? .any : (NWEndpoint.Port(rawValue: candidate) ?? .any)
        let listener = try NWListener(using: parameters, on: requested)
        let info = Bundle.main.infoDictionary
        if configuration.advertises, Self.declaresBonjourService(info) {
            // The instance name is as opaque as the record: the app's own name
            // would announce it to everyone on the network.
            let nonce = Self.randomNonce()
            listener.service = NWListener.Service(name: "debugtrace-\(nonce.prefix(8))", type: Self.serviceType,
                                                  txtRecord: NWTXTRecord(Self.txtRecord(token: token, nonce: nonce)))
        }
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
            return try await withCheckedThrowingContinuation { continuation in
                let once = OSAllocatedUnfairLock(initialState: false)
                listener.stateUpdateHandler = { [weak self] state in
                    let outcome: Result<UInt16, any Error>?
                    switch state {
                    case .ready: outcome = .success(listener.port?.rawValue ?? 0)
                    case .failed(let error): outcome = .failure(error)
                    case .cancelled: outcome = .failure(CancellationError())
                    default: outcome = nil
                    }
                    guard let outcome else { return }
                    if once.withLock({ let first = !$0; $0 = true; return first }) {
                        continuation.resume(with: outcome)
                    } else if case .failure = outcome {
                        // After start-up: the OS can drop a listening socket
                        // (across a suspension, or with a failed Bonjour
                        // registration). Without this the server kept
                        // claiming to run on a port that refused everyone.
                        Task { @MainActor in self?.listenerDied(listener, state) }
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            self.listener = nil
            throw error
        }
    }

    /// A running listener failed or was cancelled behind our back: log why
    /// and listen again, on the same port if it is still free. A deliberate
    /// `stop()` has already cleared `listener`, so it is left alone.
    private func listenerDied(_ dead: NWListener, _ state: NWListener.State) {
        guard listener === dead else { return }
        log.error("listener on port \(self.port ?? 0, privacy: .public) stopped: \(String(describing: state), privacy: .public); restarting")
        dead.cancel()
        listener = nil
        port = nil
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard listener == nil else { return }
            try? await start()
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

        // Help stays open so a model can learn how to authenticate; what it
        // shows past that needs the token.
        if request.method == "GET", path == "/" || path == "/_help" {
            return (help(request), nil)
        }

        if let failure = authenticate(request) {
            return (errorResponse(failure), nil)
        }
        if let failure = await approve(request) {
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
            return (jsonResponse(200, ["tools": .array(servedCatalog.map(MCPHandler.toolDefinition))]), nil)
        case "/_call":
            guard request.method == "POST" else {
                return (errorResponse(DebugError(.methodNotAllowed, "/_call takes POST",
                                                 hint: #"POST {"name": "<endpoint>", "arguments": {...}}"#)), nil)
            }
            guard let body = try? JSONValue.parse(request.body), let name = body["name"]?.stringValue else {
                return (errorResponse(.invalidArgument(#"body must be {"name": "<endpoint>", "arguments": {...}}"#)), nil)
            }
            if let failure = await gateCodePatching(name, for: request) { return (errorResponse(failure, endpoint: name), nil) }
            return await invoke(name, arguments: body["arguments"]?.objectValue ?? [:], pretty: false)
        default:
            break
        }

        if path.hasPrefix("/_traces/"), request.method == "GET", !configuration.confidential {
            return (traceDownload(String(path.dropFirst("/_traces/".count))), nil)
        }

        let name = String(path.dropFirst())
        guard let endpoint = surface.endpoint(named: name), permits(endpoint) else {
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
        if let failure = await gateCodePatching(name, for: request) { return (errorResponse(failure, endpoint: name), nil) }
        return await invoke(name, arguments: arguments, pretty: pretty)
    }

    private func invoke(_ name: String, arguments: [String: JSONValue], pretty: Bool) async -> Reply {
        let start = ContinuousClock.now
        switch await call(name, arguments: arguments) {
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

    // MARK: Confidential profile

    /// Whether this server may serve `endpoint` at all. Always yes, unless
    /// `configuration.confidential`: then only a query its author marked
    /// `releaseSafe` (free of personal content), and never a command.
    func permits(_ endpoint: DebugEndpoint) -> Bool {
        !configuration.confidential || (endpoint.kind == .query && endpoint.releaseSafe)
    }

    /// The endpoints a client can see and call.
    var servedCatalog: [DebugEndpoint] { surface.catalog.filter(permits) }

    /// `surface.call`, minus what this server's profile withholds. A withheld
    /// endpoint answers as unknown names do, so a probe learns nothing about
    /// what the app has.
    func call(_ name: String, arguments: [String: JSONValue]) async -> Result<DebugResult, DebugError> {
        if configuration.confidential, !(surface.endpoint(named: name).map(permits) ?? false) {
            return .failure(surface.notFound(name))
        }
        return await surface.call(name, arguments: arguments)
    }

    /// Endpoints that make the app run code a client sent. Each needs its own
    /// allowance on the device, per client and per launch, on top of access.
    nonisolated static let codePatchingEndpoints: Set<String> = ["_inject"]

    /// Nil unless `name` loads code and the person at the device hasn't allowed that.
    func gateCodePatching(_ name: String, for request: HTTPRequest) async -> DebugError? {
        guard Self.codePatchingEndpoints.contains(name) else { return nil }
        return await approve(request, purpose: .codePatching)
    }

    /// Nil when the person at the device has allowed this client for this launch.
    private func approve(_ request: HTTPRequest, purpose: DebugApprovalRequest.Purpose = .access) async -> DebugError? {
        let client = DebugApprovals.clientName(header: request.header("x-debugtrace-client"),
                                               userAgent: request.header("user-agent"))
        let appName = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (Bundle.main.infoDictionary?["CFBundleName"] as? String) ?? "this app"
        let what = purpose == .access ? "debug access" : "code changes"
        switch await approvals.allowed(client, appName: appName, purpose: purpose, timeout: configuration.approvalTimeout) {
        case .allowed:
            return nil
        case .declined:
            return DebugError(.forbidden, "\(what) for \"\(client)\" was declined on the device",
                              hint: "relaunch the app to be asked again, and choose Allow")
        case .silenced(let until):
            return DebugError(.forbidden, "the device is refusing new debug clients without asking, until \(DebugTime.iso(until))",
                              hint: "after declining requests, the person at the device silenced the prompt; relaunch the app to be asked again")
        case .waiting:
            return DebugError(.forbidden, "waiting for someone to allow \(what) for \"\(client)\" on the device",
                              hint: "accept the prompt in the app (it must be in the foreground), then retry")
        }
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
        // Without this build's token, only how to authenticate: the app's
        // name, version and endpoint list would identify it to anyone who
        // finds the port.
        if token != nil, authenticate(request) != nil {
            return .json(200, HelpDocument.anonymous().serialized(pretty: request.query["pretty"] != "0"))
        }
        let only = request.query["endpoint"]
        if let only, !(surface.endpoint(named: only).map(permits) ?? false) {
            return errorResponse(surface.notFound(only))
        }
        let document = HelpDocument.build(catalog: servedCatalog, baseURL: baseURL(request),
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
        "http://\(request.header("host") ?? "127.0.0.1:\(port ?? configuration.ports.lowerBound)")"
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
