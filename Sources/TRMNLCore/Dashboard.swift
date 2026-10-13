import Foundation

struct DashboardProfile: Codable {
    var template: String
    var location: String
    var weather_url: String
    var timezone: String
    var units: String
    var calendar_scope: String
    var lookahead_days: Int
    var instructions: String

    func validate() throws {
        guard template == "weather-agenda-v1", units == "imperial", calendar_scope == "all",
              TimeZone(identifier: timezone) != nil, (1...14).contains(lookahead_days),
              let url = URL(string: weather_url), url.scheme == "https", url.host != nil,
              clean(location, limit: 30), clean(weather_url, limit: 500), clean(instructions, limit: 3000) else {
            throw Problem(400, "invalid_profile", "Use weather-agenda-v1, imperial units, all calendars, a valid timezone/HTTPS source, and 1–14 lookahead days.")
        }
    }
    static var schema: [String: Any] { objectSchema([
        "template": ["type": "string", "enum": ["weather-agenda-v1"]], "location": stringSchema,
        "weather_url": stringSchema, "timezone": stringSchema,
        "units": ["type": "string", "enum": ["imperial"]],
        "calendar_scope": ["type": "string", "enum": ["all"]],
        "lookahead_days": ["type": "integer", "minimum": 1, "maximum": 14], "instructions": stringSchema
    ]) }
}

struct SavedDashboard: Codable {
    var revision: Int
    var profile: DashboardProfile
}

struct WeatherSnapshot: Codable {
    var observed_at: String
    var forecast_date: String
    var condition: String
    var icon: String
    var temperature: Double?
    var high: Double?
    var low: Double?
    var wind_speed: Double?
    var wind_direction: String
    var precipitation_chance: Double?
    var precipitation_period: String
    var uv_current: Double?
    var note: String
    var source_urls: [String]

    static var schema: [String: Any] { objectSchema([
        "observed_at": stringSchema, "forecast_date": stringSchema, "condition": stringSchema,
        "icon": ["type": "string", "enum": ["sun", "cloud", "partly-cloudy", "rain", "snow", "storm", "fog", "unknown"]],
        "temperature": nullableNumber, "high": nullableNumber, "low": nullableNumber,
        "wind_speed": nullableNumber, "wind_direction": stringSchema,
        "precipitation_chance": nullableNumber, "precipitation_period": stringSchema,
        "uv_current": nullableNumber, "note": stringSchema,
        "source_urls": ["type": "array", "items": stringSchema, "maxItems": 8]
    ]) }
}

struct AgendaEvent: Codable {
    var id: String
    var calendar: String
    var title: String
    var start: String
    var end: String
    var all_day: Bool
    var location: String
    static var schema: [String: Any] { objectSchema([
        "id": stringSchema, "calendar": stringSchema, "title": stringSchema,
        "start": stringSchema, "end": stringSchema, "all_day": ["type": "boolean"], "location": stringSchema
    ]) }
}

struct AgendaSnapshot: Codable {
    var fetched_at: String
    var calendars: [String]
    var failed_calendars: [String]
    var events: [AgendaEvent]
    static var schema: [String: Any] { objectSchema([
        "fetched_at": stringSchema, "calendars": ["type": "array", "items": stringSchema, "maxItems": 100],
        "failed_calendars": ["type": "array", "items": stringSchema, "maxItems": 100],
        "events": ["type": "array", "items": AgendaEvent.schema, "maxItems": 200]
    ]) }
}

struct DashboardSnapshot: Codable {
    var weather: WeatherSnapshot
    var agenda: AgendaSnapshot
    static var schema: [String: Any] { objectSchema(["weather": WeatherSnapshot.schema, "agenda": AgendaSnapshot.schema]) }

    func validate(profile: DashboardProfile, now: Date) throws {
        let w = weather, a = agenda
        guard let observed = timestamp(w.observed_at), let fetched = timestamp(a.fetched_at),
              observed <= now.addingTimeInterval(300), fetched <= now.addingTimeInterval(300),
              validDay(w.forecast_date), clean(w.condition, limit: 45), clean(w.note, limit: 100, empty: true),
              ["sun", "cloud", "partly-cloudy", "rain", "snow", "storm", "fog", "unknown"].contains(w.icon),
              clean(w.wind_direction, limit: 8, empty: true), clean(w.precipitation_period, limit: 20),
              w.source_urls.count > 0, w.source_urls.count <= 8,
              w.source_urls.allSatisfy({ clean($0, limit: 500) && URL(string: $0)?.scheme == "https" }),
              a.calendars.count > 0, a.calendars.count <= 100, a.failed_calendars.count <= 100,
              Set(a.calendars).count == a.calendars.count,
              a.calendars.allSatisfy({ clean($0, limit: 50) }),
              a.failed_calendars.allSatisfy({ a.calendars.contains($0) }), a.events.count <= 200 else {
            throw Problem(400, "invalid_snapshot", "Provide bounded source data, ISO timestamps, forecast date, and the complete calendar coverage. Use null for unavailable measurements.")
        }
        for value in [w.temperature, w.high, w.low].compactMap({ $0 }) where !(-150...150).contains(value) {
            throw Problem(400, "invalid_weather", "Temperature outside supported Fahrenheit range.")
        }
        for (value, maximum) in [(w.wind_speed, 300.0), (w.precipitation_chance, 100), (w.uv_current, 30)] {
            if let value, !(0...maximum).contains(value) { throw Problem(400, "invalid_weather", "Weather measurement outside supported range.") }
        }
        var ids = Set<String>()
        for event in a.events {
            guard clean(event.id, limit: 250), clean(event.title, limit: 200), clean(event.location, limit: 200, empty: true),
                  a.calendars.contains(event.calendar), !a.failed_calendars.contains(event.calendar),
                  ids.insert(event.calendar + ":" + event.id).inserted else { throw Problem(400, "invalid_event", "Invalid or duplicate calendar event.") }
            if event.all_day {
                guard validDay(event.start), validDay(event.end), event.start < event.end else {
                    throw Problem(400, "invalid_event", "All-day events need YYYY-MM-DD start and exclusive end dates.")
                }
            } else {
                guard let start = timestamp(event.start), let end = timestamp(event.end), start < end else {
                    throw Problem(400, "invalid_event", "Timed events need ISO timestamps with offsets and end after start.")
                }
            }
        }
    }
}

private let stringSchema: [String: Any] = ["type": "string"]
private let nullableNumber: [String: Any] = ["type": ["number", "null"]]
func objectSchema(_ properties: [String: [String: Any]]) -> [String: Any] {
    ["type": "object", "properties": properties,
     "required": properties.keys.filter { !(properties[$0]!["type"] as? [String] ?? []).contains("null") }.sorted(),
     "additionalProperties": false]
}
func clean(_ value: String, limit: Int, empty: Bool = false) -> Bool {
    (empty || !value.trimmingCharacters(in: .whitespaces).isEmpty) && value.count <= limit &&
    !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}
func timestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: value)
}
func validDay(_ value: String) -> Bool {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
    return value.count == 10 && formatter.date(from: value).map { formatter.string(from: $0) == value } == true
}
func decoded<T: Decodable>(_ type: T.Type, _ input: Any) throws -> T {
    do { return try JSONDecoder().decode(type, from: jsonData(input)) }
    catch { throw Problem(400, "invalid_document", "The document does not match the published tool schema.") }
}
func encoded<T: Encodable>(_ value: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
}
