import Foundation
import os

public struct DebugTraceConfiguration: Sendable {
    /// Log subsystems a trace and `_logs` read. The first is the app's own.
    /// Add any subsystem the app or its packages log under that is not the
    /// bundle identifier — those lines are otherwise invisible.
    public var subsystems: [String]
    /// How much log history a trace includes.
    public var logWindowSeconds: Int
    public var maxLogEntries: Int
    public var redactor: DebugRedactor

    public init(
        subsystems: [String]? = nil,
        logWindowSeconds: Int = 30 * 60,
        maxLogEntries: Int = 20_000,
        redactor: DebugRedactor = .standard
    ) {
        self.subsystems = subsystems ?? [Bundle.main.bundleIdentifier].compactMap { $0 }
        self.logWindowSeconds = logWindowSeconds
        self.maxLogEntries = maxLogEntries
        self.redactor = redactor
    }
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
    }

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
    public static func mark(_ event: String, _ detail: String? = nil) {
        breadcrumbs.mark(event, detail)
    }

    public static func begin(_ feature: String, _ detail: String? = nil) {
        breadcrumbs.begin(feature, detail)
    }

    public static func end(_ feature: String, _ detail: String? = nil) {
        breadcrumbs.end(feature, detail)
    }

    // MARK: Capture

    /// The last few archives, newest last; the server serves them for
    /// download by id.
    @MainActor public private(set) static var recentArchives: [DebugTraceArchive] = []

    @MainActor
    public static func capture(
        note: String? = nil,
        surface: DebugSurface = .shared,
        logWindowSeconds: Int? = nil
    ) async throws -> DebugTraceArchive {
        let archive = try await DebugTraceBuilder.build(
            note: note, surface: surface, configuration: configuration, credential: credential,
            logWindowSeconds: logWindowSeconds)
        recentArchives.append(archive)
        if recentArchives.count > DebugTraceBuilder.keptArchives {
            recentArchives.removeFirst(recentArchives.count - DebugTraceBuilder.keptArchives)
        }
        mark("_trace.captured", archive.id)
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
        mark("_trace.uploaded", "\(archive.id) → \(status)")
        return DebugTraceUploadResult(statusCode: status, accepted: (200..<300).contains(status), response: body)
    }
}

public struct DebugTraceUploadResult: Codable, Sendable {
    public let statusCode: Int
    public let accepted: Bool
    public let response: JSONValue?
}
