import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

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

    /// What would neutralize the cast, nil when there is none to correct.
    var whiteBalanceCorrection: WhiteBalanceCorrection? { whiteBalance.correction }

    /// The correction the preview applies: the suggested one while "Show in the preview" is on.
    var previewedWhiteBalance: WhiteBalanceCorrection? { previewWhiteBalance && afterImage == nil ? whiteBalanceCorrection : nil }

    /// The Temperature PhotoLab shows now: as typed in, else 5500 K. macOS reads another As Shot value from a RAW than
    /// PhotoLab shows (4974 K against 5694 K on the test photo), so it is no use as a default.
    var currentTemperature: Double {
        get { typedTemperature ?? 5500 }
        set { typedTemperature = min(50_000, max(2_000, newValue.rounded())) }
    }

    /// The markers as the grading sees them: with the white balance correction applied while it is shown in the preview,
    /// because PhotoLab corrects the white balance before it grades, so the grading must aim the corrected colors.
    var gradingMarkers: [Marker] {
        guard let correction = previewedWhiteBalance else { return markers }
        return markers.map { marker in
            var corrected = marker
            corrected.color = SRGBColor(linear: correction.apply(marker.color.linear)).clamped
            return corrected
        }
    }

    // MARK: Harmony

    var harmonyInputs: [HarmonyInput] {
        gradingMarkers.map {
            HarmonyInput(hue: $0.color.hsb.h, weight: DxOMapping.harmonyWeight(color: $0.color, share: $0.share))
        }
    }

    var harmony: HarmonyFit? { harmonyFit(choice: harmonyChoice, rotation: harmonyRotationOverride, space: hueSpace) }

    /// The harmony of the markers for a chosen kind (nil = detect), rotation (nil = the best fit) and color wheel.
    func harmonyFit(choice: HarmonyKind?, rotation rotationOverride: Double?, space hueSpace: HueSpace) -> HarmonyFit? {
        let inputs = harmonyInputs
        let tolerance = harmonySector
        let kind = choice ?? HarmonyDetector.detect(inputs, space: hueSpace, tolerance: tolerance)?.kind
        guard let kind else { return nil }
        if let rotation = rotationOverride {
            return HarmonyDetector.evaluate(kind, rotation: rotation, inputs: inputs, space: hueSpace, tolerance: tolerance)
                ?? HarmonyFit(kind: kind, rotation: rotation, deviation: 0, space: hueSpace, tolerance: tolerance)
        }
        return HarmonyDetector.fit(kind, to: inputs, space: hueSpace, tolerance: tolerance)
            ?? HarmonyFit(kind: kind, rotation: 0, deviation: 0, space: hueSpace, tolerance: tolerance)
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
