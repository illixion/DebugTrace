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
}
