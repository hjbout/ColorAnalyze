import Foundation

/// A DxO PhotoLab *Color Grading* preset: the four wheels of the Color Grading tool plus the balance.
///
/// The text format is the one PhotoLab 10 writes itself (a Lua-style table, tabs for indentation, one
/// `Settings.Base` block with only the keys the preset sets); `luaText()` reproduces a preset saved by
/// PhotoLab byte for byte. Hue is in degrees on DxO's hue axis (see `DxOHue`), saturation 0...100,
/// luminance -100...100.
public struct ColorGradingPreset: Sendable, Equatable {
    public struct Wheel: Sendable, Equatable {
        public var hue: Int
        public var saturation: Int
        public var luminance: Int

        public static let neutral = Wheel(hue: 0, saturation: 0, luminance: 0)

        public init(hue: Int, saturation: Int, luminance: Int) {
            self.hue = hue
            self.saturation = saturation
            self.luminance = luminance
        }
    }

    /// `Version` PhotoLab 10.1 writes into presets.
    public static let fileVersion = "21.0"
    /// File extension of PhotoLab presets.
    public static let fileExtension = "preset"

    public var master = Wheel.neutral
    public var shadows = Wheel.neutral
    public var midtones = Wheel.neutral
    public var highlights = Wheel.neutral
    /// -100...100: shifts the boundary between the shadows and highlights wheels.
    public var balance = 0

    public init(master: Wheel = .neutral, shadows: Wheel = .neutral, midtones: Wheel = .neutral,
                highlights: Wheel = .neutral, balance: Int = 0) {
        self.master = master
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.balance = balance
    }

    public func luaText() -> String {
        func wheel(_ name: String, _ w: Wheel) -> String {
            """
            \t\t\tColorGradingParams_\(name) = {
            \t\t\t\tHue = \(w.hue),
            \t\t\t\tLum = \(w.luminance),
            \t\t\t\tSat = \(w.saturation),
            \t\t\t},

            """
        }
        let version = Self.fileVersion
        return "Preset = {\n\tSettings = {\n\t\tBase = {\n"
            + "\t\t\tColorGradingActive = true,\n"
            + "\t\t\tColorGradingBalance = \(balance),\n"
            + wheel("Highlights", highlights) + wheel("Master", master)
            + wheel("Midtones", midtones) + wheel("Shadows", shadows)
            + "\t\t},\n\t\tVersion = \"\(version)\",\n\t},\n\tVersion = \"\(version)\",\n}\n"
    }
}

/// Derives a Color Grading starting point from an analysis, per tonal range:
/// - `suggest`: tint toward the hue the colors in that range should move to (the harmony's targets,
///   or the matching colors of a series palette), as strongly as the colors are off;
/// - `emphasize`: for photos without real colors (fog, dusk, black and white), strengthen the faint
///   tint each range already has.
public enum ColorGradingSuggestion {
    public enum Strength: String, CaseIterable, Identifiable, Sendable {
        case subtle, moderate, strong

        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }

        /// Saturation (0...100) of a wheel whose colors are 30° or more off target (or as colorful as
        /// `ColorGradingSuggestion.emphasisTypicalChroma` when emphasizing).
        public var maxSaturation: Double {
            switch self {
            case .subtle: 15
            case .moderate: 30
            case .strong: 50
            }
        }
    }

    /// A dominant color and the hue (sRGB degrees) it should move to.
    public struct Input: Sendable, Equatable {
        public var color: SRGBColor
        public var share: Double
        public var targetHue: Double
        /// A color the user wants left as it is: the grading may not change it, not even for a style's cast.
        public var isProtected: Bool

        public init(color: SRGBColor, share: Double, targetHue: Double, isProtected: Bool = false) {
            self.color = color
            self.share = share
            self.targetHue = targetHue
            self.isProtected = isProtected
        }
    }

    /// Why a tonal range got (or did not get) a tint.
    public enum Reason: Sendable, Equatable {
        case tinted
        /// No colors fall in this range.
        case noColors
        /// The colors are already within `minimumShift` of their targets.
        case onTarget
        /// The colors have too little tint to emphasize.
        case tooNeutral
    }

    /// What was decided for one tonal range, for showing next to the preset.
    public struct RangeDetail: Sendable, Equatable {
        public var range: TonalRange
        public var reason: Reason
        /// Mean distance (sRGB degrees) of the range's colors to their target hues (`suggest` only).
        public var meanShift: Double?
        /// The tint as sRGB hue; nil when the range is left alone.
        public var tintHue: Double?
        public var wheel: ColorGradingPreset.Wheel
    }

    /// How far the colors are from their targets: before the grading, and after it as the calibrated model predicts it.
    public struct Fit: Sendable, Equatable {
        /// Weighted mean distance, in sRGB hue degrees, of the colors with a hue to their target hues.
        public var before: Double
        public var after: Double
    }

    public struct Suggestion: Sendable, Equatable {
        public var preset: ColorGradingPreset
        public var details: [RangeDetail]
        /// Set by `optimized`; nil for the plain heuristic.
        public var fit: Fit?
        /// Selective Tone of PhotoLab's Light palette (Blacks and Shadows, -100...100), for styles that lift the darks.
        /// Not part of a Color Grading preset: they are set by hand in the Light palette.
        public var toneBlacks = 0
        public var toneShadows = 0
    }

    /// Ranges whose colors are less than this far from their targets are left alone.
    public static let minimumShift = 3.0
    /// Colors with less than this total weight in a range do not decide its tint.
    public static let minimumWeight = 0.02
    /// OKLab chroma below which a color has no tint worth emphasizing.
    public static let emphasisMinimumChroma = 0.006
    /// OKLab chroma of a clearly visible tint; colors this colorful get the strength's full saturation.
    public static let emphasisTypicalChroma = 0.04

    private static let ranges: [TonalRange] = [.shadows, .midtones, .highlights]

    private struct Accumulator {
        var weight = 0.0, sin = 0.0, cos = 0.0, shift = 0.0, share = 0.0, chroma = 0.0, present = 0.0
    }

    public static func suggest(from inputs: [Input], strength: Strength) -> Suggestion {
        var sums: [TonalRange: Accumulator] = [:]
        for input in inputs {
            let range = DxOMapping.tonalRange(for: input.color)
            sums[range, default: Accumulator()].present += input.share
            guard input.color.chroma >= DxOMapping.neutralChroma else { continue }
            let weight = input.share * min(1, input.color.chroma / 0.1)
            guard weight > 0 else { continue }
            let target = input.targetHue * .pi / 180
            var a = sums[range, default: Accumulator()]
            a.weight += weight
            a.sin += weight * Foundation.sin(target)
            a.cos += weight * Foundation.cos(target)
            a.shift += weight * abs(ColorMath.signedAngle(from: input.color.hsb.h, to: input.targetHue))
            sums[range] = a
        }
        return build(strength: strength) { range in
            guard let a = sums[range], a.present > 0 else { return (.noColors, nil, nil, 0) }
            guard a.weight >= minimumWeight else { return (.tooNeutral, nil, nil, 0) }
            let meanShift = a.shift / a.weight
            guard meanShift >= minimumShift else { return (.onTarget, meanShift, nil, 0) }
            let tint = ColorMath.normalizeDegrees(atan2(a.sin, a.cos) * 180 / .pi)
            return (.tinted, meanShift, tint, min(1, meanShift / 30))
        }
    }

    /// For photos without real colors: tints each range with the hue its (faint) colors already have,
    /// as strongly as they are colorful.
    public static func emphasize(_ colors: [(color: SRGBColor, share: Double)], strength: Strength) -> Suggestion {
        var sums: [TonalRange: Accumulator] = [:]
        for item in colors {
            let range = DxOMapping.tonalRange(for: item.color)
            sums[range, default: Accumulator()].present += item.share
            guard item.color.chroma >= emphasisMinimumChroma else { continue }
            let weight = item.share * item.color.chroma
            let hue = item.color.hsb.h * .pi / 180
            var a = sums[range, default: Accumulator()]
            a.weight += weight
            a.sin += weight * Foundation.sin(hue)
            a.cos += weight * Foundation.cos(hue)
            a.share += item.share
            a.chroma += weight
            sums[range] = a
        }
        return build(strength: strength) { range in
            guard let a = sums[range], a.present > 0 else { return (.noColors, nil, nil, 0) }
            guard a.share >= minimumWeight, a.chroma > 0 else { return (.tooNeutral, nil, nil, 0) }
            let meanChroma = a.chroma / a.share
            let tint = ColorMath.normalizeDegrees(atan2(a.sin, a.cos) * 180 / .pi)
            return (.tinted, nil, tint, min(1, meanChroma / emphasisTypicalChroma))
        }
    }

    private static func build(strength: Strength,
                              decide: (TonalRange) -> (Reason, Double?, Double?, Double)) -> Suggestion {
        var preset = ColorGradingPreset()
        var details: [RangeDetail] = []
        for range in ranges {
            var (reason, meanShift, tint, amount) = decide(range)
            var wheel = ColorGradingPreset.Wheel.neutral
            if let tintHue = tint {
                wheel = .init(hue: Int(DxOHue.fromSRGB(tintHue).rounded()) % 360,
                              saturation: Int((strength.maxSaturation * amount).rounded()), luminance: 0)
                if wheel.saturation == 0 {
                    wheel = .neutral
                    tint = nil
                    reason = .tooNeutral
                }
            }
            switch range {
            case .shadows: preset.shadows = wheel
            case .midtones: preset.midtones = wheel
            case .highlights: preset.highlights = wheel
            }
            details.append(RangeDetail(range: range, reason: reason, meanShift: meanShift, tintHue: tint, wheel: wheel))
        }
        return Suggestion(preset: preset, details: details, fit: nil)
    }
}
