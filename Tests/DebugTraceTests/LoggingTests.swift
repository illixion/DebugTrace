import Foundation
import OSLog
import Testing
@testable import DebugTrace

@Suite struct DebugLogMessageTests {
    @Test func callSitesWrittenForOSLoggerCompile() {
        // The spellings every app uses today, against os.Logger.
        let logger = DebugLogger(subsystem: "pro.rave.tests.compile", category: "C", buffer: DebugLogBuffer(mode: .development))
        let name = "ixion"
        logger.info("a \(1, privacy: .public) b \(name, privacy: .private) c \(name)")
        logger.error("hash \(name, privacy: .private(mask: .hash)) gone \(name, privacy: .sensitive)")
        logger.log(level: .debug, "level \(2.5, privacy: .public)")
        logger.log("default level")
        logger.warning("warn \(true)")
        logger.notice("\(Optional<Int>.none) \(Optional(3))")
        logger.info("t \(1.23456, format: .fixed(precision: 3))s \(1500.0, format: .fixed(precision: 0)) ms")
    }

    @Test func autoPrivacyFollowsOSLog() {
        let text = "hello"
        let message: DebugLogMessage = "n=\(42) f=\(1.5) b=\(false) s=\(text) o=\(Optional(7))"
        #expect(message.redacted == "n=42 f=1.5 b=false s=<private> o=7")
        #expect(message.revealed == "n=42 f=1.5 b=false s=hello o=7")
    }

    @Test func floatFormatMatchesOSLog() {
        let message: DebugLogMessage = "\(1.23456, format: .fixed(precision: 3)) \(2.0, format: .fixed(precision: 0))"
        #expect(message.redacted == "1.235 2")
    }

    @Test func errorsKeepDomainAndCodePublic() {
        let error: any Error = NSError(domain: NSURLErrorDomain, code: -1001,
                                       userInfo: [NSLocalizedDescriptionKey: "timed out loading https://home.example/api"])
        let message: DebugLogMessage = "load failed: \(error)"
        #expect(message.redacted == "load failed: NSURLErrorDomain -1001: <private>")
        #expect(message.revealed.contains("home.example"))
        let shown: DebugLogMessage = "\(error, privacy: .public)"
        #expect(shown.redacted.hasSuffix("https://home.example/api"))
        struct Local: Error {}
        let local: DebugLogMessage = "\(Local())"
        #expect(local.redacted.hasPrefix("DebugTraceTests.DebugLogMessageTests"))
    }

    @Test func sensitiveIsNeverRevealed() {
        let secret = "hunter2"
        let message: DebugLogMessage = "pw \(secret, privacy: .sensitive)"
        #expect(message.revealed == "pw <private>")
        #expect(!message.withholdingSensitiveValues().revealed.contains(secret))
    }

    @Test func hashMaskIsStableWithinALaunchAndHidesTheValue() {
        let a: DebugLogMessage = "\("alice@example.com", privacy: .private(mask: .hash))"
        let b: DebugLogMessage = "\("alice@example.com", privacy: .private(mask: .hash))"
        let c: DebugLogMessage = "\("bob@example.com", privacy: .private(mask: .hash))"
        #expect(a.redacted == b.redacted)
        #expect(a.redacted != c.redacted)
        #expect(a.redacted.hasPrefix("<hash:"))
        #expect(!a.redacted.contains("alice"))
    }
}

@Suite struct DebugLogBufferTests {
    @Test func developmentKeepsPrivateForTheDeviceButNotForExport() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.dev", category: "Auth", buffer: buffer)
        log.info("signed in as \("ixion@example.com") token \("abc", privacy: .sensitive)")
        let record = try! #require(buffer.records().first)
        #expect(record.revealedMessage == "signed in as ixion@example.com token <private>")
        #expect(record.redactedMessage == "signed in as <private> token <private>")
    }

    @Test func releaseNeverStoresPrivateValues() {
        let buffer = DebugLogBuffer(mode: .release)
        let log = DebugLogger(subsystem: "pro.rave.tests.release", category: "Auth", buffer: buffer)
        log.info("signed in as \("ixion@example.com") after \(3, privacy: .public) tries")
        let record = try! #require(buffer.records().first)
        #expect(record.revealedMessage == "signed in as <private> after 3 tries")
        // Not merely hidden at render time: the value is gone from the record.
        #expect(!String(describing: record.message).contains("ixion"))
    }

    @Test func releaseSkipsDebugLinesWithoutBuildingThem() {
        let buffer = DebugLogBuffer(mode: .release)
        let log = DebugLogger(subsystem: "pro.rave.tests.lazy", category: "Hot", buffer: buffer)
        var built = 0
        func expensive() -> String { built += 1; return "x" }
        log.debug("frame \(expensive(), privacy: .public)")
        #expect(buffer.records().isEmpty)
        // os_log may be streaming debug lines (a debugger, `log stream`), in
        // which case building the message is correct.
        if !OSLog(subsystem: "pro.rave.tests.lazy", category: "Hot").isEnabled(type: .debug) {
            #expect(built == 0)
        }
        buffer.capturesDebug = true
        log.debug("frame \(expensive(), privacy: .public)")
        #expect(buffer.records().count == 1)
    }

    @Test func capsEvictTheOldestAndSequencesKeepCounting() {
        let buffer = DebugLogBuffer(capacity: 3, mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.cap", category: "C", buffer: buffer)
        for index in 1...5 { log.info("line \(index)") }
        let records = buffer.records()
        #expect(records.map(\.redactedMessage) == ["line 3", "line 4", "line 5"])
        #expect(buffer.stats.evicted == 2)
        #expect(buffer.records(after: records[1].sequence).map(\.redactedMessage) == ["line 5"])
        buffer.clear()
        log.info("after clear")
        #expect(buffer.records().first?.sequence == 6)
    }

    @Test func byteCapBoundsMemory() {
        let buffer = DebugLogBuffer(capacity: 1_000, byteCapacity: 2_000, mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.bytes", category: "C", buffer: buffer)
        let payload = String(repeating: "x", count: 200)
        for _ in 0..<100 { log.info("\(payload, privacy: .public)") }
        #expect(buffer.stats.bytes <= 2_000)
        #expect(buffer.stats.count < 100)
        #expect(buffer.stats.count > 0)
    }

    @Test func readerRedactsAndCannotBeUsedToProbeHiddenValues() {
        let buffer = DebugLogBuffer(mode: .development)
        let log = DebugLogger(subsystem: "pro.rave.tests.reader", category: "Net", buffer: buffer)
        log.info("user \("carol-secret-name")")
        log.info("header \("Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123", privacy: .public)")
        let since = Date().addingTimeInterval(-60)
        let probe = DebugLogReader.buffered(DebugLogQuery(since: since, subsystems: [], contains: "carol"),
                                            buffer: buffer, redactor: .standard)
        #expect(probe.matched == 0)
        let all = DebugLogReader.buffered(DebugLogQuery(since: since, subsystems: []), buffer: buffer, redactor: .standard)
        #expect(all.entries.count == 2)
        #expect(!all.entries.map(\.message).joined().contains("abcdefghijklmnop"))
        #expect(all.entries[0].message == "user <private>")
    }

    @Test func privateValuesNeverReachTheUnifiedLog() throws {
        let subsystem = "pro.rave.tests.forward.\(UUID().uuidString.prefix(8))"
        let log = DebugLogger(subsystem: subsystem, category: "Fwd", buffer: DebugLogBuffer(mode: .development))
        let start = Date().addingTimeInterval(-1)
        log.notice("visible \(7, privacy: .public) hidden \("dave-private")")
        let result = try DebugLogReader.read(DebugLogQuery(since: start, subsystems: [subsystem], minimumLevel: .notice),
                                             redactor: .standard)
        let messages = result.entries.map(\.message)
        #expect(messages == ["visible 7 hidden <private>"])
    }
}

@Suite struct ReleaseTraceTests {
    @MainActor @Test func releaseSnapshotCarriesOnlyReleaseSafeEndpoints() async throws {
        let surface = DebugSurface(includeBuiltins: false)
        surface.register([
            .query("health", "no personal data", releaseSafe: true) { _ in ["ok": true] as JSONValue },
            .query("library", "file names") { _ in ["files": ["holiday.jpg"]] as JSONValue },
        ])
        let release = await surface.snapshot(privacy: .release)
        #expect(release.json["providers"]?["health"] != nil)
        #expect(release.json["providers"]?["library"] == nil)
        #expect(release.json["withheldInRelease"] == ["library"])
        let development = await surface.snapshot(privacy: .development)
        #expect(development.json["providers"]?["library"] != nil)
        #expect(development.json["withheldInRelease"] == nil)
    }

    @Test func breadcrumbDetailsAreStoredWithoutPrivateValues() {
        let email = "erin@example.com"
        DebugTrace.mark("tests.login", "as \(email) attempt \(2)")
        let crumb = DebugTrace.breadcrumbs.recent(limit: 20).last { $0.event == "tests.login" }
        #expect(crumb?.detail == "as <private> attempt 2")
    }
}

@Suite struct TraceLogTests {
    @MainActor @Test func traceLogsComeFromTheBufferWithPrivateValuesWithheld() async throws {
        let log = DebugLogger(subsystem: "pro.rave.tests.trace", category: "Flow")
        log.info("opened \("frank-private-album") with \(12, privacy: .public) items")
        let archive = try await DebugTrace.capture(note: "test", surface: DebugSurface(includeBuiltins: false))
        let logs = try #require(archive.textFiles["logs.txt"])
        #expect(logs.contains("opened <private> with 12 items"))
        #expect(!logs.contains("frank-private-album"))
        #expect(archive.textFiles["README.md"]?.contains("<private>") == true)
    }
}
