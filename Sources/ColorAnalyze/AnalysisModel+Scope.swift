import ColorCore
import CoreGraphics

@MainActor
extension AnalysisModel {
    // MARK: Pixel scope

    /// What the pixel scope is drawn from: every other pixel of the sampling buffer of a photo (about 175,000, enough for
    /// a smooth cloud), graded by the calibrated model when `plan` is set.
    struct PixelScopeRequest: Sendable {
        let key: Int
        let buffer: PixelBuffer
        let space: HueSpace
        let plan: GradePreview.Plan?
    }

    /// The scope for the wheel; nil while it is off. With `after` (the wheel shows the colors after grading) it shows the
    /// graded version, or the photo as the preview predicts it, like the ghost markers; otherwise the photo itself.
    func pixelScopeRequest(after: Bool) -> PixelScopeRequest? {
        guard showPixelScope, let image else { return nil }
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(image.display))
        hasher.combine(hueSpace)
        if after, let afterImage {
            hasher.combine(ObjectIdentifier(afterImage.display))
            return PixelScopeRequest(key: hasher.finalize(), buffer: afterImage.sampling, space: hueSpace, plan: nil)
        }
        if after, isPreviewActive, let plan = prediction()?.plan {
            hasher.combine(suggestionKey)
            return PixelScopeRequest(key: hasher.finalize(), buffer: image.sampling, space: hueSpace, plan: plan)
        }
        return PixelScopeRequest(key: hasher.finalize(), buffer: image.sampling, space: hueSpace, plan: nil)
    }

    /// Renders the scope in the background. The last image stays up until the new one is ready, so a drag does not
    /// make it flicker; a request that was replaced in the meantime is dropped.
    func renderPixelScope(_ request: PixelScopeRequest) async {
        guard request.key != pixelScopeKey else { return }
        let rendered = await Task.detached(priority: .userInitiated) {
            PixelScope(request.buffer, space: request.space, step: 2, plan: request.plan).image(space: request.space)
        }.value
        guard !Task.isCancelled else { return }
        pixelScopeImage = rendered
        pixelScopeKey = request.key
    }
}
