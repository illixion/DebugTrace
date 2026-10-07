import DebugTrace
import Foundation
import Testing
@testable import DebugTraceServer

@inline(never) func profilerTestSpin(until deadline: Date) -> Double {
    var x = 1.0
    while Date() < deadline { for i in 0..<10_000 { x = x * 1.000001 + Double(i % 7) } }
    return x
}

@MainActor
struct ProfilerTests {
    @Test func findsTheBusyThreadAndItsFunction() async throws {
        let surface = DebugSurface()
        surface.register(DebugProfiler.endpoint)
        let spinner = Thread { _ = profilerTestSpin(until: Date().addingTimeInterval(1.5)) }
        spinner.name = "spinner"
        spinner.start()
        guard case .success(let output) = await surface.call("_profile", arguments: ["seconds": 0.6, "threads": "all"]),
              case .json(let json) = output.body else { Issue.record("_profile failed"); return }
        let threads = json["threads"]?.arrayValue ?? []
        let spin = try #require(threads.first { $0["name"]?.stringValue == "spinner" })
        #expect((spin["busyPercent"]?.doubleValue ?? 0) > 80)
        let inclusive = spin["inclusiveTop"]?.arrayValue?.compactMap { $0["function"]?.stringValue } ?? []
        #expect(inclusive.contains { $0.contains("profilerTestSpin") }, "\(inclusive)")
        #expect((json["samples"]?.intValue ?? 0) > 50)
    }

    @Test func demanglesSwiftNames() {
        #expect(DebugProfiler.demangle("$sSi1poiyS2i_SitFZ").contains("+"))
        #expect(DebugProfiler.demangle("mach_msg2_trap") == "mach_msg2_trap")
    }
}
