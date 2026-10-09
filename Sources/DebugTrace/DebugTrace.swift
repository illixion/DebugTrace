import Foundation
import os

public struct DebugTraceConfiguration: Sendable {
    /// The app's own log subsystems, the first being the primary one. Lines
    /// from `DebugLogger` are captured whatever their subsystem; this list
    /// only decides which subsystem is shown without a prefix, and which the
    /// unified-log reader treats as the app's.
    public var subsystems: [String]
    /// See `DebugPrivacyMode`. Detected from how the app was installed
    /// unless set.
    public var privacy: DebugPrivacyMode
    /// Whether `.debug` lines are kept in the buffer. Nil: on in development,
    /// off in release.
    public var capturesDebug: Bool?
    /// Whether the unified log (every subsystem in the process: Apple
    /// frameworks, packages still on `os.Logger`) may leave the app, in a
    /// trace or through `_logs source=system`. Nil: in development only. It
    /// costs a multi-second `logd` scan per read, and framework lines can carry
    /// user data the app never chose to log — so an app whose frameworks may
    /// log people (a messenger's call SDK) sets this false.
    public var includesSystemLog: Bool?
    /// How much log history a trace includes.
    public var logWindowSeconds: Int
    public var maxLogEntries: Int
    public var redactor: DebugRedactor
    /// Whether to collect the OS's crash, hang and resource-exception
    /// diagnostics about earlier runs (MetricKit) and, in a build with an
    /// upload destination, send them to the store on the next launch.
    public var collectsDiagnostics: Bool

    public init(
        subsystems: [String]? = nil,
        privacy: DebugPrivacyMode = .detected,
        capturesDebug: Bool? = nil,
        includesSystemLog: Bool? = nil,
        logWindowSeconds: Int = 30 * 60,
        maxLogEntries: Int = 20_000,
        redactor: DebugRedactor = .standard,
        collectsDiagnostics: Bool = true
    ) {
        self.subsystems = subsystems ?? [Bundle.main.bundleIdentifier].compactMap { $0 }
        self.privacy = privacy
        self.capturesDebug = capturesDebug
        self.includesSystemLog = includesSystemLog
        self.logWindowSeconds = logWindowSeconds
        self.maxLogEntries = maxLogEntries
        self.redactor = redactor
        self.collectsDiagnostics = collectsDiagnostics
    }

    var resolvedIncludesSystemLog: Bool { includesSystemLog ?? (privacy == .development) }

    /// Whether `_logs source=system` answers: never in release, and not when
    /// the app has opted out of sharing the unified log at all.
    var systemLogReadable: Bool { privacy == .development && resolvedIncludesSystemLog }
}

/// Entry points: configure once at launch, mark features as they are used,
/// capture a trace when something goes wrong.
///
/// ```swift
/// DebugTrace.configure(.init(subsystems: ["pro.longwave.ios", "pro.longwave"]))
/// DebugTrace.begin("pcvr.stream", "90 Hz, foveated")
/// ...
/// let archive = try await DebugTrace.capture(note: "audio dropped after 2 min")
/// ```
public enum DebugTrace {
    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var configuration = DebugTraceConfiguration()
        var credential: DebugTraceCredential? = DebugTraceCredential.load()
    }

    public static var configuration: DebugTraceConfiguration {
        state.withLock { $0.configuration }
    }

    public static func configure(_ configuration: DebugTraceConfiguration) {
        state.withLock { $0.configuration = configuration }
        DebugLogBuffer.shared.mode = configuration.privacy
        DebugLogBuffer.shared.capturesDebug = configuration.capturesDebug ?? (configuration.privacy == .development)
        if configuration.collectsDiagnostics {
            DebugCrashReports.shared.start {
                Task { @MainActor in await DebugTrace.uploadPendingDiagnostics() }
            }
            // Reports stored by an earlier launch whose upload did not finish.
            if !DebugCrashReports.shared.reports(pendingOnly: true).isEmpty {
                Task { @MainActor in await DebugTrace.uploadPendingDiagnostics() }
            }
        }
    }

    public static var privacy: DebugPrivacyMode { configuration.privacy }

    /// The bundle's embedded credential, if build-and-sign put one there.
    public static var credential: DebugTraceCredential? {
        state.withLock { $0.credential }
    }

    /// Replaces the credential — for tests, or a host that ships its own.
    public static func setCredential(_ credential: DebugTraceCredential?) {
        state.withLock { $0.credential = credential }
    }

    /// Whether `upload` has somewhere to send to.
    public static var canUpload: Bool { credential?.uploadURL != nil }

    // MARK: Breadcrumbs

    public static let breadcrumbs: DebugBreadcrumbs = {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return DebugBreadcrumbs(directory: DebugBreadcrumbs.defaultDirectory,
                                sessionDetail: "\(version) (\(build)) pid \(ProcessInfo.processInfo.processIdentifier)")
    }()

    /// Records a feature-level event. Callable from any thread.
    ///
    /// Breadcrumbs are written to disk and survive relaunches, so the detail
    /// is stored as exports show it: values not marked `.public` are
    /// withheld before the write, in both privacy modes. Event names are code
    /// identifiers (`world.streaming`), never user data.
    public static func mark(_ event: String, _ detail: DebugLogMessage? = nil) {
        breadcrumbs.mark(event, detail.map(storedDetail))
    }

    public static func begin(_ feature: String, _ detail: DebugLogMessage? = nil) {
        breadcrumbs.begin(feature, detail.map(storedDetail))
    }

    public static func end(_ feature: String, _ detail: DebugLogMessage? = nil) {
        breadcrumbs.end(feature, detail.map(storedDetail))
    }

    private static func storedDetail(_ detail: DebugLogMessage) -> String {
        configuration.redactor.redact(detail.redacted)
    }

    // MARK: Capture

    /// The last few archives, newest last; the server serves them for
    /// download by id.
    @MainActor public private(set) static var recentArchives: [DebugTraceArchive] = []

    @MainActor
    public static func capture(
        note: String? = nil,
        surface: DebugSurface = .shared,
        logWindowSeconds: Int? = nil,
        diagnostics: [DebugCrashReport]? = nil
    ) async throws -> DebugTraceArchive {
        let archive = try await DebugTraceBuilder.build(
            note: note, surface: surface, configuration: configuration, credential: credential,
            logWindowSeconds: logWindowSeconds,
            diagnostics: diagnostics ?? DebugCrashReports.shared.recent())
        recentArchives.append(archive)
        if recentArchives.count > DebugTraceBuilder.keptArchives {
            recentArchives.removeFirst(recentArchives.count - DebugTraceBuilder.keptArchives)
        }
        mark("_trace.captured", "\(archive.id, privacy: .public)")
        return archive
    }

    @MainActor
    public static func archive(id: String) -> DebugTraceArchive? {
        recentArchives.last { $0.id == id }
    }

    // MARK: Upload

    /// POSTs the archive to the store. The signature travels inside the zip
    /// (`manifest.sig`), so the same file verifies whether it arrives here
    /// or is dropped into the store's web UI after an AirDrop.
    public static func upload(_ archive: DebugTraceArchive, to destination: URL? = nil) async throws -> DebugTraceUploadResult {
        guard let url = destination ?? credential?.uploadURL else {
            throw DebugError.unavailable("this build has no upload URL",
                                         hint: "builds from build-and-sign embed one; share the file instead")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue(archive.id, forHTTPHeaderField: "X-DebugTrace-Id")
        if let keyId = archive.manifest.signature?.keyId {
            request.setValue(keyId, forHTTPHeaderField: "X-DebugTrace-Key-Id")
        }
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: archive.url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONValue.parse(data)) ?? (data.isEmpty ? nil : .string(String(decoding: data.prefix(2_000), as: UTF8.self)))
        mark("_trace.uploaded", "\(archive.id, privacy: .public) → \(status)")
        return DebugTraceUploadResult(statusCode: status, accepted: (200..<300).contains(status), response: body)
    }
}

extension DebugTrace {
    private static let diagnosticsUploading = OSAllocatedUnfairLock(initialState: false)

    /// Sends the OS diagnostics not yet uploaded as one trace, which also
    /// carries the breadcrumbs of the run that ended. Does nothing without an
    /// upload destination. A refusal by the store is final (the same trace
    /// would be refused again); a network failure retries at the next launch.
    @MainActor
    public static func uploadPendingDiagnostics() async {
        guard canUpload,
              diagnosticsUploading.withLock({ busy in defer { busy = true }; return !busy }) else { return }
        defer { diagnosticsUploading.withLock { $0 = false } }
        let pending = DebugCrashReports.shared.reports(pendingOnly: true)
        guard !pending.isEmpty else { return }
        let kinds = Set(pending.flatMap(\.kinds)).sorted().joined(separator: ", ")
        do {
            // The log window is short: this launch's own log says nothing about
            // the run that ended. The lead-up is in the breadcrumbs.
            let archive = try await capture(
                note: "Automatic report: \(pending.count) OS diagnostic(s) from an earlier run (\(kinds))",
                logWindowSeconds: 60, diagnostics: pending)
            let result = try await upload(archive)
            if result.accepted {
                DebugCrashReports.shared.markDone(pending.map(\.id), state: "uploaded")
            } else if (400..<500).contains(result.statusCode) {
                DebugCrashReports.shared.markDone(pending.map(\.id), state: "rejected")
            }
        } catch {
            mark("_diagnostics.uploadFailed", "\(String(describing: error), privacy: .public)")
        }
    }
}

public struct DebugTraceUploadResult: Codable, Sendable {
    public let statusCode: Int
    public let accepted: Bool
    public let response: JSONValue?
}
