import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

/// The harmonies found for one set of colors and one sector width.
struct HarmonyMemo {
    struct Key: Hashable {
        var choice: HarmonyKind?
        var rotation: Double?
        var space: HueSpace
    }
    var inputs: [HarmonyInput] = []
    var tolerance = 0.0
    var detected: [HueSpace: HarmonyKind?] = [:]
    var fits: [Key: HarmonyFit?] = [:]
}

@MainActor
extension AnalysisModel {
    // MARK: White balance

    /// Color cast of the nearly neutral parts of the whole photo (not subject-weighted: a cast is a property of the light).
    var whiteBalance: WhiteBalanceCheck {
        guard let image else { return WhiteBalanceCheck(neutralShare: 0, cast: 0, a: 0, b: 0) }
        let key = "\(image.url.path)|\(image.analysis.width)x\(image.analysis.height)"
        if let cache = whiteBalanceCache, cache.key == key { return cache.check }
        let check = WhiteBalanceCheck.check(image.analysis)
        whiteBalanceCache = (key, check)
        return check
    }

    // MARK: Harmony

    var harmonyInputs: [HarmonyInput] {
        markers.map {
            HarmonyInput(hue: $0.color.hsb.h, weight: DxOMapping.harmonyWeight(color: $0.color, share: $0.share))
        }
    }

    var harmony: HarmonyFit? { harmonyFit(choice: harmonyChoice, rotation: harmonyRotationOverride, space: hueSpace) }

    /// The harmony of the markers for a chosen kind (nil = detect), rotation (nil = the best fit) and color wheel.
    /// Remembered for the current colors: the views ask for it many times per frame, and detecting tries every rotation of
    /// every kind.
    func harmonyFit(choice: HarmonyKind?, rotation rotationOverride: Double?, space hueSpace: HueSpace) -> HarmonyFit? {
        let inputs = harmonyInputs
        let tolerance = harmonySector
        if harmonyMemo.inputs != inputs || harmonyMemo.tolerance != tolerance {
            harmonyMemo = HarmonyMemo(inputs: inputs, tolerance: tolerance)
        }
        let key = HarmonyMemo.Key(choice: choice, rotation: rotationOverride, space: hueSpace)
        if let known = harmonyMemo.fits[key] { return known }
        let fit = findHarmony(choice: choice, rotation: rotationOverride, space: hueSpace, inputs: inputs, tolerance: tolerance)
        harmonyMemo.fits[key] = .some(fit)
        return fit
    }

    private func findHarmony(choice: HarmonyKind?, rotation rotationOverride: Double?, space hueSpace: HueSpace,
                             inputs: [HarmonyInput], tolerance: Double) -> HarmonyFit? {
        guard let kind = choice ?? detectedHarmony(inputs: inputs, space: hueSpace, tolerance: tolerance) else { return nil }
        if let rotation = rotationOverride {
            return HarmonyDetector.evaluate(kind, rotation: rotation, inputs: inputs, space: hueSpace, tolerance: tolerance)
                ?? HarmonyFit(kind: kind, rotation: rotation, deviation: 0, space: hueSpace, tolerance: tolerance)
        }
        return HarmonyDetector.fit(kind, to: inputs, space: hueSpace, tolerance: tolerance)
            ?? HarmonyFit(kind: kind, rotation: 0, deviation: 0, space: hueSpace, tolerance: tolerance)
    }

    /// The kind that fits the current colors best: it does not change while the harmony is rotated by hand.
    private func detectedHarmony(inputs: [HarmonyInput], space: HueSpace, tolerance: Double) -> HarmonyKind? {
        if let known = harmonyMemo.detected[space] { return known }
        let kind = HarmonyDetector.detect(inputs, space: space, tolerance: tolerance)?.kind
        harmonyMemo.detected[space] = .some(kind)
        return kind
    }

    /// How well the graded version matches the same harmony targets as the original.
    var afterHarmony: HarmonyFit? {
        guard hasAfterColors, let fit = harmony else { return nil }
        let inputs = markers.compactMap { marker in
            afterColor(for: marker).map {
                HarmonyInput(hue: $0.hsb.h, weight: DxOMapping.harmonyWeight(color: $0, share: marker.share))
            }
        }
        return HarmonyDetector.evaluate(fit.kind, rotation: fit.rotation, inputs: inputs, space: fit.space, tolerance: fit.tolerance)
    }
}
