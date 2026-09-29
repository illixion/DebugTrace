import DebugTrace
import Foundation
import Testing
@testable import DebugTraceServer

@MainActor
@Suite(.serialized) struct DebugTraceServerTests {
    final class Flag: @unchecked Sendable {
        var value = false
    }

    struct Client {
        let base: URL
        let session: URLSession

        func request(_ method: String, _ path: String, json: String? = nil,
                     token: String? = "secret", headers: [String: String] = [:]) async throws -> (Int, Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: path, relativeTo: base)!)
            request.httpMethod = method
            if let json {
                request.httpBody = Data(json.utf8)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, data, http)
        }

        func json(_ method: String, _ path: String, json body: String? = nil, token: String? = "secret",
                  headers: [String: String] = [:]) async throws -> (Int, JSONValue) {
            let (status, data, _) = try await request(method, path, json: body, token: token, headers: headers)
            return (status, try JSONValue.parse(data))
        }
    }

    let exited = Flag()

    func start() async throws -> (DebugTraceServer, Client) {
        let surface = DebugSurface()
        surface.register(.query("position", "player position", parameters: [
            .string("space", "coordinate space", default: "world", choices: ["world", "chunk"]),
        ]) { args in ["x": 1.5, "y": 64, "space": .string(try args.requireString("space"))] as JSONValue })
        surface.register(.command("teleport", "move the player", parameters: [
            .number("x", "x", required: true), .number("z", "z", required: true),
        ]) { args in ["x": .double(try args.requireDouble("x")), "z": .double(try args.requireDouble("z"))] as JSONValue })
        surface.register(.raw("screenshot", kind: .query, "next frame as PNG") { _ in
            .binary(Data([0x89, 0x50, 0x4E, 0x47]), contentType: "image/png", filename: "frame.png")
        })
        let flag = exited
        surface.register(.raw("exit", kind: .command, "leave", destructive: true) { _ in
            try DebugResult.json(["exiting": true]).then { flag.value = true }
        })
        let server = DebugTraceServer(surface: surface, configuration: .init(port: 0, binding: .loopback, authentication: .token("secret")))
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return (server, Client(base: URL(string: "http://127.0.0.1:\(port)")!, session: URLSession(configuration: configuration)))
    }

    @Test func helpIsOpenAndSelfDescribing() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, help) = try await client.json("GET", "/", token: nil)
        #expect(status == 200)
        #expect(help["auth"]?["required"] == true)
        let endpoints = help["endpoints"]?.arrayValue ?? []
        let teleport = try #require(endpoints.first { $0["name"] == "teleport" })
        #expect(teleport["method"] == "POST")
        #expect(teleport["example"]?.stringValue?.contains(#"-d '{"x":0,"z":0}'"#) == true)
        #expect(endpoints.first?["name"]?.stringValue?.hasPrefix("_") == true)

        let (_, one) = try await client.json("GET", "/_help?endpoint=position", token: nil)
        #expect(one["endpoints"]?.arrayValue?.count == 1)
    }

    @Test func tokenIsRequired() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (missing, body) = try await client.json("GET", "/_info", token: nil)
        #expect(missing == 401)
        #expect(body["error"]?["code"] == "unauthenticated")
        #expect(body["error"]?["hint"] != nil)
        #expect(try await client.json("GET", "/_info", token: "wrong").0 == 401)
        let (ok, info) = try await client.json("GET", "/_info")
        #expect(ok == 200)
        #expect(info["ok"] == true)
        #expect(info["data"]?["app"]?["platform"] == "macOS")
    }

    @Test func queriesTakeValidatedQueryParameters() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, body) = try await client.json("GET", "/position?space=chunk")
        #expect(status == 200)
        #expect(body["data"]?["space"] == "chunk")
        let (bad, error) = try await client.json("GET", "/position?spcae=chunk")
        #expect(bad == 400)
        #expect(error["error"]?["hint"]?.stringValue?.contains("did you mean 'space'") == true)
    }

    @Test func commandsNeedPost() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, error) = try await client.json("GET", "/teleport?x=1&z=2")
        #expect(status == 405)
        #expect(error["error"]?["hint"]?.stringValue?.contains("-X POST") == true)
        let (ok, body) = try await client.json("POST", "/teleport", json: #"{"x": 10, "z": -4.5}"#)
        #expect(ok == 200)
        #expect(body["data"] == ["x": 10.0, "z": -4.5])
    }

    @Test func unknownEndpointSuggests() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, body) = try await client.json("GET", "/postion")
        #expect(status == 404)
        #expect(body["error"]?["details"]?["suggestions"]?[0] == "position")
    }

    @Test func browserOriginatedWritesAreRefused() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, _) = try await client.json("POST", "/teleport", json: #"{"x":1,"z":1}"#,
                                                headers: ["Origin": "https://evil.example"])
        #expect(status == 403)
    }

    @Test func binaryResultsAndDeferredActions() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, data, response) = try await client.request("GET", "/screenshot")
        #expect(status == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(data == Data([0x89, 0x50, 0x4E, 0x47]))

        #expect(!exited.value)
        let (ok, _) = try await client.json("POST", "/exit")
        #expect(ok == 200)
        try await Task.sleep(for: .milliseconds(200))
        #expect(exited.value)
    }

    @Test func mcpSpeaksToolsOverJSON() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (_, initialized) = try await client.json("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        #expect(initialized["result"]?["protocolVersion"] == "2025-06-18")
        #expect(initialized["result"]?["capabilities"]?["tools"] != nil)

        let (notified, _, _) = try await client.request("POST", "/mcp", json: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        #expect(notified == 202)

        let (_, list) = try await client.json("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = list["result"]?["tools"]?.arrayValue ?? []
        let teleport = try #require(tools.first { $0["name"] == "teleport" })
        #expect(teleport["annotations"]?["readOnlyHint"] == false)
        #expect(teleport["inputSchema"]?["required"] == ["x", "z"])
        #expect(tools.first { $0["name"] == "exit" }?["annotations"]?["destructiveHint"] == true)

        let (_, called) = try await client.json("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"position","arguments":{}}}"#)
        #expect(called["result"]?["isError"] == false)
        #expect(called["result"]?["structuredContent"]?["y"] == 64)

        let (_, failed) = try await client.json("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"teleport","arguments":{"x":1}}}"#)
        #expect(failed["result"]?["isError"] == true)
        #expect(failed["result"]?["content"]?[0]?["text"]?.stringValue?.contains("missing required argument") == true)

        let (_, image) = try await client.json("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"screenshot"}}"#)
        #expect(image["result"]?["content"]?[0]?["type"] == "image")

        let (_, unknown) = try await client.json("POST", "/mcp", json: #"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)
        #expect(unknown["error"]?["code"] == -32601)
    }

    @Test func tracesAreDownloadable() async throws {
        let (server, client) = try await start()
        defer { server.stop() }
        let (status, reply) = try await client.json("POST", "/_trace", json: #"{"note":"from test","logMinutes":1}"#)
        #expect(status == 200)
        let download = try #require(reply["data"]?["download"]?.stringValue)
        let (ok, data, response) = try await client.request("GET", download)
        #expect(ok == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "application/zip")
        #expect(data.prefix(2) == Data("PK".utf8))
    }

    @Test func responsesAreRedacted() async throws {
        let surface = DebugSurface(includeBuiltins: false)
        surface.register(.query("config", "config") { _ in ["server": "https://u:pw@host/x", "apiKey": "k"] as JSONValue })
        let server = DebugTraceServer(surface: surface, configuration: .init(port: 0, binding: .loopback, authentication: .none))
        let port = try await server.start()
        defer { server.stop() }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/config")!)
        let body = try JSONValue.parse(data)
        #expect(body["data"] == ["server": "https://<redacted>@host/x", "apiKey": "<redacted>"])
    }

    @Test func parserHandlesSplitBodiesAndPercentEncoding() {
        let head = "POST /a%20b?x=1%202&flag HTTP/1.1\r\nHost: h\r\nContent-Length: 4\r\n\r\n"
        guard case .needMore = HTTPParser.parse(Data((head + "ab").utf8), maxBodyBytes: 100) else {
            Issue.record("partial body parsed as complete")
            return
        }
        guard case .complete(let request) = HTTPParser.parse(Data((head + "abcd").utf8), maxBodyBytes: 100) else {
            Issue.record("complete request not parsed")
            return
        }
        #expect(request.path == "/a b")
        #expect(request.query == ["x": "1 2", "flag": ""])
        #expect(request.body == Data("abcd".utf8))
        guard case .invalid(let status, _) = HTTPParser.parse(Data((head + "abcd").utf8), maxBodyBytes: 2) else {
            Issue.record("oversized body accepted")
            return
        }
        #expect(status == 413)
    }

    @Test func queryDecodesPlusAsSpaceButKeepsEncodedPlus() {
        let raw = "GET /say?text=hello+world&sum=1%2B1&name+x=a HTTP/1.1\r\nHost: h\r\n\r\n"
        guard case .complete(let request) = HTTPParser.parse(Data(raw.utf8), maxBodyBytes: 100) else {
            Issue.record("request not parsed")
            return
        }
        #expect(request.query == ["text": "hello world", "sum": "1+1", "name x": "a"])
    }
}

@MainActor @Suite struct PortConflictTests {
    @Test func aTakenPortFailsWithAHintInsteadOfMoving() async throws {
        let first = DebugTraceServer(surface: DebugSurface(), configuration: .init(port: 0, binding: .loopback, authentication: .none))
        let port = try await first.start()
        defer { first.stop() }
        let second = DebugTraceServer(surface: DebugSurface(), configuration: .init(port: port, binding: .loopback, authentication: .none))
        do {
            _ = try await second.start()
            second.stop()
            Issue.record("a second server bound the same port")
        } catch let error as DebugError {
            #expect(error.hint?.contains("registry") == true)
        }
        #expect(!second.isRunning)
    }
}
