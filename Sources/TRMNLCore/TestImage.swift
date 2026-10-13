import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

enum TestImage {
    static let width = 800
    static let height = 480

    static func render(name: String, code: String, message: String, date: Date) throws -> (bmp: Data, png: Data) {
        var pixels = [UInt8](repeating: 255, count: width * height)
        return try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
                throw Problem(500, "render_failed", "Could not create a bitmap canvas.")
            }
            context.setAllowsAntialiasing(false)
            context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

            guard let cgImage = context.makeImage() else { throw Problem(500, "render_failed", "Could not finalize image.") }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
                throw Problem(500, "render_failed", "Could not encode preview.")
            }
            CGImageDestinationAddImage(destination, cgImage, nil)
            guard CGImageDestinationFinalize(destination) else { throw Problem(500, "render_failed", "Could not finish preview.") }

            // BMP3: BITMAPINFOHEADER, 1 bit/pixel, black/white palette, bottom-up rows.
            let stride = ((width + 31) / 32) * 4
            let offset = 14 + 40 + 8
            var bmp = Data()
            func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bmp.append(contentsOf: $0) } }
            func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bmp.append(contentsOf: $0) } }
            bmp.append(contentsOf: [0x42, 0x4d]); u32(UInt32(offset + stride * height))
            u16(0); u16(0); u32(UInt32(offset)); u32(40); u32(UInt32(width)); u32(UInt32(height))
            u16(1); u16(1); u32(0); u32(UInt32(stride * height)); u32(2835); u32(2835); u32(2); u32(2)
            bmp.append(contentsOf: [0, 0, 0, 0, 255, 255, 255, 0])
            let buffer = bytes.bindMemory(to: UInt8.self)
            for y in (0..<height).reversed() {
                var row = [UInt8](repeating: 0, count: stride)
                for x in 0..<width where buffer[y * width + x] >= 128 { row[x / 8] |= 1 << (7 - x % 8) }
                bmp.append(contentsOf: row)
            }
            return (bmp, png as Data)
        }
    }
}
