import Foundation
import simd

/// A check for a color cast in the parts of a photo that look neutral (greys, whites, concrete, shadows).
///
/// Grading starts after white balance: a cast shifts every color, so a harmony or a grade built on it aims at the wrong
/// hues. The check averages the nearly neutral pixels in OKLab; the average (a, b) is the cast. It cannot know whether
/// those areas *should* be neutral (a white wall at sunset is orange for a reason), so the result is a hint to look at,
/// not a verdict.
public struct WhiteBalanceCheck: Sendable, Equatable {
    public enum Verdict: String, Sendable { case neutral, slight, clear, unknown }

    /// OKLab chroma below which a pixel counts as nearly neutral, and the lightness range that is considered.
    public static let neutralChroma: Float = 0.035
    public static let lightnessRange: ClosedRange<Float> = 0.25...0.92
    /// Share of the photo that must be nearly neutral for the check to say anything.
    public static let minimumShare = 0.03
    /// Mean chroma of the neutral pixels from which the cast is slight / clear.
    public static let slightCast = 0.010, clearCast = 0.020

    /// Share of the photo (0...1) that was judged nearly neutral.
    public var neutralShare: Double
    /// Mean OKLab chroma of those pixels (0 = perfectly neutral).
    public var cast: Double
    /// Mean OKLab a (+ = magenta, − = green) and b (+ = yellow/orange, − = blue).
    public var a: Double
    public var b: Double
    /// Mean OKLab lightness of those pixels: the same (a, b) is a stronger tint on a dark grey than on a light one.
    public var lightness: Double

    public init(neutralShare: Double, cast: Double, a: Double, b: Double, lightness: Double = 0.65) {
        self.neutralShare = neutralShare
        self.cast = cast
        self.a = a
        self.b = b
        self.lightness = lightness
    }

    public var verdict: Verdict {
        guard neutralShare >= Self.minimumShare else { return .unknown }
        return cast < Self.slightCast ? .neutral : cast < Self.clearCast ? .slight : .clear
    }

    /// The direction of the cast in words, e.g. "warm", "cool and green"; nil when neutral or unknown.
    public var direction: String? {
        guard verdict == .slight || verdict == .clear else { return nil }
        let threshold = 0.006
        var parts: [String] = []
        if abs(b) >= threshold { parts.append(b > 0 ? "warm (orange)" : "cool (blue)") }
        if abs(a) >= threshold { parts.append(a > 0 ? "magenta" : "green") }
        if parts.isEmpty { parts.append(abs(b) >= abs(a) ? (b > 0 ? "warm (orange)" : "cool (blue)") : (a > 0 ? "magenta" : "green")) }
        return parts.joined(separator: " and ")
    }

    /// What to try in PhotoLab's White Balance (the opposite of the cast), nil when neutral or unknown.
    public var advice: String? {
        guard verdict == .slight || verdict == .clear else { return nil }
        let threshold = 0.006
        var parts: [String] = []
        if abs(b) >= threshold { parts.append(b > 0 ? "a cooler Temperature" : "a warmer Temperature") }
        if abs(a) >= threshold { parts.append(a > 0 ? "less magenta (Tint toward green)" : "more magenta (Tint toward magenta)") }
        if parts.isEmpty { parts.append(abs(b) >= abs(a) ? (b > 0 ? "a cooler Temperature" : "a warmer Temperature") : (a > 0 ? "Tint toward green" : "Tint toward magenta")) }
        return parts.joined(separator: " and ")
    }

    /// Checks the nearly neutral pixels of `buffer`; `weights` (one per pixel) make the subject count more.
    public static func check(_ buffer: PixelBuffer, weights: [Float]? = nil) -> WhiteBalanceCheck {
        var sumA = 0.0, sumB = 0.0, sumL = 0.0, mass = 0.0, total = 0.0
        for (i, p) in buffer.lab.enumerated() {
            let w = Double(weights?[i] ?? 1)
            total += w
            guard lightnessRange.contains(p.x), (p.y * p.y + p.z * p.z).squareRoot() < neutralChroma else { continue }
            sumA += w * Double(p.y)
            sumB += w * Double(p.z)
            sumL += w * Double(p.x)
            mass += w
        }
        guard mass > 0, total > 0 else { return WhiteBalanceCheck(neutralShare: 0, cast: 0, a: 0, b: 0) }
        let a = sumA / mass, b = sumB / mass
        return WhiteBalanceCheck(neutralShare: mass / total, cast: (a * a + b * b).squareRoot(), a: a, b: b,
                                 lightness: sumL / mass)
    }
}

extension WhiteBalanceCheck {
    /// What would make the neutral areas neutral, as PhotoLab White Balance values and as a matrix for the preview; nil when
    /// the check finds no cast (neutral) or cannot judge (unknown).
    public var correction: WhiteBalanceCorrection? {
        guard verdict == .slight || verdict == .clear else { return nil }
        return WhiteBalanceCorrection(castWhite: ColorMath.okLabToLinear(SIMD3(Float(lightness), Float(a), Float(b))))
    }
}

/// The white balance that turns the measured cast into grey, in the two forms that are of use: a change of PhotoLab's
/// Temperature and Tint, and a chromatic adaptation (Bradford) of the rendered pixels for the preview.
///
/// The cast's color is placed on the Planckian locus (CIE 1960 uv): how far it lies from D65 along the locus, in mired, is
/// how far the Temperature is off; how far it lies off the locus is how far the Tint is off. A raw converter's Temperature
/// works in that same direction (a lower value cools the photo, by about the same number of mired at any temperature), so the
/// new Temperature follows from the current one, scaled by what was measured in PhotoLab (see below).
public struct WhiteBalanceCorrection: Sendable, Equatable {
    /// The cast's distance from D65 along the Planckian locus, in mired (+ = warmer cast, so the photo must go cooler).
    public var miredShift: Double
    /// Change of PhotoLab's Tint (+ = toward magenta): the cast's distance off the locus (3000 × Δuv) in PhotoLab's units.
    public var tintShift: Double

    /// Measured in PhotoLab 10.1 on a RAW (4 November 2026, see `calibration/`): the Temperature slider moves the photo's
    /// grey by about 0.86 mired per mired of the Kelvin value (0.88 for 5694 → 4500 K, 0.84 for 5694 → 7000 K), and one step
    /// of Tint (−13 → +30) moves it by 0.84 units of 3000 × Δuv. So the slider must go 1/0.86 times as far as the cast, and the
    /// Tint 1/0.84 times.
    public static let miredPerSliderMired = 0.86
    public static let uvPerTintStep = 0.84
    /// Linear sRGB → corrected linear sRGB, as three rows.
    public var rows: [SIMD3<Float>]

    /// The rendered color of what should be grey, in linear sRGB (only its chromaticity counts).
    public init(castWhite: SIMD3<Float>) {
        let cast = SIMD3<Double>(Double(castWhite.x), Double(castWhite.y), Double(castWhite.z))
        let xyz = Self.multiply(Self.sRGBToXYZ, cast)
        let d65 = Self.multiply(Self.sRGBToXYZ, SIMD3(1, 1, 1))
        let (castT, castDuv) = Self.planckian(uv: Self.uv(xyz))
        let (whiteT, whiteDuv) = Self.planckian(uv: Self.uv(d65))
        miredShift = 1e6 / castT - 1e6 / whiteT
        tintShift = (castDuv - whiteDuv) * 3000 / Self.uvPerTintStep
        // Bradford: scale the cone responses of the cast white to those of D65, at the cast's own luminance kept as is.
        let source = Self.multiply(Self.bradford, xyz / max(1e-6, xyz.y))
        let target = Self.multiply(Self.bradford, d65 / d65.y)
        let gains = target / SIMD3(max(1e-6, source.x), max(1e-6, source.y), max(1e-6, source.z))
        func column(_ basis: SIMD3<Double>) -> SIMD3<Double> {
            let cone = Self.multiply(Self.bradford, Self.multiply(Self.sRGBToXYZ, basis)) * gains
            return Self.multiply(Self.xyzToSRGB, Self.multiply(Self.bradfordInverse, cone))
        }
        let c0 = column(SIMD3(1, 0, 0)), c1 = column(SIMD3(0, 1, 0)), c2 = column(SIMD3(0, 0, 1))
        rows = (0..<3).map { SIMD3(Float(c0[$0]), Float(c1[$0]), Float(c2[$0])) }
    }

    /// The Temperature to set when PhotoLab shows `current` Kelvin now (clamped to its 2000…50000 K).
    public func temperature(from current: Double) -> Double {
        let mired = 1e6 / max(1, current) + miredShift / Self.miredPerSliderMired
        return min(50_000, max(2_000, mired > 0 ? 1e6 / mired : 50_000))
    }

    /// The Kelvin change from `current`, e.g. −620 at 5500 K.
    public func temperatureChange(from current: Double) -> Double { temperature(from: current) - current }

    public func apply(_ linear: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3((rows[0] * linear).sum(), (rows[1] * linear).sum(), (rows[2] * linear).sum())
    }

    // MARK: Colorimetry

    static let sRGBToXYZ: [SIMD3<Double>] = [SIMD3(0.4124564, 0.3575761, 0.1804375), SIMD3(0.2126729, 0.7151522, 0.0721750),
                                             SIMD3(0.0193339, 0.1191920, 0.9503041)]
    static let xyzToSRGB: [SIMD3<Double>] = [SIMD3(3.2404542, -1.5371385, -0.4985314), SIMD3(-0.9692660, 1.8760108, 0.0415560),
                                             SIMD3(0.0556434, -0.2040259, 1.0572252)]
    static let bradford: [SIMD3<Double>] = [SIMD3(0.8951, 0.2664, -0.1614), SIMD3(-0.7502, 1.7135, 0.0367),
                                            SIMD3(0.0389, -0.0685, 1.0296)]
    static let bradfordInverse: [SIMD3<Double>] = [SIMD3(0.9869929, -0.1470543, 0.1599627), SIMD3(0.4323053, 0.5183603, 0.0492912),
                                                   SIMD3(-0.0085287, 0.0400428, 0.9684867)]

    static func multiply(_ m: [SIMD3<Double>], _ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((m[0] * v).sum(), (m[1] * v).sum(), (m[2] * v).sum())
    }

    /// CIE 1960 uv of an XYZ color.
    static func uv(_ xyz: SIMD3<Double>) -> SIMD2<Double> {
        let d = max(1e-9, xyz.x + 15 * xyz.y + 3 * xyz.z)
        return SIMD2(4 * xyz.x / d, 6 * xyz.y / d)
    }

    /// The Planckian locus in CIE 1960 uv (Krystek 1985, 1000–15000 K).
    static func locus(_ t: Double) -> SIMD2<Double> {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        return SIMD2(u, v)
    }

    /// Correlated color temperature and Duv (+ = above the locus, toward green) of a uv point, searched in mired.
    static func planckian(uv point: SIMD2<Double>) -> (temperature: Double, duv: Double) {
        func distance(_ mired: Double) -> Double { simd_distance_squared(locus(1e6 / mired), point) }
        var best = 1e6 / 6500, bestDistance = Double.infinity
        for mired in stride(from: 1e6 / 15_000, through: 1e6 / 1_000, by: 1.0) where distance(mired) < bestDistance {
            best = mired
            bestDistance = distance(mired)
        }
        var low = max(1e6 / 15_000, best - 1), high = min(1e6 / 1_000, best + 1)
        for _ in 0..<40 {
            let m1 = low + (high - low) / 3, m2 = high - (high - low) / 3
            if distance(m1) < distance(m2) { high = m2 } else { low = m1 }
        }
        let mired = (low + high) / 2, t = 1e6 / mired
        let onLocus = locus(t), tangent = locus(t * 1.001) - locus(t * 0.999)
        let offset = point - onLocus
        // Higher temperature runs toward smaller u; the side to the left of that direction (larger v) is green.
        let side = tangent.x * offset.y - tangent.y * offset.x
        return (t, (side < 0 ? 1 : -1) * simd_length(offset))
    }
}
