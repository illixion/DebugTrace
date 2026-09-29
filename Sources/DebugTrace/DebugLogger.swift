import Foundation
import os

/// Who the app's own diagnostics are for, which decides what is kept.
///
/// - `development`: the developer's own builds. Private values are kept in
///   the in-process log buffer and shown on this device's own console, so
///   debugging doesn't need everything marked public. Every export (traces,
///   the debug server, the clipboard, the OS log) still withholds them.
/// - `release`: App Store and TestFlight builds, where traces come from real
///   users. Private values are dropped the moment they are logged, debug
///   lines are not captured unless switched on, and a trace carries only
///   what an endpoint has declared safe (`releaseSafe`) and never the OS log
///   of other subsystems.
///
/// Both modes run every export through the pattern redactor, which catches
/// secrets a call site wrongly marked `.public`.
public enum DebugPrivacyMode: String, Sendable, Codable, CaseIterable {
    case development, release

    /// `release` for App Store and TestFlight installs, `development` for
    /// everything else. Detection fails safe: a store-distributed build has no
    /// development provisioning profile, and anything that can't be shown to
    /// be a development build is treated as release.
    public static let detected: DebugPrivacyMode = {
        #if targetEnvironment(simulator)
        return .development
        #elseif os(macOS)
        // Mac App Store installs carry a receipt; developer builds don't.
        let receipt = Bundle.main.bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        return FileManager.default.fileExists(atPath: receipt.path) ? .release : .development
        #else
        // Development, ad hoc and enterprise builds embed their provisioning
        // profile. The App Store and TestFlight strip it.
        return Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") != nil
            ? .development : .release
        #endif
    }()
}

/// One line in the in-process buffer.
public struct DebugLogRecord: Sendable, Identifiable {
    /// Increases by one per record for the life of the process, so a reader
    /// can ask for what arrived after the last record it saw.
    public let sequence: Int
    public let date: Date
    public let level: DebugLogLevel
    public let subsystem: String
    public let category: String
    let message: DebugLogMessage

    public var id: Int { sequence }

    /// The message as exports show it: hidden values replaced. Pass it
    /// through the configured redactor before it leaves the process.
    public var redactedMessage: String { message.redacted }

    /// The message for this device's own screen: private values in full in
    /// development mode (release mode never stored them).
    public var revealedMessage: String { message.revealed }

    func entry(redactor: DebugRedactor) -> DebugLogEntry {
        DebugLogEntry(time: DebugTime.iso(date), level: level, subsystem: subsystem,
                      category: category, message: redactor.redact(message.redacted))
    }
}

/// The in-process ring of this app's own log lines, capped by count and by
/// bytes. It lives only in memory: nothing is written to disk, and it is
/// gone when the process ends (breadcrumbs are the part that persists).
///
/// Reading it costs a lock and a copy — unlike `OSLogStore`, whose every read
/// makes `logd` scan the whole system archive — so a console can tail it live.
public final class DebugLogBuffer: @unchecked Sendable {
    public struct Stats: Sendable, Codable {
        public let count: Int
        public let bytes: Int
        /// Records evicted to stay under the caps since launch.
        public let evicted: Int
        public let capacity: Int
        public let byteCapacity: Int
        public let capturesDebug: Bool
        public let privacy: DebugPrivacyMode
    }

    private struct State {
        var records: [DebugLogRecord?]
        var head = 0
        var count = 0
        var bytes = 0
        var evicted = 0
        var nextSequence = 1
        var capacity: Int
        var byteCapacity: Int
        var mode: DebugPrivacyMode
        var capturesDebug: Bool
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(capacity: Int = 5_000, byteCapacity: Int = 2 * 1024 * 1024,
                mode: DebugPrivacyMode = .detected, capturesDebug: Bool? = nil) {
        state = OSAllocatedUnfairLock(initialState: State(
            records: Array(repeating: nil, count: max(capacity, 1)),
            capacity: max(capacity, 1), byteCapacity: byteCapacity, mode: mode,
            capturesDebug: capturesDebug ?? (mode == .development)))
    }

    /// The buffer every `DebugLogger` writes to.
    public static let shared = DebugLogBuffer()

    public var mode: DebugPrivacyMode {
        get { state.withLock { $0.mode } }
        set { state.withLock { $0.mode = newValue } }
    }

    /// Whether `.debug` lines are kept. On by default in development, off in
    /// release; a support flow can switch it on while reproducing a problem.
    public var capturesDebug: Bool {
        get { state.withLock { $0.capturesDebug } }
        set { state.withLock { $0.capturesDebug = newValue } }
    }

    public var stats: Stats {
        state.withLock {
            Stats(count: $0.count, bytes: $0.bytes, evicted: $0.evicted, capacity: $0.capacity,
                  byteCapacity: $0.byteCapacity, capturesDebug: $0.capturesDebug, privacy: $0.mode)
        }
    }

    /// The sequence number the next record will get.
    public var nextSequence: Int { state.withLock { $0.nextSequence } }

    /// Stores a line, applying the privacy mode first. Returns the stored
    /// message, which is what the OS log is sent too.
    @discardableResult
    func append(level: DebugLogLevel, subsystem: String, category: String,
                message: DebugLogMessage, date: Date = Date()) -> DebugLogMessage {
        state.withLock { state in
            let kept = state.mode == .release
                ? message.withholdingHiddenValues()
                : message.withholdingSensitiveValues()
            if level == .debug && !state.capturesDebug { return kept }
            let record = DebugLogRecord(sequence: state.nextSequence, date: date, level: level,
                                        subsystem: subsystem, category: category, message: kept)
            state.nextSequence += 1
            let size = kept.byteCount + subsystem.utf8.count + category.utf8.count + 48
            if state.count == state.capacity { Self.evictOldest(&state) }
            let slot = (state.head + state.count) % state.capacity
            state.records[slot] = record
            state.count += 1
            state.bytes += size
            while state.bytes > state.byteCapacity && state.count > 1 { Self.evictOldest(&state) }
            return kept
        }
    }

    private static func evictOldest(_ state: inout State) {
        guard state.count > 0, let oldest = state.records[state.head] else { return }
        state.bytes -= oldest.message.byteCount + oldest.subsystem.utf8.count + oldest.category.utf8.count + 48
        state.records[state.head] = nil
        state.head = (state.head + 1) % state.capacity
        state.count -= 1
        state.evicted += 1
    }

    /// Records with a sequence number above `sequence`, oldest first.
    public func records(after sequence: Int = 0) -> [DebugLogRecord] {
        state.withLock { state in
            var out: [DebugLogRecord] = []
            out.reserveCapacity(state.count)
            for offset in 0..<state.count {
                if let record = state.records[(state.head + offset) % state.capacity], record.sequence > sequence {
                    out.append(record)
                }
            }
            return out
        }
    }

    /// Empties the buffer. Sequence numbers keep counting up.
    public func clear() {
        state.withLock { state in
            state.records = Array(repeating: nil, count: state.capacity)
            state.head = 0
            state.count = 0
            state.bytes = 0
        }
    }
}

/// A drop-in for `os.Logger` that also keeps each line in `DebugLogBuffer`.
/// Declare it where the app declared its loggers:
///
/// ```swift
/// static let render = DebugLogger(subsystem: subsystem, category: "Render")
/// AppLog.render.info("frame \(index) took \(ms, privacy: .public) ms")
/// ```
///
/// Every line also goes to the unified log, with hidden values already
/// withheld, so Xcode and `log stream` see it. Private values therefore never
/// reach the OS log in either mode; read them on the in-app console.
///
/// `debug` takes its message lazily: when debug capture is off and nothing
/// is streaming debug lines, the message is never built, so per-frame
/// logging stays cheap.
public struct DebugLogger: Sendable {
    public let subsystem: String
    public let category: String
    private let logger: Logger
    private let buffer: DebugLogBuffer

    public init(subsystem: String, category: String, buffer: DebugLogBuffer = .shared) {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
        self.buffer = buffer
    }

    public func debug(_ message: @autoclosure () -> DebugLogMessage) {
        guard buffer.capturesDebug || OSLog(subsystem: subsystem, category: category).isEnabled(type: .debug) else {
            return
        }
        write(.debug, message())
    }

    public func trace(_ message: @autoclosure () -> DebugLogMessage) { debug(message()) }
    public func info(_ message: @autoclosure () -> DebugLogMessage) { write(.info, message()) }
    public func notice(_ message: @autoclosure () -> DebugLogMessage) { write(.notice, message()) }
    /// `os.Logger.log(_:)` is the default level, which is notice.
    public func log(_ message: @autoclosure () -> DebugLogMessage) { write(.notice, message()) }
    /// `os.Logger.warning` is the error level underneath; so is this.
    public func warning(_ message: @autoclosure () -> DebugLogMessage) { write(.error, message()) }
    public func error(_ message: @autoclosure () -> DebugLogMessage) { write(.error, message()) }
    public func fault(_ message: @autoclosure () -> DebugLogMessage) { write(.fault, message()) }
    public func critical(_ message: @autoclosure () -> DebugLogMessage) { write(.fault, message()) }

    public func log(level: OSLogType, _ message: @autoclosure () -> DebugLogMessage) {
        switch level {
        case .debug: debug(message())
        case .info: write(.info, message())
        case .error: write(.error, message())
        case .fault: write(.fault, message())
        default: write(.notice, message())
        }
    }

    private func write(_ level: DebugLogLevel, _ message: DebugLogMessage) {
        let kept = buffer.append(level: level, subsystem: subsystem, category: category, message: message)
        let text = kept.redacted
        logger.log(level: level.osLogType, "\(text, privacy: .public)")
        if DebugLogMirror.isEnabled, level != .debug || buffer.capturesDebug {
            DebugLogMirror.write(level: level, subsystem: subsystem, category: category, text: text)
        }
    }
}

extension DebugLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .error: .error
        case .fault: .fault
        }
    }
}

/// Mirrors the app's own log lines to stderr, one compact line each, when the
/// launch environment sets `DEBUGTRACE_STDERR=1` in a development build.
///
/// This is for `build-and-sign --log`, which launches the app with
/// `devicectl --console` and writes what it prints to a file that a language
/// model reads. Mirroring the unified log instead (`OS_ACTIVITY_DT_MODE`)
/// drowns the app's lines in Apple framework output, in a verbose format.
/// Here it's only the app's lines, debug included, in the trace's `logs.txt`
/// format, exported the same way: hidden values withheld and the redactor
/// applied, since the file is read off the device. Never in release mode.
public enum DebugLogMirror {
    public static let environmentKey = "DEBUGTRACE_STDERR"

    public static var isEnabled: Bool {
        requested && DebugLogBuffer.shared.mode == .development
    }

    private static let requested = ProcessInfo.processInfo.environment[environmentKey] == "1"

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private static let lock = OSAllocatedUnfairLock()

    static func write(level: DebugLogLevel, subsystem: String, category: String, text: String) {
        let configuration = DebugTrace.configuration
        let source = subsystem == configuration.subsystems.first ? category : "\(subsystem)/\(category)"
        let message = configuration.redactor.redact(text)
        // One write per line, under a lock, so lines from different threads
        // never interleave mid-line.
        lock.withLock {
            let line = "\(formatter.string(from: Date())) \(level.letter) \(source): \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
