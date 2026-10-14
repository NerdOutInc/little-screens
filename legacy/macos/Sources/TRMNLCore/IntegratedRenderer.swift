import Foundation
import CoreGraphics
import ImageIO

/// Generated scene, deterministic data. Blank surfaces are part of the art contract.
enum IntegratedRenderer {
    static let definition: [String: Any] = [
        "id": "daily-companion-v2", "width": 800, "height": 480, "weather_column_width": 267,
        "agenda_title_font_px": 20, "agenda_time_font_px": 16, "agenda_detail_font_px": 14,
        "calendar_policy": "Right two-thirds, full height. Bold titles and original time ranges; regular-weight details below titles. Up to two measured lines each, day groups, no calendar numbers/legend, overflow count.",
        "scene_policy": "800x480 background PNG, at most 45000 bytes. Leave pure-white text surfaces: weather x44..216 y150..460, agenda x281..766 y18..439. Illustrate frames/objects around these surfaces; no baked-in data or text. Same character/reference all local day; new character each day; edit when condition or time phase changes.",
        "weather_policy": "Fahrenheit/mph; high today, low tonight, explicit precipitation period, current UV only. Unknown is a dash. Draw values into scene surfaces.",
        "format": "800x480 2-bit grayscale PNG under 90000 bytes; firmware 1.6.0+"
    ]

    struct Entry {
        let row: AgendaRow
        let dayHeadingY: CGFloat?
        let y: CGFloat
        let height: CGFloat
        let time: Ink.TextBlock
        let title: Ink.TextBlock
        let details: Ink.TextBlock
    }
    static func layout(_ rows: [AgendaRow], profile: DashboardProfile) -> [Entry] {
        var entries: [Entry] = [], y: CGFloat = 18, previousDay: Date?
        for row in rows {
            let title = Ink.wrap(row.event.title, size: 20, width: 362, bold: true)
            let details = Ink.wrap(row.event.details ?? "", size: 14, width: 362, bold: false)
            let time = Ink.wrap(CompanionRenderer.timeRange(row, profile: profile), size: 16, width: 114, bold: true)
            let height = CGFloat(max(title.lines.count * 23 + details.lines.count * 17, time.lines.count * 18 + 3)) + (details.lines.isEmpty ? 9 : 11)
            let heading: CGFloat = previousDay == row.day ? 0 : 28
            // Never orphan a day heading or split an event across the footer.
            guard y + heading + height <= 431 else { break }
            let dayHeadingY = heading == 0 ? nil : y
            y += heading
            entries.append(Entry(row: row, dayHeadingY: dayHeadingY, y: y, height: height, time: time, title: title, details: details))
            y += height; previousDay = row.day
        }
        return entries
    }

    static func render(profile: DashboardProfile, snapshot: DashboardSnapshot, scene: DailyScene, art: Data, now: Date) throws -> DashboardRender {
        try snapshot.validate(profile: profile, now: now)
        guard scene.date == CompanionRenderer.day(now, profile: profile), scene.phase == CompanionRenderer.phase(now, profile: profile), scene.condition == snapshot.weather.icon else {
            throw Problem(409, "scene_stale", "Update the scene for today's date, current time phase, and weather icon; preserve today's character identity.")
        }
        guard let source = CGImageSourceCreateWithData(art as CFData, nil), let illustration = CGImageSourceCreateImageAtIndex(source, 0, nil),
              illustration.width == 800, illustration.height == 480 else {
            throw Problem(409, "scene_size", "Save an 800x480 background with blank weather and agenda surfaces for daily-companion-v2.")
        }
        let rows = DashboardRenderer.rows(profile: profile, snapshot: snapshot, now: now), entries = layout(rows, profile: profile)
        let cal = DashboardRenderer.calendar(profile)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = cal.timeZone
        func date(_ value: Date, _ pattern: String) -> String { f.dateFormat = pattern; return f.string(from: value) }
        func number(_ value: Double?) -> String { value.map { $0.rounded() == $0 ? String(Int($0)) : String(format: "%.1f", $0) } ?? "—" }
        let image = try BitmapCanvas.render(grayscale: true) { context in
            context.draw(illustration, in: CGRect(x: 0, y: 0, width: 800, height: 480))
            let ink = Ink(context: context), w = snapshot.weather
            ink.text(profile.location.uppercased(), 46, 151, 14, width: 170, bold: true)
            ink.text(date(now, "EEE, MMM d").uppercased(), 46, 173, 12, width: 170)
            ink.text(number(w.temperature) + "°", 44, 194, 61, width: 150, bold: true)
            ink.text("F", 198, 238, 14, width: 18)
            ink.text(w.condition, 46, 270, 21, width: 170, bold: true)
            ink.text("H " + number(w.high) + "°   L " + number(w.low) + "°", 46, 303, 19, width: 170)
            ink.text("Wind " + (w.wind_direction.isEmpty ? "" : w.wind_direction + " ") + number(w.wind_speed) + " mph", 46, 336, 16, width: 170)
            ink.text("Precip " + w.precipitation_period.lowercased() + " " + number(w.precipitation_chance) + (w.precipitation_chance == nil ? "" : "%"), 46, 366, 14, width: 170)
            ink.text("UV now  " + number(w.uv_current), 46, 396, 18, width: 170, bold: true)
            let stale = now.timeIntervalSince(timestamp(w.observed_at)!) > 5400 || w.forecast_date != CompanionRenderer.day(now, profile: profile)
            ink.text((stale ? "STALE · " : "") + "Weather " + date(timestamp(w.observed_at)!, "h:mm a"), 46, 442, 10, width: 170, bold: stale)

            for entry in entries {
                if let y = entry.dayHeadingY {
                    let day = entry.row.day
                    let label = cal.isDate(day, inSameDayAs: now) ? "TODAY" : (cal.isDate(day, inSameDayAs: cal.date(byAdding: .day, value: 1, to: now)!) ? "TOMORROW" : date(day, "EEEE").uppercased())
                    ink.text(label + " · " + date(day, "MMM d").uppercased(), 282, y, 16, width: 484, bold: true)
                    ink.line(282, y + 23, 766, y + 23)
                }
                // Rare long/cross-midnight ranges may wrap, never silently lose the end time.
                for (index, line) in entry.time.lines.enumerated() { ink.text(line, 282, entry.y + 3 + CGFloat(index * 18), 16, width: 114, bold: true) }
                for (index, line) in entry.title.lines.enumerated() { ink.text(line, 404, entry.y + CGFloat(index * 23), 20, width: 362, bold: true) }
                for (index, line) in entry.details.lines.enumerated() {
                    ink.text(line, 404, entry.y + CGFloat(entry.title.lines.count * 23 + 2 + index * 17), 14, width: 362)
                }
            }
            if rows.isEmpty { ink.text("No upcoming events", 282, 45, 20, width: 484, bold: true) }
            let staleAgenda = now.timeIntervalSince(timestamp(snapshot.agenda.fetched_at)!) > 7200
            let failed = snapshot.agenda.failed_calendars.count
            let footer = (staleAgenda ? "STALE · " : "") + "Updated " + date(timestamp(snapshot.agenda.fetched_at)!, "h:mm a")
                + (failed > 0 ? " · \(failed) calendars unavailable" : "")
                + (entries.count < rows.count ? " · +\(rows.count - entries.count) more" : "")
            ink.text(footer, 282, 432, 10, width: 484, bold: staleAgenda || failed > 0)
        }
        return DashboardRender(bmp: image.bmp, png: image.png, shown: entries.count, omitted: rows.count - entries.count,
            truncated: entries.filter { $0.title.truncated }.count)
    }
}
