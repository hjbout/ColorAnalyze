import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// "Where would a viewer look?" — used to let the subject count more than the background.
public enum Saliency {
    public enum SaliencyError: LocalizedError {
        case noResult

        public var errorDescription: String? {
            "The subject of the photo could not be detected."
        }
    }

    /// Attention-based saliency (Apple Vision) as a `width`×`height` map with values in 0...1,
    /// row-major from the top-left. Vision returns a coarse heat map; it is resampled
    /// bilinearly and scaled so the strongest spot is 1.
    public static func attentionMap(for image: CGImage, width: Int, height: Int) throws -> [Float] {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first else { throw SaliencyError.noResult }
        let grid = readGrid(observation.pixelBuffer)
        guard grid.width > 0, grid.height > 0 else { throw SaliencyError.noResult }
        return resample(grid: grid.values, gridWidth: grid.width, gridHeight: grid.height,
                        width: width, height: height)
    }

    /// The foreground objects of the photo as a `width`×`height` mask with values in 0...1 (1 = subject), row-major from
    /// the top-left: Vision's foreground instance mask, the "lift subject" of Photos, with all instances together. Unlike
    /// the attention map it follows the outline of people, animals and objects, so it tells subject from background
    /// pixel by pixel. Nil when the photo has no foreground (a landscape).
    public static func foregroundMask(for image: CGImage, width: Int, height: Int) throws -> [Float]? {
        try foregroundMasks(for: image, sizes: [(width, height)])?.first
    }

    /// The foreground mask at several sizes from one detection (one for the analysis, a finer one to show).
    public static func foregroundMasks(for image: CGImage, sizes: [(width: Int, height: Int)]) throws -> [[Float]]? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        let grid = readGrid(buffer)
        guard grid.width > 0, grid.height > 0 else { return nil }
        return sizes.map {
            boxDownsample(grid: grid.values, gridWidth: grid.width, gridHeight: grid.height, width: $0.width, height: $0.height)
        }
    }

    /// Area average of a fine grid onto a coarser one.
    static func boxDownsample(grid: [Float], gridWidth gw: Int, gridHeight gh: Int, width: Int, height: Int) -> [Float] {
        var sums = [Float](repeating: 0, count: width * height), counts = sums
        for y in 0..<gh {
            let ty = min(height - 1, y * height / gh)
            for x in 0..<gw {
                let i = ty * width + min(width - 1, x * width / gw)
                sums[i] += grid[y * gw + x]
                counts[i] += 1
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / $1 : 0 }
    }

    /// Per-pixel weights: 1 for the background up to `1 + strength` on the most salient spot.
    public static func weights(for map: [Float], strength: Float) -> [Float] {
        map.map { 1 + strength * $0 }
    }

    /// Bilinear resampling of a coarse grid, then scaling so the maximum is 1.
    public static func resample(grid: [Float], gridWidth gw: Int, gridHeight gh: Int,
                                width: Int, height: Int) -> [Float] {
        guard gw > 0, gh > 0, width > 0, height > 0, grid.count == gw * gh else {
            return [Float](repeating: 0, count: max(0, width * height))
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let fy = (Float(y) + 0.5) * Float(gh) / Float(height) - 0.5
            let y0 = max(0, min(gh - 1, Int(fy.rounded(.down))))
            let y1 = min(gh - 1, y0 + 1)
            let ty = min(1, max(0, fy - Float(y0)))
            for x in 0..<width {
                let fx = (Float(x) + 0.5) * Float(gw) / Float(width) - 0.5
                let x0 = max(0, min(gw - 1, Int(fx.rounded(.down))))
                let x1 = min(gw - 1, x0 + 1)
                let tx = min(1, max(0, fx - Float(x0)))
                let top = grid[y0 * gw + x0] * (1 - tx) + grid[y0 * gw + x1] * tx
                let bottom = grid[y1 * gw + x0] * (1 - tx) + grid[y1 * gw + x1] * tx
                out[y * width + x] = top * (1 - ty) + bottom * ty
            }
        }
        if let peak = out.max(), peak > 0 {
            for i in out.indices { out[i] /= peak }
        }
        return out
    }

    /// Overlay that keeps the salient area clear and darkens the rest by up to `dim` (0...1).
    public static func spotlightImage(map: [Float], width: Int, height: Int, dim: Double = 0.62) -> CGImage? {
        guard width > 0, height > 0, map.count == width * height else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for (i, s) in map.enumerated() {
            let t = min(1, max(0, (Double(s) - 0.15) / 0.7))
            let keep = t * t * (3 - 2 * t) // smoothstep
            bytes[i * 4 + 3] = UInt8((dim * (1 - keep) * 255).rounded()) // premultiplied black
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private static func readGrid(_ buffer: CVPixelBuffer) -> (values: [Float], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return ([], 0, 0) }
        var values = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<w { values[y * w + x] = row[x] }
        }
        return (values, w, h)
    }
}
