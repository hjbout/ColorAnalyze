import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

@MainActor
extension AnalysisModel {
    // MARK: DxO Color Grading

    /// What the suggested Color Grading preset aims at.
    enum GradingTarget: String, CaseIterable, Identifiable {
        /// Toward the harmony's target hues.
        case harmony
        /// Toward the matching colors of the series palette.
        case series
        /// Strengthen the faint tint each tonal range already has (for photos without real colors).
        case emphasize
        var id: String { rawValue }
    }

    /// Sets the strength for this run only (command line); the remembered preference is left alone.
    func useGradingStrength(_ strength: ColorGradingSuggestion.Strength) {
        rememberGradingStrength = false
        gradingStrength = strength
        rememberGradingStrength = true
    }
    /// The style the intention points to (*warme avond* → warm highlights), when it is not the one chosen.
    var intentionStyle: (style: GradingStyle, words: [String])? {
        guard let suggestion = Intention.suggestedStyle(for: intention), suggestion.style != gradingStyle else { return nil }
        return suggestion
    }

    /// The style the grading really uses: none at an amount of 0.
    var appliedStyle: GradingStyle { gradingStyleAmount > 0 ? gradingStyle : .neutral }

    /// With a style the amount scales the style's cast; with Neutral it scales the whole grading.
    var styleCastAmount: Double { gradingStyle == .neutral ? 1 : gradingStyleAmount }
    var gradingScale: Double { gradingStyle == .neutral ? gradingStyleAmount : 1 }

    /// Where the grading really aims: the series palette only when it is available and shown, and the
    /// existing tints when there is no harmony to aim at (a photo of fog, dusk or in black and white).
    var effectiveGradingTarget: GradingTarget {
        switch gradingTarget {
        case .emphasize: return .emphasize
        case .series where isSeriesReferenceShown: return .series
        default: return harmony == nil ? .emphasize : .harmony
        }
    }

    /// True when "Harmony" or "Series" was chosen but the grading falls back to the existing tints.
    var gradingFallsBackToTints: Bool {
        gradingTarget != .emphasize && effectiveGradingTarget == .emphasize
    }

    /// Per tonal range, the tint that brings the photo's colors closest to the harmony (or the series palette), found with
    /// the calibrated model of PhotoLab's Color Grading. The result is kept until something it depends on changes.
    var colorGrading: ColorGradingSuggestion.Suggestion? {
        let key = suggestionKey
        if let cache = gradingCache, cache.key == key { return cache.grading }
        let grading = computeColorGrading()
        gradingCache = (key, grading)
        return grading
    }

    /// Everything the suggestion depends on, as one number: the markers, the harmony and the aim.
    var suggestionKey: Int {
        var hasher = Hasher()
        for marker in markers {
            hasher.combine(marker.color.hex)
            hasher.combine(Int((marker.share * 10_000).rounded()))
            hasher.combine(isProtected(marker))
            hasher.combine(marker.targetHue)
        }
        hasher.combine(harmonyChoice?.rawValue)
        hasher.combine(harmonyRotationOverride)
        hasher.combine(hueSpace.rawValue)
        hasher.combine(harmonySector.rawValue)
        hasher.combine(gradingStrength.rawValue)
        hasher.combine(gradingStyle.rawValue)
        hasher.combine(gradingStyleAmount)
        hasher.combine(gradingTarget.rawValue)
        hasher.combine(isSeriesReferenceShown)
        hasher.combine(referencePhoto?.url.path)
        for color in seriesPalette { hasher.combine(color.color.hex) }
        return hasher.finalize()
    }

    func computeColorGrading() -> ColorGradingSuggestion.Suggestion? {
        guard !markers.isEmpty else { return nil }
        var inputs: [ColorGradingSuggestion.Input] = []
        switch effectiveGradingTarget {
        case .emphasize:
            return ColorGradingSuggestion.optimizedEmphasis(markers.map { ($0.color, $0.share) }, strength: gradingStrength, style: appliedStyle, styleAmount: styleCastAmount, scale: gradingScale)
        case .harmony:
            guard let fit = harmony else { return nil }
            inputs = markers.map {
                let hue = $0.color.hsb.h
                if let target = $0.targetHue { return .init(color: $0.color, share: $0.share, targetHue: target) }
                return .init(color: $0.color, share: $0.share, targetHue: isProtected($0) ? hue : hue + fit.shift(for: hue))
            }
        case .series:
            for marker in markers {
                if marker.color.chroma < DxOMapping.neutralChroma {
                    // Greys have no target, but the grading must not tint them.
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h))
                } else if let target = marker.targetHue {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: target))
                } else if isProtected(marker) {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h))
                } else if let shift = seriesMatch(for: marker)?.hueShift {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h + shift))
                }
            }
        }
        return ColorGradingSuggestion.optimized(from: inputs, strength: gradingStrength, style: appliedStyle, styleAmount: styleCastAmount, scale: gradingScale)
    }

    /// Per channel of PhotoLab's HSL tool, how far its Hue handle should turn (degrees on PhotoLab's ring;
    /// + = counter-clockwise), aimed like the Color Grading suggestion: at the harmony or at the reference
    /// palette. Nothing when the grading only strengthens the existing tints: there is no target to turn toward.
    var hslSuggestions: [HSLSuggestion.Channel] {
        guard !markers.isEmpty else { return [] }
        let aim = effectiveGradingTarget
        let fit = harmony
        return HSLSuggestion.channels(from: markers.enumerated().map { index, marker in
            let target: Double? = switch aim {
            case .harmony: fit?.shift(for: marker.color.hsb.h)
            case .series: seriesMatch(for: marker)?.hueShift
            case .emphasize: nil
            }
            let shift = (aim == .emphasize ? nil : marker.manualShift() ?? (isProtected(marker) ? nil : target)).map { $0 * gradingScale }
            return HSLSuggestion.Input(number: index + 1, color: marker.color, share: marker.share, hueShift: shift)
        })
    }
}
