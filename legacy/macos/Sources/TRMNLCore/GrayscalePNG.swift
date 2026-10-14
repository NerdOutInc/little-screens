import Foundation
import zlib

/// Real 2-bit grayscale PNG, as required by the OG's four-tone firmware path.
enum GrayscalePNG {
    static func encode(_ pixels: UnsafeMutableBufferPointer<UInt8>, width: Int, height: Int) throws -> Data {
        var rows = [UInt8](); rows.reserveCapacity((width / 4 + 1) * height)
        for y in 0..<height {
            rows.append(0) // PNG filter: None
            for x in stride(from: 0, to: width, by: 4) {
                var packed: UInt8 = 0
                for offset in 0..<4 where x + offset < width {
                    packed |= (pixels[y * width + x + offset] / 85) << (6 - offset * 2)
                }
                rows.append(packed)
            }
        }
        var size = compressBound(uLong(rows.count))
        var compressed = [UInt8](repeating: 0, count: Int(size))
        guard compress2(&compressed, &size, rows, uLong(rows.count), Z_BEST_COMPRESSION) == Z_OK else {
            throw Problem(500, "render_failed", "Could not compress grayscale screen.")
        }
        func big(_ n: UInt32) -> Data { var n = n.bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        func chunk(_ type: String, _ data: Data) -> Data {
            let payload = Data(type.utf8) + data
            let checksum = payload.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(payload.count)) }
            return big(UInt32(data.count)) + payload + big(UInt32(checksum))
        }
        let header = big(UInt32(width)) + big(UInt32(height)) + Data([2, 0, 0, 0, 0])
        let result = Data([137, 80, 78, 71, 13, 10, 26, 10]) + chunk("IHDR", header)
            + chunk("IDAT", Data(compressed.prefix(Int(size)))) + chunk("IEND", Data())
        guard result.count < 90000 else { throw Problem(400, "image_too_large", "Screen exceeds the OG's 90000-byte limit.") }
        return result
    }
}
