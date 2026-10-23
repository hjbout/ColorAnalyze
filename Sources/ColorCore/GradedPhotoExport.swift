import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Applies the suggested grading to a photo at its full resolution and writes it as a 16-bit TIFF or a JPEG.
public enum GradedPhotoExport {
    public enum ExportError: LocalizedError {
        case unreadable(URL)
        case renderFailed
        case writeFailed(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url): "Could not read “\(url.lastPathComponent)” at full resolution."
            case .renderFailed: "The graded photo could not be rendered."
            case .writeFailed(let url): "Could not write “\(url.lastPathComponent)”."
            }
        }
    }

    /// Rows per strip: bounds the memory of the floating-point buffers, whatever the size of the photo.
    private static let stripRows = 256

    public enum Format: Sendable {
        case tiff, jpeg

        public var type: UTType { self == .tiff ? .tiff : .jpeg }
        public var fileExtension: String { self == .tiff ? "tiff" : "jpg" }
    }

    /// A photo at its own size, oriented, as ImageIO decodes it (RAW included), with the metadata of the file.
    public struct FullPhoto: @unchecked Sendable {
        public let image: CGImage
        public let properties: [CFString: Any]
    }

    public static func loadFullResolution(url: URL) throws -> FullPhoto {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ExportError.unreadable(url) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, ImageLoader.displayMaxDimension),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ExportError.unreadable(url)
        }
        return FullPhoto(image: image, properties: properties)
    }

    /// Grades `source` strip by strip into a 16-bit image of the same size, in the color space of the source
    /// (sRGB when that cannot be an RGB output): colors outside sRGB survive the grading and are only
    /// clipped to the gamut of the source's own space.
    public static func render(_ source: CGImage, settings: GradePreviewSettings) -> CGImage? {
        let plan = GradePreview.Plan(settings)
        let w = source.width, h = source.height
        var space = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        let working = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        var top = 0
        while top < h {
            let rows = min(stripRows, h - top)
            guard let strip = source.cropping(to: CGRect(x: 0, y: top, width: w, height: rows)) else { return nil }
            let buffer = PixelBuffer(image: strip, maxDimension: max(w, rows))
            guard buffer.width == w, buffer.height == rows else { return nil }
            let linear = buffer.linear, lab = buffer.lab
            var floats = [Float](repeating: 1, count: w * rows * 4)
            floats.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let pixels = out.baseAddress!
                let bands = min(rows, 16)
                DispatchQueue.concurrentPerform(iterations: bands) { band in
                    for i in (band * rows / bands * w)..<((band + 1) * rows / bands * w) {
                        let graded = plan.applyLinear(linear: linear[i], lab: lab[i])
                        pixels[i * 4] = graded.x
                        pixels[i * 4 + 1] = graded.y
                        pixels[i * 4 + 2] = graded.z
                    }
                }
            }
            let stripImage: CGImage? = floats.withUnsafeMutableBytes { raw in
                CGContext(data: raw.baseAddress, width: w, height: rows, bitsPerComponent: 32, bytesPerRow: w * 16,
                          space: working, bitmapInfo: CGBitmapInfo.floatComponents.rawValue
                              | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
            }
            guard let stripImage else { return nil }
            context.draw(stripImage, in: CGRect(x: 0, y: h - top - rows, width: w, height: rows))
            top += rows
        }
        return context.makeImage()
    }

    /// The metadata of the original for the graded file: pixels are already upright and the size and
    /// encoding belong to the new file, so those keys go and the orientation becomes 1.
    static func metadata(from original: [CFString: Any], format: Format) -> [CFString: Any] {
        var out = original
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
                    kCGImagePropertyProfileName, kCGImagePropertyHasAlpha, kCGImagePropertyJFIFDictionary,
                    kCGImagePropertyRawDictionary, kCGImagePropertyDNGDictionary, kCGImagePropertyIsFloat,
                    kCGImagePropertyIsIndexed] { out[key] = nil }
        out[kCGImagePropertyOrientation] = 1
        var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFCompression] = format == .tiff ? 5 : nil
        out[kCGImagePropertyTIFFDictionary] = tiff
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        return out
    }

    /// Reads the photo at `url`, grades it and writes it to `destination` (TIFF: 16 bits, LZW; JPEG: quality 0.95),
    /// in the photo's own color space and with its metadata.
    public static func write(photo url: URL, settings: GradePreviewSettings, format: Format = .tiff, to destination: URL) throws {
        let photo = try loadFullResolution(url: url)
        guard let graded = render(photo.image, settings: settings) else { throw ExportError.renderFailed }
        guard let target = CGImageDestinationCreateWithURL(destination as CFURL, format.type.identifier as CFString, 1, nil)
        else { throw ExportError.writeFailed(destination) }
        var properties = metadata(from: photo.properties, format: format)
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.95 }
        CGImageDestinationAddImage(target, graded, properties as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw ExportError.writeFailed(destination) }
    }
}
