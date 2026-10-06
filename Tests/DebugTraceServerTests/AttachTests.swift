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

    @Test func txtRecordNamesTheBuild() {
        let txt = DebugTraceServer.txtRecord(info: [
            "CFBundleIdentifier": "pro.example.app", "CFBundleVersion": "abc1234",
            "CFBundleShortVersionString": "1.0", "CFBundleName": "Example",
        ], keyId: "k1")
        #expect(txt == ["txtvers": "1", "bundleId": "pro.example.app", "build": "abc1234",
                        "version": "1.0", "name": "Example", "keyId": "k1"])
        #expect(DebugTraceServer.txtRecord(info: ["CFBundleDisplayName": "Shown", "CFBundleName": "Inner"], keyId: nil)["name"] == "Shown")
        #expect(DebugTraceServer.txtRecord(info: nil, keyId: nil) == ["txtvers": "1"])
    }

    @MainActor @Test func aTokenRecordedInTheCredentialIsTheOneDemanded() throws {
        let key = Data(repeating: 7, count: 32)
        let credential = try DebugTraceCredential(keyId: "k", signingKey: key, commandToken: "per-build-token")
        let previous = DebugTrace.credential
        DebugTrace.setCredential(credential)
        defer { DebugTrace.setCredential(previous) }
        let server = DebugTraceServer(surface: DebugSurface(), configuration: .init(ports: 0...0, binding: .loopback))
        #expect(server.token == "per-build-token" || ProcessInfo.processInfo.environment["DEBUGTRACE_TOKEN"] != nil)
    }
}
