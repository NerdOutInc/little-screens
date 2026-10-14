import XCTest
@testable import TRMNLCore

private let fixedNow = timestamp("2026-10-13T23:00:00Z")!
private func profile() -> DashboardProfile {
    DashboardProfile(template: "weather-agenda-v1", location: "Example City", weather_url: "https://example.com/weather",
                     timezone: "America/Chicago", units: "imperial", calendar_scope: "all", lookahead_days: 7,
                     instructions: "Weather left. All calendars right. Current UV only.")
}
private func snapshot() -> DashboardSnapshot {
    DashboardSnapshot(weather: WeatherSnapshot(observed_at: "2026-10-13T22:55:00Z", forecast_date: "2026-10-13", condition: "Cloudy", icon: "cloud",
        temperature: 56, high: 60, low: 45, wind_speed: 8, wind_direction: "N", precipitation_chance: 70, precipitation_period: "Tonight", uv_current: 0,
        note: "Rain possible later.", source_urls: ["https://example.com/weather"]),
        agenda: AgendaSnapshot(fetched_at: "2026-10-13T22:58:00Z", calendars: ["Personal", "Shared"], failed_calendars: [], events: []))
}

extension ServiceTests {
    func testDashboardStagePublishPersistAndProtectProfileRevision() throws {
        try restart(now: { fixedNow }); try start(); _ = try setup(); let active = try confirm()
        let id = active["device_id"] as! String
        let oldImage = (active["publication"] as! [String: Any])["image_id"] as! String
        let saved = try body(call("save_dashboard", ["device_id": id, "profile": try encoded(profile()), "expected_revision": 1, "request_id": UUID().uuidString]))
        XCTAssertEqual(saved["revision"] as? Int, 2)
        let arguments: [String: Any] = ["device_id": id, "snapshot": try encoded(snapshot()), "expected_revision": 2, "request_id": UUID().uuidString]
        let staged = try body(call("render_dashboard", arguments))
        let rendered = staged["rendered"] as! [String: Any]
        let imageID = rendered["image_id"] as! String
        XCTAssertEqual((staged["publication"] as! [String: Any])["image_id"] as? String, oldImage)
        XCTAssertEqual(try call("render_dashboard", arguments).body, try jsonData(staged))
        try restart(now: { fixedNow })
        let restored = try body(call("get_device_profile", ["device_id": id]))
        XCTAssertEqual(((restored["dashboard"] as! [String: Any])["profile"] as! [String: Any])["timezone"] as? String, "America/Chicago")
        XCTAssertEqual(try call("publish_screen", ["device_id": id, "image_id": imageID, "expected_revision": 3, "request_id": UUID().uuidString]).status, 200)
        XCTAssertEqual((try device()["publication"] as! [String: Any])["image_id"] as? String, imageID)
        XCTAssertEqual(try call("save_dashboard", ["device_id": id, "profile": try encoded(profile()), "expected_revision": 4, "request_id": UUID().uuidString]).status, 200)
        XCTAssertEqual(try call("publish_screen", ["device_id": id, "image_id": imageID, "expected_revision": 5, "request_id": UUID().uuidString]).status, 409)
    }

    func testDashboardRejectsWrongDeviceAndExpiredRender() throws {
        var time = fixedNow
        try restart(now: { time }); try start(); _ = try setup(); let first = try confirm()
        let id = first["device_id"] as! String
        XCTAssertEqual(try call("save_dashboard", ["device_id": id, "profile": try encoded(profile()), "expected_revision": 1, "request_id": UUID().uuidString]).status, 200)
        let rendered = try body(call("render_dashboard", ["device_id": id, "snapshot": try encoded(snapshot()), "expected_revision": 2, "request_id": UUID().uuidString]))["rendered"] as! [String: Any]
        try start(); _ = try setup("AA:BB:CC:DD:EE:02"); let other = try confirm("AA:BB:CC:DD:EE:02")
        let otherID = other["device_id"] as! String
        XCTAssertEqual(try call("save_dashboard", ["device_id": otherID, "profile": try encoded(profile()), "expected_revision": 1, "request_id": UUID().uuidString]).status, 200)
        XCTAssertEqual(try call("publish_screen", ["device_id": otherID, "image_id": rendered["image_id"]!, "expected_revision": 2, "request_id": UUID().uuidString]).status, 409)
        time = time.addingTimeInterval(1801)
        XCTAssertEqual(try call("publish_screen", ["device_id": id, "image_id": rendered["image_id"]!, "expected_revision": 3, "request_id": UUID().uuidString]).status, 409)
    }
}

final class DashboardTests: XCTestCase {
    func testAgendaDateBoundariesAndAllDayExclusiveEnd() throws {
        var data = snapshot()
        data.agenda.events = [
            AgendaEvent(id: "ended", calendar: "Personal", title: "Ended", start: "2026-10-13T10:00:00-05:00", end: "2026-10-13T11:00:00-05:00", all_day: false, location: ""),
            AgendaEvent(id: "ongoing", calendar: "Shared", title: "Ongoing", start: "2026-10-13T17:00:00-05:00", end: "2026-10-13T19:00:00-05:00", all_day: false, location: ""),
            AgendaEvent(id: "day", calendar: "Personal", title: "Two-day event", start: "2026-10-13", end: "2026-10-15", all_day: true, location: ""),
            AgendaEvent(id: "utc", calendar: "Shared", title: "Local evening", start: "2026-10-14T00:00:00Z", end: "2026-10-14T01:00:00Z", all_day: false, location: "")
        ]
        try data.validate(profile: profile(), now: fixedNow)
        let rows = DashboardRenderer.rows(profile: profile(), snapshot: data, now: fixedNow)
        XCTAssertEqual(rows.map { $0.event.id }, ["day", "ongoing", "utc", "day"])
        XCTAssertEqual(Set(rows.map(\.day)).count, 2)
        let duplicate = data.agenda.events[0]; data.agenda.events.append(duplicate)
        XCTAssertThrowsError(try data.validate(profile: profile(), now: fixedNow))
    }

    func testDenseAgendaReportsOverflowAndTruncation() throws {
        var data = snapshot()
        data.agenda.events = (0..<40).map {
            AgendaEvent(id: String($0), calendar: "Personal", title: "A long event title with enough detail to require deliberate truncation \($0)",
                        start: "2026-10-14T09:00:00-05:00", end: "2026-10-14T10:00:00-05:00", all_day: false, location: "Example Hall")
        }
        let rendered = try DashboardRenderer.render(profile: profile(), snapshot: data, now: fixedNow)
        XCTAssertEqual(rendered.bmp.count, 48062)
        XCTAssertGreaterThan(rendered.shown, 10)
        XCTAssertEqual(rendered.shown + rendered.omitted, 40)
        XCTAssertEqual(rendered.truncated, rendered.shown)
    }

    func testBadDatesWeatherAndPartialCalendarCoverage() throws {
        var data = snapshot()
        data.weather.uv_current = nil
        data.agenda.failed_calendars = ["Shared"]
        XCTAssertNoThrow(try data.validate(profile: profile(), now: fixedNow))
        data.weather.precipitation_chance = 101
        XCTAssertThrowsError(try data.validate(profile: profile(), now: fixedNow))
        data.weather.precipitation_chance = nil
        data.weather.forecast_date = "2026-02-30"
        XCTAssertThrowsError(try data.validate(profile: profile(), now: fixedNow))
        data.weather.forecast_date = "2026-10-13"
        data.agenda.fetched_at = "2026-10-14T00:00:00Z"
        XCTAssertThrowsError(try data.validate(profile: profile(), now: fixedNow))
    }
}
