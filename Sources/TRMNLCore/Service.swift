import Foundation
import CryptoKit
import CoreFoundation

public struct Configuration {
    public var directory: URL
    public var deviceHost: String
    public var devicePort: UInt16
    public var agentPort: UInt16
    public var refreshSeconds: Int
    public init(directory: URL, deviceHost: String, devicePort: UInt16 = 8787, agentPort: UInt16 = 8788, refreshSeconds: Int = 60) {
        self.directory = directory; self.deviceHost = deviceHost; self.devicePort = devicePort
        self.agentPort = agentPort; self.refreshSeconds = refreshSeconds
    }
    public var agentURL: String { "http://localhost:\(agentPort)" }
    public var deviceURL: String { "http://\(deviceHost):\(devicePort)" }
}

struct Tool {
    var name: String
    var description: String
    var readOnly: Bool
    var fields: [String: String]
    var objects: [String: [String: Any]] = [:]
    var descriptor: [String: Any] {
        ["name": name, "description": description, "annotations": ["readOnlyHint": readOnly],
         "inputSchema": ["type": "object", "properties": fields.reduce(into: [String: [String: Any]]()) { result, field in result[field.key] = objects[field.key] ?? ["type": field.value] },
                         "required": fields.keys.sorted(), "additionalProperties": false]]
    }
    func validate(_ input: [String: Any]) throws {
        guard Set(input.keys) == Set(fields.keys) else { throw Problem(400, "invalid_arguments", "Expected exactly: \(fields.keys.sorted().joined(separator: ", ")).") }
        for (key, type) in fields {
            if type == "string" {
                guard let value = input[key] as? String, !value.isEmpty, value.count <= 200,
                      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw Problem(400, "invalid_arguments", "\(key) must be a nonempty single-line string, at most 200 characters.")
                }
            } else if type == "object" {
                guard input[key] is [String: Any] else { throw Problem(400, "invalid_arguments", "\(key) must be a JSON object.") }
            } else {
                guard let value = input[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue >= 0, value.doubleValue <= 1_000_000_000,
                      value.doubleValue.rounded() == value.doubleValue else {
                    throw Problem(400, "invalid_arguments", "\(key) must be a nonnegative integer.")
                }
            }
        }
        if let id = input["request_id"] as? String, UUID(uuidString: id) == nil {
            throw Problem(400, "invalid_request_id", "Use a UUID for request_id and reuse it for retries.")
        }
    }
}

/// All calls are made on one serial queue, including firmware and agent requests.
public final class TRMNLService {
    public let configuration: Configuration
    private let store: Store
    private let secret: SymmetricKey
    private var registry: Registry
    private let session = randomToken()
    private let now: () -> Date
    private let imageDirectory: URL
    private var lastDeviceError: [String: String] = [:]

    public func recordRejectedDeviceRequest(_ reason: String) {
        lastDeviceError = ["at": iso(now().timeIntervalSince1970), "message": reason]
    }
    private let tools: [Tool] = [
        Tool(name: "get_server_info", description: "Read server addresses, pairing revision, capabilities, and next steps. Start here.", readOnly: true, fields: [:]),
        Tool(name: "list_devices", description: "List the known TRMNL devices, their stable IDs, identification codes, states, and revisions.", readOnly: true, fields: [:]),
        Tool(name: "get_pairing_status", description: "Read the pairing window and pending devices. Match the physical identification code before confirming a device.", readOnly: true, fields: [:]),
        Tool(name: "get_device_status", description: "Read a device's current publication, last check-in, image response time, and diagnostic. Image serving does not prove physical rendering.", readOnly: true, fields: ["device_id": "string"]),
        Tool(name: "get_write_receipt", description: "Look up a committed write by request_id after an uncertain result. Reuse the original ID and input when retrying.", readOnly: true, fields: ["request_id": "string"]),
        Tool(name: "start_pairing", description: "Open a 10-minute window for OG device enrollment. Use the pairing revision from get_server_info and a new UUID request_id. Returns physical Wi-Fi instructions.", readOnly: false, fields: ["expected_revision": "integer", "request_id": "string"]),
        Tool(name: "confirm_device", description: "Confirm the pending physical device identified by its code and assign a name (40 characters maximum). Closes pairing. Use the device's current revision and a UUID request_id.", readOnly: false, fields: ["device_id": "string", "name": "string", "expected_revision": "integer", "request_id": "string"]),
        Tool(name: "publish_test_screen", description: "Render and publish an 800x480 1-bit BMP test screen for one active OG. Supply a short message (70 characters maximum), current device revision, and UUID request_id. Returns a committed receipt and PNG preview URL.", readOnly: false, fields: ["device_id": "string", "message": "string", "expected_revision": "integer", "request_id": "string"]),
        Tool(name: "get_device_profile", description: "Read a device's saved dashboard preferences, exact template definition, current revision, and last published data. Use saved sources and preferences for future updates.", readOnly: true, fields: ["device_id": "string"]),
        Tool(name: "save_dashboard", description: "Save user-approved weather/agenda preferences for one active device. This does not change the display. Use a UUID request_id and current device revision. Routine content refreshes should not change preferences.", readOnly: false, fields: ["device_id": "string", "profile": "object", "expected_revision": "integer", "request_id": "string"], objects: ["profile": DashboardProfile.schema]),
        Tool(name: "render_dashboard", description: "Stage an immutable weather/agenda screen using the saved profile and fresh source data. No external fetching happens here. Return PNG preview, image ID, and event overflow counts. Use null for unknown weather values; dates need explicit offsets except all-day YYYY-MM-DD exclusive end dates. Inspect preview before publish_screen.", readOnly: false, fields: ["device_id": "string", "snapshot": "object", "expected_revision": "integer", "request_id": "string"], objects: ["snapshot": DashboardSnapshot.schema]),
        Tool(name: "publish_screen", description: "Publish a previously rendered image to its owning device after inspecting the preview. Rejects an image from another device or an outdated profile. Supply image_id, current device revision, and a UUID request_id.", readOnly: false, fields: ["device_id": "string", "image_id": "string", "expected_revision": "integer", "request_id": "string"]),
        Tool(name: "disconnect_device", description: "Retire a device and revoke API/image access without resetting the physical device or deleting its saved records. Use its current revision and UUID request_id; only call when the user requests disconnection.", readOnly: false, fields: ["device_id": "string", "expected_revision": "integer", "request_id": "string"])
    ]

    public init(configuration: Configuration, secret: Data, now: @escaping () -> Date = Date.init) throws {
        self.configuration = configuration; self.secret = SymmetricKey(data: secret); self.now = now
        guard (1...65535).contains(Int(configuration.agentPort)), configuration.agentPort != configuration.devicePort,
              (60...86400).contains(configuration.refreshSeconds) else { throw Problem(400, "invalid_configuration", "Use distinct ports and a refresh interval of 60–86400 seconds.") }
        store = try Store(directory: configuration.directory)
        registry = try store.load()
        imageDirectory = configuration.directory.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Never resume an enrollment window after a server restart.
        if registry.pairingUntil > 0 { registry.pairingUntil = 0; registry.pairingRevision += 1; try store.save(registry) }
        cleanupImages()
    }

    private func token(_ device: Device, purpose: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data("\(purpose):\(device.id):\(device.nonce)".utf8), using: secret)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func device(_ id: String) throws -> Device {
        guard let result = registry.devices[id] else { throw Problem(404, "device_not_found", "Unknown device ID.") }; return result
    }

    private func summary(_ device: Device) -> [String: Any] {
        var result: [String: Any] = ["device_id": device.id, "name": device.name, "identification_code": device.code,
                                   "mac_address": device.mac, "state": device.state, "revision": device.revision,
                                   "firmware": device.firmware, "model": device.model,
                                   "width": 800, "height": 480, "image_format": "BMP3 1-bit",
                                   "physical_display_verified": false]
        if let value = device.lastSeen { result["last_check_in"] = iso(value) }
        if let value = device.lastImageServedAt { result["last_image_response_at"] = iso(value) }
        if let value = device.lastImageServed { result["last_image_response_id"] = value }
        if let value = device.lastLog { result["last_device_log"] = value }
        if let publication = registry.publications[device.currentImage] {
            result["publication"] = ["image_id": publication.id, "sha256": publication.sha256, "created_at": iso(publication.createdAt),
                                     "preview_url": configuration.agentURL + "/previews/\(publication.id).png"]
        }
        return result
    }

    private func iso(_ value: Double) -> String { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value)) }
    private var pairingOpen: Bool { registry.pairingUntil > now().timeIntervalSince1970 }
    private func pairingStatus() -> [String: Any] {
        ["open": pairingOpen, "revision": registry.pairingRevision,
         "expires_at": registry.pairingUntil > 0 ? iso(registry.pairingUntil) : "closed",
         "pending_devices": registry.devices.values.filter { $0.state == "pending" }.sorted { $0.mac < $1.mac }.map(summary)]
    }

    public func agent(_ request: Request) -> Response {
        do {
            let hosts = ["localhost:\(configuration.agentPort)", "127.0.0.1:\(configuration.agentPort)"]
            guard hosts.contains(request.headers["host"] ?? "") else { throw Problem(403, "invalid_host", "Use the local agent URL shown by the app.") }
            if let site = request.headers["sec-fetch-site"], site != "same-origin" && site != "none" {
                throw Problem(403, "cross_site_request", "Open the agent page directly.")
            }
            if request.method == "GET", request.path == "/" || request.path == "/help" {
                let html = try webFile("index.html").replacingOccurrences(of: "{{AGENT_URL}}", with: configuration.agentURL)
                    .replacingOccurrences(of: "{{DEVICE_URL}}", with: configuration.deviceURL)
                return Response(200, Data(html.utf8), type: "text/html; charset=utf-8",
                                headers: ["Set-Cookie": "ai_trmnl_session=\(session); HttpOnly; SameSite=Strict; Path=/"])
            }
            if request.method == "GET", ["/tools.js", "/style.css"].contains(request.path) {
                return Response(200, Data(try webFile(String(request.path.dropFirst())).utf8),
                                type: request.path.hasSuffix(".js") ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8")
            }
            let cookies = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cookies.contains(where: { constantTimeEqual($0, "ai_trmnl_session=" + session) }) else {
                throw Problem(401, "open_agent_page", "Open the Help page to establish a local session.")
            }
            if request.method == "GET", request.path == "/api/tools" { return .json(["tools": tools.map(\.descriptor)]) }
            if request.method == "GET", request.path.hasPrefix("/previews/") {
                let image = String(request.path.dropFirst("/previews/".count).dropLast(4))
                guard request.path.hasSuffix(".png"), let publication = registry.publications[image],
                      try device(publication.deviceID).state != "disconnected" else { throw Problem(404, "image_not_found", "Preview unavailable.") }
                return Response(200, try Data(contentsOf: imageDirectory.appendingPathComponent(image + ".png")), type: "image/png")
            }
            guard request.method == "POST", request.path.hasPrefix("/api/tools/") else { throw Problem(404, "not_found", "Unknown agent route.") }
            guard hosts.map({ "http://" + $0 }).contains(request.headers["origin"] ?? ""), request.headers["x-ai-trmnl"] == "1" else {
                throw Problem(403, "invalid_origin", "Agent writes require the local page origin and request header.")
            }
            guard request.headers["content-type"]?.split(separator: ";").first == "application/json" else { throw Problem(415, "json_required", "Use application/json.") }
            let name = String(request.path.dropFirst("/api/tools/".count))
            guard let tool = tools.first(where: { $0.name == name }) else { throw Problem(404, "unknown_tool", "Unknown tool.") }
            guard request.body.count <= HTTPParser.maxBody,
                  let input = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else { throw Problem(400, "invalid_json", "Expected a JSON object.") }
            try tool.validate(input)
            return .json(try invoke(tool, input))
        } catch let error as Problem { return .problem(error) }
        catch { return .problem(Problem(500, "server_error", "Local operation failed. Check the data directory and restart if necessary.")) }
    }

    private func webFile(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Web") else { throw Problem(500, "missing_resource", "Help resource missing.") }
        return try String(contentsOf: url)
    }

    private func invoke(_ tool: Tool, _ input: [String: Any]) throws -> [String: Any] {
        switch tool.name {
        case "get_server_info":
            return ["version": "0.2.0", "milestone": "saved weather and agenda dashboards", "agent_url": configuration.agentURL,
                    "device_server_url": configuration.deviceURL, "pairing": pairingStatus(), "refresh_seconds": configuration.refreshSeconds,
                    "storage": "SQLite + Keychain + image files", "next_step": "List devices. If your OG is not registered, start_pairing, then follow the Help page's physical connection steps.",
                    "last_device_error": lastDeviceError,
                    "templates": [DashboardRenderer.definition], "not_implemented": ["arbitrary templates", "hourly scheduling", "launch at login"]]
        case "list_devices": return ["devices": registry.devices.values.sorted { $0.mac < $1.mac }.map(summary)]
        case "get_pairing_status": return pairingStatus()
        case "get_device_status": return summary(try device(input["device_id"] as! String))
        case "get_device_profile":
            let device = try device(input["device_id"] as! String)
            var result = summary(device)
            result["dashboard"] = try device.dashboard.map(encoded) ?? NSNull()
            result["template_definition"] = DashboardRenderer.definition
            if let snapshot = registry.publications[device.currentImage]?.snapshot { result["last_snapshot"] = try encoded(snapshot) }
            return result
        case "get_write_receipt": return try store.receipt(input["request_id"] as! String) ?? ["found": false]
        default: break
        }
        let requestID = input["request_id"] as! String
        let inputDigest = digest(try jsonData(["tool": tool.name, "input": input]))
        if let replay = try store.receipt(requestID, digest: inputDigest) { return replay }
        let before = registry
        do {
            let expected = (input["expected_revision"] as! NSNumber).intValue
            var result: [String: Any]
            var staged: Publication?
            if tool.name == "start_pairing" {
                guard expected == registry.pairingRevision else { throw Problem(409, "revision_conflict", "Read the current pairing revision before trying again.") }
                registry.pairingUntil = now().timeIntervalSince1970 + 600
                registry.pairingRevision += 1
                result = pairingStatus()
                result["device_server_url"] = configuration.deviceURL
                result["instructions"] = "On the powered-on OG, hold the rear button for 6–8 seconds. Join its TRMNL Wi-Fi from a phone, choose your 2.4 GHz household Wi-Fi, select Custom Server, and enter \(configuration.deviceURL). Wait for its identification screen, then match its code using get_pairing_status."
            } else {
                var device = try self.device(input["device_id"] as! String)
                guard device.revision == expected else { throw Problem(409, "revision_conflict", "Read this device's current revision before trying again.") }
                switch tool.name {
                case "confirm_device":
                    guard device.state == "pending" else { throw Problem(409, "not_pending", "Only pending devices can be confirmed.") }
                    let name = input["name"] as! String
                    guard name.count <= 40 else { throw Problem(400, "name_too_long", "Use a name of at most 40 characters.") }
                    device.state = "active"; device.name = name
                    registry.pairingUntil = 0; registry.pairingRevision += 1
                case "publish_test_screen":
                    guard device.state == "active" else { throw Problem(409, "device_not_active", "Confirm this device first.") }
                    let message = input["message"] as! String
                    guard message.count <= 70 else { throw Problem(400, "message_too_long", "Use a message of at most 70 characters.") }
                    let publication = try makeImage(device: device, title: device.name, message: message)
                    registry.publications[publication.id] = publication; device.currentImage = publication.id
                case "save_dashboard":
                    guard device.state == "active" else { throw Problem(409, "device_not_active", "Confirm this device first.") }
                    let profile = try decoded(DashboardProfile.self, input["profile"]!)
                    try profile.validate()
                    device.dashboard = SavedDashboard(revision: (device.dashboard?.revision ?? 0) + 1, profile: profile)
                case "render_dashboard":
                    guard device.state == "active", let dashboard = device.dashboard else { throw Problem(409, "dashboard_required", "Save a dashboard for this active device first.") }
                    let snapshot = try decoded(DashboardSnapshot.self, input["snapshot"]!)
                    let rendered = try DashboardRenderer.render(profile: dashboard.profile, snapshot: snapshot, now: now())
                    var publication = try saveImage(device: device, title: dashboard.profile.location + " weather + agenda", image: (rendered.bmp, rendered.png))
                    publication.dashboardRevision = dashboard.revision; publication.snapshot = snapshot
                    publication.shownEvents = rendered.shown; publication.omittedEvents = rendered.omitted; publication.truncatedTitles = rendered.truncated
                    registry.publications[publication.id] = publication; staged = publication
                case "publish_screen":
                    guard device.state == "active", let dashboard = device.dashboard,
                          let publication = registry.publications[input["image_id"] as! String],
                          publication.deviceID == device.id, publication.dashboardRevision == dashboard.revision else {
                        throw Problem(409, "image_conflict", "Render an image for this device's current saved profile first.")
                    }
                    guard now().timeIntervalSince1970 - publication.createdAt < 1800 else {
                        throw Problem(409, "render_expired", "This preview is over 30 minutes old. Render again so agenda filtering and freshness markers stay current.")
                    }
                    device.currentImage = publication.id
                case "disconnect_device":
                    guard device.state != "disconnected" else { throw Problem(409, "already_disconnected", "This device is already disconnected.") }
                    device.state = "disconnected"; device.nonce = randomToken()
                default: throw Problem(404, "unknown_tool", "Unknown tool.")
                }
                device.revision += 1
                registry.devices[device.id] = device
                result = summary(device)
                if let dashboard = device.dashboard { result["dashboard_revision"] = dashboard.revision }
                if let staged {
                    result["rendered"] = ["image_id": staged.id, "preview_url": configuration.agentURL + "/previews/\(staged.id).png",
                                          "sha256": staged.sha256, "shown_event_rows": staged.shownEvents!, "omitted_event_rows": staged.omittedEvents!, "truncated_titles": staged.truncatedTitles!]
                }
                if tool.name == "disconnect_device" {
                    result["next_step"] = "Reopen the device's Wi-Fi portal and choose another server or its official hosted-server option. This operation does not erase its displayed image or reset its Wi-Fi."
                } else if tool.name == "render_dashboard" { result["next_step"] = "Inspect rendered.preview_url, then publish_screen with the returned image_id and device revision." }
                else if tool.name == "save_dashboard" { result["next_step"] = "Collect sources using the saved profile, then render_dashboard. Saving preferences does not publish a screen." }
                else { result["next_step"] = "Press the rear button briefly to request content, or wait for the next check-in. Ask the user to confirm what is visible." }
            }
            result["request_id"] = requestID; result["committed"] = true
            pruneHistory()
            try store.save(registry, receipt: (requestID, inputDigest, result))
            cleanupImages()
            return result
        } catch { registry = before; cleanupImages(); throw error }
    }

    private func makeImage(device: Device, title: String, message: String) throws -> Publication {
        let image = try TestImage.render(name: title, code: device.code, message: message, date: now())
        return try saveImage(device: device, title: title, image: image)
    }

    private func saveImage(device: Device, title: String, image: (bmp: Data, png: Data)) throws -> Publication {
        let id = UUID().uuidString.lowercased()
        for (extensionName, data) in [("bmp", image.bmp), ("png", image.png)] {
            let path = imageDirectory.appendingPathComponent(id + "." + extensionName)
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        return Publication(id: id, deviceID: device.id, title: title, createdAt: now().timeIntervalSince1970, sha256: digest(image.bmp))
    }

    private func pruneHistory() {
        for device in registry.devices.values {
            let all = registry.publications.values.filter { $0.deviceID == device.id }.sorted { $0.createdAt > $1.createdAt }
            for old in all.dropFirst(20) where old.id != device.currentImage { registry.publications.removeValue(forKey: old.id) }
        }
    }

    private func cleanupImages() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files where ["bmp", "png"].contains(file.pathExtension) && registry.publications[file.deletingPathExtension().lastPathComponent] == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }

    public func firmware(_ request: Request) -> Response {
        let before = registry
        do {
            if request.method == "GET", request.path == "/" {
                return Response(200, Data("AI TRMNL device server. On the Mac running this app, choose Help from its menu bar icon to get started.\n".utf8), type: "text/plain; charset=utf-8")
            }
            if request.method == "GET", request.path == "/api/setup" { return .json(try setup(request)) }
            if request.method == "GET", request.path.hasPrefix("/screens/") { return try imageResponse(request) }
            guard (request.method == "GET" && request.path == "/api/display") || (request.method == "POST" && request.path == "/api/log") else {
                throw Problem(404, "not_found", "Unknown firmware route.")
            }
            var device = try authenticated(request)
            device.lastSeen = now().timeIntervalSince1970
            if let version = header("fw-version", request), version.count <= 64 { device.firmware = version }
            if request.path == "/api/log" {
                guard request.body.count <= HTTPParser.maxBody,
                      let value = try? JSONSerialization.jsonObject(with: request.body),
                      let logs = (value as? [String: Any])?["logs"] as? [[String: Any]], logs.count <= 50 else {
                    throw Problem(400, "invalid_logs", "Expected at most 50 log entries.")
                }
                // Firmware diagnostics can include credential-bearing URLs. Redact before persisting.
                device.lastLog = (logs.last?["message"] as? String).map { message in
                    var redacted = message
                    for purpose in ["api", "image"] {
                        redacted = redacted.replacingOccurrences(of: token(device, purpose: purpose), with: "[redacted]")
                    }
                    redacted = redacted.replacingOccurrences(of: "(?i)([?&]token=)[^\\s&#]+", with: "$1[redacted]", options: .regularExpression)
                    return String(redacted.prefix(500))
                }
                registry.devices[device.id] = device; try store.save(registry)
                return Response(204)
            }
            try validateDimensions(request)
            registry.devices[device.id] = device; try store.save(registry)
            return .json(display(device))
        } catch let error as Problem {
            recordRejectedDeviceRequest(error.description)
            registry = before; cleanupImages(); return .problem(error)
        }
        catch {
            recordRejectedDeviceRequest("Device operation failed.")
            registry = before; cleanupImages(); return .problem(Problem(500, "server_error", "Device operation failed."))
        }
    }

    private func header(_ name: String, _ request: Request) -> String? {
        request.headers[name] ?? request.headers[name.replacingOccurrences(of: "-", with: "_")]
    }

    private func macAddress(_ request: Request) throws -> String {
        let raw = (request.headers["id"] ?? "").uppercased()
        guard raw.range(of: "^[0-9A-F]{2}(:[0-9A-F]{2}){5}$", options: .regularExpression) != nil else {
            throw Problem(400, "invalid_device_id", "Expected an ID header containing the device MAC address.")
        }
        return raw
    }

    private func validateDimensions(_ request: Request) throws {
        for (key, expected) in [("width", 800), ("height", 480)] {
            if let raw = request.headers[key], Int(raw) != expected {
                throw Problem(400, "unsupported_display", "Expected \(key) \(expected); device reported \(Int(raw).map(String.init) ?? "a noninteger value"). This prototype renders only 800×480 OG displays.")
            }
        }
    }

    private func authenticated(_ request: Request) throws -> Device {
        let mac = try macAddress(request)
        guard let device = registry.devices.values.first(where: { $0.mac == mac }), device.state != "disconnected",
              constantTimeEqual(header("access-token", request) ?? "", token(device, purpose: "api")) else {
            throw Problem(401, "invalid_device_token", "Device credentials are invalid or revoked.")
        }
        return device
    }

    private func setup(_ request: Request) throws -> [String: Any] {
        guard pairingOpen else { throw Problem(403, "pairing_closed", "Ask Codex to start pairing from the local Help page.") }
        let mac = try macAddress(request)
        try validateDimensions(request)
        var device = registry.devices.values.first(where: { $0.mac == mac })
        if device == nil || device?.state == "disconnected" {
            guard registry.devices.values.filter({ $0.state == "pending" }).count < 20 else { throw Problem(429, "pending_limit", "Resolve pending registrations before adding another device.") }
            let id = device?.id ?? UUID().uuidString.lowercased()
            device = Device(id: id, mac: mac, name: "Ready to pair", code: String(id.prefix(8)).uppercased(), nonce: randomToken(),
                            state: "pending", revision: (device?.revision ?? -1) + 1,
                            firmware: String((header("fw-version", request) ?? "unknown").prefix(64)),
                            model: String((request.headers["model"] ?? "OG (unreported)").prefix(64)), currentImage: "")
            let publication = try makeImage(device: device!, title: "READY TO PAIR", message: "Tell Codex the device code shown above.")
            registry.publications[publication.id] = publication
            device!.currentImage = publication.id
        }
        device!.lastSeen = now().timeIntervalSince1970
        registry.devices[device!.id] = device!
        try store.save(registry)
        return ["status": 200, "api_key": token(device!, purpose: "api"), "friendly_id": device!.code,
                "image_url": imageURL(device!), "filename": device!.currentImage + ".bmp", "message": "Tell Codex the device code \(device!.code)."]
    }

    private func imageURL(_ device: Device) -> String {
        configuration.deviceURL + "/screens/\(device.currentImage).bmp?token=" + token(device, purpose: "image")
    }
    private func display(_ device: Device) -> [String: Any] {
        ["status": 0, "image_url": imageURL(device), "filename": device.currentImage + ".bmp",
         "refresh_rate": configuration.refreshSeconds, "update_firmware": false, "reset_firmware": false,
         "firmware_url": "", "special_function": "none"]
    }

    private func imageResponse(_ request: Request) throws -> Response {
        let id = String(request.path.dropFirst("/screens/".count).dropLast(4))
        guard request.path.hasSuffix(".bmp"), let publication = registry.publications[id],
              var device = registry.devices[publication.deviceID], device.state != "disconnected",
              constantTimeEqual(request.query["token"] ?? "", token(device, purpose: "image")) else {
            throw Problem(404, "image_not_found", "Image unavailable.")
        }
        let data = try Data(contentsOf: imageDirectory.appendingPathComponent(id + ".bmp"))
        device.lastImageServed = id; device.lastImageServedAt = now().timeIntervalSince1970
        registry.devices[device.id] = device; try store.save(registry)
        return Response(200, data, type: "image/bmp")
    }
}
