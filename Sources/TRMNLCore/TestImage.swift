import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum TestImage {
    static let width = 800
    static let height = 480

    static func render(name: String, code: String, message: String, date: Date) throws -> (bmp: Data, png: Data) {
        return try BitmapCanvas.render { context in
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(3)
            context.stroke(CGRect(x: 18, y: 18, width: 764, height: 444))
            func text(_ value: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
                let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
                let string = NSAttributedString(string: value, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ])
                let line = CTLineCreateWithAttributedString(string)
                let clipped = CTLineCreateTruncatedLine(line, 700, .end,
                    CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: string.attributes(at: 0, effectiveRange: nil)))) ?? line
                context.textPosition = CGPoint(x: 48, y: y)
                CTLineDraw(clipped, context)
            }
            text("AI TRMNL", y: 398, size: 25, bold: true)
            text(name, y: 326, size: 40, bold: true)
            text("DEVICE \(code)", y: 251, size: 52, bold: true)
            text(message, y: 190, size: 23)
            context.move(to: CGPoint(x: 48, y: 161)); context.addLine(to: CGPoint(x: 752, y: 161)); context.strokePath()
            text("800 × 480 · BLACK & WHITE · LOCAL SERVER", y: 121, size: 17)
            text(ISO8601DateFormatter().string(from: date), y: 86, size: 17)
            text("Tiny screen. Big first impression.", y: 49, size: 17)

        }
    }
}
