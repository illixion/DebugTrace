import DebugTrace
import Foundation
import Testing
@testable import DebugTraceServer

/// `Configuration.confidential`: a private messenger's server shows a status
/// page and nothing more.
@MainActor
@Suite(.serialized) struct ConfidentialTests {
    func serve(confidential: Bool) async throws -> (DebugTraceServer, URL) {
        let surface = DebugSurface()
        surface.register(.query("safeState", "counts only", releaseSafe: true) { _ in ["count": 3] })
        surface.register(.query("contentState", "has names") { _ in ["name": "Alice"] })
        surface.register(.command("send", "sends") { _ in ["ok": true] })
        surface.register(.untyped("_inject", kind: .command, "load code", releaseSafe: true) { _ in ["ok": true] })
        let server = DebugTraceServer(surface: surface, configuration: .init(
            ports: 0...0, binding: .loopback, authentication: .token("t"), approval: .allowAll,
            confidential: confidential))
        return (server, URL(string: "http://127.0.0.1:\(try await server.start())")!)
    }

    func send(_ base: URL, _ path: String, post: Bool = false, body: String? = nil) async throws -> (Int, JSONValue) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = post ? "POST" : "GET"
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try JSONValue.parse(data))
    }

    @Test func onlySafeQueriesAreServed() async throws {
        let (server, base) = try await serve(confidential: true)
        defer { server.stop() }
        #expect(try await send(base, "/safeState").0 == 200)
        #expect(try await send(base, "/_info").0 == 200)
        for refused in ["/contentState", "/_logs", "/_snapshot", "/_traces/x.zip"] {
            #expect(try await send(base, refused).0 == 404, "\(refused)")
        }
        for refused in ["/send", "/_inject", "/_trace"] {
            #expect(try await send(base, refused, post: true, body: "{}").0 == 404, "\(refused)")
        }
    }

    @Test func theCatalogsOmitWhatIsWithheld() async throws {
        let (server, base) = try await serve(confidential: true)
        defer { server.stop() }
        let tools = try await send(base, "/_tools").1["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(Set(tools).isSuperset(of: ["safeState", "_info"]))
        #expect(Set(tools).isDisjoint(with: ["contentState", "send", "_inject", "_logs", "_snapshot", "_trace"]))
        let helped = try await send(base, "/").1.serializedString()
        #expect(!helped.contains("contentState") && !helped.contains("\"send\""))
        let call = try await send(base, "/_call", post: true, body: #"{"name":"send","arguments":{}}"#)
        #expect(call.0 == 404)
        let mcp = try await send(base, "/mcp", post: true, body: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"contentState","arguments":{}}}"#)
        #expect(mcp.1["result"]?["isError"]?.boolValue == true)
        #expect(!mcp.1.serializedString().contains("Alice"))
    }

    @Test func anOrdinaryServerServesEverything() async throws {
        let (server, base) = try await serve(confidential: false)
        defer { server.stop() }
        #expect(try await send(base, "/contentState").0 == 200)
        #expect(try await send(base, "/send", post: true, body: "{}").0 == 200)
    }

    @Test func confidentialNeverLoadsThePatchRuntime() {
        #expect(!DebugTraceServer.Configuration(confidential: true).loadsPatchRuntime)
        #expect(DebugTraceServer.Configuration().loadsPatchRuntime)
    }
}
