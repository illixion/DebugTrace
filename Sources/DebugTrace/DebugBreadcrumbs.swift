import Foundation

/// One recorded event.
public struct DebugBreadcrumb: Codable, Sendable, Equatable {
    public let time: String
    public let session: String
    public let event: String
    public let detail: String?
}

/// A feature that is in use right now.
public struct DebugActiveFeature: Codable, Sendable, Equatable {
    public let name: String
    public let since: String
    public let detail: String?
}

/// Feature marks that survive a relaunch.
///
/// `OSLogStore` can only read the current process, so after a crash the log
/// that explains it is gone. This small JSONL file is what a trace has from
/// the previous run: which features were in use and what happened last.
/// Record *feature-level* events here — a stream starting, a world loading,
/// a mode switch — not per-frame ones: every mark is a synchronous file
/// append.
///
/// Lock-guarded rather than an actor so `mark` can be called from a render
/// thread or a network callback without an `await`, the same rule
/// RAVEEngine's collection layer follows.
public final class DebugBreadcrumbs: @unchecked Sendable {
    public let sessionId: String
    public let sessionStartedAt: Date
    public let directory: URL?
    let maxFileBytes: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var fileBytes = 0
    private var recentMarks: [DebugBreadcrumb] = []
    private var activeFeatures: [String: DebugActiveFeature] = [:]
    private static let recentLimit = 500

    public init(directory: URL?, maxFileBytes: Int = 256 * 1024, sessionDetail: String? = nil) {
        self.sessionId = String(UUID().uuidString.prefix(8)).lowercased()
        self.sessionStartedAt = Date()
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            openCurrentFile()
        }
        mark("_session.start", sessionDetail)
    }

    public var currentFileURL: URL? { directory?.appendingPathComponent("breadcrumbs.jsonl") }
    public var previousFileURL: URL? { directory?.appendingPathComponent("breadcrumbs.previous.jsonl") }

    /// The default location: Application Support, except on tvOS, where
    /// only Caches is writable.
    public static var defaultDirectory: URL? {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #endif
        // A Mac app outside the sandbox shares Application Support with every
        // other one, so namespace by bundle id there. Test runners and tools
        // with no identity of their own write to the temporary directory
        // rather than littering the user's Library.
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.hasPrefix("com.apple.") else {
            return FileManager.default.temporaryDirectory.appendingPathComponent("DebugTrace-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        #if os(macOS)
        return base?.appendingPathComponent(identifier, isDirectory: true).appendingPathComponent("DebugTrace", isDirectory: true)
        #else
        return base?.appendingPathComponent("DebugTrace", isDirectory: true)
        #endif
    }

    // MARK: Recording

    public func mark(_ event: String, _ detail: String? = nil) {
        let crumb = DebugBreadcrumb(time: DebugTime.iso(Date()), session: sessionId, event: event, detail: detail)
        lock.lock()
        defer { lock.unlock() }
        recentMarks.append(crumb)
        if recentMarks.count > Self.recentLimit * 2 {
            recentMarks.removeFirst(recentMarks.count - Self.recentLimit)
        }
        append(crumb)
    }

    /// Marks a feature as in use until `end` is called with the same name.
    /// Beginning one that is already active refreshes its detail.
    public func begin(_ feature: String, _ detail: String? = nil) {
        lock.lock()
        activeFeatures[feature] = DebugActiveFeature(name: feature, since: DebugTime.iso(Date()), detail: detail)
        lock.unlock()
        mark("\(feature).begin", detail)
    }

    public func end(_ feature: String, _ detail: String? = nil) {
        lock.lock()
        let wasActive = activeFeatures.removeValue(forKey: feature) != nil
        lock.unlock()
        if wasActive { mark("\(feature).end", detail) }
    }

    // MARK: Reading

    public var active: [DebugActiveFeature] {
        lock.lock()
        defer { lock.unlock() }
        return activeFeatures.values.sorted { $0.since < $1.since }
    }

    /// Marks from this session, newest last.
    public func recent(limit: Int = 100) -> [DebugBreadcrumb] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recentMarks.suffix(limit))
    }

    /// Both files' contents, oldest first, for a trace.
    public func fileContents() -> (current: Data?, previous: Data?) {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        let current = currentFileURL.flatMap { try? Data(contentsOf: $0) }
        let previous = previousFileURL.flatMap { try? Data(contentsOf: $0) }
        return (current, previous)
    }

    // MARK: File

    /// Called with the lock held.
    private func append(_ crumb: DebugBreadcrumb) {
        guard let handle else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(crumb) else { return }
        line.append(0x0A)
        do {
            try handle.write(contentsOf: line)
            fileBytes += line.count
        } catch {
            return
        }
        if fileBytes > maxFileBytes { rotate() }
    }

    private func openCurrentFile() {
        guard let url = currentFileURL else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        fileBytes = Int((try? handle?.seekToEnd()) ?? 0)
        if fileBytes > maxFileBytes { rotate() }
    }

    /// Keeps one previous file, so the history is bounded at twice the cap.
    private func rotate() {
        guard let current = currentFileURL, let previous = previousFileURL else { return }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        FileManager.default.createFile(atPath: current.path, contents: nil)
        handle = try? FileHandle(forWritingTo: current)
        fileBytes = 0
    }
}
