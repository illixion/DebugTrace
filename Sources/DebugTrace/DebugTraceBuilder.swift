import CryptoKit
import Foundation

public struct DebugTraceFile: Codable, Sendable, Equatable {
    public let path: String
    public let bytes: Int
    public let sha256: String
}

/// `manifest.json`. Signed byte-for-byte as written; the verifier hashes
/// every listed file and rejects any file not listed.
public struct DebugTraceManifest: Codable, Sendable {
    public struct App: Codable, Sendable {
        public let bundleId: String
        public let name: String
        public let version: String
        public let build: String
        public let platform: String
    }

    public struct Device: Codable, Sendable {
        public let model: String
        public let os: String
    }

    public struct Signature: Codable, Sendable {
        public let algorithm: String
        public let keyId: String
    }

    public let format: String
    public let traceId: String
    public let createdAt: String
    public let session: String
    public let app: App
    public let device: Device
    public let note: String?
    /// Absent when the build carries no credential; `manifest.sig` is then
    /// absent too.
    public let signature: Signature?
    public let files: [DebugTraceFile]
}

public struct DebugTraceArchive: Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let filename: String
    public let bytes: Int
    public let manifest: DebugTraceManifest
    /// The text files' contents, so the person sending a trace can read
    /// exactly what leaves the device before it does.
    public let textFiles: [String: String]
    public var signed: Bool { manifest.signature != nil }
}

/// Assembles a trace. Layout:
///
/// ```
/// manifest.json      what is in here, with hashes; the signed document
/// manifest.sig       64-byte Ed25519 signature over manifest.json (signed builds)
/// README.md          this layout, for whoever — or whatever — opens the zip
/// info.json          _info
/// snapshot.json      every traced query (DebugSurface.snapshot)
/// logs.txt           the app's own log buffer, newest last
/// system-log.txt     the process's unified log (development builds only)
/// breadcrumbs.jsonl  feature marks, this session and earlier ones
/// breadcrumbs.previous.jsonl
/// note.txt           the reporter's note
/// attachments/…      registered attachments and binary query results
/// ```
enum DebugTraceBuilder {
    static let format = "debugtrace/1"
    static let keptArchives = 5

    @MainActor
    static func build(
        note: String?,
        surface: DebugSurface,
        configuration: DebugTraceConfiguration,
        credential: DebugTraceCredential?,
        logWindowSeconds: Int?
    ) async throws -> DebugTraceArchive {
        let redactor = configuration.redactor
        let traceId = UUID().uuidString.lowercased()
        let createdAt = Date()
        let info = DebugAppInfo.current()
        var files: [(path: String, data: Data)] = []

        files.append(("README.md", Data(readme.utf8)))
        files.append(("info.json", redactor.redact(try JSONValue(encoding: info)).serialized(pretty: true)))

        let snapshot = await surface.snapshot(privacy: configuration.privacy)
        files.append(("snapshot.json", redactor.redact(snapshot.json).serialized(pretty: true)))
        for (path, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
            files.append((path, data))
        }

        let window = logWindowSeconds ?? configuration.logWindowSeconds
        files.append(("logs.txt", Data(bufferText(configuration: configuration, windowSeconds: window).utf8)))
        if configuration.resolvedIncludesSystemLog {
            files.append(("system-log.txt", Data(await systemLogText(configuration: configuration, windowSeconds: window).utf8)))
        }

        let crumbs = DebugTrace.breadcrumbs.fileContents()
        if let current = crumbs.current {
            files.append(("breadcrumbs.jsonl", Data(redactor.redact(String(decoding: current, as: UTF8.self)).utf8)))
        }
        if let previous = crumbs.previous {
            files.append(("breadcrumbs.previous.jsonl", Data(redactor.redact(String(decoding: previous, as: UTF8.self)).utf8)))
        }

        if let note, !note.isEmpty {
            files.append(("note.txt", Data(redactor.redact(note).utf8)))
        }

        for attachment in surface.registeredAttachments {
            do {
                if let data = try await attachment.provider() {
                    files.append(("attachments/\(attachment.name)", data))
                }
            } catch {
                files.append(("attachments/\(attachment.name).error.txt", Data(String(describing: error).utf8)))
            }
        }

        let listed = files.map {
            DebugTraceFile(path: $0.path, bytes: $0.data.count,
                           sha256: SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined())
        }
        let manifest = DebugTraceManifest(
            format: format, traceId: traceId, createdAt: DebugTime.iso(createdAt),
            session: info.trace.session,
            app: .init(bundleId: info.app.bundleId, name: info.app.name, version: info.app.version,
                       build: info.app.build, platform: info.app.platform),
            device: .init(model: info.device.model, os: info.device.os),
            note: note?.isEmpty == false ? note : nil,
            signature: credential.map { .init(algorithm: "ed25519", keyId: $0.keyId) },
            files: listed)
        let manifestData = try JSONValue(encoding: manifest).serialized(pretty: true)

        var zip = ZipWriter()
        try zip.add(path: "manifest.json", data: manifestData, modified: createdAt)
        if let credential {
            try zip.add(path: "manifest.sig", data: try credential.sign(manifestData), modified: createdAt)
        }
        for file in files {
            try zip.add(path: file.path, data: file.data, modified: createdAt)
        }
        let archiveData = zip.finish()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DebugTrace", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = archiveName(app: info.app.name, date: createdAt, traceId: traceId)
        let url = directory.appendingPathComponent(filename)
        try archiveData.write(to: url, options: .atomic)
        prune(directory)
        let textExtensions: Set<String> = ["txt", "json", "jsonl", "md"]
        var textFiles: [String: String] = [:]
        for file in files where textExtensions.contains((file.path as NSString).pathExtension) {
            textFiles[file.path] = String(decoding: file.data, as: UTF8.self)
        }
        return DebugTraceArchive(id: traceId, url: url, filename: filename, bytes: archiveData.count,
                                 manifest: manifest, textFiles: textFiles)
    }

    private static func bufferText(configuration: DebugTraceConfiguration, windowSeconds: Int) -> String {
        let query = DebugLogQuery(since: Date().addingTimeInterval(-Double(windowSeconds)), subsystems: [],
                                  minimumLevel: .debug, limit: configuration.maxLogEntries)
        let logs = DebugLogReader.buffered(query, redactor: configuration.redactor)
        let stats = DebugLogBuffer.shared.stats
        var header = [
            "# the app's own log, last \(windowSeconds / 60) min, privacy mode \(stats.privacy.rawValue)",
            "# \(logs.entries.count) entries\(logs.truncated ? " (newest kept of \(logs.matched))" : ""); debug lines \(stats.capturesDebug ? "kept" : "not kept")",
        ]
        if stats.evicted > 0 {
            header.append("# the buffer dropped its \(stats.evicted) oldest entries this run to stay under \(stats.capacity) entries / \(stats.byteCapacity / 1024) KB")
        }
        return (header + logs.entries.map { $0.line(primarySubsystem: configuration.subsystems.first) })
            .joined(separator: "\n") + "\n"
    }

    private static func systemLogText(configuration: DebugTraceConfiguration, windowSeconds: Int) async -> String {
        let query = DebugLogQuery(since: Date().addingTimeInterval(-Double(windowSeconds)), subsystems: [],
                                  minimumLevel: .info, limit: configuration.maxLogEntries)
        let result = await Task.detached(priority: .utility) {
            Result { try DebugLogReader.read(query, redactor: configuration.redactor) }
        }.value
        var header = [
            "# unified log of this process, every subsystem, last \(windowSeconds / 60) min",
            "# the app's own lines are in logs.txt too; this adds Apple frameworks and code not on DebugLogger",
            "# the OS keeps no .debug entries and drops .info ones within minutes",
        ]
        switch result {
        case .success(let logs):
            header.append("# \(logs.entries.count) entries\(logs.truncated ? " (newest kept of \(logs.matched))" : "")")
            return (header + logs.entries.map { $0.line(primarySubsystem: configuration.subsystems.first) })
                .joined(separator: "\n") + "\n"
        case .failure(let error):
            header.append("# could not read the log store: \(error)")
            return header.joined(separator: "\n") + "\n"
        }
    }

    static func archiveName(app: String, date: Date, traceId: String) -> String {
        let safe = app.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(String(safe))-trace-\(formatter.string(from: date))-\(traceId.prefix(8)).zip"
    }

    private static func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys) else { return }
        let archives = contents.filter { $0.pathExtension == "zip" }.sorted {
            let a = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return a > b
        }
        for stale in archives.dropFirst(keptArchives) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    static let readme = """
    # Debug trace

    Captured by the app's DebugTrace package. Timestamps are ISO 8601 UTC.

    - `manifest.json`: app, build (git SHA from build-and-sign), device, and the SHA-256 of every
      other file. `manifest.sig` is an Ed25519 signature over manifest.json's exact bytes, made
      with the per-build key named in `signature.keyId`.
    - `info.json`: app identity, device, process health (memory footprint, thermal state).
    - `snapshot.json`: `providers.<name>` is the result of each debug-surface query at capture
      time: `{ok, data | error | attachment, version, elapsedMs}`. The same endpoints can be
      queried live over the app's debug server.
    - `logs.txt`: the app's own log lines for this run, `<time> <level> <category>: <message>`;
      levels D I N E F. Held in memory only, so earlier runs are not here.
    - `system-log.txt` (development builds only): the OS unified log of this process, which
      adds Apple frameworks and code outside the app's logger.
    - `breadcrumbs*.jsonl`: feature marks, persisted across launches — the only record of
      what happened before a crash. `session` changes at each launch; `X.begin`/`X.end`
      bracket a feature being in use.
    - `note.txt`: what the reporter was investigating.
    - `attachments/`: app-provided files and binary query results.

    Privacy: values the app logged as private appear as `<private>` (or `<hash:…>`, a hash
    salted per launch, so equal values match within one trace). Values that looked like
    secrets were replaced with `<redacted>`. `info.json` → `trace.privacy` says which mode
    captured this: in `release` mode (App Store and TestFlight builds), private values were
    never stored, and `snapshot.json` carries only endpoints the app declared free of personal
    data (`withheldInRelease` names the rest).
    """
}
