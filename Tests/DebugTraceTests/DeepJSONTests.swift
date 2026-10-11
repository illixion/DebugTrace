import Foundation
import Testing
@testable import DebugTrace

/// Deeply nested values on a small stack. A 300-frame MetricKit crash report
/// encoded on a Swift task's 512 KB stack crashed Hypnos mid-film and on every
/// relaunch after (2026-10-11); these run each path on such a stack with
/// values far deeper than it could hold before.
@Suite(.serialized) struct DeepJSONTests {
    /// Runs `body` on a thread with a task-sized stack.
    static func onSmallStack<T>(_ body: @escaping () throws -> T) throws -> T {
        nonisolated(unsafe) var result: Result<T, any Error>?
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = Result { try body() }
            done.signal()
        }
        thread.stackSize = 512 << 10
        thread.start()
        done.wait()
        return try result!.get()
    }

    /// A legacy-layout call stack `depth` frames deep.
    static func frameChain(_ depth: Int) -> JSONValue {
        var frame: JSONValue = ["binaryUUID": "B", "offsetIntoBinaryTextSegment": .int(depth), "sampleCount": 1]
        for level in stride(from: depth - 1, through: 0, by: -1) {
            frame = ["binaryUUID": "A", "offsetIntoBinaryTextSegment": .int(level), "sampleCount": 1, "subFrames": [frame]]
        }
        return frame
    }

    static func nested(_ depth: Int) -> JSONValue {
        var value: JSONValue = "leaf"
        for _ in 0..<depth { value = ["child": [value]] }
        return value
    }

    @Test func deepValuesSerializeAndParseOnASmallStack() throws {
        let depth = 5000
        let ok = try Self.onSmallStack { () -> Bool in
            var value = Self.nested(depth)
            let text = value.serialized()
            var back = try JSONValue.parse(text)
            let same = back.depth == value.depth && back.serialized() == text
            JSONValue.dismantle(&back)
            JSONValue.dismantle(&value)
            return same
        }
        #expect(ok)
    }

    @Test func deepValuesRedactOnASmallStack() throws {
        let redacted = try Self.onSmallStack { () -> String in
            var value: JSONValue = ["token": "Bearer hunter2hunter2hunter2"]
            for _ in 0..<3000 { value = ["child": value] }
            var out = DebugRedactor.standard.redact(value)
            var cursor = out
            while let next = cursor["child"] { cursor = next }
            let text = cursor["token"]?.stringValue ?? ""
            cursor = .null
            JSONValue.dismantle(&out)
            JSONValue.dismantle(&value)
            return text
        }
        #expect(redacted == DebugRedactor.marker)
    }

    @Test func deepCrashReportIsStoredFlat() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepJSONTests-\(UUID().uuidString)", isDirectory: true)
        let store = DebugCrashReports(directory: directory)
        let depth = 2000
        try Self.onSmallStack {
            var report: JSONValue = ["crashDiagnostics": [["callStackTree": ["callStacks": [
                ["threadAttributed": true, "callStackRootFrames": Self.frameChain(depth)]]]]]]
            store.record(kinds: ["crash"], report: report, source: "test")
            JSONValue.dismantle(&report)
        }
        let stored = try #require(store.reports().first)
        #expect(JSONValue.nesting(of: stored.data) < 10)
        let envelope = try JSONValue.parse(stored.data)
        let frames = try #require(envelope["report"]?["crashDiagnostics"]?[0]?["callStackTree"]?["callStacks"]?[0]?["frames"]?.arrayValue)
        #expect(frames.count == depth + 1)
        #expect(frames.map { $0["depth"]?.intValue } == (0...depth).map { $0 })
        #expect(frames.allSatisfy { $0["subFrames"] == nil })
        #expect(frames.last?["binaryUUID"]?.stringValue == "B")
    }

    /// A hang's tree branches: children follow their parent one level deeper.
    @Test func branchingTreesKeepTheirShape() {
        let tree: JSONValue = ["n": "root", "subFrames": [
            ["n": "a", "subFrames": [["n": "a1"]]],
            ["n": "b"],
        ]]
        let flat = DebugCrashReports.flatFrames([tree])
        #expect(flat.map { $0["n"]?.stringValue } == ["root", "a", "a1", "b"])
        #expect(flat.map { $0["depth"]?.intValue } == [0, 1, 2, 1])
    }

    /// A report stored nested by an older build is flattened when read, and
    /// the flat copy kept.
    @Test func nestedReportOnDiskIsMigrated() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeepJSONTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var envelope: JSONValue = ["id": "abc123", "receivedAt": "2026-10-11T04:08:20.803Z", "source": "test",
                                   "kinds": ["crash"],
                                   "report": ["crashDiagnostic": ["callStackTree": ["callStackThreads": [
                                       ["threadAttributed": true, "rootFrames": [Self.frameChain(400)]]]]]]]
        let url = directory.appendingPathComponent("abc123.json")
        try JSONValue.writeIteratively(envelope, pretty: false).write(to: url)
        JSONValue.dismantle(&envelope)

        let reports = try Self.onSmallStack { DebugCrashReports(directory: directory).reports() }
        #expect(reports.map(\.id) == ["abc123"])
        let onDisk = try Data(contentsOf: url)
        #expect(JSONValue.nesting(of: onDisk) < 10)
        let frames = try JSONValue.parse(onDisk)["report"]?["crashDiagnostic"]?["callStackTree"]?["callStackThreads"]?[0]?["frames"]?.arrayValue
        #expect(frames?.count == 401)
    }

    /// The iterative writer and parser agree with Foundation's on ordinary
    /// values, so a deep value reads like any other.
    @Test func iterativeCodersMatchFoundation() throws {
        let sample: JSONValue = [
            "text": "quote \" slash / back \\ tab \t newline \n bell \u{07} é 🎬",
            "numbers": [0, -3, 1.5, 1e-7, 123456789.25, 2.0],
            "flags": [true, false, .null],
            "empty": ["array": [], "object": [:]],
            "nested": ["b": 2, "a": ["z": "last", "y": "first"]],
            "inf": .double(.infinity),
        ]
        for pretty in [false, true] {
            let foundation = sample.serialized(pretty: pretty)
            let iterative = JSONValue.writeIteratively(sample, pretty: pretty)
            #expect(try JSONValue.parse(iterative) == JSONValue.parse(foundation))
            #expect(try JSONValue.parseIteratively(foundation) == JSONValue.parse(foundation))
            if !pretty {
                #expect(String(decoding: iterative, as: UTF8.self) == String(decoding: foundation, as: UTF8.self))
            }
        }
        #expect(throws: (any Error).self) { try JSONValue.parseIteratively(Data("[1, 2".utf8)) }
        #expect(throws: (any Error).self) { try JSONValue.parseIteratively(Data("{\"a\" 1}".utf8)) }
    }

    /// The direct encoder spells values as `JSONValue(encoding:)` does.
    @Test func directEncoderMatchesTheRoundTrip() throws {
        struct Inner: Codable { var name: String; var tags: [String]; var missing: Int? }
        struct Sample: Encodable {
            var date = Date(timeIntervalSince1970: 1_760_000_000)
            var data = Data([1, 2, 3])
            var url = URL(string: "https://example.com/a/b")!
            var double = 0.1
            var float: Float = 0.1
            var nonFinite = Double.nan
            var big = UInt64.max
            var inner = Inner(name: "x", tags: ["a", "b"], missing: nil)
            var map = ["k": [1, 2]]
            var optional: String? = "here"
        }
        let direct = try JSONValueEncoder().encode(Sample())
        let roundTrip = try JSONValue(encoding: Sample())
        #expect(direct == roundTrip)
    }
}
