import Foundation
import Testing
@testable import DebugTrace
@testable import DebugTraceServer

/// When the server starts on its own, and what it advertises.
@Suite struct AttachTests {
    @Test func startsOnlyInDevelopmentBuilds() {
        for environment in [nil, "1", "0"] as [String?] {
            for token in [true, false] {
                #expect(!DebugTraceServer.requested(environment: environment, privacy: .release, hasCommandToken: token),
                        "release must never listen (env \(environment ?? "unset"), token \(token))")
            }
        }
    }

    @Test func aSignedDevBuildStartsWithoutBeingAsked() {
        #expect(DebugTraceServer.requested(environment: nil, privacy: .development, hasCommandToken: true))
    }

    @Test func anUnsignedDevBuildWaitsForAnExplicitRequest() {
        // An Xcode run has no credential: no listener, so no Local Network prompt.
        #expect(!DebugTraceServer.requested(environment: nil, privacy: .development, hasCommandToken: false))
        #expect(DebugTraceServer.requested(environment: "1", privacy: .development, hasCommandToken: false))
    }

    @Test func zeroTurnsItOffForOneLaunch() {
        #expect(!DebugTraceServer.requested(environment: "0", privacy: .development, hasCommandToken: true))
    }

    @Test func advertisesOnlyADeclaredServiceType() {
        #expect(DebugTraceServer.declaresBonjourService(["NSBonjourServices": ["_other._tcp", "_debugtrace._tcp"]]))
        #expect(!DebugTraceServer.declaresBonjourService(["NSBonjourServices": ["_other._tcp"]]))
        #expect(!DebugTraceServer.declaresBonjourService([:]))
        #expect(!DebugTraceServer.declaresBonjourService(nil))
    }

    @Test func theAdvertisementNamesNothingAndOnlyTheTokenRecognisesIt() {
        let txt = DebugTraceServer.txtRecord(token: "tok", nonce: "0011223344556677")
        #expect(Set(txt.keys) == ["txtvers", "n", "t"])
        #expect(txt["n"] == "0011223344556677")
        // The value debugtrace-mcp computes (Tests/DebugTraceMCPTests checks the same pair).
        #expect(txt["t"] == DebugTraceServer.advertisementTag(token: "tok", nonce: "0011223344556677"))
        #expect(txt["t"] == "2q1z0OLi6fUaWdLY")
        #expect(DebugTraceServer.advertisementTag(token: "other", nonce: "0011223344556677") != txt["t"])
        #expect(DebugTraceServer.txtRecord(token: nil, nonce: "x") == ["txtvers": "2"])
        #expect(DebugTraceServer.randomNonce() != DebugTraceServer.randomNonce())
    }

    @MainActor @Test func aTokenRecordedInTheCredentialIsTheOneDemanded() throws {
        let key = Data(repeating: 7, count: 32)
        let credential = try DebugTraceCredential(keyId: "k", signingKey: key, commandToken: "per-build-token")
        let previous = DebugTrace.credential
        DebugTrace.setCredential(credential)
        defer { DebugTrace.setCredential(previous) }
        let server = DebugTraceServer(surface: DebugSurface(), configuration: .init(ports: 0...0, binding: .loopback, approval: .allowAll))
        #expect(server.token == "per-build-token" || ProcessInfo.processInfo.environment["DEBUGTRACE_TOKEN"] != nil)
    }
}
