import Foundation

/// A gamma-encoded sRGB color. Components are in 0...1 for colors inside the sRGB gamut; colors
/// outside it (saturated colors of a Display P3 or Adobe RGB photo) keep their true value as
/// components below 0 or above 1 ("extended sRGB") instead of being clipped. Text readouts
/// (`hex`, `rgb255`, `hsl`) are clipped to sRGB; `hsb` is not, so saturation can exceed 1.
public struct SRGBColor: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(linear: SIMD3<Float>) {
        r = ColorMath.linearToSRGB(Double(linear.x))
        g = ColorMath.linearToSRGB(Double(linear.y))
        b = ColorMath.linearToSRGB(Double(linear.z))
    }

    public init(oklab: SIMD3<Float>) {
        self.init(linear: ColorMath.okLabToLinear(oklab))
    }

    public var linear: SIMD3<Float> {
        SIMD3(Float(ColorMath.sRGBToLinear(r)),
              Float(ColorMath.sRGBToLinear(g)),
              Float(ColorMath.sRGBToLinear(b)))
    }

    public var oklab: SIMD3<Float> { ColorMath.linearToOKLab(linear) }

    /// OKLab chroma; ~0 for greys, ~0.26 for pure sRGB red.
    public var chroma: Double {
        let lab = oklab
        return Double((lab.y * lab.y + lab.z * lab.z).squareRoot())
    }

    /// CIE L* (0...100), perceptual lightness.
    public var lightness: Double {
        let lin = linear
        let y = Double(0.2126 * lin.x + 0.7152 * lin.y + 0.0722 * lin.z)
        return y > 216.0 / 24389.0 ? 116 * cbrt(y) - 16 : y * 24389.0 / 27.0
    }

    public var rgb255: (r: Int, g: Int, b: Int) {
        (Self.to255(r), Self.to255(g), Self.to255(b))
    }

    public var hex: String {
        let c = rgb255
        return String(format: "#%02X%02X%02X", c.r, c.g, c.b)
    }

    /// Hue in degrees (0..<360), saturation and brightness in 0...1.
    public var hsb: (h: Double, s: Double, b: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        let s = maxC == 0 ? 0 : delta / maxC
        return (hue(maxC: maxC, delta: delta), s, maxC)
    }

    /// Hue in degrees (0..<360), saturation and lightness in 0...1.
    public var hsl: (h: Double, s: Double, l: Double) {
        let c = clamped
        let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b)
        let delta = maxC - minC
        let l = (maxC + minC) / 2
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        return (c.hue(maxC: maxC, delta: delta), min(1, s), l)
    }

    /// The color clipped to the sRGB gamut (components in 0...1).
    public var clamped: SRGBColor {
        SRGBColor(r: min(1, max(0, r)), g: min(1, max(0, g)), b: min(1, max(0, b)))
    }

    /// True when the color lies outside the sRGB gamut, i.e. its hex and RGB readouts are clipped.
    public var isOutsideSRGB: Bool {
        let l = linear
        return l.min() < -0.01 || l.max() > 1.01     // a little slack for rounding and averaging
    }

    /// Display P3 components (0...1, same transfer curve as sRGB), clipped to the P3 gamut.
    public var displayP3Components: (r: Double, g: Double, b: Double) {
        let l = linear
        let r = 0.8224621 * Double(l.x) + 0.1775380 * Double(l.y)
        let g = 0.0331941 * Double(l.x) + 0.9668058 * Double(l.y)
        let b = 0.0170827 * Double(l.x) + 0.0723974 * Double(l.y) + 0.9105199 * Double(l.z)
        let encode = { (v: Double) in min(1, max(0, ColorMath.linearToSRGB(v))) }
        return (encode(r), encode(g), encode(b))
    }

    /// Display P3 as 8-bit values.
    public var displayP3RGB255: (r: Int, g: Int, b: Int) {
        let c = displayP3Components
        return (Self.to255(c.r), Self.to255(c.g), Self.to255(c.b))
    }

    public static func fromHSB(h: Double, s: Double, b: Double) -> SRGBColor {
        let c = b * s
        let hp = ColorMath.normalizeDegrees(h) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = b - c
        return SRGBColor(r: r1 + m, g: g1 + m, b: b1 + m)
    }

    private func hue(maxC: Double, delta: Double) -> Double {
        guard delta > 0 else { return 0 }
        let h: Double
        if maxC == r {
            h = 60 * ((g - b) / delta)
        } else if maxC == g {
            h = 60 * ((b - r) / delta + 2)
        } else {
            h = 60 * ((r - g) / delta + 4)
        }
        return ColorMath.normalizeDegrees(h)
    }

    private static func to255(_ v: Double) -> Int {
        Int((min(1, max(0, v)) * 255).rounded())
    }
}

public enum ColorMath {
    /// sRGB transfer curve, mirrored below zero and unclamped above one (extended sRGB), so
    /// colors outside the gamut survive a round trip.
    public static func sRGBToLinear(_ c: Double) -> Double {
        let a = abs(c)
        let v = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return c < 0 ? -v : v
    }

    public static func linearToSRGB(_ c: Double) -> Double {
        let a = abs(c)
        let v = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return c < 0 ? -v : v
    }

    /// Lookup table for 8-bit sRGB → linear.
    public static let sRGB8ToLinear: [Float] = (0..<256).map { Float(sRGBToLinear(Double($0) / 255)) }

    /// Björn Ottosson's OKLab, from linear sRGB.
    public static func linearToOKLab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let l = 0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z
        let m = 0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z
        let s = 0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z
        let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
        return SIMD3(
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
        )
    }

    public static func okLabToLinear(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
        let m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
        let s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return SIMD3(
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    public static func distanceSquared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return (d * d).sum()
    }

    public static func normalizeDegrees(_ d: Double) -> Double {
        let v = d.truncatingRemainder(dividingBy: 360)
        return v < 0 ? v + 360 : v
    }

    /// Signed shortest angular difference `to - from`, in (-180, 180].
    public static func signedAngle(from: Double, to: Double) -> Double {
        var d = normalizeDegrees(to - from)
        if d > 180 { d -= 360 }
        return d
    }
}
