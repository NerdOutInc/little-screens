import Foundation
import CoreGraphics
import ImageIO

enum CompanionRenderer {
    static let definition: [String: Any] = [
        "id": "daily-companion-v1", "width": 800, "height": 480, "weather_column_width": 200,
        "agenda_title_font_px": 18, "agenda_time_font_px": 14, "agenda_row_height_px": 29,
        "calendar_policy": "Full-height right 600px; all calendars, day groups, original compact start-end times, no calendar numbers or legend; overflow count",
        "scene_policy": "176x220 art, same character/reference all local day; new character each day; edit scene when condition or phase changes. Morning 05–11, afternoon 12–16, evening 17–20, night 21–04.",
        "weather_policy": "Fahrenheit/mph; high today, low tonight, explicit precipitation period, current UV only; null shown as dash",
        "format": "800x480 2-bit grayscale PNG under 90000 bytes; firmware 1.6.0+"
    ]
    static func day(_ now: Date, profile: DashboardProfile) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: profile.timezone); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: now)
    }
    static func phase(_ now: Date, profile: DashboardProfile) -> String {
        switch DashboardRenderer.calendar(profile).component(.hour, from: now) {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "night"
        }
    }
    static func timeRange(_ row: AgendaRow, profile: DashboardProfile) -> String {
        if row.event.all_day { return "All day" }
        let cal = DashboardRenderer.calendar(profile)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        func clock(_ d: Date) -> String {
            f.dateFormat = cal.component(.minute, from: d) == 0 ? "ha" : "h:mma"
            return f.string(from: d).lowercased().replacingOccurrences(of: "am", with: "a").replacingOccurrences(of: "pm", with: "p")
        }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: row.start), to: cal.startOfDay(for: row.end)).day!
        return clock(row.start) + "-" + clock(row.end) + (days > 0 ? " +\(days)d" : "")
    }
    static func render(profile: DashboardProfile, snapshot: DashboardSnapshot, scene: DailyScene, art: Data, now: Date) throws -> DashboardRender {
        try snapshot.validate(profile: profile, now: now)
        guard scene.date == day(now, profile: profile), scene.phase == phase(now, profile: profile), scene.condition == snapshot.weather.icon else {
            throw Problem(409, "scene_stale", "Update the scene for today's date, current time phase, and weather icon; preserve today's character identity.")
        }
        guard let source = CGImageSourceCreateWithData(art as CFData, nil), let illustration = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Problem(500, "scene_missing", "Saved scene image is unavailable.")
        }
        guard illustration.width == 176, illustration.height == 220 else {
            throw Problem(409, "scene_size", "Save 176x220 scene art for daily-companion-v1.")
        }
        let rows = DashboardRenderer.rows(profile: profile, snapshot: snapshot, now: now), cal = DashboardRenderer.calendar(profile)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        func date(_ value: Date, _ pattern: String) -> String { f.dateFormat = pattern; return f.string(from: value) }
        func number(_ value: Double?) -> String { value.map { $0.rounded() == $0 ? String(Int($0)) : String(format: "%.1f", $0) } ?? "—" }
        var shown = 0, truncated = 0
        let image = try BitmapCanvas.render(grayscale: true) { context in
            let ink = Ink(context: context), w = snapshot.weather
            ink.line(200, 0, 200, 480, width: 2)
            ink.text(profile.location.uppercased(), 12, 9, 15, width: 176, bold: true)
            ink.text(date(now, "EEE, MMM d").uppercased(), 12, 30, 12, width: 176)
            ink.text(number(w.temperature) + "°", 9, 45, 57, width: 151, bold: true)
            ink.text("F", 164, 85, 14, width: 20)
            ink.text(w.condition, 12, 108, 19, width: 176, bold: true)
            ink.text("H " + number(w.high) + "°   L " + number(w.low) + "°", 12, 138, 18, width: 176)
            ink.text("Wind " + (w.wind_direction.isEmpty ? "" : w.wind_direction + " ") + number(w.wind_speed) + " mph", 12, 166, 16, width: 176)
            ink.text("Precip " + w.precipitation_period.lowercased() + " " + number(w.precipitation_chance) + (w.precipitation_chance == nil ? "" : "%"), 12, 191, 14, width: 176)
            ink.text("UV now  " + number(w.uv_current), 12, 214, 16, width: 176, bold: true)
            context.saveGState(); context.interpolationQuality = .high
            context.draw(illustration, in: CGRect(x: 12, y: 20, width: 176, height: 220)); context.restoreGState()
            let stale = now.timeIntervalSince(timestamp(w.observed_at)!) > 5400 || w.forecast_date != day(now, profile: profile)
            ink.text((stale ? "STALE · " : "") + "Weather " + date(timestamp(w.observed_at)!, "h:mm a"), 12, 464, 10, width: 176, bold: stale)

            var y: CGFloat = 10, previousDay: Date?
            for row in rows {
                let newDay = previousDay != row.day
                if y + (newDay ? 29 : 0) + 29 > 452 { break }
                if newDay {
                    ink.box(214, y, 574, 24, fill: true)
                    let label = cal.isDate(row.day, inSameDayAs: now) ? "TODAY" : (cal.isDate(row.day, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!) ? "TOMORROW" : date(row.day, "EEEE").uppercased())
                    ink.text(label + " · " + date(row.day, "MMM d").uppercased(), 222, y + 2, 15, width: 558, bold: true, white: true)
                    y += 29; previousDay = row.day
                }
                let range = timeRange(row, profile: profile)
                ink.text(range, 216, y + 3, range.count > 14 ? 12 : 14, width: 120)
                if ink.text(row.event.title, 344, y, 18, width: 444) { truncated += 1 }
                y += 29; shown += 1
            }
            if rows.isEmpty { ink.text("No upcoming events", 216, 40, 20, width: 560) }
            let staleAgenda = now.timeIntervalSince(timestamp(snapshot.agenda.fetched_at)!) > 7200
            let failed = snapshot.agenda.failed_calendars.count
            ink.line(214, 457, 788, 457)
            let footer = (staleAgenda ? "STALE · " : "") + "Updated " + date(timestamp(snapshot.agenda.fetched_at)!, "h:mm a")
                + (failed > 0 ? " · \(failed) calendars unavailable" : "")
                + (shown < rows.count ? " · +\(rows.count - shown) more" : "")
            ink.text(footer, 216, 463, 11, width: 572, bold: staleAgenda || failed > 0)
        }
        return DashboardRender(bmp: image.bmp, png: image.png, shown: shown, omitted: rows.count - shown, truncated: truncated)
    }
}
