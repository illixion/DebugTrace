import CryptoKit
import Foundation
import os
#if canImport(MetricKit) && !os(tvOS)
import MetricKit
#endif

/// One batch of diagnostics the OS delivered about an earlier run.
public struct DebugCrashReport: Sendable, Identifiable {
    public let id: String
    public let receivedAt: Date
    /// `crash`, `hang`, `cpuException`, `diskWriteException`, `appLaunch`.
    public let kinds: [String]
    /// The stored envelope: `{id, receivedAt, source, kinds, report}`, where
    /// `report` is MetricKit's own JSON.
    public let data: Data
}

/// Crash, hang and resource-exception diagnostics from MetricKit, kept on disk
/// until a trace carries them off the device.
///
/// An app cannot read the `.ips` files in Settings, but the OS hands the app
/// the same events through MetricKit on the launch after they happen: no signal
/// handler, and it sees kills (watchdog, memory) that one cannot. The report is
/// a call-stack tree of binary UUIDs and offsets, not a symbolicated crash log;
/// the store symbolicates it. See [traces.md](../../Docs/traces.md).
///
/// Lock-guarded like `DebugBreadcrumbs`: MetricKit calls back on its own queue.
public final class DebugCrashReports: @unchecked Sendable {
    public static let shared = DebugCrashReports(
        directory: DebugBreadcrumbs.defaultDirectory?.appendingPathComponent("Diagnostics", isDirectory: true))

    public let directory: URL?
    private let lock = NSLock()
    private var started = false
    private var didRecord: (@Sendable () -> Void)?
    #if canImport(MetricKit) && !os(tvOS)
    private var retained: [AnyObject] = []
    #endif

    static let keptReports = 20
    static let maxAge: TimeInterval = 14 * 24 * 3600
    private static let uploadsFile = "uploads.json"

    public init(directory: URL?) {
        self.directory = directory
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Intake

    /// Subscribes to MetricKit. Idempotent. `didRecord` runs after each new
    /// report is stored. Does nothing on tvOS (no MetricKit) or in a process
    /// with no identity of its own, such as a test runner.
    public func start(didRecord: (@Sendable () -> Void)? = nil) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        self.didRecord = didRecord
        lock.unlock()
        #if canImport(MetricKit) && !os(tvOS)
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.hasPrefix("com.apple.") else { return }
        // DEBUGTRACE_LEGACY_METRICKIT=1 forces the pre-27 path, to test it on a 27 device.
        let forceLegacy = ProcessInfo.processInfo.environment["DEBUGTRACE_LEGACY_METRICKIT"] == "1"
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *), !forceLegacy {
            let manager = MetricManager()
            let task = Task { [weak self] in
                for await report in manager.diagnosticReports {
                    guard let self else { return }
                    let kind: String
                    switch report.result {
                    case .crash: kind = "crash"
                    case .hang: kind = "hang"
                    case .cpuException: kind = "cpuException"
                    case .diskWriteException: kind = "diskWriteException"
                    case .appLaunch: kind = "appLaunch"
                    @unknown default: kind = "unknown"
                    }
                    guard let json = try? JSONValue(encoding: report) else { continue }
                    self.record(kinds: [kind], report: json, source: "MetricManager")
                }
            }
            lock.lock(); retained = [manager, TaskBox(task)]; lock.unlock()
        } else {
            let subscriber = LegacySubscriber { [weak self] kinds, json in
                self?.record(kinds: kinds, report: json, source: "MXMetricManager")
            }
            lock.lock(); retained = [subscriber]; lock.unlock()
            MXMetricManager.shared.add(subscriber)
        }
        #endif
    }

    func record(kinds: [String], report: JSONValue, source: String) {
        guard let directory else { return }
        let digest = SHA256.hash(data: report.serialized()).prefix(6).map { String(format: "%02x", $0) }.joined()
        let now = Date()
        let url = directory.appendingPathComponent("\(digest).json")
        lock.lock()
        defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let envelope: JSONValue = [
            "id": .string(digest),
            "receivedAt": .string(DebugTime.iso(now)),
            "source": .string(source),
            "kinds": .array(kinds.map(JSONValue.string)),
            "report": report,
        ]
        do { try envelope.serialized().write(to: url, options: .atomic) } catch { return }
        prune(directory)
        let callback = didRecord
        DispatchQueue.global(qos: .utility).async { callback?() }
    }

    // MARK: Reading

    /// Stored reports, oldest first. `pendingOnly` leaves out those already
    /// uploaded or refused by the store.
    public func reports(pendingOnly: Bool = false) -> [DebugCrashReport] {
        lock.lock()
        defer { lock.unlock() }
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let done = uploadStates(directory)
        var reports: [DebugCrashReport] = []
        for name in names where name.hasSuffix(".json") && name != Self.uploadsFile {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let envelope = try? JSONValue.parse(data),
                  let id = envelope["id"]?.stringValue else { continue }
            if pendingOnly, done[id] != nil { continue }
            let received = envelope["receivedAt"]?.stringValue.flatMap { try? Date($0, strategy: .iso8601.year().month().day()
                .time(includingFractionalSeconds: true).timeZone(separator: .omitted)) } ?? .distantPast
            let kinds = envelope["kinds"]?.arrayValue?.compactMap(\.stringValue) ?? []
            reports.append(DebugCrashReport(id: id, receivedAt: received, kinds: kinds, data: data))
        }
        return reports.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// What a hand-captured trace carries as context: the last week's, at
    /// most ten, newest kept.
    public func recent(limit: Int = 10, within seconds: TimeInterval = 7 * 24 * 3600) -> [DebugCrashReport] {
        let cutoff = Date().addingTimeInterval(-seconds)
        return Array(reports().filter { $0.receivedAt >= cutoff }.suffix(limit))
    }

    /// Records the store's verdict so an uploaded or refused report is not
    /// sent again. A failed attempt is not recorded: it retries next launch.
    public func markDone(_ ids: [String], state: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let directory else { return }
        var states = uploadStates(directory)
        for id in ids { states[id] = state }
        if let data = try? JSONEncoder().encode(states) {
            try? data.write(to: directory.appendingPathComponent(Self.uploadsFile), options: .atomic)
        }
    }

    // MARK: Files

    private func uploadStates(_ directory: URL) -> [String: String] {
        (try? Data(contentsOf: directory.appendingPathComponent(Self.uploadsFile)))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    /// Called with the lock held. Drops reports past the age or count cap.
    private func prune(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        let reports = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.uploadsFile }
            .map { ($0, (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        for (index, entry) in reports.enumerated() where index >= Self.keptReports || entry.1 < cutoff {
            try? FileManager.default.removeItem(at: entry.0)
        }
    }
}

#if canImport(MetricKit) && !os(tvOS)
private final class TaskBox: @unchecked Sendable {
    let task: Task<Void, Never>
    init(_ task: Task<Void, Never>) { self.task = task }
    deinit { task.cancel() }
}

/// The pre-iOS 27 delivery path.
private final class LegacySubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let handler: @Sendable ([String], JSONValue) -> Void

    init(handler: @escaping @Sendable ([String], JSONValue) -> Void) {
        self.handler = handler
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            var kinds: [String] = []
            if payload.crashDiagnostics?.isEmpty == false { kinds.append("crash") }
            if payload.hangDiagnostics?.isEmpty == false { kinds.append("hang") }
            if payload.cpuExceptionDiagnostics?.isEmpty == false { kinds.append("cpuException") }
            if payload.diskWriteExceptionDiagnostics?.isEmpty == false { kinds.append("diskWriteException") }
            #if !os(macOS)
            if payload.appLaunchDiagnostics?.isEmpty == false { kinds.append("appLaunch") }
            #endif
            guard let json = try? JSONValue.parse(payload.jsonRepresentation()) else { continue }
            handler(kinds, json)
        }
    }
}
#endif
