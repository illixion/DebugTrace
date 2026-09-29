import Foundation
import Network

/// One parsed HTTP/1.1 request. The server closes every connection after one
/// response, so there is no keep-alive or pipelining to handle.
struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseResult: Sendable {
    case needMore
    case complete(HTTPRequest)
    case invalid(status: Int, message: String)
}

enum HTTPParser {
    static let maxHeaderBytes = 64 * 1024
    private static let separator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data, maxBodyBytes: Int) -> HTTPParseResult {
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .invalid(status: 431, message: "request header too large") : .needMore
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .invalid(status: 400, message: "malformed request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid(status: 400, message: "bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid(status: 413, message: "body exceeds \(maxBodyBytes) bytes") }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid(status: 411, message: "chunked bodies are not supported; send Content-Length")
        }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .needMore }
        let body = buffer[bodyStart..<(bodyStart + length)]

        let target = String(requestLine[1])
        let components = URLComponents(string: target.hasPrefix("/") ? "http://x\(target)" : target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            // A bare `?flag` has a nil value; boolean parameters read "" as true.
            query[item.name] = item.value ?? ""
        }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        return .complete(HTTPRequest(method: String(requestLine[0]).uppercased(),
                                     path: path.isEmpty ? "/" : path,
                                     query: query, headers: headers, body: Data(body)))
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [(String, String)] = []

    static func json(_ status: Int, _ value: Data) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: value)
    }

    static func empty(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain", body: Data())
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        // Deliberately no Access-Control-Allow-Origin: the old server sent
        // `*`, which let any web page in any browser on the LAN read state.
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        default: "Status"
        }
    }
}
