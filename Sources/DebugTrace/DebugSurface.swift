import Foundation
import os

/// The app's registry of debug endpoints — one list that the HTTP server, the
/// MCP endpoint and the debug trace all read.
///
/// That single list is the point: whatever an app exposes for a model to
/// query live is, with no extra code, what a trace captures for a model to
/// read later. A feature adds an endpoint here once and appears everywhere.
///
/// `@MainActor`, like the servers it replaces: handlers read app models
/// race-free with no snapshot plumbing, and traffic is a handful of small
/// requests while someone is debugging.
@MainActor
public final class DebugSurface {
    public static let shared = DebugSurface()

    /// A file a trace includes as-is (LambdaVision's `crash.log`).
    public struct Attachment: Sendable {
        public let name: String
        public let provider: @MainActor @Sendable () async throws -> Data?
    }

    /// Names apps may register: camelCase, as tool names for MCP and as
    /// path segments for HTTP. Built-ins take a leading underscore.
    public static let namePattern = "^[a-z][A-Za-z0-9]{0,47}$"

    /// Endpoint results larger than this are refused from snapshots, so one
    /// runaway provider can't crowd out the rest of a trace.
    public static let snapshotProviderLimit = 512 * 1024

    public let allowCommands: Bool
    private var endpoints: [String: DebugEndpoint] = [:]
    private var order: [String] = []
    private var attachments: [String: Attachment] = [:]
    private let nameRegex = try! NSRegularExpression(pattern: DebugSurface.namePattern)

    /// - Parameter allowCommands: false makes this a read-only surface:
    ///   commands stay listed (so a model is told why) but refuse to run.
    public init(includeBuiltins: Bool = true, allowCommands: Bool = true) {
        self.allowCommands = allowCommands
        if includeBuiltins { registerBuiltins() }
    }

    // MARK: Registration

    /// Registers an endpoint, replacing one of the same name.
    public func register(_ endpoint: DebugEndpoint) {
        precondition(endpoint.isBuiltin || isValidName(endpoint.name),
                     "DebugSurface: '\(endpoint.name)' is not a valid endpoint name (\(Self.namePattern))")
        if endpoints[endpoint.name] == nil { order.append(endpoint.name) }
        endpoints[endpoint.name] = endpoint
    }

    public func register(_ endpoints: [DebugEndpoint]) {
        for endpoint in endpoints { register(endpoint) }
    }

    public func unregister(_ name: String) {
        endpoints[name] = nil
        order.removeAll { $0 == name }
    }

    public func registerAttachment(_ name: String, provider: @escaping @MainActor @Sendable () async throws -> Data?) {
        attachments[name] = Attachment(name: name, provider: provider)
    }

    public func unregisterAttachment(_ name: String) {
        attachments[name] = nil
    }

    private func isValidName(_ name: String) -> Bool {
        nameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    // MARK: Lookup

    /// Built-ins first, then app endpoints in registration order.
    public var catalog: [DebugEndpoint] {
        let all = order.compactMap { endpoints[$0] }
        return all.filter(\.isBuiltin) + all.filter { !$0.isBuiltin }
    }

    public func endpoint(named name: String) -> DebugEndpoint? { endpoints[name] }

    public var registeredAttachments: [Attachment] {
        attachments.values.sorted { $0.name < $1.name }
    }

    public func notFound(_ name: String) -> DebugError {
        let suggestions = DebugSuggest.ranked(name, in: order)
        return DebugError(
            .notFound, "no endpoint named '\(name)'",
            hint: suggestions.isEmpty
                ? "list endpoints with _help"
                : "did you mean \(suggestions.map { "'\($0)'" }.joined(separator: " or "))? list endpoints with _help",
            details: suggestions.isEmpty ? nil : .object(["suggestions": .array(suggestions.map(JSONValue.string))]))
    }

    // MARK: Calling

    /// Validates `arguments` against the endpoint's parameters and runs it.
    /// Never throws: every failure comes back as a `DebugError`, the shape
    /// every transport reports.
    public func call(_ name: String, arguments: [String: JSONValue] = [:]) async -> Result<DebugResult, DebugError> {
        guard let endpoint = endpoints[name] else { return .failure(notFound(name)) }
        if endpoint.kind == .command && !allowCommands {
            return .failure(DebugError(.forbidden, "'\(name)' is a command and this surface is read-only",
                                       hint: "queries still work; see _help"))
        }
        let validated: DebugArguments
        do {
            validated = try validate(arguments, for: endpoint)
        } catch {
            return .failure(error)
        }
        return await Self.run(endpoint, with: validated)
    }

    func validate(_ arguments: [String: JSONValue], for endpoint: DebugEndpoint) throws(DebugError) -> DebugArguments {
        let declared = Dictionary(uniqueKeysWithValues: endpoint.parameters.map { ($0.name, $0) })
        for key in arguments.keys.sorted() where declared[key] == nil {
            let accepted = endpoint.parameters.map(\.signature)
            let suggestion = DebugSuggest.closest(to: key, in: Array(declared.keys))
            var hint = accepted.isEmpty
                ? "'\(endpoint.name)' takes no arguments"
                : "accepted: \(accepted.joined(separator: "; "))"
            if let suggestion { hint = "did you mean '\(suggestion)'? " + hint }
            throw .invalidArgument("unknown argument '\(key)' for '\(endpoint.name)'", hint: hint)
        }
        var values: [String: JSONValue] = [:]
        var missing: [DebugParameter] = []
        for parameter in endpoint.parameters {
            if let raw = arguments[parameter.name], raw != .null {
                values[parameter.name] = try parameter.coerce(raw, endpoint: endpoint.name)
            } else if let defaultValue = parameter.defaultValue {
                values[parameter.name] = defaultValue
            } else if parameter.required {
                missing.append(parameter)
            }
        }
        if !missing.isEmpty {
            throw .invalidArgument(
                "missing required argument\(missing.count == 1 ? "" : "s") for '\(endpoint.name)': \(missing.map(\.name).joined(separator: ", "))",
                hint: "expected \(missing.map(\.signature).joined(separator: "; "))")
        }
        return DebugArguments(values, endpoint: endpoint.name)
    }

    /// Runs a handler with the endpoint's timeout. A handler that overruns
    /// is cancelled and its eventual result dropped; the caller has already
    /// been told `timeout`.
    private static func run(_ endpoint: DebugEndpoint, with arguments: DebugArguments) async -> Result<DebugResult, DebugError> {
        let once = OSAllocatedUnfairLock(initialState: false)
        let handler = endpoint.handler
        let name = endpoint.name
        let timeout = endpoint.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<DebugResult, DebugError>, Never>) in
            // The timer is cancelled as soon as the handler finishes, so a
            // fast call leaves nothing sleeping behind it.
            let timer = Task { try await Task.sleep(for: timeout) }
            let work = Task { @MainActor in
                let result: Result<DebugResult, DebugError>
                do {
                    result = .success(try await handler(arguments))
                } catch {
                    result = .failure(DebugError.wrapping(error))
                }
                timer.cancel()
                if once.withLock({ let first = !$0; $0 = true; return first }) {
                    continuation.resume(returning: result)
                }
            }
            Task {
                guard (try? await timer.value) != nil else { return }
                if once.withLock({ let first = !$0; $0 = true; return first }) {
                    work.cancel()
                    continuation.resume(returning: .failure(DebugError(
                        .timeout, "'\(name)' did not finish within \(timeout)",
                        hint: "the app may be busy or the handler is stuck; check _logs")))
                }
            }
        }
    }

    // MARK: Snapshot

    public struct Snapshot: Sendable {
        /// `{format, capturedAt, providers: {name: {version, ok, data | error | attachment, elapsedMs}}}`
        public let json: JSONValue
        /// Binary results of traced queries, keyed by their path in a trace.
        public let files: [String: Data]
    }

    /// Calls every traced query. What a trace captures and what `_snapshot`
    /// returns — the same code, so a model can check live what a trace would
    /// have recorded.
    public func snapshot(privacy: DebugPrivacyMode? = nil) async -> Snapshot {
        var providers: [String: JSONValue] = [:]
        var files: [String: Data] = [:]
        var withheld: [String] = []
        let privacy = privacy ?? DebugTrace.privacy
        for endpoint in catalog {
            guard let arguments = endpoint.traceArguments else { continue }
            // A release trace comes from a real user: only what an endpoint
            // declared free of personal data goes in.
            if privacy == .release && !endpoint.releaseSafe {
                withheld.append(endpoint.name)
                continue
            }
            let start = ContinuousClock.now
            let result = await call(endpoint.name, arguments: arguments)
            let elapsed = ContinuousClock.now - start
            var entry: [String: JSONValue] = [
                "version": .int(endpoint.version),
                "elapsedMs": .double(Self.milliseconds(elapsed)),
            ]
            switch result {
            case .success(let output):
                output.afterDelivery?()
                switch output.body {
                case .json(let value):
                    if value.serialized().count > Self.snapshotProviderLimit {
                        entry["ok"] = false
                        entry["error"] = DebugError(.tooLarge, "result exceeds \(Self.snapshotProviderLimit) bytes",
                                                    hint: "narrow its trace arguments or split it").json
                    } else {
                        entry["ok"] = true
                        entry["data"] = value
                    }
                case .binary(let binary):
                    let path = "attachments/\(binary.filename ?? "\(endpoint.name).bin")"
                    files[path] = binary.data
                    entry["ok"] = true
                    entry["attachment"] = .string(path)
                    entry["contentType"] = .string(binary.contentType)
                }
            case .failure(let error):
                entry["ok"] = false
                entry["error"] = error.json
            }
            providers[endpoint.name] = .object(entry)
        }
        var document: [String: JSONValue] = [
            "format": "debugsurface/1",
            "capturedAt": .string(DebugTime.iso(Date())),
            "privacy": .string(privacy.rawValue),
            "providers": .object(providers),
        ]
        if !withheld.isEmpty {
            // Named, so a reader knows the data exists and why it's absent.
            document["withheldInRelease"] = .array(withheld.map { .string($0) })
        }
        let json = JSONValue.object(document)
        return Snapshot(json: json, files: files)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return ((Double(seconds) * 1000 + Double(attoseconds) / 1e15) * 10).rounded() / 10
    }

    // MARK: Built-ins

    private func registerBuiltins() {
        register(.query("_info", "App identity (bundle id, git SHA build, version), device, process health (memory footprint, thermal state, uptime) and trace configuration, including the privacy mode and the log buffer's fill. Start here.",
                        releaseSafe: true) { _ in
            DebugAppInfo.current()
        })

        register(.query(
            "_logs",
            "This app's log lines, newest last. source=app (default) is the app's own logging, every level including debug, for the whole run up to the buffer's cap: cheap, call it as often as needed. source=system is the OS unified log of this process (Apple frameworks, code not yet on the app's logger): development builds only, info level and up, only the last few minutes, and each call makes the OS log daemon scan its whole archive (about 2 s, and it slows the device), so don't poll it. Both are gone after a relaunch (see _features for what persists). Values the app logged as private show as <private>; secrets are redacted.",
            parameters: [
                .string("source", "app: the app's own log buffer; system: the OS unified log (development builds only)",
                        default: "app", choices: ["app", "system"]),
                .integer("sinceSeconds", "how far back to read", default: 300, range: 1...86_400),
                .string("level", "minimum level", default: "info", choices: DebugLogLevel.allCases.map(\.rawValue)),
                .string("category", "only this logger category (exact match)"),
                .string("contains", "only entries whose message or category contains this text (case-insensitive, matched against the redacted text)"),
                .integer("limit", "maximum entries returned; the newest are kept", default: 200, range: 1...5_000),
                .string("format", "lines: one compact string per entry; json: objects", default: "lines", choices: ["lines", "json"]),
            ],
            trace: .never
        ) { arguments in
            let configuration = DebugTrace.configuration
            let system = arguments.string("source") == "system"
            if system && configuration.privacy == .release {
                throw DebugError(.forbidden, "the unified log is not readable in release builds",
                                 hint: "use source=app; release builds only share the app's own, privacy-filtered log")
            }
            if system && !configuration.systemLogReadable {
                throw DebugError(.forbidden, "this app does not share the unified log",
                                 hint: "use source=app; this app turned off includesSystemLog because framework log lines can carry personal data")
            }
            let query = DebugLogQuery(
                since: Date().addingTimeInterval(-Double(arguments.int("sinceSeconds") ?? 300)),
                subsystems: [],
                minimumLevel: DebugLogLevel(rawValue: arguments.string("level") ?? "info") ?? .info,
                category: arguments.string("category"),
                contains: arguments.string("contains"),
                limit: arguments.int("limit") ?? 200)
            let result = system
                ? try await Task.detached(priority: .utility) {
                    try DebugLogReader.read(query, redactor: configuration.redactor)
                }.value
                : DebugLogReader.buffered(query, redactor: configuration.redactor)
            let primary = configuration.subsystems.first
            let entries: JSONValue = arguments.string("format") == "json"
                ? try JSONValue(encoding: result.entries)
                : .array(result.entries.map { .string($0.line(primarySubsystem: primary)) })
            return DebugLogsReply(source: system ? "system" : "app", entries: entries,
                                  returned: result.entries.count, matched: result.matched,
                                  truncated: result.truncated,
                                  buffer: system ? nil : DebugLogBuffer.shared.stats)
        })

        register(.query("_features", "Features in use right now, and this session's recent feature marks, newest last. The marks also persist across relaunches in a trace's breadcrumbs files.",
                        parameters: [.integer("limit", "recent marks returned", default: 50, range: 1...500)],
                        releaseSafe: true) { arguments in
            let crumbs = DebugTrace.breadcrumbs
            return DebugFeaturesReply(session: crumbs.sessionId,
                                      sessionStartedAt: DebugTime.iso(crumbs.sessionStartedAt),
                                      active: crumbs.active,
                                      recent: crumbs.recent(limit: arguments.int("limit") ?? 50))
        })

        register(.raw("_snapshot", kind: .query,
                      "Every traced query's current result in one document — exactly what a debug trace would capture as snapshot.json.",
                      trace: .never) { [weak self] _ in
            guard let self else { throw DebugError.unavailable("surface is gone") }
            return DebugResult(body: .json(await self.snapshot().json))
        })

        register(.command(
            "_trace",
            "Build a debug trace archive (logs, breadcrumbs, snapshot, info; signed when the build carries a key) and optionally upload it to the app store server. Returns its manifest and, over HTTP, a download path.",
            parameters: [
                .string("note", "what was being investigated; stored as note.txt"),
                .boolean("upload", "also upload it to the store", default: false),
                .integer("logMinutes", "minutes of log history to include", default: 30, range: 1...1_440),
            ],
            timeout: .seconds(120)
        ) { [weak self] arguments in
            guard let self else { throw DebugError.unavailable("surface is gone") }
            let archive = try await DebugTrace.capture(
                note: arguments.string("note"), surface: self,
                logWindowSeconds: (arguments.int("logMinutes") ?? 30) * 60)
            var upload: DebugTraceUploadResult?
            if arguments.bool("upload") == true {
                upload = try await DebugTrace.upload(archive)
            }
            return DebugTraceReply(traceId: archive.id, filename: archive.filename, bytes: archive.bytes,
                                   signed: archive.signed, download: "/_traces/\(archive.id).zip",
                                   files: archive.manifest.files, upload: upload)
        })
    }
}

struct DebugLogsReply: Encodable {
    let source: String
    let entries: JSONValue
    let returned: Int
    let matched: Int
    let truncated: Bool
    /// For source=app: fill and evictions, so a reader can tell "nothing
    /// happened" from "it scrolled out".
    let buffer: DebugLogBuffer.Stats?
}

struct DebugFeaturesReply: Encodable {
    let session: String
    let sessionStartedAt: String
    let active: [DebugActiveFeature]
    let recent: [DebugBreadcrumb]
}

struct DebugTraceReply: Encodable {
    let traceId: String
    let filename: String
    let bytes: Int
    let signed: Bool
    let download: String
    let files: [DebugTraceFile]
    let upload: DebugTraceUploadResult?
}
