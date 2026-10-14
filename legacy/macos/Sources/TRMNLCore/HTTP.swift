import Foundation
import Network

public struct Request {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, query: [String: String] = [:], headers: [String: String] = [:], body: Data = Data()) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body
    }
}

public struct Response {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    init(_ status: Int = 200, _ body: Data = Data(), type: String = "application/json", headers: [String: String] = [:]) {
        self.status = status; self.body = body; self.headers = headers
        self.headers["Content-Type"] = type
        self.headers["Cache-Control"] = "no-store"
        self.headers["X-Content-Type-Options"] = "nosniff"
        self.headers["Referrer-Policy"] = "no-referrer"
        self.headers["X-Frame-Options"] = "DENY"
        self.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
    }
    static func json(_ value: Any, status: Int = 200) -> Response {
        Response(status, (try? jsonData(value)) ?? Data("{}".utf8))
    }
    static func problem(_ problem: Problem) -> Response {
        .json(["error": problem.code, "message": problem.description, "status": problem.status], status: problem.status)
    }
    func wire() -> Data {
        let labels = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 409: "Conflict",
                      413: "Content Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests",
                      431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable", 507: "Insufficient Storage"]
        var text = "HTTP/1.1 \(status) \(labels[status] ?? "Error")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for key in headers.keys.sorted() { text += "\(key): \(headers[key]!)\r\n" }
        text += "\r\n"
        return Data(text.utf8) + body
    }
}

/// Deliberately bounded HTTP/1.0–1.1 subset for firmware + JSON fetches.
/// No transfer encodings, pipelining, upgrades, or persistent connections.
enum HTTPParser {
    static let maxHeader = 16384
    static let maxBody = 65536
    static func parse(_ data: Data) throws -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeader { throw Problem(431, "headers_too_large", "Headers exceed 16 KiB.") }
            return nil
        }
        guard end.lowerBound <= maxHeader else { throw Problem(431, "headers_too_large", "Headers exceed 16 KiB.") }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw Problem(400, "bad_request", "Invalid headers.") }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])),
              first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("#"),
              let url = URLComponents(string: "http://local" + first[1]) else {
            throw Problem(400, "bad_request", "Invalid request target.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                throw Problem(400, "bad_request", "Invalid header.")
            }
            let key = String(line[..<colon]).lowercased()
            let punctuation = Set("!#$%&'*+-.^_`|~".utf8)
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || punctuation.contains($0) }) else {
                throw Problem(400, "bad_request", "Invalid header name: \(key.prefix(60)).")
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let previous = headers[key] {
                // HTTP permits repeated list-valued fields. Firmware/ESP32 clients can
                // both add Accept-Encoding. Never fold framing or credential fields.
                guard ["accept", "accept-encoding", "accept-language", "cache-control", "connection"].contains(key) else {
                    throw Problem(400, "bad_request", "Duplicate header: \(key.prefix(60)).")
                }
                headers[key] = previous + ", " + value
            } else {
                headers[key] = value
            }
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw Problem(400, "bad_request", "Host required; transfer encoding and Expect are unsupported.")
        }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText) else {
            throw Problem(400, "bad_request", "Invalid Content-Length.")
        }
        guard length <= maxBody else { throw Problem(413, "body_too_large", "Body exceeds 64 KiB.") }
        let available = data.count - end.upperBound
        if available < length { return nil }
        guard available == length else { throw Problem(400, "bad_request", "Pipelining is unsupported.") }
        var query: [String: String] = [:]
        for item in url.queryItems ?? [] {
            guard query[item.name] == nil else { throw Problem(400, "bad_request", "Duplicate query parameter.") }
            query[item.name] = item.value ?? ""
        }
        return Request(method: String(first[0]), path: url.path, query: query, headers: headers, body: data[end.upperBound...])
    }
}

public final class HTTPServer {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: (Request) -> Response
    private var connections: [UUID: HTTPConnection] = [:]
    public var onFailure: ((String) -> Void)?
    public var onRejectedRequest: ((String) -> Void)?

    public init(host: String, port: UInt16, queue: DispatchQueue, handler: @escaping (Request) -> Response) throws {
        self.queue = queue; self.handler = handler
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.onFailure?(error.localizedDescription) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.connections.count < 64 else { connection.cancel(); return }
            let id = UUID()
            let client = HTTPConnection(connection: connection, queue: self.queue, handler: self.handler,
                                        rejected: self.onRejectedRequest) { [weak self] in
                self?.connections.removeValue(forKey: id)
            }
            self.connections[id] = client
            client.start()
        }
        listener.start(queue: queue)
    }

    public func stop() { listener.cancel() }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (Request) -> Response
    private let finish: () -> Void
    private let rejected: ((String) -> Void)?
    private var data = Data()
    private var done = false
    private var timeout: DispatchWorkItem?
    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping (Request) -> Response,
         rejected: ((String) -> Void)?, finish: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.handler = handler; self.rejected = rejected; self.finish = finish
    }
    func start() {
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        receive()
    }
    private func close() {
        guard !done else { return }; done = true
        timeout?.cancel(); connection.cancel(); finish()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self, !self.done else { return }
            if let chunk { self.data.append(chunk) }
            do {
                if let request = try HTTPParser.parse(self.data) {
                    self.send(self.handler(request)); return
                }
                if complete || error != nil { self.close() } else { self.receive() }
            } catch let problem as Problem { self.rejected?(problem.description); self.send(.problem(problem)) }
            catch { self.send(.problem(Problem(400, "bad_request", "Could not parse request."))) }
        }
    }
    private func send(_ response: Response) {
        // contentProcessed means queued locally, not acknowledged by the OG. An
        // immediate cancel can truncate an image over slower household Wi-Fi.
        timeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.close() }
        self.timeout = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        connection.send(content: response.wire(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self, !self.done else { return }
            if error != nil { self.close() } else { self.awaitPeerClose() }
        })
    }
    private func awaitPeerClose() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, complete, error in
            guard let self, !self.done else { return }
            if complete || error != nil { self.close() } else { self.awaitPeerClose() }
        }
    }
}
