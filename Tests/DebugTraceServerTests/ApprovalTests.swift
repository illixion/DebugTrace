import DebugTrace
import Foundation
import Testing
@testable import DebugTraceServer

/// The device-side prompt in front of every authenticated request.
@MainActor
@Suite(.serialized) struct ApprovalTests {
    final class Asked: @unchecked Sendable {
        var clients: [String] = []
        var offers = 0
        var onScreen = 0
        var mostOnScreen = 0
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
        #expect(await first.allowed("Agent", appName: "App", timeout: .seconds(1)) == .allowed)
        // A relaunch of the same build: no prompt.
        let relaunch = DebugApprovals(mode: mode, defaults: defaults, build: "abc1234")
        #expect(await relaunch.allowed("Agent", appName: "App", timeout: .seconds(1)) == .allowed)
        #expect(asked.clients.count == 1)
        // A new build asks again.
        let rebuilt = DebugApprovals(mode: mode, defaults: defaults, build: "def5678")
        #expect(await rebuilt.allowed("Agent", appName: "App", timeout: .seconds(1)) == .allowed)
        #expect(asked.clients.count == 2)
    }

    @Test func promptsForDifferentClientsNeverStack() async throws {
        let asked = Asked()
        let mode = DebugApproval.custom { request in
            asked.clients.append(request.client)
            asked.onScreen += 1
            asked.mostOnScreen = max(asked.mostOnScreen, asked.onScreen)
            try? await Task.sleep(for: .milliseconds(50))
            asked.onScreen -= 1
            return .allowOnce
        }
        let approvals = DebugApprovals(mode: mode, defaults: Self.scratchDefaults())
        async let a = approvals.allowed("A", appName: "App", timeout: .seconds(5))
        async let b = approvals.allowed("B", appName: "App", timeout: .seconds(5))
        async let c = approvals.allowed("C", appName: "App", timeout: .seconds(5))
        #expect(await [a, b, c] == [.allowed, .allowed, .allowed])
        #expect(Set(asked.clients) == ["A", "B", "C"])
        #expect(asked.mostOnScreen == 1)
    }

    @Test func aQueuedPromptNobodyWaitsForAnyMoreIsNeverShown() async throws {
        let asked = Asked()
        let gate = AsyncStream<Void>.makeStream()
        let mode = DebugApproval.custom { request in
            asked.clients.append(request.client)
            if request.client == "First" { for await _ in gate.stream { break } }
            return .deny
        }
        let approvals = DebugApprovals(mode: mode, defaults: Self.scratchDefaults())
        async let first = approvals.allowed("First", appName: "App", timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        // Queued behind First's prompt, and gives up before it is answered.
        #expect(await approvals.allowed("Flood", appName: "App", timeout: .milliseconds(100)) == .waiting)
        gate.continuation.yield()
        #expect(await first == .declined)
        try await Task.sleep(for: .milliseconds(50))
        #expect(asked.clients == ["First"])
    }

    func declining(silences: Bool, asked: Asked) -> DebugApproval {
        .custom({ request in
            asked.clients.append(request.client)
            return request.client == "Mine" ? .allowOnce : .deny
        }, silence: { offer in
            asked.offers += 1
            #expect(offer.duration == .seconds(3600))
            return silences
        })
    }

    @Test func aSecondDeclineOffersSilenceWhichRefusesNewClientsWithoutAsking() async throws {
        let asked = Asked()
        let (server, base) = try await serve(declining(silences: true, asked: asked))
        defer { server.stop() }
        #expect(try await get(base, "/_info", client: "Mine").0 == 200)
        #expect(try await get(base, "/_info", client: "Spam 1").0 == 403)
        #expect(asked.offers == 0)
        #expect(try await get(base, "/_info", client: "Spam 2").0 == 403)
        #expect(asked.offers == 1)
        let (status, body) = try await get(base, "/_info", client: "Spam 3")
        #expect(status == 403)
        #expect(body["error"]?["message"]?.stringValue?.contains("without asking") == true)
        #expect(body["error"]?["hint"]?.stringValue?.contains("relaunch") == true)
        #expect(asked.clients == ["Mine", "Spam 1", "Spam 2"])
        // Already allowed: unaffected.
        #expect(try await get(base, "/_info", client: "Mine").0 == 200)
    }

    @Test func keepAskingKeepsAskingAndOffersAgainAfterTwoMore() async throws {
        let asked = Asked()
        let approvals = DebugApprovals(mode: declining(silences: false, asked: asked), defaults: Self.scratchDefaults())
        for name in ["S1", "S2", "S3"] {
            #expect(await approvals.allowed(name, appName: "App", timeout: .seconds(5)) == .declined)
        }
        #expect(asked.offers == 1)
        #expect(await approvals.allowed("S4", appName: "App", timeout: .seconds(5)) == .declined)
        #expect(asked.offers == 2)
        #expect(asked.clients == ["S1", "S2", "S3", "S4"])
    }

    @Test func silenceEnds() async throws {
        let asked = Asked()
        let mode = DebugApproval.custom({ request in asked.clients.append(request.client); return .deny },
                                        silence: { _ in true })
        let approvals = DebugApprovals(mode: mode, defaults: Self.scratchDefaults(), silenceDuration: .milliseconds(200))
        _ = await approvals.allowed("S1", appName: "App", timeout: .seconds(5))
        _ = await approvals.allowed("S2", appName: "App", timeout: .seconds(5))
        guard case .silenced = await approvals.allowed("S3", appName: "App", timeout: .seconds(5)) else {
            Issue.record("expected silence")
            return
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await approvals.allowed("S3", appName: "App", timeout: .seconds(5)) == .declined)
        #expect(asked.clients == ["S1", "S2", "S3"])
    }

    @Test func theOfferNamesItsLength() {
        #expect(DebugSilenceOffer(appName: "A", duration: .seconds(3600)).acceptLabel == "Silence for an hour")
        #expect(DebugSilenceOffer(appName: "A", duration: .seconds(7200)).durationText == "2 hours")
        #expect(DebugSilenceOffer(appName: "A", duration: .seconds(900)).durationText == "15 minutes")
    }

    static func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DebugTraceApprovalTests-\(UUID().uuidString)")!
    }

    @Test func clientNamesAreShortAndPrintable() {
        #expect(DebugApprovals.clientName(header: "App Store page on Pegasus", userAgent: nil) == "App Store page on Pegasus")
        #expect(DebugApprovals.clientName(header: nil, userAgent: "curl/8.7.1") == "curl/8.7.1")
        #expect(DebugApprovals.clientName(header: nil, userAgent: nil) == "An unnamed client")
        #expect(DebugApprovals.clientName(header: "a\nb\u{0007}c", userAgent: nil) == "abc")
        #expect(DebugApprovals.clientName(header: String(repeating: "x", count: 200), userAgent: nil).count == 80)
    }
}
