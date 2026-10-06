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
    /// Position in the app's log buffer, for reading on from it
    /// (`_logs afterSequence=`). Nil for unified-log entries.
    public var sequence: Int? = nil

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
    /// Only buffer records after this sequence number; `since` is then
    /// ignored. The app's own buffer only.
    public var afterSequence: Int? = nil

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
    /// For the app's buffer: the newest sequence number examined, matched or
    /// not. Pass it back as `afterSequence` to read only what came after.
    public var lastSequence: Int? = nil
    public var truncated: Bool { matched > entries.count }
}

/// Reads log lines: the app's own from `DebugLogBuffer`, everything else
/// from the unified log.
///
/// **The buffer** (`buffered`) holds every `DebugLogger` line, debug
/// included, for the whole session up to its caps. Reading it is cheap.
///
/// **The unified log** (`read`) is for lines the app doesn't control:
/// Apple frameworks and code still on `os.Logger`. The OS imposes limits no
/// code here can lift:
/// - `.debug` entries are never stored, and `.info` ones only in memory,
///   where the system drops them within minutes.
/// - Only the current process: after a crash or relaunch the previous run's
///   entries are unreachable. `DebugBreadcrumbs` is the persisted part.
/// - A read is expensive whatever the query: `position(date:)` is ignored
///   and `getEntries` makes `logd` scan the whole system log archive
///   (~1.9 s on macOS 27, charged to `logd`, not this process). Read on
///   demand only, never on a timer.
///
/// Both run every returned message through the redactor, and `contains`
/// matches the redacted text, so a search can't be used to probe for a
/// value the redactor hides.
public enum DebugLogReader {
    public static func buffered(_ query: DebugLogQuery, buffer: DebugLogBuffer = .shared,
                                redactor: DebugRedactor) -> DebugLogResult {
        let needle = query.contains?.lowercased()
        let limit = max(1, query.limit)
        var kept: [DebugLogEntry] = []
        var matched = 0
        // The cursor is the newest record looked at, taken from the same
        // snapshot, so a line appended mid-read is neither skipped nor
        // returned twice.
        // Clamped to what exists, so a cursor from a previous launch (or a
        // guess) can't skip the lines that come next.
        var lastSequence = min(query.afterSequence ?? Int.max, buffer.nextSequence - 1)
        for record in buffer.records(after: query.afterSequence ?? 0) {
            lastSequence = max(lastSequence, record.sequence)
            guard query.afterSequence != nil || record.date >= query.since,
                  record.level >= query.minimumLevel else { continue }
            if let category = query.category, record.category != category { continue }
            if !query.subsystems.isEmpty, !query.subsystems.contains(record.subsystem) { continue }
            let entry = record.entry(redactor: redactor)
            if let needle, !entry.message.lowercased().contains(needle), !entry.category.lowercased().contains(needle) {
                continue
            }
            matched += 1
            kept.append(entry)
        }
        if kept.count > limit { kept.removeFirst(kept.count - limit) }
        return DebugLogResult(entries: kept, matched: matched, lastSequence: lastSequence)
    }

    /// The unified log. An empty `subsystems` reads every subsystem in the
    /// process.
    public static func read(_ query: DebugLogQuery, redactor: DebugRedactor) throws -> DebugLogResult {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: query.since)
        var clauses: [String] = []
        var arguments: [Any] = []
        if !query.subsystems.isEmpty {
            clauses.append("subsystem IN %@")
            arguments.append(query.subsystems)
        }
        if let category = query.category {
            clauses.append("category == %@")
            arguments.append(category)
        }
        let predicate = clauses.isEmpty ? nil : NSPredicate(format: clauses.joined(separator: " AND "), argumentArray: arguments)
        let needle = query.contains?.lowercased()
        let limit = max(1, query.limit)

        var kept: [DebugLogEntry] = []
        var matched = 0
        for case let entry as OSLogEntryLog in try store.getEntries(at: position, matching: predicate) {
            let level = DebugLogLevel(entry.level)
            guard level >= query.minimumLevel else { continue }
            var message = entry.composedMessage
            if let needle {
                // Match what the caller would be shown, not the raw text.
                message = redactor.redact(message)
                if !message.lowercased().contains(needle), !entry.category.lowercased().contains(needle) { continue }
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
