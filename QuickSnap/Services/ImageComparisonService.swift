import AppKit
import CoreGraphics

struct ImageComparisonService {
    static let similarityThreshold: CGFloat = 0.25

    /// Returns a difference score: 0.0 = identical, 1.0 = completely different
    static func pixelDifference(_ imageA: NSImage, _ imageB: NSImage) -> CGFloat {
        let size = 64
        guard let pixelsA = rasterize(imageA, size: size),
              let pixelsB = rasterize(imageB, size: size) else { return 1.0 }

        var totalDiff: Int = 0
        let count = size * size * 4 // RGBA
        for i in stride(from: 0, to: count, by: 4) {
            totalDiff += abs(Int(pixelsA[i]) - Int(pixelsB[i]))     // R
            totalDiff += abs(Int(pixelsA[i+1]) - Int(pixelsB[i+1])) // G
            totalDiff += abs(Int(pixelsA[i+2]) - Int(pixelsB[i+2])) // B
        }

        let maxDiff = size * size * 3 * 255
        return CGFloat(totalDiff) / CGFloat(maxDiff)
    }

    private static func rasterize(_ image: NSImage, size: Int) -> [UInt8]? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return pixels
    }
}
