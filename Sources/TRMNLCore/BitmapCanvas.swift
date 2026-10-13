import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Shared 800×480 canvas and firmware-compatible 1-bit BMP3 encoder.
enum BitmapCanvas {
    static let width = 800, height = 480
    static func render(_ draw: (CGContext) throws -> Void) throws -> (bmp: Data, png: Data) {
        var pixels = [UInt8](repeating: 255, count: width * height)
        return try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
                throw Problem(500, "render_failed", "Could not create a bitmap canvas.")
            }
            context.setAllowsAntialiasing(false); context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            try draw(context)
            // Color emoji and fallback fonts can still introduce gray pixels. Preview
            // the exact black/white pixels that the OG will receive in its bitmap.
            context.flush()
            let buffer = bytes.bindMemory(to: UInt8.self)
            for index in buffer.indices { buffer[index] = buffer[index] >= 128 ? 255 : 0 }
            guard let image = context.makeImage() else { throw Problem(500, "render_failed", "Could not finalize image.") }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
                throw Problem(500, "render_failed", "Could not encode preview.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw Problem(500, "render_failed", "Could not finish preview.") }
            let stride = ((width + 31) / 32) * 4, offset = 62
            var bmp = Data()
            func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bmp.append(contentsOf: $0) } }
            func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { bmp.append(contentsOf: $0) } }
            bmp.append(contentsOf: [0x42, 0x4d]); u32(UInt32(offset + stride * height))
            u16(0); u16(0); u32(UInt32(offset)); u32(40); u32(UInt32(width)); u32(UInt32(height))
            u16(1); u16(1); u32(0); u32(UInt32(stride * height)); u32(2835); u32(2835); u32(2); u32(2)
            bmp.append(contentsOf: [0, 0, 0, 0, 255, 255, 255, 0])
            for y in (0..<height).reversed() {
                var row = [UInt8](repeating: 0, count: stride)
                for x in 0..<width where buffer[y * width + x] >= 128 { row[x / 8] |= 1 << (7 - x % 8) }
                bmp.append(contentsOf: row)
            }
            return (bmp, png as Data)
        }
    }
}

struct Ink {
    let context: CGContext
    func line(_ x: CGFloat, _ y: CGFloat, _ endX: CGFloat, _ endY: CGFloat, width: CGFloat = 1) {
        context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(width)
        context.move(to: CGPoint(x: x, y: 480 - y)); context.addLine(to: CGPoint(x: endX, y: 480 - endY)); context.strokePath()
    }
    func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, fill: Bool = false) {
        let rect = CGRect(x: x, y: 480 - y - height, width: width, height: height)
        context.setFillColor(gray: 0, alpha: 1); context.setStrokeColor(gray: 0, alpha: 1); context.setLineWidth(1)
        if fill { context.fill(rect) } else { context.stroke(rect) }
    }
    @discardableResult
    func text(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, width: CGFloat,
              bold: Bool = false, white: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTForegroundColorAttributeName as String): CGColor(gray: white ? 1 : 0, alpha: 1)
        ]
        let value = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(value)
        let overflow = CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width)
        let result = CTLineCreateTruncatedLine(line, Double(width), .end,
            CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))) ?? line
        context.textPosition = CGPoint(x: x, y: 480 - y - size)
        CTLineDraw(result, context)
        return overflow
    }
}
