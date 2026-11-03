import ColorCore
import Foundation

@MainActor
extension AnalysisModel {
    // MARK: Separation of subject and background

    /// The map the subject is taken from: the foreground mask, or the attention map when the photo has no foreground.
    /// Nil until both have been looked for.
    var separationSubjectMap: [Float]? {
        if let foregroundMask { return foregroundMask }
        return foregroundMaskChecked ? saliency : nil
    }

    /// Looks for a foreground (people, animals, objects) once per photo.
    func ensureForegroundMask() async {
        guard !foregroundMaskChecked, let image else { return }
        if let running = foregroundMaskTask { return await running.value }
        let display = image.display
        let sizes = [(image.analysis.width, image.analysis.height), (image.sampling.width, image.sampling.height)]
        let task = Task {
            let masks = await Task.detached(priority: .userInitiated) {
                try? Saliency.foregroundMasks(for: display, sizes: sizes)
            }.value
            guard self.image?.display === display else { return }
            foregroundMask = masks?[0]
            foregroundDisplayMask = masks.map { ($0[1], sizes[1].0, sizes[1].1) }
            foregroundMaskChecked = true
        }
        foregroundMaskTask = task
        await task.value
        foregroundMaskTask = nil
    }

    /// Shows or hides the foreground mask over the photo: what the separation check takes as the subject.
    func refreshForegroundOverlay() {
        guard showForeground else {
            foregroundOverlay = nil
            return
        }
        Task {
            await ensureForegroundMask()
            guard showForeground else { return }
            foregroundOverlay = foregroundDisplayMask.flatMap {
                Saliency.spotlightImage(map: $0.values, width: $0.width, height: $0.height)
            }
        }
    }

    /// Finds the subject for the separation check: the foreground, and the attention map in case there is none.
    func prepareSubject() async {
        await ensureForegroundMask()
        _ = await ensureSaliency(reportsFailure: false)
    }

    /// What the separation check depends on: the photo, its subject map, and the graded version or the predicted grading.
    /// Nil until the subject map is there.
    var separationRequestKey: Int? {
        guard let image, separationSubjectMap != nil else { return nil }
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(image.display))
        hasher.combine(foregroundMask != nil)
        if let afterImage {
            hasher.combine(ObjectIdentifier(afterImage.display))
        } else if isPreviewActive {
            hasher.combine(suggestionKey)
        }
        return hasher.finalize()
    }

    /// Checks the separation of the photo (once) and of the graded version or the prediction, in the background.
    func refreshSeparation() async {
        guard let key = separationRequestKey, key != separationKey, let image, let map = separationSubjectMap else { return }
        // The photo's own check is kept unless the subject map changed (the foreground found after the attention map).
        let before = separationUsesForeground == (foregroundMask != nil) ? separation : nil
        let lab = image.analysis.lab
        // A graded version only counts when it has the photo's framing, so the subject map fits it.
        let graded = afterImage.flatMap {
            $0.analysis.width == image.analysis.width && $0.analysis.height == image.analysis.height ? $0.analysis.lab : nil
        }
        let plan = afterImage == nil && isPreviewActive ? prediction()?.plan : nil
        let result = await Task.detached(priority: .userInitiated) {
            let photo = before ?? SeparationCheck.check(lab: lab, saliency: map)
            var after: SeparationCheck?
            if let graded {
                after = SeparationCheck.check(lab: graded, saliency: map)
            } else if let plan {
                after = SeparationCheck.check(lab: lab.map { plan.apply($0) }, saliency: map)
            }
            return (photo, after)
        }.value
        guard !Task.isCancelled, separationRequestKey == key else { return }
        separation = result.0
        afterSeparation = result.1
        separationKey = key
        separationUsesForeground = foregroundMask != nil
    }

    /// Per marker, the share of the pixels nearest to its color that are subject (empty without a subject map).
    var subjectFractions: [Double] {
        guard let image, let map = separationSubjectMap else { return [] }
        let key = markersKey
        if let cache = subjectFractionCache, cache.key == key, cache.fractions.count == markers.count { return cache.fractions }
        let fractions = SeparationCheck.subjectFractions(lab: image.analysis.lab, saliency: map,
                                                         colors: markers.map(\.color.oklab))
        subjectFractionCache = (key, fractions)
        return fractions
    }

    func subjectFraction(of marker: Marker) -> Double? {
        let fractions = subjectFractions
        guard let index = markers.firstIndex(where: { $0.id == marker.id }), fractions.indices.contains(index) else { return nil }
        return fractions[index]
    }

    /// True for a color that lies almost only in the background.
    func isBackground(_ marker: Marker) -> Bool {
        subjectFraction(of: marker).map { $0 <= SeparationCheck.backgroundFraction } ?? false
    }

    /// The OKLab hue angles the subject has: of each colored marker that lies mostly on the subject, or else of the
    /// subject's mean color. Empty when the subject has no color of its own.
    var subjectHueAngles: [Double] {
        let fractions = subjectFractions
        let angles = markers.indices.compactMap { index -> Double? in
            let color = markers[index].color
            guard fractions.indices.contains(index), fractions[index] >= 0.5, color.chroma >= DxOMapping.neutralChroma else { return nil }
            let lab = color.oklab
            return ColorMath.normalizeDegrees(Double(atan2(lab.z, lab.y)) * 180 / .pi)
        }
        if !angles.isEmpty { return angles }
        return separation?.subjectHueAngle.map { [$0] } ?? []
    }

    /// The hue shift (sRGB degrees) that sets a background color further apart from the nearest hue of the subject; nil for
    /// subject colors, greys, protected colors and background colors that are far enough already.
    func separationShift(for marker: Marker) -> Double? {
        guard marker.color.chroma >= DxOMapping.neutralChroma, !isProtected(marker), isBackground(marker) else { return nil }
        let lab = marker.color.oklab
        let angle = ColorMath.normalizeDegrees(Double(atan2(lab.z, lab.y)) * 180 / .pi)
        guard let nearest = subjectHueAngles.min(by: {
            abs(ColorMath.signedAngle(from: $0, to: angle)) < abs(ColorMath.signedAngle(from: $1, to: angle))
        }) else { return nil }
        let hue = marker.color.hsb.h
        let shift = ColorMath.signedAngle(from: hue, to: SeparationCheck.separatedHue(of: marker.color, fromSubjectAngle: nearest))
        return abs(shift) < 0.5 ? nil : shift
    }
}
