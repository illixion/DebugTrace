import DebugTrace
import Foundation
import Testing
@testable import DebugTraceInject

@MainActor
struct InjectTests {
    @Test func registersInDevelopmentOnly() async {
        let surface = DebugSurface(includeBuiltins: false)
        DebugTraceInject.register(on: surface)
        #expect(surface.endpoint(named: "_inject")?.kind == .command)
        #expect(surface.endpoint(named: "_inject")?.destructive == true)
        #expect(surface.endpoint(named: "_patches")?.kind == .query)
    }

    @Test func rejectsNonBase64() async {
        let surface = DebugSurface(includeBuiltins: false)
        DebugTraceInject.register(on: surface)
        let result = await surface.call("_inject", arguments: ["patch": "!!! not base64"])
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .invalidArgument)
        #expect(error.hint != nil)
    }

    @Test func refusesAFileThatIsNotACodeSignedDylib() async {
        let surface = DebugSurface(includeBuiltins: false)
        DebugTraceInject.register(on: surface)
        let junk = Data("not a mach-o".utf8).base64EncodedString()
        let result = await surface.call("_inject", arguments: ["patch": .string(junk)])
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == .failedPrecondition)
        #expect(error.hint?.isEmpty == false)
        #expect(DebugTraceInject.loaded.isEmpty)
    }

    @Test func hintsNameTheFix() {
        #expect(DebugTraceInject.hint(forLoadFailure: "missing code signature in x").contains("same development certificate"))
        #expect(DebugTraceInject.hint(forLoadFailure: "symbol not found in flat namespace '_x'").contains("--inject"))
    }

    @Test func inflatesADeflatedPatchToItsDeclaredSize() async throws {
        let original = Data((0..<4000).map { UInt8($0 % 7) })
        let deflated = try (original as NSData).compressed(using: .zlib) as Data
        #expect(try DebugTraceInject.inflate(deflated, expecting: original.count) == original)
        // A wrong declared size is an error, never a cut or padded patch.
        #expect(throws: DebugError.self) { try DebugTraceInject.inflate(deflated, expecting: original.count - 1) }
        #expect(throws: DebugError.self) { try DebugTraceInject.inflate(deflated, expecting: original.count + 1) }
        #expect(throws: DebugError.self) { try DebugTraceInject.inflate(Data("not deflate".utf8), expecting: 10) }
    }

    /// What `debugtrace-mcp` sends: Python's zlib with wbits=-15, a raw DEFLATE stream.
    @Test func inflatesWhatPythonDeflated() throws {
        let sent = Data(base64Encoded: "Uyk2Dy7PTCsJ9TQJy0wtD3B0dDX3qCzIyy8OMzQOTi0pycxLLw5JTAJJhqmMKh5VPKp4VPGo4lHFo4pHFQ8mxQA=")!
        let expected = Data(String(repeating: "$s7SwiftUI4ViewPAAE7HypnosV13SettingsTabViewV", count: 50).utf8)
        #expect(expected.count == 2250)
        #expect(try DebugTraceInject.inflate(sent, expecting: 2250) == expected)
    }
}
