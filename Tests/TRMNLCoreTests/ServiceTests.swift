import XCTest
import AppKit
@testable import TRMNLCore

final class ServiceTests: XCTestCase {
    var directory: URL!
    var service: TRMNLService!
    var cookie = ""
    let secret = Data(repeating: 7, count: 32)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try restart()
    }
    override func tearDownWithError() throws { service = nil; try? FileManager.default.removeItem(at: directory) }
    func restart(now: @escaping () -> Date = Date.init) throws {
        service = nil
        service = try TRMNLService(configuration: Configuration(directory: directory, deviceHost: "192.168.1.50"), secret: secret, now: now)
        let response = service.agent(Request(method: "GET", path: "/", headers: ["host": "localhost:8788"]))
        XCTAssertEqual(response.status, 200)
        cookie = String(response.headers["Set-Cookie"]!.split(separator: ";")[0])
    }
    func body(_ response: Response) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any]) }
    func call(_ name: String, _ input: [String: Any] = [:]) throws -> Response {
        service.agent(Request(method: "POST", path: "/api/tools/" + name,
            headers: ["host": "localhost:8788", "origin": "http://localhost:8788", "cookie": cookie,
                      "content-type": "application/json", "x-ai-trmnl": "1"], body: try jsonData(input)))
    }
    func start() throws {
        let pairing = try body(call("get_pairing_status"))
        let result = try call("start_pairing", ["expected_revision": pairing["revision"]!, "request_id": UUID().uuidString])
        XCTAssertEqual(result.status, 200)
    }
    func setup(_ mac: String = "AA:BB:CC:DD:EE:01") throws -> [String: Any] {
        let response = service.firmware(Request(method: "GET", path: "/api/setup", headers: ["id": mac, "width": "800", "height": "480", "fw-version": "1.8.16", "model": "og"]))
        XCTAssertEqual(response.status, 200)
        return try body(response)
    }
    func device(_ mac: String = "AA:BB:CC:DD:EE:01") throws -> [String: Any] {
        let devices = try body(call("list_devices"))["devices"] as! [[String: Any]]
        return try XCTUnwrap(devices.first { $0["mac_address"] as? String == mac })
    }
    func confirm(_ mac: String = "AA:BB:CC:DD:EE:01") throws -> [String: Any] {
        let item = try device(mac)
        let response = try call("confirm_device", ["device_id": item["device_id"]!, "name": "Office OG", "expected_revision": item["revision"]!, "request_id": UUID().uuidString])
        XCTAssertEqual(response.status, 200); return try body(response)
    }
    func image(_ url: String) -> Response {
        let components = URLComponents(string: url)!
        return service.firmware(Request(method: "GET", path: components.path,
            query: Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value!) })))
    }
    func display(key: String, mac: String = "AA:BB:CC:DD:EE:01") -> Response {
        service.firmware(Request(method: "GET", path: "/api/display", headers: ["id": mac, "access-token": key]))
    }

    func testPairPublishFetchAndRestart() throws {
        try start(); let setup = try setup(); let key = setup["api_key"] as! String
        let pending = try body(display(key: key))
        XCTAssertEqual(pending["status"] as? Int, 0)
        XCTAssertEqual(image(pending["image_url"] as! String).body.count, 48062)
        let active = try confirm()
        XCTAssertEqual(try body(call("get_pairing_status"))["open"] as? Bool, false)
        let requestID = UUID().uuidString
        let input: [String: Any] = ["device_id": active["device_id"]!, "message": "HELLO FROM CODEX", "expected_revision": active["revision"]!, "request_id": requestID]
        let receipt = try body(call("publish_test_screen", input))
        XCTAssertEqual(receipt["committed"] as? Bool, true)
        let screen = try body(display(key: key))
        XCTAssertNotEqual(screen["filename"] as? String, pending["filename"] as? String)
        XCTAssertEqual(screen["update_firmware"] as? Bool, false)
        XCTAssertEqual(screen["reset_firmware"] as? Bool, false)
        let bmp = image(screen["image_url"] as! String)
        XCTAssertEqual(bmp.status, 200); XCTAssertEqual(bmp.headers["Content-Type"], "image/bmp")
        let saved = try device()
        XCTAssertNotNil(saved["last_image_response_at"])
        XCTAssertEqual(saved["physical_display_verified"] as? Bool, false)
        try restart()
        XCTAssertEqual(display(key: key).status, 200)
        XCTAssertEqual(try body(display(key: key))["filename"] as? String, screen["filename"] as? String)
        XCTAssertEqual(try jsonData(body(call("publish_test_screen", input))), try jsonData(receipt))
        XCTAssertEqual(try body(call("get_write_receipt", ["request_id": requestID]))["request_id"] as? String, requestID)
    }

    func testPairingClosedExpiredAndRestartClosed() throws {
        XCTAssertEqual(service.firmware(Request(method: "GET", path: "/api/setup", headers: ["id": "AA:BB:CC:DD:EE:01"])).status, 403)
        var time = Date(timeIntervalSince1970: 1_000_000)
        try restart(now: { time }); try start()
        time = time.addingTimeInterval(601)
        XCTAssertEqual(try body(call("get_pairing_status"))["open"] as? Bool, false)
        XCTAssertEqual(service.firmware(Request(method: "GET", path: "/api/setup", headers: ["id": "AA:BB:CC:DD:EE:01"])).status, 403)
        try start(); try restart()
        XCTAssertEqual(try body(call("get_pairing_status"))["open"] as? Bool, false)
    }

    func testIdempotencyConflictsAndStaleRevision() throws {
        try start(); _ = try setup(); let active = try confirm()
        let requestID = UUID().uuidString
        var input: [String: Any] = ["device_id": active["device_id"]!, "message": "FIRST", "expected_revision": active["revision"]!, "request_id": requestID]
        let first = try call("publish_test_screen", input)
        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(try call("publish_test_screen", input).body, first.body)
        input["message"] = "DIFFERENT"
        XCTAssertEqual(try call("publish_test_screen", input).status, 409)
        input["request_id"] = UUID().uuidString
        XCTAssertEqual(try call("publish_test_screen", input).status, 409)
        XCTAssertEqual((try device()["revision"] as? Int), 2)
    }

    func testThreeDevicesHaveIndependentImagesAndTokens() throws {
        var credentials: [[String: Any]] = []
        for suffix in ["01", "02", "03"] {
            try start()
            let mac = "AA:BB:CC:DD:EE:" + suffix
            credentials.append(try setup(mac)); _ = try confirm(mac)
        }
        let first = try device()
        XCTAssertEqual(try call("publish_test_screen", ["device_id": first["device_id"]!, "message": "ONLY ONE", "expected_revision": first["revision"]!, "request_id": UUID().uuidString]).status, 200)
        XCTAssertEqual(try device("AA:BB:CC:DD:EE:02")["revision"] as? Int, 1)
        XCTAssertEqual(display(key: credentials[0]["api_key"] as! String, mac: "AA:BB:CC:DD:EE:02").status, 401)
        let u1 = try body(display(key: credentials[0]["api_key"] as! String))["image_url"] as! String
        let u2 = try body(display(key: credentials[1]["api_key"] as! String, mac: "AA:BB:CC:DD:EE:02"))["image_url"] as! String
        var mixed = URLComponents(string: u1)!; mixed.queryItems = URLComponents(string: u2)!.queryItems
        XCTAssertEqual(image(mixed.string!).status, 404)
        XCTAssertNotEqual(image(u1).body, image(u2).body)
    }

    func testDisconnectRevokesImagesAndRePairRotatesTokens() throws {
        try start(); let setup = try setup(); let active = try confirm()
        let old = setup["api_key"] as! String
        let oldURL = try body(display(key: old))["image_url"] as! String
        let result = try call("disconnect_device", ["device_id": active["device_id"]!, "expected_revision": active["revision"]!, "request_id": UUID().uuidString])
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(display(key: old).status, 401); XCTAssertEqual(image(oldURL).status, 404)
        try start(); let replacement = try self.setup()
        XCTAssertNotEqual(replacement["api_key"] as? String, old)
        XCTAssertEqual(try device()["device_id"] as? String, active["device_id"] as? String)
        XCTAssertEqual(display(key: replacement["api_key"] as! String).status, 200)
    }

    func testAgentProtectionAndLANSeparation() throws {
        let home = service.agent(Request(method: "GET", path: "/", headers: ["host": "evil.example:8788"]))
        XCTAssertEqual(home.status, 403)
        XCTAssertEqual(service.agent(Request(method: "GET", path: "/api/tools", headers: ["host": "localhost:8788"])).status, 401)
        let request = Request(method: "POST", path: "/api/tools/start_pairing", headers: ["host": "localhost:8788", "cookie": cookie,
            "origin": "https://evil.example", "content-type": "application/json", "x-ai-trmnl": "1"], body: try jsonData([:]))
        XCTAssertEqual(service.agent(request).status, 403)
        XCTAssertEqual(service.firmware(request).status, 404)
        XCTAssertEqual(service.agent(Request(method: "GET", path: "/", headers: ["host": "localhost:8788", "sec-fetch-site": "cross-site"])).status, 403)
        XCTAssertEqual(try call("start_pairing", ["expected_revision": true, "request_id": UUID().uuidString]).status, 400)
        XCTAssertEqual(try call("list_devices", ["extra": 1]).status, 400)
        XCTAssertEqual(try call("get_device_status", ["device_id": "missing"]).status, 404)
    }

    func testSetupRetriesAndUnsupportedDimensions() throws {
        try start(); let first = try setup(); let retry = try setup()
        XCTAssertEqual(first["api_key"] as? String, retry["api_key"] as? String)
        XCTAssertEqual(first["image_url"] as? String, retry["image_url"] as? String)
        XCTAssertEqual(service.firmware(Request(method: "GET", path: "/api/setup", headers: ["id": "AA:BB:CC:DD:EE:02", "width": "1872"])).status, 400)
        XCTAssertEqual(service.firmware(Request(method: "GET", path: "/api/setup", headers: ["id": "not-a-mac"])).status, 400)
    }

    func testLogsAreBoundedAndRequireDeviceAuthentication() throws {
        try start(); let setup = try setup()
        let headers = ["id": "AA:BB:CC:DD:EE:01", "access_token": setup["api_key"] as! String]
        let response = service.firmware(Request(method: "POST", path: "/api/log", headers: headers,
            body: try jsonData(["logs": [["message": String(repeating: "x", count: 1000)]]])))
        XCTAssertEqual(response.status, 204)
        XCTAssertEqual((try device()["last_device_log"] as? String)?.count, 500)
        let sensitive = "key=\(setup["api_key"]!) image=\(setup["image_url"]!)"
        XCTAssertEqual(service.firmware(Request(method: "POST", path: "/api/log", headers: headers,
            body: try jsonData(["logs": [["message": sensitive]]]))).status, 204)
        let diagnostic = try XCTUnwrap(device()["last_device_log"] as? String)
        XCTAssertFalse(diagnostic.contains(setup["api_key"] as! String))
        XCTAssertTrue(diagnostic.contains("key=[redacted]"))
        XCTAssertTrue(diagnostic.hasSuffix("token=[redacted]"))
        XCTAssertEqual(service.firmware(Request(method: "POST", path: "/api/log", headers: headers,
            body: try jsonData(["logs": Array(repeating: ["message": "x"], count: 51)]))).status, 400)
    }

    func testBMPEncodingAndPreviewOrientation() throws {
        let image = try TestImage.render(name: "Office OG", code: "ABCD1234", message: "HELLO FROM CODEX", date: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(image.bmp.count, 48062)
        XCTAssertEqual(Array(image.bmp.prefix(2)), [0x42, 0x4d])
        func uint(_ offset: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(image.bmp[offset + $1]) << (8 * $1) } }
        XCTAssertEqual(uint(10, 4), 62); XCTAssertEqual(uint(14, 4), 40)
        XCTAssertEqual(uint(18, 4), 800); XCTAssertEqual(uint(22, 4), 480)
        XCTAssertEqual(uint(28, 2), 1); XCTAssertEqual(uint(30, 4), 0)
        let bmp = try XCTUnwrap(NSBitmapImageRep(data: image.bmp))
        let png = try XCTUnwrap(NSBitmapImageRep(data: image.png))
        XCTAssertEqual(bmp.pixelsWide, 800); XCTAssertEqual(bmp.pixelsHigh, 480)
        for y in stride(from: 0, to: 480, by: 7) {
            for x in stride(from: 0, to: 800, by: 7) {
                let a = bmp.colorAt(x: x, y: y)!.usingColorSpace(.genericGray)!.whiteComponent
                let b = png.colorAt(x: x, y: y)!.usingColorSpace(.genericGray)!.whiteComponent
                XCTAssertEqual(a > 0.5, b > 0.5, "BMP/PNG mismatch at \(x),\(y)")
            }
        }
    }
}

final class HTTPParserTests: XCTestCase {
    func testFirmwareListHeadersAreCombinedWithoutAllowingAmbiguousFraming() throws {
        let parsed = try XCTUnwrap(HTTPParser.parse(Data("GET /api/display HTTP/1.1\r\nHost: local\r\nAccept-Encoding: identity;q=1,*;q=0\r\nAccept-Encoding: identity\r\nX.Firmware: og\r\n\r\n".utf8)))
        XCTAssertEqual(parsed.headers["accept-encoding"], "identity;q=1,*;q=0, identity")
        XCTAssertEqual(parsed.headers["x.firmware"], "og")
        for name in ["Host", "Content-Length", "Access-Token", "ID"] {
            let headers = name == "Host" ? "Host: local\r\nHost: local" : "Host: local\r\n\(name): 0\r\n\(name): 0"
            XCTAssertThrowsError(try HTTPParser.parse(Data("GET / HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)))
        }
    }

    func testFragmentedBodyAndQuery() throws {
        let prefix = Data("POST /api/tools/get_server_info?x=y HTTP/1.1\r\nHost: localhost:8788\r\nContent-Length: 2\r\n\r\n{".utf8)
        XCTAssertNil(try HTTPParser.parse(prefix))
        let parsed = try XCTUnwrap(HTTPParser.parse(prefix + Data("}".utf8)))
        XCTAssertEqual(parsed.query["x"], "y"); XCTAssertEqual(parsed.body, Data("{}".utf8))
    }
    func testRejectsAmbiguousFramingAndOversizedRequests() throws {
        for headers in ["Content-Length: 2\r\nContent-Length: 3", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 65537", "Expect: 100-continue"] {
            XCTAssertThrowsError(try HTTPParser.parse(Data("POST / HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try HTTPParser.parse(Data(repeating: 65, count: 16385)))
        XCTAssertThrowsError(try HTTPParser.parse(Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPParser.parse(Data("GET /?x=1&x=2 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
    }
}
