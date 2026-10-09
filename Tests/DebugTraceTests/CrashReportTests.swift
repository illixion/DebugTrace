import Foundation
import Testing
@testable import DebugTrace

@MainActor
@Suite(.serialized) struct CrashReportTests {
    static func store() -> DebugCrashReports {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrashReportTests-\(UUID().uuidString)", isDirectory: true)
        return DebugCrashReports(directory: directory)
    }

    static let report: JSONValue = [
        "crashDiagnostics": [["callStackTree": ["callStacks": []], "exceptionType": 1]],
        "metaData": ["appBuildVersion": "abc1234", "token": "Bearer hunter2hunter2hunter2"],
    ]

    @Test func recordsOncePerReportAndTracksUploads() throws {
        let store = Self.store()
        store.record(kinds: ["crash"], report: Self.report, source: "test")
        store.record(kinds: ["crash"], report: Self.report, source: "test")
        let pending = store.reports(pendingOnly: true)
        #expect(pending.count == 1)
        #expect(pending[0].kinds == ["crash"])

        store.markDone(pending.map(\.id), state: "uploaded")
        #expect(store.reports(pendingOnly: true).isEmpty)
        #expect(store.reports().count == 1)

        store.record(kinds: ["hang"], report: ["hangDiagnostics": [[:]]], source: "test")
        #expect(store.reports(pendingOnly: true).map(\.kinds) == [["hang"]])
    }

    @Test func keepsOnlyTheNewestReports() {
        let store = Self.store()
        for index in 0..<(DebugCrashReports.keptReports + 5) {
            store.record(kinds: ["crash"], report: ["n": .int(index)], source: "test")
        }
        #expect(store.reports().count == DebugCrashReports.keptReports)
    }

    @Test func traceCarriesRedactedReports() async throws {
        let store = Self.store()
        store.record(kinds: ["crash"], report: Self.report, source: "test")
        let reports = store.reports()
        DebugTrace.setCredential(nil)
        let archive = try await DebugTrace.capture(
            surface: DebugSurface(includeBuiltins: false), logWindowSeconds: 60, diagnostics: reports)

        let path = "crashes/\(reports[0].id).json"
        #expect(archive.manifest.files.contains { $0.path == path })
        let text = try #require(archive.textFiles[path])
        #expect(text.contains("abc1234"))
        #expect(text.contains("\"kinds\""))
        #expect(!text.contains("hunter2"))
    }
}
