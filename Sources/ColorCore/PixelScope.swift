import CoreGraphics
import Foundation

/// A vectorscope of a photo on the HSB wheel: how much of the photo sits at each hue and saturation, as a density grid
/// over the disc. Positions are those of the markers (`WheelGeometry.point`): the color's sRGB hue placed on the wheel of
/// `space`, counter-clockwise from 3 o'clock, with HSB saturation as the radius.
///
/// Every pixel counts with a weight that fades out below an HSB brightness of 0.15, because the HSB saturation of nearly
/// black pixels is noise and would otherwise scatter them over the whole wheel.
public struct PixelScope: Sendable {
    /// Cells per side of the grid.
    public static let size = 256
    /// The saturation at the edge of the grid: like the markers, colors outside the sRGB gamut sit just beyond the rim.
    public static let reach = 1.1
    /// Cells with less weight than this (after the blur, a lone pixel leaves 0.25 at most) stay empty, so stray pixels
    /// do not speckle the wheel.
    static let minimumCount: Float = 0.5

    /// Density per cell, 0...1, row-major from the top-left; 1 is the 99th percentile of the occupied cells.
    public let density: [Float]

    /// The scope of `pixels` (linear sRGB, extended), each first passed through `transform` when given.
    public init(pixels: [SIMD3<Float>], space: HueSpace, transform: ((Int, SIMD3<Float>) -> SIMD3<Float>)? = nil) {
        let n = Self.size
        let half = Double(n) / 2
        var counts = [Float](repeating: 0, count: n * n)
        for (i, pixel) in pixels.enumerated() {
            let hsb = SRGBColor(linear: transform?(i, pixel) ?? pixel).hsb
            let weight = Float(min(1, max(0, (hsb.b - 0.03) / 0.12)))
            guard weight > 0 else { continue }
            let a = space.position(ofRGBHue: hsb.h) * .pi / 180
            let r = min(hsb.s, Self.reach) / Self.reach * half
            let x = Int(half + cos(a) * r), y = Int(half - sin(a) * r)
            counts[min(n - 1, max(0, y)) * n + min(n - 1, max(0, x))] += weight
        }
        let blurred = Self.blur(counts, size: n)
        let occupied = blurred.filter { $0 >= Self.minimumCount }.sorted()
        guard let top = occupied.isEmpty ? nil : occupied[min(occupied.count - 1, Int(Double(occupied.count) * 0.99))],
              top > 0 else {
            density = [Float](repeating: 0, count: n * n)
            return
        }
        let scale = log1p(top)
        density = blurred.map { $0 >= Self.minimumCount ? min(1, log1p($0) / scale) : 0 }
    }

    /// The scope of a photo, from every `step`-th pixel in both directions; as `plan` predicts PhotoLab renders it when
    /// given.
    public init(_ buffer: PixelBuffer, space: HueSpace, step: Int = 1, plan: GradePreview.Plan? = nil) {
        let step = max(1, step)
        var indices: [Int] = []
        indices.reserveCapacity((buffer.width / step + 1) * (buffer.height / step + 1))
        for y in stride(from: 0, to: buffer.height, by: step) {
            for x in stride(from: 0, to: buffer.width, by: step) { indices.append(y * buffer.width + x) }
        }
        let pixels = indices.map { buffer.linear[$0] }
        guard let plan else {
            self.init(pixels: pixels, space: space)
            return
        }
        let lab = buffer.lab
        self.init(pixels: pixels, space: space) { i, pixel in plan.applyLinear(linear: pixel, lab: lab[indices[i]]) }
    }

    /// Density at a saturation and sRGB hue, for tests and readouts.
    public func density(atRGBHue hue: Double, saturation: Double, space: HueSpace) -> Float {
        let n = Self.size, half = Double(n) / 2
        let a = space.position(ofRGBHue: hue) * .pi / 180
        let r = min(saturation, Self.reach) / Self.reach * half
        let x = min(n - 1, max(0, Int(half + cos(a) * r))), y = min(n - 1, max(0, Int(half - sin(a) * r)))
        return density[y * n + x]
    }

    /// The grid as an image to lay over a darkened wheel, `reach` times the wheel's diameter: each occupied cell in the
    /// wheel's own color at that spot, turning white where the photo is densest.
    public func image(space: HueSpace) -> CGImage {
        let n = Self.size, half = Double(n) / 2
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let d = Double(density[y * n + x])
                guard d > 0 else { continue }
                let dx = Double(x) + 0.5 - half, dy = half - (Double(y) + 0.5)
                let s = min(1, hypot(dx, dy) / half * Self.reach)
                let position = ColorMath.normalizeDegrees(atan2(dy, dx) * 180 / .pi)
                let color = SRGBColor.fromHSB(h: space.rgbHue(atPosition: position), s: s, b: 1)
                let white = 0.6 * d * d
                let alpha = 0.15 + 0.85 * d
                let i = (y * n + x) * 4
                bytes[i] = UInt8((color.r + (1 - color.r) * white) * alpha * 255)
                bytes[i + 1] = UInt8((color.g + (1 - color.g) * white) * alpha * 255)
                bytes[i + 2] = UInt8((color.b + (1 - color.b) * white) * alpha * 255)
                bytes[i + 3] = UInt8(alpha * 255)
            }
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                      bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    /// A 1-2-1 blur in both directions, so the sparse counts of a small buffer become a cloud.
    private static func blur(_ values: [Float], size n: Int) -> [Float] {
        var horizontal = values
        for y in 0..<n {
            for x in 0..<n {
                let l = values[y * n + max(0, x - 1)], r = values[y * n + min(n - 1, x + 1)]
                horizontal[y * n + x] = (l + 2 * values[y * n + x] + r) / 4
            }
        }
        var result = horizontal
        for y in 0..<n {
            for x in 0..<n {
                let u = horizontal[max(0, y - 1) * n + x], d = horizontal[min(n - 1, y + 1) * n + x]
                result[y * n + x] = (u + 2 * horizontal[y * n + x] + d) / 4
            }
        }
        return result
    }
}
