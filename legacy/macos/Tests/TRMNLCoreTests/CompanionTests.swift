import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TRMNLCore

private let companionNow = timestamp("2026-10-14T17:00:00Z")!
private func companionProfile() -> DashboardProfile {
    DashboardProfile(template: "daily-companion-v1", location: "Example City", weather_url: "https://example.com/weather",
        timezone: "America/Chicago", units: "imperial", calendar_scope: "all", lookahead_days: 7, instructions: "Full height agenda; daily character.")
}
private func sceneInput(width: Int = 176, height: Int = 220) throws -> SceneInput {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    for n in 0..<4 {
        context.setFillColor(gray: CGFloat(n) / 3, alpha: 1)
        context.fill(CGRect(x: n * width / 4, y: 0, width: width / 4, height: height))
    }
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
    return SceneInput(date: "2026-10-14", character: "Cat", identity: "Black left-eye patch", condition: "cloud", phase: "afternoon", prompt: "Cloudy bathroom cat.", png_base64: (data as Data).base64EncodedString())
}
private func companionSnapshot() -> DashboardSnapshot {
    DashboardSnapshot(weather: WeatherSnapshot(observed_at: "2026-10-14T16:55:00Z", forecast_date: "2026-10-14", condition: "Cloudy", icon: "cloud", temperature: 51, high: 57, low: 47, wind_speed: 0, wind_direction: "N", precipitation_chance: 1, precipitation_period: "Today", uv_current: nil, note: "", source_urls: ["https://example.com/weather"]), agenda: AgendaSnapshot(fetched_at: "2026-10-14T16:58:00Z", calendars: ["Personal"], failed_calendars: [], events: []))
}

final class CompanionTests: XCTestCase {
    func testDetailsAreOptionalBoundedAndWrapWithoutRowCollisions() throws {
        var profile = companionProfile(); profile.template = "daily-companion-v2"
        var event = AgendaEvent(id: "one", calendar: "Personal", title: "A somewhat longer title that needs two lines to stay readable", start: "2026-10-14T19:00:00-05:00", end: "2026-10-14T20:00:00-05:00", all_day: false, location: "")
        let oldJSON = try encoded(event)
        XCTAssertNil(try decoded(AgendaEvent.self, oldJSON).details)
        event.details = "Arrive five minutes early. Bring the materials listed in your invitation."
        var snapshot = companionSnapshot(); snapshot.agenda.events = [event]
        XCTAssertNoThrow(try snapshot.validate(profile: profile, now: companionNow))
        snapshot.agenda.events[0].details = String(repeating: "x", count: 241)
        XCTAssertThrowsError(try snapshot.validate(profile: profile, now: companionNow))
        snapshot.agenda.events = (0..<20).map { i in
            var e = event; e.id = String(i)
            if i >= 3 { e.start = "2026-10-15T11:30:00-05:00"; e.end = "2026-10-16T01:00:00-05:00" }
            return e
        }
        let rows = DashboardRenderer.rows(profile: profile, snapshot: snapshot, now: companionNow)
        let entries = IntegratedRenderer.layout(rows, profile: profile)
        XCTAssertGreaterThan(entries.count, 1); XCTAssertLessThan(entries.count, rows.count)
        XCTAssertEqual(entries.first?.title.lines.count, 2)
        XCTAssertEqual(entries.first?.details.lines.count, 2)
        for (index, entry) in entries.enumerated() {
            XCTAssertLessThanOrEqual(entry.y + entry.height, 431)
            XCTAssertGreaterThanOrEqual(entry.height, CGFloat(entry.time.lines.count * 18 + 3))
            XCTAssertEqual(entry.dayHeadingY != nil, index == 0 || entries[index - 1].row.day != entry.row.day)
            if index > 0 { XCTAssertGreaterThanOrEqual(entry.dayHeadingY ?? entry.y, entries[index - 1].y + entries[index - 1].height) }
            for line in entry.title.lines { XCTAssertLessThanOrEqual(Ink.textWidth(line, size: 20, bold: true), 362) }
            for line in entry.details.lines { XCTAssertLessThanOrEqual(Ink.textWidth(line, size: 14, bold: false), 362) }
        }
        let longWord = Ink.wrap(String(repeating: "🐱W", count: 100), size: 20, width: 362, bold: true)
        XCTAssertEqual(longWord.lines.count, 2); XCTAssertTrue(longWord.truncated)
        for line in longWord.lines { XCTAssertLessThanOrEqual(Ink.textWidth(line, size: 20, bold: true), 362) }
    }

    func testSceneDimensionsFollowTemplateAndRequireNewBackgroundAfterSwitch() throws {
        var profile = companionProfile(); profile.template = "daily-companion-v2"
        let old = try sceneInput(), full = try sceneInput(width: 800, height: 480)
        XCTAssertThrowsError(try old.validate(profile: profile, previous: nil, now: companionNow))
        XCTAssertNoThrow(try full.validate(profile: profile, previous: nil, now: companionNow))
        XCTAssertThrowsError(try full.validate(profile: companionProfile(), previous: nil, now: companionNow))
        let scene = DailyScene(id: "id", referenceID: "id", date: old.date, character: old.character, identity: old.identity, condition: old.condition, phase: old.phase, prompt: old.prompt)
        XCTAssertThrowsError(try IntegratedRenderer.render(profile: profile, snapshot: companionSnapshot(), scene: scene, art: Data(base64Encoded: old.png_base64)!, now: companionNow))
        XCTAssertThrowsError(try CompanionRenderer.render(profile: companionProfile(), snapshot: companionSnapshot(), scene: scene, art: Data(base64Encoded: full.png_base64)!, now: companionNow))
        let screen = try IntegratedRenderer.render(profile: profile, snapshot: companionSnapshot(), scene: scene, art: Data(base64Encoded: full.png_base64)!, now: companionNow)
        XCTAssertEqual(screen.png[24], 2); XCTAssertEqual(screen.png[25], 0)
        XCTAssertLessThan(screen.png.count, 90000)
    }

    func testOriginalTimeRangesAndCrossMidnight() {
        func range(_ start: String, _ end: String, allDay: Bool = false) -> String {
            let event = AgendaEvent(id: "event", calendar: "Personal", title: "Event", start: start, end: end, all_day: allDay, location: "")
            return CompanionRenderer.timeRange(AgendaRow(day: companionNow, event: event, start: timestamp(start)!, end: timestamp(end)!), profile: companionProfile())
        }
        XCTAssertEqual(range("2026-10-14T19:00:00-05:00", "2026-10-14T20:00:00-05:00"), "7p-8p")
        XCTAssertEqual(range("2026-10-14T11:30:00-05:00", "2026-10-14T12:45:00-05:00"), "11:30a-12:45p")
        XCTAssertEqual(range("2026-10-14T23:00:00-05:00", "2026-10-15T01:00:00-05:00"), "11p-1a +1d")
        XCTAssertEqual(range("2026-10-14T00:00:00Z", "2026-10-15T00:00:00Z", allDay: true), "All day")
    }

    func testSceneValidationAndPhaseBoundaries() throws {
        var input = try sceneInput(), profile = companionProfile()
        XCTAssertNoThrow(try input.validate(profile: profile, previous: nil, now: companionNow))
        input.png_base64 = Data("not a PNG".utf8).base64EncodedString()
        XCTAssertThrowsError(try input.validate(profile: profile, previous: nil, now: companionNow))
        input = try sceneInput(); input.phase = "morning"
        XCTAssertThrowsError(try input.validate(profile: profile, previous: nil, now: companionNow))
        XCTAssertEqual(CompanionRenderer.phase(companionNow.addingTimeInterval(-1), profile: profile), "morning")
        profile.timezone = "Pacific/Auckland"
        XCTAssertEqual(CompanionRenderer.day(companionNow, profile: profile), "2026-10-15")
    }

    func testFourGrayPNGDecodesWithExactTonesAndOrientation() throws {
        let input = try sceneInput()
        let scene = DailyScene(id: "id", referenceID: "id", date: input.date, character: input.character, identity: input.identity, condition: input.condition, phase: input.phase, prompt: input.prompt)
        let output = try CompanionRenderer.render(profile: companionProfile(), snapshot: companionSnapshot(), scene: scene, art: Data(base64Encoded: input.png_base64)!, now: companionNow)
        XCTAssertEqual(output.png[24], 2); XCTAssertEqual(output.png[25], 0)
        XCTAssertLessThan(output.png.count, 90000)
        let source = CGImageSourceCreateWithData(output.png as CFData, nil)!, image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(image.width, 800); XCTAssertEqual(image.height, 480)
        let pixels = image.dataProvider!.data! as Data
        XCTAssertGreaterThan(pixels.count, 0)
        // Decode into 8-bit gray to assert all four tones survive the PNG codec.
        var decoded = [UInt8](repeating: 0, count: 800 * 480)
        decoded.withUnsafeMutableBytes { bytes in
            let c = CGContext(data: bytes.baseAddress, width: 800, height: 480, bitsPerComponent: 8, bytesPerRow: 800, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: 800, height: 480))
        }
        XCTAssertEqual(Set(decoded), Set([0, 85, 170, 255]))
        for n in 0..<4 { XCTAssertEqual(decoded[300 * 800 + 20 + n * 44], UInt8(n * 85)) }
        var stale = scene; stale.condition = "rain"
        XCTAssertThrowsError(try CompanionRenderer.render(profile: companionProfile(), snapshot: companionSnapshot(), scene: stale, art: Data(base64Encoded: input.png_base64)!, now: companionNow))
    }
}

extension ServiceTests {
    func testDailyScenePinsIdentitySurvivesRestartAndPublishesPNG() throws {
        try restart(now: { companionNow }); try start(); let enrollment = try setup(); let active = try confirm()
        let id = active["device_id"] as! String
        XCTAssertEqual(try call("save_dashboard", ["device_id": id, "profile": try encoded(companionProfile()), "expected_revision": 1, "request_id": UUID().uuidString]).status, 200)
        let scene = try sceneInput()
        let args: [String: Any] = ["device_id": id, "scene": try encoded(scene), "expected_revision": 2, "request_id": UUID().uuidString]
        let saved = try call("save_daily_scene", args)
        XCTAssertEqual(saved.status, 200); XCTAssertEqual(try call("save_daily_scene", args).body, saved.body)
        let first = try body(call("get_device_profile", ["device_id": id]))["daily_scene"] as! [String: Any]
        var changed = scene; changed.identity = "Different cat"
        XCTAssertEqual(try call("save_daily_scene", ["device_id": id, "scene": try encoded(changed), "expected_revision": 3, "request_id": UUID().uuidString]).status, 409)
        let staged = try body(call("render_dashboard", ["device_id": id, "snapshot": try encoded(companionSnapshot()), "expected_revision": 3, "request_id": UUID().uuidString]))["rendered"] as! [String: Any]
        XCTAssertEqual(try call("save_daily_scene", ["device_id": id, "scene": try encoded(scene), "expected_revision": 4, "request_id": UUID().uuidString]).status, 200)
        XCTAssertEqual(try call("publish_screen", ["device_id": id, "image_id": staged["image_id"]!, "expected_revision": 5, "request_id": UUID().uuidString]).status, 409)
        try restart(now: { companionNow })
        let restored = try body(call("get_device_profile", ["device_id": id]))["daily_scene"] as! [String: Any]
        XCTAssertEqual(first["referenceID"] as? String, restored["referenceID"] as? String)
        XCTAssertNotEqual(first["id"] as? String, restored["id"] as? String)
        let rendered = try body(call("render_dashboard", ["device_id": id, "snapshot": try encoded(companionSnapshot()), "expected_revision": 5, "request_id": UUID().uuidString]))["rendered"] as! [String: Any]
        XCTAssertEqual(try call("publish_screen", ["device_id": id, "image_id": rendered["image_id"]!, "expected_revision": 6, "request_id": UUID().uuidString]).status, 200)
        let display = try body(display(key: enrollment["api_key"] as! String)), response = image(display["image_url"] as! String)
        XCTAssertTrue((display["filename"] as! String).hasSuffix(".png"))
        XCTAssertEqual(response.status, 200); XCTAssertEqual(response.headers["Content-Type"], "image/png")
        XCTAssertEqual(digest(response.body), rendered["sha256"] as? String)
        // Upgrading the same device retains today's original character reference.
        var integrated = companionProfile(); integrated.template = "daily-companion-v2"
        XCTAssertEqual(try call("save_dashboard", ["device_id": id, "profile": try encoded(integrated), "expected_revision": 7, "request_id": UUID().uuidString]).status, 200)
        XCTAssertEqual(try call("render_dashboard", ["device_id": id, "snapshot": try encoded(companionSnapshot()), "expected_revision": 8, "request_id": UUID().uuidString]).status, 409)
        let background = try sceneInput(width: 800, height: 480)
        XCTAssertEqual(try call("save_daily_scene", ["device_id": id, "scene": try encoded(background), "expected_revision": 8, "request_id": UUID().uuidString]).status, 200)
        var snapshot = companionSnapshot()
        snapshot.agenda.events = [AgendaEvent(id: "detail-event", calendar: "Personal", title: "Workshop", start: "2026-10-14T19:00:00-05:00", end: "2026-10-14T20:00:00-05:00", all_day: false, location: "", details: "Bring your project.")]
        let detailed = try body(call("render_dashboard", ["device_id": id, "snapshot": try encoded(snapshot), "expected_revision": 9, "request_id": UUID().uuidString]))["rendered"] as! [String: Any]
        XCTAssertEqual(try call("publish_screen", ["device_id": id, "image_id": detailed["image_id"]!, "expected_revision": 10, "request_id": UUID().uuidString]).status, 200)
        try restart(now: { companionNow })
        let upgraded = try body(call("get_device_profile", ["device_id": id]))
        XCTAssertEqual((upgraded["daily_scene"] as? [String: Any])?["referenceID"] as? String, first["referenceID"] as? String)
        let savedSnapshot = try decoded(DashboardSnapshot.self, upgraded["last_snapshot"]!)
        XCTAssertEqual(savedSnapshot.agenda.events.first?.details, "Bring your project.")
        let finalDisplay = try body(self.display(key: enrollment["api_key"] as! String))
        XCTAssertEqual(digest(image(finalDisplay["image_url"] as! String).body), detailed["sha256"] as? String)
    }
}
