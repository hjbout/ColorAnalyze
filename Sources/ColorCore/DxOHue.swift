import Foundation

/// DxO PhotoLab's hue axis.
///
/// What PhotoLab calls *hue* — the position on the rings of its HSL tool and the Hue of the Color Grading wheels — is the
/// HSV hue of a color in **Rec.2020 primaries**, after the sRGB tone curve (measured with PhotoLab 10.1 on a chart of known
/// colors, see `calibration/`). That is not the sRGB hue: sRGB red is at about 14° of DxO's axis, sRGB yellow at 60° is
/// already inside the fade to green, and a less saturated color sits closer to its sRGB hue than a saturated one.
/// The eight slices of the HSL tool (`HSLHueSlices` of every sidecar of PhotoLab 10.1, Wide Gamut pipeline) are fade
/// ranges on that axis.
public enum DxOHue {
    /// One slice of the HSL tool: it fades in over `fadeIn`, is fully active from `fadeInEnd` to
    /// `fadeOutStart`, and fades out over `fadeOut`. Degrees on DxO's hue axis; ranges may wrap past 360.
    public struct Slice: Sendable, Equatable {
        public var channel: DxOChannel
        public var fadeInStart: Double
        public var fadeInEnd: Double
        public var fadeOutStart: Double
        public var fadeOutEnd: Double

        /// Middle of the fully active part.
        public var center: Double {
            var end = fadeOutStart
            if end < fadeInEnd { end += 360 }
            return ColorMath.normalizeDegrees((fadeInEnd + end) / 2)
        }

        /// 0...1: how much of `hue` (DxO degrees) belongs to this slice.
        public func membership(of hue: Double) -> Double {
            func relative(_ x: Double) -> Double { ColorMath.normalizeDegrees(x - fadeInStart) }
            let t = relative(hue)
            let inEnd = relative(fadeInEnd), outStart = relative(fadeOutStart), outEnd = relative(fadeOutEnd)
            if t <= inEnd { return inEnd == 0 ? 1 : t / inEnd }
            if t <= outStart { return 1 }
            if t <= outEnd { return outEnd == outStart ? 0 : 1 - (t - outStart) / (outEnd - outStart) }
            return 0
        }
    }

    /// Read from `HSLHueSlices` of a PhotoLab 10.1 sidecar (`HSLHueSlicesColorPipeline = "WideGamut"`).
    public static let slices: [Slice] = [
        Slice(channel: .red, fadeInStart: 325.07000732421875, fadeInEnd: 343.75900268554688,
              fadeOutStart: 15.623000144958496, fadeOutEnd: 31.136999130249023),
        Slice(channel: .orange, fadeInStart: 15.623000144958496, fadeInEnd: 31.136999130249023,
              fadeOutStart: 41.144001007080078, fadeOutEnd: 50.113998413085938),
        Slice(channel: .yellow, fadeInStart: 41.144001007080078, fadeInEnd: 50.113998413085938,
              fadeOutStart: 54.533000946044922, fadeOutEnd: 63.109001159667969),
        Slice(channel: .green, fadeInStart: 54.533000946044922, fadeInEnd: 63.109001159667969,
              fadeOutStart: 145.70199584960938, fadeOutEnd: 171.41499328613281),
        Slice(channel: .cyan, fadeInStart: 145.70199584960938, fadeInEnd: 171.41499328613281,
              fadeOutStart: 201.0989990234375, fadeOutEnd: 216.15199279785156),
        Slice(channel: .blue, fadeInStart: 201.0989990234375, fadeInEnd: 216.15199279785156,
              fadeOutStart: 246.54600524902344, fadeOutEnd: 264.98599243164062),
        Slice(channel: .purple, fadeInStart: 246.54600524902344, fadeInEnd: 264.98599243164062,
              fadeOutStart: 275.5260009765625, fadeOutEnd: 294.79800415039062),
        Slice(channel: .magenta, fadeInStart: 275.5260009765625, fadeInEnd: 294.79800415039062,
              fadeOutStart: 325.07000732421875, fadeOutEnd: 343.75900268554688),
    ]

    /// PhotoLab's hue of a color, degrees (0..<360), or nil for a color without hue (grey).
    public static func hue(of color: SRGBColor) -> Double? {
        let wide = GradePreview.toWide
        let linear = color.linear
        func channel(_ row: Int) -> Double {
            let v = Double(wide[row][0] * linear.x + wide[row][1] * linear.y + wide[row][2] * linear.z)
            return min(1, max(0, ColorMath.linearToSRGB(max(0, v))))
        }
        let r = channel(0), g = channel(1), b = channel(2)
        let high = max(r, g, b), low = min(r, g, b), chroma = high - low
        guard chroma > 1e-6 else { return nil }
        var hue: Double
        if high == r { hue = (g - b) / chroma } else if high == g { hue = 2 + (b - r) / chroma } else { hue = 4 + (r - g) / chroma }
        return ColorMath.normalizeDegrees(hue * 60)
    }

    /// PhotoLab's hue of the pure sRGB color with this sRGB hue.
    public static func fromSRGB(_ hue: Double) -> Double {
        pureHue(ColorMath.normalizeDegrees(hue))
    }

    private static func pureHue(_ srgbHue: Double) -> Double {
        hue(of: SRGBColor.fromHSB(h: srgbHue, s: 1, b: 1)) ?? srgbHue
    }

    /// The sRGB hue (0..<360) of the pure color at this DxO hue; the inverse of `fromSRGB`.
    public static func toSRGB(_ dxoHue: Double) -> Double {
        let target = ColorMath.normalizeDegrees(dxoHue)
        // `fromSRGB` rises around the circle; find the sRGB hue by bisection on the unwrapped function.
        let start = pureHue(0)
        let unwrapped = { (h: Double) -> Double in
            var d = pureHue(h) - start
            if d < 0 { d += 360 }
            return d
        }
        var wanted = target - start
        if wanted < 0 { wanted += 360 }
        var low = 0.0, high = 360.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if unwrapped(mid) < wanted { low = mid } else { high = mid }
        }
        return ColorMath.normalizeDegrees((low + high) / 2)
    }

    /// What turning a color by `shift` degrees of sRGB hue (same saturation and brightness) comes to on DxO's ring: the signed
    /// distance (-180...180) between the color's PhotoLab hue and the target's. This is the number for the *Hue* handle on
    /// the ring of PhotoLab's HSL palette; positive turns counter-clockwise (red → orange → yellow → green …).
    /// nil when the color or its target has no hue.
    public static func ringShift(of color: SRGBColor, bySRGBShift shift: Double) -> Double? {
        let hsb = color.hsb
        guard let from = hue(of: color),
              let to = hue(of: SRGBColor.fromHSB(h: hsb.h + shift, s: hsb.s, b: hsb.b)) else { return nil }
        return ColorMath.signedAngle(from: from, to: to)
    }

    /// The same for pure colors: `hue` is an sRGB hue.
    public static func ringShift(fromSRGBHue hue: Double, bySRGBShift shift: Double) -> Double {
        ColorMath.signedAngle(from: fromSRGB(hue), to: fromSRGB(hue + shift))
    }

    /// The channel of the HSL tool a DxO hue belongs to most.
    public static func channel(atDxOHue hue: Double) -> DxOChannel {
        slices.max { $0.membership(of: hue) < $1.membership(of: hue) }?.channel ?? .red
    }

}
