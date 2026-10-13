import Foundation
import CoreGraphics

struct AgendaRow {
    var day: Date
    var event: AgendaEvent
    var start: Date
    var end: Date
}

struct DashboardRender {
    var bmp: Data
    var png: Data
    var shown: Int
    var omitted: Int
    var truncated: Int
}

enum DashboardRenderer {
    static let definition: [String: Any] = [
        "id": "weather-agenda-v1", "width": 800, "height": 480,
        "weather_column_width": 314, "agenda_title_font_px": 18,
        "agenda_row_height_px": 29, "agenda_order": "day, all-day first, start time, title, calendar",
        "calendar_policy": "all calendars, ongoing and upcoming events, exclusive all-day end dates, chronological overflow count",
        "weather_policy": "Fahrenheit and mph; high today, low tonight; explicit precipitation period; unavailable numeric values shown as dash",
        "freshness_policy": "weather older than 90 minutes and agenda older than 120 minutes marked STALE; timestamps always shown"
    ]
    static func calendar(_ profile: DashboardProfile) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = TimeZone(identifier: profile.timezone)!
        return result
    }
    static func rows(profile: DashboardProfile, snapshot: DashboardSnapshot, now: Date) -> [AgendaRow] {
        let cal = calendar(profile), today = cal.startOfDay(for: now)
        let dates = DateFormatter(); dates.locale = Locale(identifier: "en_US_POSIX"); dates.timeZone = cal.timeZone; dates.dateFormat = "yyyy-MM-dd"
        var result: [AgendaRow] = []
        for offset in 0...profile.lookahead_days {
            let day = cal.date(byAdding: .day, value: offset, to: today)!
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            for event in snapshot.agenda.events {
                let start = event.all_day ? dates.date(from: event.start)! : timestamp(event.start)!
                let end = event.all_day ? dates.date(from: event.end)! : timestamp(event.end)!
                if start < next && end > max(day, now) {
                    result.append(AgendaRow(day: day, event: event, start: start, end: end))
                }
            }
        }
        return result.sorted {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.event.all_day != $1.event.all_day { return $0.event.all_day }
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.event.title != $1.event.title { return $0.event.title < $1.event.title }
            return $0.event.calendar < $1.event.calendar
        }
    }
    static func render(profile: DashboardProfile, snapshot: DashboardSnapshot, now: Date) throws -> DashboardRender {
        try snapshot.validate(profile: profile, now: now)
        let rows = rows(profile: profile, snapshot: snapshot, now: now), cal = calendar(profile)
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = cal.timeZone
        func date(_ value: Date, _ pattern: String) -> String { format.dateFormat = pattern; return format.string(from: value) }
        func number(_ value: Double?) -> String { value.map { $0.rounded() == $0 ? String(Int($0)) : String(format: "%.1f", $0) } ?? "—" }
        let names = snapshot.agenda.calendars
        let codes = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, String($0.offset + 1)) })
        var shown = 0, truncated = 0
        let image = try BitmapCanvas.render { context in
            let ink = Ink(context: context), w = snapshot.weather
            ink.text(profile.location.uppercased(), 16, 14, 18, width: 280, bold: true)
            ink.text(date(now, "EEEE, MMM d").uppercased(), 16, 39, 12, width: 280)
            ink.line(314, 16, 314, 445, width: 2)
            ink.text(number(w.temperature) + "°", 13, 58, 91, width: 198, bold: true)
            ink.text("F", 18, 151, 13, width: 30)
            icon(w.icon, ink: ink, x: 213, y: 93)
            ink.text(w.condition, 16, 174, 23, width: 284, bold: true)
            ink.text("HIGH TODAY / LOW TONIGHT", 16, 211, 11, width: 282, bold: true)
            ink.text(number(w.high) + "°  /  " + number(w.low) + "°", 16, 227, 24, width: 282)
            ink.text("WIND", 16, 267, 11, width: 60, bold: true)
            ink.text((w.wind_direction.isEmpty ? "" : w.wind_direction + " ") + number(w.wind_speed) + " mph", 74, 260, 24, width: 218, bold: true)
            let wind = w.wind_speed.map { $0 < 1 ? "Calm" : $0 < 12 ? "Light breeze" : $0 < 20 ? "Breezy" : "Windy" } ?? "Wind unavailable"
            ink.text(wind, 74, 289, 13, width: 212)
            ink.line(16, 312, 297, 312)
            ink.text("PRECIP · " + w.precipitation_period.uppercased(), 16, 325, 10, width: 149, bold: true)
            ink.text(number(w.precipitation_chance) + (w.precipitation_chance == nil ? "" : "%"), 16, 342, 30, width: 140, bold: true)
            ink.text("UV INDEX NOW", 169, 325, 10, width: 133, bold: true)
            ink.text(number(w.uv_current), 169, 345, 26, width: 132, bold: true)
            ink.text(w.note, 16, 387, 12, width: 281)
            let weatherStale = now.timeIntervalSince(timestamp(w.observed_at)!) > 5400 || w.forecast_date != date(now, "yyyy-MM-dd")
            ink.text((weatherStale ? "STALE · " : "") + "Weather " + date(timestamp(w.observed_at)!, "h:mm a"), 16, 430, 11, width: 281, bold: weatherStale)

            ink.text("AGENDA", 332, 14, 18, width: 120, bold: true)
            ink.text("ALL \(names.count) CALENDARS", 594, 18, 13, width: 190)
            let agendaStale = now.timeIntervalSince(timestamp(snapshot.agenda.fetched_at)!) > 7200
            let warnings = snapshot.agenda.failed_calendars.isEmpty ? "" : " · \(snapshot.agenda.failed_calendars.count) unavailable"
            ink.text((agendaStale ? "STALE · " : "") + "Updated " + date(timestamp(snapshot.agenda.fetched_at)!, "h:mm a") + warnings, 332, 39, 12, width: 450, bold: agendaStale || !warnings.isEmpty)
            var y: CGFloat = 62, previousDay: Date?
            for row in rows {
                let newDay = previousDay != row.day
                if y + (newDay ? 26 : 0) + 29 > 429 { break }
                if newDay {
                    ink.box(332, y, 452, 22, fill: true)
                    let dayName = cal.isDate(row.day, inSameDayAs: now) ? "TODAY" : (cal.isDate(row.day, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!) ? "TOMORROW" : date(row.day, "EEEE").uppercased())
                    ink.text(dayName + " · " + date(row.day, "MMM d").uppercased(), 338, y + 1, 14, width: 436, bold: true, white: true)
                    y += 26; previousDay = row.day
                }
                var time = "ALL DAY"
                if !row.event.all_day {
                    func clock(_ d: Date) -> String { date(d, cal.component(.minute, from: d) == 0 ? "ha" : "h:mma").lowercased().replacingOccurrences(of: "am", with: "a").replacingOccurrences(of: "pm", with: "p") }
                    time = row.start < now && cal.isDate(row.day, inSameDayAs: now) ? "NOW–" + clock(row.end) : clock(row.start) + "–" + clock(row.end)
                    if !cal.isDate(row.start, inSameDayAs: row.end) { time = "CONTINUES" }
                }
                ink.text(time, 332, y + 3, time.count > 11 ? 12 : 14, width: 98)
                if ink.text(row.event.title, 436, y, 18, width: 318) { truncated += 1 }
                ink.text(codes[row.event.calendar]!, 767, y + 3, 14, width: 17, bold: true)
                y += 29; shown += 1
            }
            if rows.isEmpty { ink.text("No upcoming events", 332, 82, 20, width: 450) }
            if shown < rows.count { ink.text("+\(rows.count - shown) more event rows in the next \(profile.lookahead_days) days", 332, 431, 12, width: 451) }
            ink.line(16, 450, 784, 450)
            let legend = names.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: " · ")
            ink.text(legend, 16, 455, 14, width: 768)
        }
        return DashboardRender(bmp: image.bmp, png: image.png, shown: shown, omitted: rows.count - shown, truncated: truncated)
    }

    static func icon(_ kind: String, ink: Ink, x: CGFloat, y: CGFloat) {
        let ctx = ink.context
        func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, fill: Bool = false) {
            ctx.setStrokeColor(gray: 0, alpha: 1); ctx.setFillColor(gray: 0, alpha: 1); ctx.setLineWidth(3)
            let rect = CGRect(x: x, y: 480 - y - h, width: w, height: h)
            if fill { ctx.fillEllipse(in: rect) } else { ctx.strokeEllipse(in: rect) }
        }
        if kind == "sun" || kind == "partly-cloudy" {
            ellipse(x + 21, y, 33, 33)
            for i in 0..<8 {
                let angle = Double(i) * .pi / 4
                ink.line(x + 37 + 24 * cos(angle), y + 16 + 24 * sin(angle), x + 37 + 33 * cos(angle), y + 16 + 33 * sin(angle), width: 3)
            }
        }
        if kind != "sun" && kind != "unknown" {
            // Solid silhouettes survive the OG's one-bit output and small physical size.
            ellipse(x, y + 22, 39, 30, fill: true); ellipse(x + 22, y + 6, 44, 46, fill: true); ellipse(x + 48, y + 23, 35, 29, fill: true)
            ink.box(x + 18, y + 33, 48, 18, fill: true)
        }
        if kind == "rain" || kind == "storm" {
            for i in 0..<3 { ink.line(x + CGFloat(i * 24) + 14, y + 62, x + CGFloat(i * 24) + 7, y + 77, width: 3) }
        } else if kind == "snow" {
            for i in 0..<3 { ink.text("*", x + CGFloat(i * 24) + 8, y + 53, 28, width: 25, bold: true) }
        } else if kind == "fog" {
            for i in 0..<2 { ink.line(x, y + CGFloat(i * 12) + 65, x + 82, y + CGFloat(i * 12) + 65, width: 2) }
        }
    }
}
