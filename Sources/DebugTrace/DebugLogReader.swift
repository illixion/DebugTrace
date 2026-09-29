import Foundation
import OSLog

public enum DebugLogLevel: String, CaseIterable, Sendable, Codable, Comparable {
    case debug, info, notice, error, fault

    var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .error: 3
        case .fault: 4
        }
    }

    public static func < (lhs: DebugLogLevel, rhs: DebugLogLevel) -> Bool { lhs.rank < rhs.rank }

    /// `Logger.warning` is `.error` underneath — os_log has no warning level.
    init(_ level: OSLogEntryLog.Level) {
        switch level {
        case .debug: self = .debug
        case .info: self = .info
        case .notice: self = .notice
        case .error: self = .error
        case .fault: self = .fault
        default: self = .info
        }
    }

    var letter: String {
        switch self {
        case .debug: "D"
        case .info: "I"
        case .notice: "N"
        case .error: "E"
        case .fault: "F"
        }
    }
}

public struct DebugLogEntry: Codable, Sendable, Equatable {
    public let time: String
    public let level: DebugLogLevel
    public let subsystem: String
    public let category: String
    public let message: String

    /// `2026-09-29T10:11:12.345Z N Render: message`. The subsystem is shown
    /// only when it is not the app's primary one.
    public func line(primarySubsystem: String?) -> String {
        let source = subsystem == primarySubsystem ? category : "\(subsystem)/\(category)"
        return "\(time) \(level.letter) \(source): \(message)"
    }
}

public struct DebugLogQuery: Sendable {
    public var since: Date
    public var subsystems: [String]
    public var minimumLevel: DebugLogLevel
    public var category: String?
    public var contains: String?
    public var limit: Int

    public init(since: Date, subsystems: [String], minimumLevel: DebugLogLevel = .info,
                category: String? = nil, contains: String? = nil, limit: Int = 200) {
        self.since = since
        self.subsystems = subsystems
        self.minimumLevel = minimumLevel
        self.category = category
        self.contains = contains
        self.limit = limit
    }
}

public struct DebugLogResult: Sendable {
    /// The newest `limit` matches, oldest first.
    public let entries: [DebugLogEntry]
    /// How many entries matched before `limit` was applied.
    public let matched: Int
    public var truncated: Bool { matched > entries.count }
}

/// Reads this process's unified-log entries.
///
/// Two limits come from the OS and no code here can lift them:
/// - `.debug` entries are never stored, so they cannot be read back. Log at
///   `.info` or above what should reach a trace (RAVEConsole's
///   `effectiveDebugLevel` promotes while a console is open, not otherwise).
/// - Only the current process: after a crash or relaunch the previous run's
///   entries are unreachable. `DebugBreadcrumbs` is the persisted part.
///
/// A read is expensive whatever the query: `position(date:)` is ignored and
/// `getEntries` makes `logd` scan the whole system log archive (~1.9 s on
/// macOS 27, charged to `logd`, not this process). Read on demand only;
/// RAVEConsole paces its live tail by this cost for the same reason.
///
/// Also: anything logged under a subsystem missing from `subsystems` is
/// invisible, and `print()` never reaches the log at all.
public enum DebugLogReader {
    public static func read(_ query: DebugLogQuery, redactor: DebugRedactor) throws -> DebugLogResult {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: query.since)
        var format = "subsystem IN %@"
        var arguments: [Any] = [query.subsystems]
        if let category = query.category {
            format += " AND category == %@"
            arguments.append(category)
        }
        let predicate = NSPredicate(format: format, argumentArray: arguments)
        let needle = query.contains?.lowercased()
        let limit = max(1, query.limit)

        var kept: [DebugLogEntry] = []
        var matched = 0
        for case let entry as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
            let level = DebugLogLevel(entry.level)
            guard level >= query.minimumLevel else { continue }
            let message = entry.composedMessage
            if let needle, !message.lowercased().contains(needle), !entry.category.lowercased().contains(needle) {
                continue
            }
            matched += 1
            kept.append(DebugLogEntry(time: DebugTime.iso(entry.date), level: level,
                                      subsystem: entry.subsystem, category: entry.category,
                                      message: message))
            // Keep the newest `limit`, trimming in batches.
            if kept.count >= limit * 2 { kept.removeFirst(kept.count - limit) }
        }
        if kept.count > limit { kept.removeFirst(kept.count - limit) }
        // Redacted after the cap so only what is returned pays for it.
        let redacted = kept.map {
            DebugLogEntry(time: $0.time, level: $0.level, subsystem: $0.subsystem,
                          category: $0.category, message: redactor.redact($0.message))
        }
        return DebugLogResult(entries: redacted, matched: matched)
    }
}
