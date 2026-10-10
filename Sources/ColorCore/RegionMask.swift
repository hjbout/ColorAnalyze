import CoreGraphics
import Foundation

/// The pixels of a buffer that are closest to one of several colors — the "region"
/// a marker stands for. Uses the same nearest-color rule as the coverage percentages,
/// so the highlighted area is exactly the area that is counted.
public struct RegionMask: Sendable {
    public let width: Int
    public let height: Int
    public let inside: [Bool]

    public init(colorAt index: Int, of colors: [SIMD3<Float>], in buffer: PixelBuffer) {
        width = buffer.width
        height = buffer.height
        inside = colors.indices.contains(index)
            ? buffer.lab.map { KMeans.nearest($0, in: colors) == index }
            : [Bool](repeating: false, count: buffer.lab.count)
    }

    /// Fraction of pixels inside the region.
    public var coverage: Double {
        inside.isEmpty ? 0 : Double(inside.lazy.filter { $0 }.count) / Double(inside.count)
    }

    /// Overlay that leaves the region untouched and darkens everything else by `dim` (0...1).
    /// Draw it stretched over the photo with high-quality interpolation for soft edges.
    public func overlayImage(dim: Double = 0.62) -> CGImage? {
        let alpha = UInt8((min(1, max(0, dim)) * 255).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, isInside) in inside.enumerated() where !isInside {
            bytes[i * 4 + 3] = alpha // premultiplied black
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
