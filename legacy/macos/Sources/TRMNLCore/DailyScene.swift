import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Identity is pinned for a local calendar day; later scenes retain the first reference.
struct DailyScene: Codable {
    var id: String
    var referenceID: String
    var date: String
    var character: String
    var identity: String
    var condition: String
    var phase: String
    var prompt: String
}

struct SceneInput: Codable {
    var date: String
    var character: String
    var identity: String
    var condition: String
    var phase: String
    var prompt: String
    var png_base64: String

    static var schema: [String: Any] { objectSchema([
        "date": ["type": "string"], "character": ["type": "string"], "identity": ["type": "string"],
        "condition": ["type": "string"], "phase": ["type": "string", "enum": ["morning", "afternoon", "evening", "night"]],
        "prompt": ["type": "string"], "png_base64": ["type": "string", "maxLength": 60000]
    ]) }

    func validate(profile: DashboardProfile, previous: DailyScene?, now: Date) throws -> Data {
        let width = profile.template == "daily-companion-v2" ? 800 : 176
        let height = profile.template == "daily-companion-v2" ? 480 : 220
        guard date == CompanionRenderer.day(now, profile: profile), clean(character, limit: 60), clean(identity, limit: 500),
              clean(condition, limit: 45), clean(prompt, limit: 3000),
              phase == CompanionRenderer.phase(now, profile: profile), png_base64.count <= 60000,
              let data = Data(base64Encoded: png_base64), data.count <= 45000,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw Problem(400, "invalid_scene", "Use today's local date/current phase, bounded character metadata, and one \(width)x\(height) PNG (at most 45000 bytes) encoded as base64.")
        }
        if let previous, previous.date == date, (previous.character != character || previous.identity != identity) {
            throw Problem(409, "character_changed", "Keep the same character and identity for the entire local day. Use the saved reference image for scene edits.")
        }
        return data
    }
}
