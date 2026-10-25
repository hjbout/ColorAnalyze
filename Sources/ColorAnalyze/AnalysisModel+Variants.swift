import CoreGraphics
import ColorCore
import Foundation

/// A pinned grading setup: the choices that steer the suggestion, with the fit it predicted when it was pinned.
struct GradeVariant: Identifiable, Equatable {
    let id = UUID()
    var style: GradingStyle
    var amount: Double
    var target: AnalysisModel.GradingTarget
    var harmony: HarmonyKind?
    var harmonyRotation: Double?
    /// The color wheel the harmony is computed on.
    var hueSpace: HueSpace
    var fitBefore: Double?
    var fitAfter: Double?

    init(style: GradingStyle, amount: Double, target: AnalysisModel.GradingTarget, harmony: HarmonyKind?,
         harmonyRotation: Double? = nil, hueSpace: HueSpace = .rgb, fitBefore: Double? = nil, fitAfter: Double? = nil) {
        self.hueSpace = hueSpace
        self.style = style
        self.amount = amount
        self.target = target
        self.harmony = harmony
        self.harmonyRotation = harmonyRotation
        self.fitBefore = fitBefore
        self.fitAfter = fitAfter
    }

    init?(session: Session.Variant) {
        guard let style = GradingStyle(rawValue: session.style),
              let target = AnalysisModel.GradingTarget(rawValue: session.target) else { return nil }
        self.init(style: style, amount: session.amount, target: target, harmony: session.harmony.flatMap(HarmonyKind.init(rawValue:)),
                  harmonyRotation: session.harmonyRotation,
                  hueSpace: session.hueSpace.flatMap(HueSpace.init(rawValue:)) ?? .rgb, fitBefore: session.fitBefore, fitAfter: session.fitAfter)
    }

    var session: Session.Variant {
        .init(style: style.rawValue, amount: amount, target: target.rawValue, harmony: harmony?.rawValue,
              harmonyRotation: harmonyRotation, hueSpace: hueSpace == .rgb ? nil : hueSpace.rawValue,
              fitBefore: fitBefore, fitAfter: fitAfter)
    }

    /// The style's name without a parenthetical ("Teal & orange (cinematic)" → "Teal & orange").
    var title: String {
        style.displayName.components(separatedBy: " (").first ?? style.displayName
    }

    /// True when `other` steers the suggestion the same way (the fit it predicted does not count).
    func sameSetup(as other: GradeVariant) -> Bool {
        style == other.style && abs(amount - other.amount) < 0.001 && target == other.target && harmony == other.harmony
            && harmonyRotation == other.harmonyRotation && hueSpace == other.hueSpace
    }
}

/// What a variant looks like on this photo, as the calibrated model predicts PhotoLab renders it.
struct VariantPreview {
    var image: CGImage?
    var fitBefore: Double?
    var fitAfter: Double?
    /// Parts of the suggestion that lie outside what was measured.
    var caveats: [String]
}

@MainActor
extension AnalysisModel {
    // MARK: Grading variants

    /// The choices the suggestion is built from right now, without the fit.
    var currentChoices: GradeVariant {
        GradeVariant(style: gradingStyle, amount: gradingAmount, target: gradingTarget, harmony: harmonyChoice,
                     harmonyRotation: harmonyRotationOverride, hueSpace: hueSpace)
    }

    /// The setup the suggestion is built from right now.
    var currentSetup: GradeVariant {
        var setup = currentChoices
        let fit = colorGrading?.fit
        setup.fitBefore = fit?.before
        setup.fitAfter = fit?.after
        return setup
    }

    /// The pinned variant the current setup equals, if any.
    var activeVariantID: GradeVariant.ID? {
        let setup = currentChoices
        return variants.first { $0.sameSetup(as: setup) }?.id
    }

    /// Pins the current setup. One that is pinned already is only reported.
    func pinCurrentVariant() {
        guard colorGrading != nil else { return }
        if let id = activeVariantID, let index = variants.firstIndex(where: { $0.id == id }) {
            showNotice("Already pinned as variant \(index + 1)")
            return
        }
        variants.append(currentSetup)
        isDirty = true
        showNotice("Pinned as variant \(variants.count)")
    }

    func applyVariant(_ id: GradeVariant.ID) {
        guard let variant = variants.first(where: { $0.id == id }) else { return }
        gradingStyle = variant.style
        gradingAmount = variant.amount
        gradingTarget = variant.target
        if hueSpace != variant.hueSpace { hueSpace = variant.hueSpace }   // resets the rotation
        if harmonyChoice != variant.harmony { harmonyChoice = variant.harmony }   // resets the rotation
        harmonyRotationOverride = variant.harmonyRotation
    }

    /// Steps through the pinned variants (-1 = previous, 1 = next), wrapping around.
    func stepVariant(_ offset: Int) {
        guard !variants.isEmpty else { return }
        let current = variants.firstIndex { $0.id == activeVariantID }
        let next = current.map { ($0 + offset + variants.count) % variants.count } ?? (offset > 0 ? 0 : variants.count - 1)
        applyVariant(variants[next].id)
    }

    /// Replaces a variant by the current setup.
    func updateVariant(_ id: GradeVariant.ID) {
        guard let index = variants.firstIndex(where: { $0.id == id }) else { return }
        variants[index] = currentSetup
        isDirty = true
    }

    func removeVariant(_ id: GradeVariant.ID) {
        variants.removeAll { $0.id == id }
        if variants.isEmpty { showVariantGrid = false }
        isDirty = true
    }

    // MARK: Previews of the variants

    /// Changes whenever a variant's preview has to be made again: the photo, the markers, a variant, the size.
    var variantPreviewKey: Int {
        var hasher = Hasher()
        hasher.combine(image?.url)
        hasher.combine(markersKey)
        hasher.combine(variantGridSize)
        for variant in variants {
            hasher.combine(variant.id)
            hasher.combine(variant.style.rawValue)
            hasher.combine(variant.amount)
            hasher.combine(variant.target.rawValue)
            hasher.combine(variant.harmony?.rawValue)
            hasher.combine(variant.harmonyRotation)
            hasher.combine(variant.hueSpace.rawValue)
        }
        return hasher.finalize()
    }

    /// Longest side of the variant previews: small for the strip, larger for the grid.
    var variantGridSize: Int { showVariantGrid ? 900 : 300 }

    /// Makes the preview of every variant (and of the original, which has none). Meant to run from a `.task(id:)`, so
    /// a change cancels it; the wait lets a drag of a marker come to rest first.
    func refreshVariantPreviews() async {
        guard let image, !variants.isEmpty else {
            variantPreviews = [:]
            return
        }
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        let display = image.display
        let size = variantGridSize
        let buffer: PixelBuffer
        if let source = variantSource, source.image === display, source.size == size {
            buffer = source.buffer
        } else {
            buffer = await Task.detached(priority: .utility) { PixelBuffer(image: display, maxDimension: size) }.value
            variantSource = (display, size, buffer)
        }
        var made: [GradeVariant.ID: VariantPreview] = [:]
        for variant in variants {
            guard !Task.isCancelled else { return }
            let grading = computeColorGrading(for: variant)
            guard let grading else {
                made[variant.id] = VariantPreview(image: nil, fitBefore: nil, fitAfter: nil, caveats: [])
                continue
            }
            let settings = gradeSettings(for: variant, grading: grading)
            let rendered = await Task.detached(priority: .utility) { GradePreview.render(buffer, settings: settings) }.value
            made[variant.id] = VariantPreview(image: rendered, fitBefore: grading.fit?.before, fitAfter: grading.fit?.after,
                                              caveats: settings.modelCaveats)
        }
        guard !Task.isCancelled else { return }
        variantPreviews = made
    }
}
