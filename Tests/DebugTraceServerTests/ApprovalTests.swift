import DebugTrace
import Foundation
import Testing
@testable import DebugTraceServer

/// The device-side prompt in front of every authenticated request.
@MainActor
@Suite(.serialized) struct ApprovalTests {
    final class Asked: @unchecked Sendable {
        var clients: [String] = []
    }

    func serve(_ approval: DebugApproval, timeout: Duration = .seconds(5)) async throws -> (DebugTraceServer, URL) {
        let server = DebugTraceServer(surface: DebugSurface(), configuration: .init(
            ports: 0...0, binding: .loopback, authentication: .token("t"), approval: approval, approvalTimeout: timeout))
        let port = try await server.start()
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    func get(_ base: URL, _ path: String, client: String? = "Test client") async throws -> (Int, JSONValue) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.setValue("Bearer t", forHTTPHeaderField: "Authorization")
        if let client { request.setValue(client, forHTTPHeaderField: "X-DebugTrace-Client") }
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try JSONValue.parse(data))
    }

    @Test func allowedClientsAreServedAndAskedOnce() async throws {
        let asked = Asked()
        let (server, base) = try await serve(.custom { request in
            asked.clients.append(request.client)
            return .allowOnce
        })
        defer { server.stop() }
        #expect(try await get(base, "/_info").0 == 200)
        #expect(try await get(base, "/_info").0 == 200)
        #expect(asked.clients == ["Test client"])
    }

    @Test func eachClientIsAskedSeparately() async throws {
        let asked = Asked()
        let (server, base) = try await serve(.custom { request in
            asked.clients.append(request.client)
            return request.client == "Good" ? .allowOnce : .deny
        })
        defer { server.stop() }
        #expect(try await get(base, "/_info", client: "Good").0 == 200)
        let (status, body) = try await get(base, "/_info", client: "Bad")
        #expect(status == 403)
        #expect(body["error"]?["message"]?.stringValue?.contains("declined") == true)
        #expect(body["error"]?["hint"]?.stringValue?.contains("relaunch") == true)
        // A refusal sticks for the launch: no second prompt.
        #expect(try await get(base, "/_info", client: "Bad").0 == 403)
        #expect(asked.clients == ["Good", "Bad"])
    }

    @Test func helpNeedsNoApproval() async throws {
        let asked = Asked()
        let (server, base) = try await serve(.custom { request in asked.clients.append(request.client); return .deny })
        defer { server.stop() }
        var request = URLRequest(url: base.appending(path: "/"))
        request.timeoutInterval = 10
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 200)
        #expect(asked.clients.isEmpty)
    }

    @Test func aWrongTokenNeverReachesThePrompt() async throws {
        let asked = Asked()
        let (server, base) = try await serve(.custom { request in asked.clients.append(request.client); return .allowOnce })
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "/_info", relativeTo: base)!)
        request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 401)
        #expect(asked.clients.isEmpty)
    }

    @Test func anUnansweredPromptTimesOutWithAHintAndConcurrentRequestsShareIt() async throws {
        let asked = Asked()
        let gate = AsyncStream<Void>.makeStream()
        let (server, base) = try await serve(.custom { request in
            asked.clients.append(request.client)
            for await _ in gate.stream { break }
            return .allowOnce
        }, timeout: .milliseconds(300))
        defer { server.stop() }
        async let first = get(base, "/_info")
        async let second = get(base, "/_info")
        let (a, b) = try await (first, second)
        #expect(a.0 == 403 && b.0 == 403)
        #expect(a.1["error"]?["message"]?.stringValue?.contains("waiting") == true)
        #expect(asked.clients.count == 1)
        // Answered later: the next request goes through.
        gate.continuation.yield()
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await get(base, "/_info").0 == 200)
        #expect(asked.clients.count == 1)
    }

    @Test func allowForBuildIsRememberedForThatBuildOnly() async {
        let defaults = UserDefaults(suiteName: "DebugTraceApprovalTests-\(UUID().uuidString)")!
        let asked = Asked()
        let mode = DebugApproval.custom { request in asked.clients.append(request.client); return .allowForBuild }
        let first = DebugApprovals(mode: mode, defaults: defaults, build: "abc1234")
        #expect(await first.allowed("Agent", appName: "App", timeout: .seconds(1)) == true)
        // A relaunch of the same build: no prompt.
        let relaunch = DebugApprovals(mode: mode, defaults: defaults, build: "abc1234")
        #expect(await relaunch.allowed("Agent", appName: "App", timeout: .seconds(1)) == true)
        #expect(asked.clients.count == 1)
        // A new build asks again.
        let rebuilt = DebugApprovals(mode: mode, defaults: defaults, build: "def5678")
        #expect(await rebuilt.allowed("Agent", appName: "App", timeout: .seconds(1)) == true)
        #expect(asked.clients.count == 2)
    }

    @Test func clientNamesAreShortAndPrintable() {
        #expect(DebugApprovals.clientName(header: "App Store page on Pegasus", userAgent: nil) == "App Store page on Pegasus")
        #expect(DebugApprovals.clientName(header: nil, userAgent: "curl/8.7.1") == "curl/8.7.1")
        #expect(DebugApprovals.clientName(header: nil, userAgent: nil) == "An unnamed client")
        #expect(DebugApprovals.clientName(header: "a\nb\u{0007}c", userAgent: nil) == "abc")
        #expect(DebugApprovals.clientName(header: String(repeating: "x", count: 200), userAgent: nil).count == 80)
    }
}
