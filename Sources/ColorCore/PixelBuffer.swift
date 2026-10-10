import CoreGraphics
import Foundation
import ImageIO

/// A downsampled image as linear sRGB and OKLab pixels, row-major from the top-left.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let linear: [SIMD3<Float>]
    public let lab: [SIMD3<Float>]

    public init(width: Int, height: Int, linear: [SIMD3<Float>]) {
        precondition(linear.count == width * height)
        self.width = width
        self.height = height
        self.linear = linear
        self.lab = linear.map(ColorMath.linearToOKLab)
    }

    /// Draws `image` into a floating-point context in extended linear sRGB no larger than `maxDimension`.
    /// Tagged profiles (Display P3, Adobe RGB, …) are converted by ColorSync without clipping, so
    /// colors outside the sRGB gamut end up as linear values below 0 or above 1.
    public init(image: CGImage, maxDimension: Int) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 32,
                                bytesPerRow: w * 16, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
                                bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue
                                    | CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var linear = [SIMD3<Float>](repeating: .zero, count: w * h)
        for i in 0..<(w * h) {
            linear[i] = SIMD3(floats[i * 4], floats[i * 4 + 1], floats[i * 4 + 2])
        }
        self.init(width: w, height: h, linear: linear)
    }

    /// Average color in a disc around a normalized (0...1, top-left origin) point.
    /// `radius` is a fraction of the short side.
    public func sample(at point: CGPoint, radius: Double) -> SRGBColor {
        let cx = Double(width) * Double(point.x)
        let cy = Double(height) * Double(point.y)
        let r = max(0.75, radius * Double(min(width, height)))
        let x0 = max(0, Int((cx - r).rounded(.down))), x1 = min(width - 1, Int((cx + r).rounded(.up)))
        let y0 = max(0, Int((cy - r).rounded(.down))), y1 = min(height - 1, Int((cy + r).rounded(.up)))
        var sum = SIMD3<Float>.zero
        var n: Float = 0
        if x0 <= x1, y0 <= y1 {
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                    if dx * dx + dy * dy <= r * r {
                        sum += linear[y * width + x]
                        n += 1
                    }
                }
            }
        }
        if n == 0 {
            let x = min(width - 1, max(0, Int(cx))), y = min(height - 1, max(0, Int(cy)))
            return SRGBColor(linear: linear[y * width + x])
        }
        return SRGBColor(linear: sum / n)
    }
}

/// A decoded photo plus the buffers used for analysis.
public struct LoadedImage: @unchecked Sendable {
    public let url: URL
    /// Oriented, sRGB-managed preview used for display.
    public let display: CGImage
    /// Small buffer for clustering and coverage.
    public let analysis: PixelBuffer
    /// Larger buffer for marker sampling.
    public let sampling: PixelBuffer
}

public enum ImageLoaderError: LocalizedError {
    case unreadable(URL)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): "Could not read an image from “\(url.lastPathComponent)”."
        }
    }
}

public enum ImageLoader {
    public static let displayMaxDimension = 2048
    public static let analysisMaxDimension = 256
    public static let samplingMaxDimension = 1024

    /// Decodes JPEG/PNG/TIFF/HEIC and camera RAW (via ImageIO), applying EXIF orientation.
    public static func load(url: URL) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoaderError.unreadable(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: displayMaxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let display = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoaderError.unreadable(url)
        }
        return LoadedImage(
            url: url,
            display: display,
            analysis: PixelBuffer(image: display, maxDimension: analysisMaxDimension),
            sampling: PixelBuffer(image: display, maxDimension: samplingMaxDimension)
        )
    }
}
