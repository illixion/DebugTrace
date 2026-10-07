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
        #expect(DebugProfiler.demangle("_ZN3rcp16SharedSimulation24handle_runloop_will_idleEv")
                == "rcp::SharedSimulation::handle_runloop_will_idle()")
    }
}

struct SharedCacheSymbolTests {
    /// Where the OS ships a readable symbols file, a system function resolves
    /// to a name; where it doesn't, the lookup says so instead of guessing.
    @Test func resolvesASystemFunctionOrDeclines() throws {
        guard let symbols = DebugSharedCacheSymbols.shared else { return }
        let address = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_retain"))
        var info = Dl_info()
        #expect(dladdr(address, &info) != 0)
        let name = symbols.name(for: UInt(bitPattern: address) + 4, imageBase: UInt(bitPattern: info.dli_fbase))
        #expect(name?.contains("retain") == true, "\(name ?? "nil")")
    }
}
