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
                    // A crash's call-stack tree nests once per frame: converted on a
                    // deep stack, with each frame tree flattened as it is encoded,
                    // so nothing deep is ever stored (see Self.flattened).
                    let json: JSONValue? = DebugDeepStack.run {
                        let encoder = JSONValueEncoder()
                        encoder.intercept = { value in
                            (value as? ContiguousArray<CallStackFrame>).map(Self.flatFrames)
                        }
                        return (try? encoder.encode(report)).map(Self.flattened)
                    }
                    guard let json else { continue }
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
        let report = report.isDeep ? DebugDeepStack.run { Self.flattened(report) } : report
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

    // MARK: Flat frames

    /// MetricKit nests a call stack one level per frame (`subFrames`), which
    /// no coder here can take at any real depth: 300 frames overflowed a
    /// task's stack (Hypnos, 2026-10-11) and 256 hit Foundation's 512-level
    /// limit. Stored reports carry each tree as a flat list instead: every
    /// `rootFrames` (27+) or `callStackRootFrames` (older) becomes `frames`,
    /// the tree's frames in depth-first order, each with its `depth` (0 for a
    /// root) and without `subFrames`. A frame's children are the frames after
    /// it one level deeper, up to the next frame at its own depth or less.
    static func flattened(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map(flattened))
        case .object(let members):
            var out: [String: JSONValue] = [:]
            for (key, member) in members {
                if key == "rootFrames" || key == "callStackRootFrames" {
                    let roots: [JSONValue] = member.arrayValue ?? [member]
                    // Already flat (flattened as MetricKit's report was encoded).
                    let flat = roots.allSatisfy { $0["depth"] != nil && $0["subFrames"] == nil }
                    out["frames"] = .array(flat ? roots : flatFrames(roots))
                } else {
                    out[key] = flattened(member)
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    /// Depth-first, without recursion.
    static func flatFrames(_ roots: [JSONValue]) -> [JSONValue] {
        var out: [JSONValue] = []
        var pending: [(JSONValue, Int)] = roots.reversed().map { ($0, 0) }
        while let (frame, depth) = pending.popLast() {
            guard var members = frame.objectValue else { continue }
            let children = members.removeValue(forKey: "subFrames")?.arrayValue ?? []
            members["depth"] = .int(depth)
            out.append(.object(members))
            for child in children.reversed() { pending.append((child, depth + 1)) }
        }
        return out
    }

    #if canImport(MetricKit) && !os(tvOS)
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    static func flatFrames(_ roots: ContiguousArray<CallStackFrame>) -> JSONValue {
        var out: [JSONValue] = []
        var pending: [(CallStackFrame, Int)] = roots.reversed().map { ($0, 0) }
        while let (frame, depth) = pending.popLast() {
            var members: [String: JSONValue] = ["depth": .int(depth)]
            if let uuid = frame.binaryUUID { members["binaryUUID"] = .string(uuid.uuidString) }
            if let address = frame.address { members["address"] = .int(Int(clamping: address)) }
            if let offset = frame.offsetIntoBinaryTextSegment { members["offsetIntoBinaryTextSegment"] = .int(Int(clamping: offset)) }
            if let count = frame.sampleCount { members["sampleCount"] = .int(count) }
            out.append(.object(members))
            for child in frame.subFrames.reversed() { pending.append((child, depth + 1)) }
        }
        return .array(out)
    }
    #endif

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
            let url = directory.appendingPathComponent(name)
            guard var data = try? Data(contentsOf: url) else { continue }
            // Stored before frames were flattened: flatten it once, on a deep
            // stack, and keep the flat copy.
            if JSONValue.nesting(of: data) > DebugDeepStack.depthThreshold {
                guard let flat = DebugDeepStack.run({ () -> Data? in
                    guard var deep = try? JSONValue.parse(data) else { return nil }
                    let flat = Self.flattened(deep).serialized()
                    JSONValue.dismantle(&deep)
                    return flat
                }) else { continue }
                try? flat.write(to: url, options: .atomic)
                data = flat
            }
            guard let envelope = try? JSONValue.parse(data),
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
            let data = payload.jsonRepresentation()
            guard let json: JSONValue = DebugDeepStack.run({
                guard var deep = try? JSONValue.parse(data) else { return nil }
                let flat = DebugCrashReports.flattened(deep)
                JSONValue.dismantle(&deep)
                return flat
            }) else { continue }
            handler(kinds, json)
        }
    }
}
#endif
