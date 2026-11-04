import Foundation

/// Steers the grading toward the contrasts an intention asks for (`Intention.contrastAims`): of every style, a few levels of
/// HSL Saturation and, for light–dark, a few tone curves of the Light palette, the combination is chosen whose predicted
/// contrast profile comes closest to the aims, with the least change. The prediction is the calibrated model of PhotoLab (`GradePreview`) applied to a
/// sample of the photo's pixels.
///
/// What it can move: warm–cool and complementary (the styles' casts), saturation and extension (HSL Saturation per
/// channel), hue a little (the monochrome style), and light–dark both ways: an S-curve of Selective Tone (darker Blacks and
/// Shadows, lighter Highlights and Whites) or Contrast up, the reverse or the faded style down.
public enum ContrastSteering {
    /// One combination of levers.
    public struct Option: Sendable, Equatable {
        public var style: GradingStyle
        /// HSL Saturation per channel (-100...100).
        public var saturation: [DxOChannel: Double]
        /// The Light palette: added to the style's Selective Tone, and Contrast.
        public var tone: Tone

        public init(style: GradingStyle, saturation: [DxOChannel: Double] = [:], tone: Tone = Tone()) {
            self.style = style
            self.saturation = saturation
            self.tone = tone
        }
    }

    /// Sliders of PhotoLab's Light palette (-100...100).
    public struct Tone: Sendable, Equatable {
        public var blacks = 0.0, shadows = 0.0, highlights = 0.0, whites = 0.0, contrast = 0.0

        public init(blacks: Double = 0, shadows: Double = 0, highlights: Double = 0, whites: Double = 0, contrast: Double = 0) {
            self.blacks = blacks
            self.shadows = shadows
            self.highlights = highlights
            self.whites = whites
            self.contrast = contrast
        }

        public var isNeutral: Bool { self == Tone() }
        var size: Double { [blacks, shadows, highlights, whites, contrast].map(abs).max() ?? 0 }

        /// The settings with these sliders on top of their own Selective Tone.
        public func applied(to settings: GradePreviewSettings) -> GradePreviewSettings {
            var s = settings
            func clamp(_ v: Double) -> Double { max(-100, min(100, v)) }
            s.toneBlacks = clamp(s.toneBlacks + blacks)
            s.toneShadows = clamp(s.toneShadows + shadows)
            s.toneHighlights = clamp(s.toneHighlights + highlights)
            s.toneWhites = clamp(s.toneWhites + whites)
            s.contrast = clamp(s.contrast + contrast)
            return s
        }

        /// The S-curve that stretches the tonal range, as measured in `calibration/exports/T-scurve`, times `k`.
        static func sCurve(_ k: Double) -> Tone { Tone(blacks: -40 * k, shadows: -20 * k, highlights: 30 * k, whites: 20 * k) }

        func with(contrast: Double) -> Tone {
            var t = self
            t.contrast = contrast
            return t
        }
    }

    /// The tone curves to try for light–dark: S-curves and Contrast up for a strong one, the reverse for a weak one.
    public static func tonePlans(aims: [ContrastProfile.Kind: Intention.ContrastAim]) -> [Tone] {
        switch aims[.lightDark] {
        case .high: return [Tone(), .sCurve(0.5), .sCurve(1), .sCurve(1.5), Tone(contrast: 30), Tone(contrast: 60), Tone.sCurve(1).with(contrast: 30)]
        case .low: return [Tone(), .sCurve(-0.5), .sCurve(-1), Tone(contrast: -40)]
        case nil: return [Tone()]
        }
    }

    /// A style's grading as preview settings, with the weighted hue distance of the colors to their targets after it.
    public struct Candidate: Sendable {
        public var style: GradingStyle
        public var settings: GradePreviewSettings
        public var hueFitAfter: Double?

        public init(style: GradingStyle, settings: GradePreviewSettings, hueFitAfter: Double?) {
            self.style = style
            self.settings = settings
            self.hueFitAfter = hueFitAfter
        }
    }

    public struct Result: Sendable, Equatable {
        public var option: Option
        /// Strengths of the asked contrasts in the photo, and as predicted with the option.
        public var before: [ContrastProfile.Kind: Double]
        public var after: [ContrastProfile.Kind: Double]
    }

    /// How far a strength is from what is asked: 0 once it is there (see `ContrastProfile.status`).
    public static func gap(_ strength: Double, toward aim: Intention.ContrastAim) -> Double {
        aim == .high ? max(0, 0.6 - strength) : max(0, strength - 0.35)
    }

    /// The HSL Saturation plans to try, from none to strong: lower all channels for a low saturation, raise them for a high
    /// one, lower all but the accent's channel for a strong extension, and the accent's for a weak one. Protected channels
    /// (skin, colors locked by hand) are left alone.
    public static func saturationPlans(aims: [ContrastProfile.Kind: Intention.ContrastAim], channels: Set<DxOChannel>,
                                       protected: Set<DxOChannel>, accent: DxOChannel?) -> [[DxOChannel: Double]] {
        let free = channels.subtracting(protected).subtracting([.neutral])
        guard aims[.saturation] != nil || aims[.extension] != nil, !free.isEmpty else { return [[:]] }
        return [[:]] + [10.0, 20, 30].map { level in
            var plan: [DxOChannel: Double] = [:]
            for channel in free {
                var value = 0.0
                switch aims[.saturation] {
                case .low: value -= level
                case .high: value += level
                case nil: break
                }
                switch aims[.extension] {
                case .high where channel != accent: value -= level
                case .low where channel == accent: value -= level
                default: break
                }
                if value != 0 { plan[channel] = max(-60, min(60, value)) }
            }
            return plan
        }
    }

    /// The best option for `aims`, judged on `lab` (a sample of the photo's OKLab pixels). `candidates` are the styles'
    /// gradings; the hue fit of `.neutral` is the reference a style may cost some of.
    public static func choose(candidates: [Candidate], lab: [SIMD3<Float>], aims: [ContrastProfile.Kind: Intention.ContrastAim],
                              saturationPlans: [[DxOChannel: Double]], tonePlans: [Tone] = [Tone()]) -> Result? {
        guard !candidates.isEmpty, !aims.isEmpty, !lab.isEmpty else { return nil }
        let photo = ContrastProfile(lab: lab)
        let reference = candidates.first { $0.style == .neutral }?.hueFitAfter
        var best: (score: Double, option: Option, profile: ContrastProfile)?
        for candidate in candidates {
            for plan in saturationPlans {
                for tone in tonePlans {
                    var settings = tone.applied(to: candidate.settings)
                    settings.hslSaturation = plan
                    let grade = GradePreview.Plan(settings)
                    let profile = ContrastProfile(lab: lab.map { grade.apply($0) })
                    var score = 0.0
                    for (kind, aim) in aims {
                        let g = gap(profile.strength(kind), toward: aim)
                        score += 10 * g * g
                    }
                    // Prefer the least change: a style that costs hue accuracy, saturation, tone, any style at all.
                    if let fit = candidate.hueFitAfter, let reference { score += 0.004 * max(0, fit - reference) }
                    score += 0.0005 * (plan.values.map(abs).max() ?? 0)
                    score += 0.0003 * tone.size
                    if candidate.style != .neutral { score += 0.004 }
                    if best == nil || score < best!.score - 1e-9 {
                        best = (score, Option(style: candidate.style, saturation: plan, tone: tone), profile)
                    }
                }
            }
        }
        guard let best else { return nil }
        return Result(option: best.option,
                      before: aims.keys.reduce(into: [:]) { $0[$1] = photo.strength($1) },
                      after: aims.keys.reduce(into: [:]) { $0[$1] = best.profile.strength($1) })
    }

    /// About `count` pixels of `lab`, evenly spread.
    public static func sample(_ lab: [SIMD3<Float>], count: Int = 4000) -> [SIMD3<Float>] {
        let step = max(1, lab.count / max(1, count))
        return stride(from: 0, to: lab.count, by: step).map { lab[$0] }
    }
}
