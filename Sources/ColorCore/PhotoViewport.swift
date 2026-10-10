import CoreGraphics
import Foundation

/// Zoom and pan of the photo inside its pane. At zoom 1 the photo fits the pane and is centered;
/// `pan` is the offset of the photo's center from the pane's center, in points.
public struct PhotoViewport: Equatable, Sendable {
    public static let zoomRange: ClosedRange<CGFloat> = 1...32
    /// Factor of one zoom-in / zoom-out step.
    public static let step: CGFloat = 1.5

    public var zoom: CGFloat = 1
    public var pan: CGSize = .zero

    public init(zoom: CGFloat = 1, pan: CGSize = .zero) {
        self.zoom = zoom
        self.pan = pan
    }

    public var isZoomed: Bool { zoom > 1.0001 }

    /// Zooms to `newZoom`, keeping the point `anchor` (given as its offset from the pane's center) at the
    /// same spot on the photo; nil keeps the pane's center fixed.
    public mutating func setZoom(_ newZoom: CGFloat, anchor: CGPoint? = nil) {
        let target = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, newZoom))
        let factor = target / zoom
        if let a = anchor {
            pan = CGSize(width: a.x + (pan.width - a.x) * factor, height: a.y + (pan.height - a.y) * factor)
        } else {
            pan = CGSize(width: pan.width * factor, height: pan.height * factor)
        }
        zoom = target
        if zoom <= 1.0001 { fit() }
    }

    public mutating func zoom(by factor: CGFloat, anchor: CGPoint? = nil) {
        setZoom(zoom * factor, anchor: anchor)
    }

    /// Back to the photo fitting the pane.
    public mutating func fit() {
        zoom = 1
        pan = .zero
    }

    /// Where the photo is in the pane (top-left origin), given its size at zoom 1 and the pane's size.
    public func photoRect(photoFit: CGSize, pane: CGSize) -> CGRect {
        let size = CGSize(width: photoFit.width * zoom, height: photoFit.height * zoom)
        return CGRect(x: (pane.width - size.width) / 2 + pan.width,
                      y: (pane.height - size.height) / 2 + pan.height,
                      width: size.width, height: size.height)
    }

    /// The same viewport with the pan limited so the photo cannot leave the pane: in a direction where the
    /// photo is larger than the pane its edge may go `margin` points past the pane's edge; where it is
    /// smaller it stays centered.
    public func clamped(photoFit: CGSize, pane: CGSize, margin: CGFloat = 40) -> PhotoViewport {
        func limit(_ photo: CGFloat, _ pane: CGFloat) -> CGFloat {
            let size = photo * zoom
            return size > pane ? (size - pane) / 2 + margin : 0
        }
        let lx = limit(photoFit.width, pane.width), ly = limit(photoFit.height, pane.height)
        var result = self
        result.pan = CGSize(width: min(lx, max(-lx, pan.width)), height: min(ly, max(-ly, pan.height)))
        return result
    }

    /// The zoom at which one pixel of an image `imagePixels` wide is one point on screen, for a photo that
    /// is `photoFitWidth` points wide at zoom 1.
    public static func actualPixelsZoom(imagePixels: CGFloat, photoFitWidth: CGFloat) -> CGFloat {
        guard photoFitWidth > 0 else { return 1 }
        return min(zoomRange.upperBound, max(1, imagePixels / photoFitWidth))
    }
}
