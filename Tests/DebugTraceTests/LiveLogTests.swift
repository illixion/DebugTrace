import Foundation
import Testing
@testable import DebugTrace

/// The cursor that lets a client tail the log: `_logs afterSequence=` plus
/// `waitSeconds` for a long poll.
@Suite struct LiveLogTests {
    private func logger(_ buffer: DebugLogBuffer) -> DebugLogger {
        DebugLogger(subsystem: "pro.rave.tests.live", category: "Live", buffer: buffer)
    }

    private func query(after: Int?, level: DebugLogLevel = .info, contains: String? = nil, limit: Int = 200) -> DebugLogQuery {
        var query = DebugLogQuery(since: .distantFuture, subsystems: [], minimumLevel: level, contains: contains, limit: limit)
        query.afterSequence = after
        return query
    }

    @Test func cursorReturnsOnlyNewLinesAndIgnoresSince() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = logger(buffer)
        log.info("one"); log.info("two")
        // `since` is in the future: without a cursor nothing would match.
        let first = DebugLogReader.buffered(query(after: 0), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(first.entries.map(\.message) == ["one", "two"])
        #expect(first.entries.map(\.sequence) == [1, 2])
        #expect(first.lastSequence == 2)

        log.info("three")
        let next = DebugLogReader.buffered(query(after: first.lastSequence), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(next.entries.map(\.message) == ["three"])
        #expect(next.lastSequence == 3)

        let idle = DebugLogReader.buffered(query(after: next.lastSequence), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(idle.entries.isEmpty)
        #expect(idle.lastSequence == 3)
    }

    @Test func cursorAdvancesPastLinesTheFilterDrops() {
        // A client filtering on errors must not re-read the same info lines forever.
        let buffer = DebugLogBuffer(mode: .development)
        let log = logger(buffer)
        log.info("noise"); log.info("noise")
        let result = DebugLogReader.buffered(query(after: 0, level: .error), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(result.entries.isEmpty)
        #expect(result.lastSequence == 2)
    }

    @Test func limitKeepsTheNewestAndTheCursorStillCoversAll() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = logger(buffer)
        for index in 1...5 { log.info("line \(index, privacy: .public)") }
        let result = DebugLogReader.buffered(query(after: 0, limit: 2), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(result.entries.map(\.message) == ["line 4", "line 5"])
        #expect(result.truncated)
        #expect(result.lastSequence == 5)
    }

    @Test func entriesStayPrivacyFiltered() {
        let buffer = DebugLogBuffer(mode: .development)
        let secret = "hunter2"
        logger(buffer).info("user \(secret)")
        let entry = DebugLogReader.buffered(query(after: 0), buffer: buffer, redactor: DebugRedactor.standard).entries.first
        #expect(entry?.message == "user <private>")
    }

    @Test func aCursorPastTheEndIsClampedSoNewLinesStillArrive() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = logger(buffer)
        log.info("a")
        let ahead = DebugLogReader.buffered(query(after: 999_999), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(ahead.entries.isEmpty)
        #expect(ahead.lastSequence == 1)
        log.info("b")
        let next = DebugLogReader.buffered(query(after: ahead.lastSequence), buffer: buffer, redactor: DebugRedactor.standard)
        #expect(next.entries.map(\.message) == ["b"])
    }

    @Test func anEmptyBufferStartsTheCursorAtZero() {
        let result = DebugLogReader.buffered(query(after: 0), buffer: DebugLogBuffer(mode: .development), redactor: DebugRedactor.standard)
        #expect(result.lastSequence == 0)
    }

    @Test func noCursorKeepsTheOldBehaviour() {
        let buffer = DebugLogBuffer(mode: .development)
        logger(buffer).info("old")
        let since = DebugLogQuery(since: Date().addingTimeInterval(-60), subsystems: [])
        #expect(DebugLogReader.buffered(since, buffer: buffer, redactor: DebugRedactor.standard).entries.count == 1)
    }

    // MARK: The endpoint

    @MainActor @Test func endpointLongPollReturnsWhenALineArrives() async throws {
        let surface = DebugSurface()
        let marker = "livepoll-\(UUID().uuidString)"
        let log = DebugLogger(subsystem: "pro.rave.tests.live", category: "Live")
        let start = try await surface.call("_logs", arguments: ["afterSequence": 0, "contains": .string(marker)]).get().json
        let cursor = start?["lastSequence"]?.intValue ?? 0
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            log.notice("\(marker, privacy: .public) arrived")
        }
        let began = ContinuousClock.now
        let reply = try await surface.call("_logs", arguments: [
            "afterSequence": .int(cursor), "waitSeconds": 10, "contains": .string(marker),
        ]).get().json
        let waited = ContinuousClock.now - began
        #expect(reply?["returned"]?.intValue == 1)
        #expect(reply?["entries"]?[0]?.stringValue?.contains("arrived") == true)
        #expect(waited < .seconds(5))
        #expect((reply?["lastSequence"]?.intValue ?? 0) > cursor)
    }

    @MainActor @Test func endpointLongPollTimesOutEmpty() async throws {
        let surface = DebugSurface()
        let reply = try await surface.call("_logs", arguments: [
            "afterSequence": .int(DebugLogBuffer.shared.nextSequence), "waitSeconds": 1,
            "contains": .string("never-\(UUID().uuidString)"),
        ]).get().json
        #expect(reply?["returned"]?.intValue == 0)
    }

    @MainActor @Test func endpointRejectsMisuseWithHints() async {
        let surface = DebugSurface()
        let wait = await surface.call("_logs", arguments: ["waitSeconds": 2]).failure
        #expect(wait?.code == .invalidArgument)
        #expect(wait?.hint?.contains("afterSequence") == true)
        let negative = await surface.call("_logs", arguments: ["afterSequence": -1]).failure
        #expect(negative?.code == .invalidArgument)
        let system = await surface.call("_logs", arguments: ["source": "system", "afterSequence": 0]).failure
        #expect(system?.code == .invalidArgument)
        let tooLong = await surface.call("_logs", arguments: ["afterSequence": 0, "waitSeconds": 26]).failure
        #expect(tooLong?.code == .invalidArgument)
    }
}
