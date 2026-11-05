import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

/// A search for a grading with everything it needs from the markers, so it can run off the main thread.
struct GradingRequest: Sendable {
    enum Aim: Sendable {
        case emphasis([(color: SRGBColor, share: Double)])
        case hues([ColorGradingSuggestion.Input], guardingGreys: Bool)
    }
    var aim: Aim
    var strength: ColorGradingSuggestion.Strength
    var style: GradingStyle
    var scale: Double

    func run() -> ColorGradingSuggestion.Suggestion {
        switch aim {
        case .emphasis(let colors):
            ColorGradingSuggestion.optimizedEmphasis(colors, strength: strength, style: style, scale: scale)
        case .hues(let inputs, let guardingGreys):
            ColorGradingSuggestion.optimized(from: inputs, strength: strength, style: style, scale: scale, guardingGreys: guardingGreys)
        }
    }
}

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
        /// Push the background's hues away from the subject's, so the subject stands apart (`SeparationCheck`).
        case separation
        var id: String { rawValue }
    }

    /// The style the intention points to (*warme avond* → warm highlights), when it is not the one chosen.
    var intentionStyle: (style: GradingStyle, words: [String])? {
        guard let suggestion = Intention.suggestedStyle(for: intention), suggestion.style != gradingStyle else { return nil }
        return suggestion
    }

    /// The optimizer's saturation limit: the amount scales the grading it finds, so 1 is Moderate and 3 more than Strong.
    var gradingStrength: ColorGradingSuggestion.Strength { .moderate }

    /// Where the grading really aims: the series palette only when it is available and shown, and the
    /// existing tints when there is no harmony to aim at (a photo of fog, dusk or in black and white).
    var effectiveGradingTarget: GradingTarget { effectiveTarget(gradingTarget, harmony: harmony) }

    func effectiveTarget(_ target: GradingTarget, harmony: HarmonyFit?) -> GradingTarget {
        switch target {
        case .emphasize: return .emphasize
        case .series where isSeriesReferenceShown: return .series
        case .separation where !subjectHueAngles.isEmpty: return .separation
        default: return harmony == nil ? .emphasize : .harmony
        }
    }

    /// True when "Harmony" or "Series" was chosen but the grading falls back to the existing tints.
    var gradingFallsBackToTints: Bool {
        gradingTarget != .emphasize && gradingTarget != .separation && effectiveGradingTarget == .emphasize
    }

    /// True when "Separation" was chosen but there is no subject with a color of its own to stand apart from.
    var separationFallsBack: Bool { gradingTarget == .separation && effectiveGradingTarget != .separation }

    /// Per tonal range, the tint that brings the photo's colors closest to the harmony (or the series palette), found with
    /// the calibrated model of PhotoLab's Color Grading. The result is kept until something it depends on changes.
    var colorGrading: ColorGradingSuggestion.Suggestion? {
        let key = suggestionKey
        if let cache = gradingCache, cache.key == key { return cache.grading }
        let grading = computeColorGrading(for: currentChoices)
        gradingCache = (key, grading)
        return grading
    }

    /// Everything the suggestion depends on, as one number: the markers, the harmony and the aim.
    var suggestionKey: Int {
        var hasher = Hasher()
        hasher.combine(markersKey)
        hasher.combine(harmonyChoice?.rawValue)
        hasher.combine(harmonyRotationOverride)
        hasher.combine(effectiveStyle.rawValue)
        if let option = activeSteering?.option {
            hasher.combine(option.tone.blacks)
            hasher.combine(option.tone.shadows)
            hasher.combine(option.tone.highlights)
            hasher.combine(option.tone.whites)
            hasher.combine(option.tone.contrast)
            for (channel, value) in option.saturation.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                hasher.combine(channel.rawValue)
                hasher.combine(value)
            }
        }
        hasher.combine(gradingAmount)
        hasher.combine(gradingTarget.rawValue)
        return hasher.finalize()
    }

    /// What every grading setup depends on, whatever its style, amount, aim and harmony: the markers, the wheel, the sector
    /// and the series or reference palette.
    var markersKey: Int {
        var hasher = Hasher()
        func combine(_ color: SRGBColor) {
            let rgb = color.rgb255
            hasher.combine(rgb.r)
            hasher.combine(rgb.g)
            hasher.combine(rgb.b)
        }
        for marker in markers {
            combine(marker.color)
            hasher.combine(Int((marker.share * 10_000).rounded()))
            hasher.combine(isProtected(marker))
            hasher.combine(marker.targetHue)
            hasher.combine(marker.referenceIndex)
        }
        hasher.combine(hueSpace.rawValue)
        hasher.combine(harmonySector)
        hasher.combine(isSeriesReferenceShown)
        hasher.combine(referencePhoto?.url.path)
        hasher.combine(separationSubjectMap != nil)
        hasher.combine(foregroundMask != nil)
        for color in seriesPalette { combine(color.color) }
        return hasher.finalize()
    }

    func computeColorGrading(for setup: GradeVariant) -> ColorGradingSuggestion.Suggestion? {
        gradingRequest(for: setup)?.run()
    }

    /// What the grading of a setup is found from; nil when there is nothing to aim at.
    func gradingRequest(for setup: GradeVariant) -> GradingRequest? {
        let markers = markers
        guard !markers.isEmpty else { return nil }
        var inputs: [ColorGradingSuggestion.Input] = []
        let harmony = harmonyFit(choice: setup.harmony, rotation: setup.harmonyRotation, space: setup.hueSpace)
        switch effectiveTarget(setup.target, harmony: harmony) {
        case .emphasize:
            return GradingRequest(aim: .emphasis(markers.map { ($0.color, $0.share) }), strength: gradingStrength, style: setup.style, scale: setup.amount)
        case .harmony:
            guard let fit = harmony else { return nil }
            inputs = markers.map {
                let hue = $0.color.hsb.h
                if let target = $0.targetHue { return .init(color: $0.color, share: $0.share, targetHue: target) }
                return .init(color: $0.color, share: $0.share, targetHue: isProtected($0) ? hue : hue + fit.shift(for: hue),
                             isProtected: isProtected($0))
            }
        case .series:
            for marker in markers {
                if marker.color.chroma < DxOMapping.neutralChroma {
                    // Greys have no target, but the grading must not tint them.
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h))
                } else if let target = marker.targetHue {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: target))
                } else if isProtected(marker) {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h, isProtected: true))
                } else if let shift = seriesMatch(for: marker)?.hueShift {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h + shift))
                }
            }
        case .separation:
            inputs = markers.map { marker in
                let hue = marker.color.hsb.h
                if let target = marker.targetHue { return .init(color: marker.color, share: marker.share, targetHue: target) }
                if let shift = separationShift(for: marker) {
                    return .init(color: marker.color, share: marker.share, targetHue: hue + shift)
                }
                return .init(color: marker.color, share: marker.share, targetHue: hue, isProtected: separationHolds(marker))
            }
            return GradingRequest(aim: .hues(inputs, guardingGreys: true), strength: gradingStrength, style: setup.style, scale: setup.amount)
        }
        return GradingRequest(aim: .hues(inputs, guardingGreys: false), strength: gradingStrength, style: setup.style, scale: setup.amount)
    }

    /// Per channel of PhotoLab's HSL tool, how far its Hue handle should turn (degrees on PhotoLab's ring;
    /// + = counter-clockwise), aimed like the Color Grading suggestion: at the harmony or at the reference
    /// palette. Nothing when the grading only strengthens the existing tints: there is no target to turn toward.
    var hslSuggestions: [HSLSuggestion.Channel] { hslSuggestions(for: currentChoices) }

    func hslSuggestions(for setup: GradeVariant) -> [HSLSuggestion.Channel] {
        HSLSuggestion.channels(from: hslInputs(for: setup))
    }

    /// The HSL channels the Separation aim leaves alone although the background wants them turned: the subject has colors there.
    var separationBlockedChannels: [DxOChannel] {
        effectiveGradingTarget == .separation ? HSLSuggestion.blockedChannels(from: hslInputs(for: currentChoices)) : []
    }

    private func hslInputs(for setup: GradeVariant) -> [HSLSuggestion.Input] {
        let markers = markers
        guard !markers.isEmpty else { return [] }
        let fit = harmonyFit(choice: setup.harmony, rotation: setup.harmonyRotation, space: setup.hueSpace)
        let aim = effectiveTarget(setup.target, harmony: fit)
        return markers.enumerated().map { index, marker in
            let target: Double? = switch aim {
            case .harmony: fit?.shift(for: marker.color.hsb.h)
            case .series: seriesMatch(for: marker)?.hueShift
            case .separation: separationShift(for: marker)
            case .emphasize: nil
            }
            // Less than 1 turns part of the way; more than 1 would only turn the color past its target.
            let shift = (aim == .emphasize ? nil : marker.manualShift() ?? (isProtected(marker) ? nil : target)).map { $0 * min(setup.amount, 1) }
            return HSLSuggestion.Input(number: index + 1, color: marker.color, share: marker.share, hueShift: shift,
                                       holds: aim == .separation && shift == nil && separationHolds(marker))
        }
    }
}
