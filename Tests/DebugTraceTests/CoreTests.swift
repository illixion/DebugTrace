import CryptoKit
import Foundation
import OSLog
import Testing
@testable import DebugTrace

// MARK: - JSONValue

@Suite struct JSONValueTests {
    @Test func objectiveCNumbersKeepTheirType() throws {
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"b": true, "i": 3, "d": 1.5}"#.utf8))
        let value = JSONValue(any: parsed)
        #expect(value["b"] == .bool(true))
        #expect(value["i"] == .int(3))
        #expect(value["d"] == .double(1.5))
    }

    @Test func swiftValuesConvert() {
        let optional: Int? = nil
        let value = JSONValue(any: ["n": 1, "flag": false, "f": Float(2), "none": optional as Any, "list": [1, "a"]] as [String: Any])
        #expect(value["n"] == .int(1))
        #expect(value["flag"] == .bool(false))
        #expect(value["f"] == .double(2))
        #expect(value["none"] == .null)
        #expect(value["list"] == .array([.int(1), .string("a")]))
    }

    @Test func nonFiniteNumbersSerialize() {
        let text = JSONValue.object(["far": .double(.infinity), "x": .double(.nan)]).serializedString()
        #expect(text == #"{"far":"inf","x":"nan"}"#)
    }

    @Test func encodableKeepsPropertyNamesAndDictionaryKeys() throws {
        struct Reading: Encodable { let elapsedMs: Double; let perCategory: [String: Int] }
        let value = try JSONValue(encoding: Reading(elapsedMs: 2, perCategory: ["VideoWindow": 1]))
        #expect(value["elapsedMs"] == .double(2))
        #expect(value["perCategory"]?["VideoWindow"] == .int(1))
    }
}

// MARK: - Surface

@MainActor
@Suite struct DebugSurfaceTests {
    struct Echo: Encodable { let x: Double; let n: Int; let flag: Bool; let mode: String }

    func surface() -> DebugSurface {
        let surface = DebugSurface(includeBuiltins: false)
        surface.register(.query("echo", "echo", parameters: [
            .number("x", "x", required: true),
            .integer("n", "n", default: 3, range: 0...10),
            .boolean("flag", "flag", default: false),
            .string("mode", "mode", default: "fast", choices: ["fast", "slow"]),
        ]) { args in
            Echo(x: try args.requireDouble("x"), n: try args.requireInt("n"),
                 flag: try args.requireBool("flag"), mode: try args.requireString("mode"))
        })
        surface.register(.command("teleport", "move", parameters: [.number("x", "x", required: true)]) { args in
            ["x": try args.requireDouble("x")]
        })
        return surface
    }

    @Test func queryStringsAreCoercedAndDefaultsApplied() async throws {
        let result = try await surface().call("echo", arguments: ["x": "1.5", "flag": ""]).get()
        #expect(result.json == ["x": 1.5, "n": 3, "flag": true, "mode": "fast"])
    }

    @Test func unknownArgumentIsRejectedWithSuggestion() async {
        let error = await surface().call("echo", arguments: ["x": 1, "flgg": true]).failure
        #expect(error?.code == .invalidArgument)
        #expect(error?.hint?.contains("did you mean 'flag'") == true)
    }

    @Test func missingRequiredArgumentNamesIt() async {
        let error = await surface().call("echo").failure
        #expect(error?.message.contains("x") == true)
        #expect(error?.hint?.contains("x (number, required)") == true)
    }

    @Test func choicesAndRangesAreEnforced() async {
        let surface = surface()
        let choice = await surface.call("echo", arguments: ["x": 1, "mode": "fsat"]).failure
        #expect(choice?.hint == "did you mean 'fast'?")
        let range = await surface.call("echo", arguments: ["x": 1, "n": 11]).failure
        #expect(range?.code == .invalidArgument)
        let type = await surface.call("echo", arguments: ["x": "abc"]).failure
        #expect(type?.message.contains("must be a number") == true)
    }

    @Test func unknownEndpointSuggestsNearest() async {
        let error = await surface().call("teleprt").failure
        #expect(error?.code == .notFound)
        #expect(error?.hint?.contains("'teleport'") == true)
    }

    @Test func readOnlySurfaceRefusesCommands() async {
        let surface = DebugSurface(includeBuiltins: false, allowCommands: false)
        surface.register(.command("go", "go") { _ in ["ok": true] })
        #expect(await surface.call("go").failure?.code == .forbidden)
    }

    @Test func slowHandlerTimesOut() async {
        let surface = DebugSurface(includeBuiltins: false)
        surface.register(.query("slow", "slow", timeout: .milliseconds(50)) { _ in
            try await Task.sleep(for: .seconds(5))
            return ["never": true]
        })
        #expect(await surface.call("slow").failure?.code == .timeout)
    }

    @Test func snapshotCapturesOnlyTracedQueries() async {
        let surface = surface()
        surface.register(.query("state", "state") { _ in ["players": 1] })
        surface.register(.query("hidden", "not traced", trace: .never) { _ in ["x": 1] })
        surface.register(.raw("frame", kind: .query, "png", trace: .arguments([:])) { _ in
            .binary(Data([0x89, 0x50]), contentType: "image/png", filename: "frame.png")
        })
        let snapshot = await surface.snapshot()
        let providers = snapshot.json["providers"]?.objectValue ?? [:]
        #expect(Set(providers.keys) == ["state", "frame"])  // echo needs x; teleport is a command
        #expect(providers["state"]?["data"] == ["players": 1])
        #expect(providers["frame"]?["attachment"] == "attachments/frame.png")
        #expect(snapshot.files["attachments/frame.png"] == Data([0x89, 0x50]))
    }

    @Test func untypedHandlersStillWork() async throws {
        let surface = DebugSurface(includeBuiltins: false)
        surface.register(.untyped("legacy", kind: .query, "old route") { _ in
            ["far": Double.infinity, "nested": ["a": [1, 2]]]
        })
        let result = try await surface.call("legacy").get()
        #expect(result.json?.serializedString() == #"{"far":"inf","nested":{"a":[1,2]}}"#)
    }

    @Test func builtinsDescribeTheApp() async throws {
        let surface = DebugSurface()
        DebugTrace.begin("test.feature", "detail")
        defer { DebugTrace.end("test.feature") }
        let info = try await surface.call("_info").get().json
        #expect(info?["app"]?["platform"] == "macOS")
        #expect(info?["process"]?["memoryFootprintBytes"]?.intValue ?? 0 > 0)
        let features = try await surface.call("_features").get().json
        #expect(features?["active"]?[0]?["name"] == "test.feature")
        #expect(surface.catalog.first?.name.hasPrefix("_") == true)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Redaction

@Suite struct DebugRedactorTests {
    let redactor = DebugRedactor.standard

    @Test(arguments: [
        ("Authorization: Bearer abcdefgh12345678", "Authorization: Bearer <redacted>"),
        ("GET https://user:hunter2@example.com/x", "GET https://<redacted>@example.com/x"),
        ("url=https://h/api?token=s3cret&page=2", "url=https://h/api?token=<redacted>&page=2"),
        ("jwt eyJhbGciOi.eyJzdWIiOiIx.c2lnbmF0dXJl done", "jwt <redacted jwt> done"),
        (#"config {"api_key": "abc123"}"#, #"config {"api_key": "<redacted>"}"#),
        ("password=hunter2 ok", "password=<redacted> ok"),
        ("-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----", "<redacted private key>"),
    ])
    func secretsAreRedacted(input: String, expected: String) {
        #expect(redactor.redact(input) == expected)
    }

    @Test(arguments: [
        "token successfully refreshed",
        "Loaded 12 tokens in 3 ms",
        "stream 1920x1080 @ 90 Hz, bitrate 40 Mbps",
    ])
    func ordinaryTextIsLeftAlone(input: String) {
        #expect(redactor.redact(input) == input)
    }

    @Test func sensitiveKeysAreRedactedButFlagsSurvive() {
        let value: JSONValue = ["password": "x", "accessToken": "y", "hasToken": true, "maxTokens": 4096, "token": nil]
        #expect(redactor.redact(value) == ["password": "<redacted>", "accessToken": "<redacted>", "hasToken": true, "maxTokens": 4096, "token": nil])
    }
}

// MARK: - Zip

@Suite struct ZipWriterTests {
    @Test func archiveIsReadableByInfoZip() throws {
        let large = Data(String(repeating: "compressible line\n", count: 500).utf8)
        var zip = ZipWriter()
        try zip.add(path: "a.txt", data: Data("hi".utf8))
        try zip.add(path: "dir/large.txt", data: large)
        try zip.add(path: "ünïcode.json", data: Data("{}".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID()).zip")
        try zip.finish().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try run("/usr/bin/unzip", ["-tq", url.path]).status == 0)
        #expect(try run("/usr/bin/unzip", ["-p", url.path, "dir/large.txt"]).output == large)
        #expect(try run("/usr/bin/unzip", ["-p", url.path, "a.txt"]).output == Data("hi".utf8))
        #expect(try run("/usr/bin/unzip", ["-Z1", url.path]).text.contains("ünïcode.json"))
    }

    @Test func crcMatchesKnownValue() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}

// MARK: - Credential and trace

@MainActor
@Suite(.serialized) struct DebugTraceBuilderTests {
    static let privateKey = Curve25519.Signing.PrivateKey()

    func credential() throws -> DebugTraceCredential {
        let plist: [String: Any] = [
            "Version": 1, "KeyID": "test-key",
            "SigningKey": Self.privateKey.rawRepresentation.base64EncodedString(),
            "UploadURL": "https://example.invalid/api/traces", "CommandToken": "tok",
        ]
        return try DebugTraceCredential.parse(plist: PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    }

    @Test func credentialPlistParses() throws {
        let credential = try credential()
        #expect(credential.keyId == "test-key")
        #expect(credential.commandToken == "tok")
        #expect(credential.uploadURL?.host == "example.invalid")
        #expect(credential.publicKey == Self.privateKey.publicKey.rawRepresentation)
    }

    @Test func signedTraceVerifiesFileByFile() async throws {
        DebugTrace.setCredential(try credential())
        defer { DebugTrace.setCredential(nil) }
        let surface = DebugSurface()
        surface.register(.query("world", "world state") { _ in ["loaded": true, "password": "hunter2"] as JSONValue })
        surface.registerAttachment("crash.log") { Data("boom".utf8) }
        DebugTrace.mark("test.captureStarted")

        let archive = try await DebugTrace.capture(note: "investigating", surface: surface, logWindowSeconds: 60)
        #expect(archive.signed)
        #expect(DebugTrace.archive(id: archive.id)?.url == archive.url)

        let names = try run("/usr/bin/unzip", ["-Z1", archive.url.path]).text.split(separator: "\n").map(String.init)
        for expected in ["manifest.json", "manifest.sig", "README.md", "info.json", "snapshot.json",
                         "logs.txt", "breadcrumbs.jsonl", "note.txt", "attachments/crash.log"] {
            #expect(names.contains(expected), "missing \(expected)")
        }

        let manifestData = try run("/usr/bin/unzip", ["-p", archive.url.path, "manifest.json"]).output
        let signature = try run("/usr/bin/unzip", ["-p", archive.url.path, "manifest.sig"]).output
        #expect(Self.privateKey.publicKey.isValidSignature(signature, for: manifestData))

        let manifest = try JSONValue.parse(manifestData)
        #expect(manifest["signature"]?["keyId"] == "test-key")
        let listed = manifest["files"]?.arrayValue ?? []
        #expect(Set(listed.compactMap { $0["path"]?.stringValue }) == Set(names).subtracting(["manifest.json", "manifest.sig"]))
        for file in listed {
            let path = try #require(file["path"]?.stringValue)
            let data = try run("/usr/bin/unzip", ["-p", archive.url.path, path]).output
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(file["sha256"]?.stringValue == digest, "hash mismatch for \(path)")
        }

        let snapshot = try JSONValue.parse(try run("/usr/bin/unzip", ["-p", archive.url.path, "snapshot.json"]).output)
        #expect(snapshot["providers"]?["world"]?["data"] == ["loaded": true, "password": "<redacted>"])
        let crumbs = try run("/usr/bin/unzip", ["-p", archive.url.path, "breadcrumbs.jsonl"]).text
        #expect(crumbs.contains("test.captureStarted"))
    }

    @Test func unsignedTraceHasNoSignature() async throws {
        DebugTrace.setCredential(nil)
        let archive = try await DebugTrace.capture(surface: DebugSurface(includeBuiltins: false), logWindowSeconds: 60)
        #expect(!archive.signed)
        #expect(try !run("/usr/bin/unzip", ["-Z1", archive.url.path]).text.contains("manifest.sig"))
    }

    /// The store verifies with Node's crypto — prove the formats agree.
    @Test func nodeVerifiesTheSignature() throws {
        guard let node = ["/usr/local/bin/node", "/opt/homebrew/bin/node"].first(where: FileManager.default.isExecutableFile) else {
            return
        }
        let message = Data("{\"format\":\"debugtrace/1\"}".utf8)
        let signature = try credential().sign(message)
        let script = """
        const c = require('crypto');
        const key = c.createPublicKey({key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), Buffer.from(process.argv[1], 'base64')]), format: 'der', type: 'spki'});
        process.stdout.write(String(c.verify(null, Buffer.from(process.argv[2], 'base64'), key, Buffer.from(process.argv[3], 'base64'))));
        """
        let result = try run(node, ["-e", script, Self.privateKey.publicKey.rawRepresentation.base64EncodedString(),
                                    message.base64EncodedString(), signature.base64EncodedString()])
        #expect(result.text == "true")
    }
}

// MARK: - Breadcrumbs and logs

@Suite struct DebugBreadcrumbsTests {
    @Test func featuresAreTrackedAndPersisted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crumbs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crumbs = DebugBreadcrumbs(directory: directory)
        crumbs.begin("stream", "90 Hz")
        #expect(crumbs.active.map(\.name) == ["stream"])
        crumbs.end("stream")
        crumbs.end("stream")  // a second end is not recorded
        #expect(crumbs.active.isEmpty)
        #expect(crumbs.recent().map(\.event) == ["_session.start", "stream.begin", "stream.end"])

        let reopened = DebugBreadcrumbs(directory: directory)
        let text = String(decoding: reopened.fileContents().current ?? Data(), as: UTF8.self)
        #expect(text.contains("stream.begin"))
        #expect(text.components(separatedBy: "_session.start").count == 3)
    }

    @Test func fileRotatesAtTheCap() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crumbs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let crumbs = DebugBreadcrumbs(directory: directory, maxFileBytes: 1_000)
        for index in 0..<50 { crumbs.mark("event.\(index)") }
        let files = crumbs.fileContents()
        #expect(files.previous != nil)
        #expect((files.current?.count ?? 0) <= 1_200)
    }
}

@Suite struct DebugLogReaderTests {
    @Test func readsBackThisProcessesLogs() throws {
        let subsystem = "com.illixion.debugtrace.tests"
        let marker = UUID().uuidString
        Logger(subsystem: subsystem, category: "Reader").notice("marker \(marker, privacy: .public) token=abcdef123")
        let result = try DebugLogReader.read(
            DebugLogQuery(since: Date().addingTimeInterval(-30), subsystems: [subsystem], contains: marker),
            redactor: .standard)
        let entry = try #require(result.entries.last)
        #expect(entry.category == "Reader")
        #expect(entry.level == .notice)
        #expect(entry.message == "marker \(marker) token=<redacted>")
        #expect(entry.line(primarySubsystem: subsystem).contains(" N Reader: marker"))
    }
}

// MARK: - Helpers

struct ProcessOutput {
    let status: Int32
    let output: Data
    var text: String { String(decoding: output, as: UTF8.self) }
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessOutput(status: process.terminationStatus, output: data)
}
