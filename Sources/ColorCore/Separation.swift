import Foundation
import simd

/// How well the subject stands apart from the background in lightness and color. Next to skin tones, this is what
/// colorists set first in the balance: a subject that shares its colors and lightness with its surroundings does not
/// stand out, however harmonious those colors are.
///
/// The subject is taken from a map of the photo: Vision's foreground mask when the photo has a foreground (it follows the
/// outline of people and objects), or else the attention map. Only the core of the subject counts as subject (weight 0.5 and
/// up) and only what is clearly outside it as background, so the soft edge of an attention map, which covers subject and
/// background alike, counts as neither. Both are summarized in OKLab: their mean color (lightness and the a/b direction), their mean chroma, and how
/// much of the subject has colors that are common in the background (it *blends in* there).
public struct SeparationCheck: Sendable, Equatable {
    public enum Verdict: String, Sendable { case strong, moderate, weak, unknown }

    /// The subject must cover at least / at most this share of the photo for the check to say anything.
    public static let subjectShareRange = 0.02...0.85
    /// OKLab lightness difference of the means below which the lightness separation is weak, and from which it is strong.
    public static let weakLightness = 0.05, strongLightness = 0.15
    /// OKLab a/b distance of the means below which the color separation is weak, and from which it is strong.
    public static let weakColor = 0.03, strongColor = 0.08
    /// Share of the subject in colors common in the background above which it blends in, and below which it stands out.
    public static let blendsIn = 0.6, standsOut = 0.3
    /// Chroma of the subject's mean color below which it has no hue of its own to stand apart with.
    public static let minimumSubjectChroma: Float = 0.02

    /// Share of the photo (0...1) that is subject.
    public var subjectShare: Double
    /// Mean OKLab color of the subject and of the background.
    public var subject: SIMD3<Float>
    public var background: SIMD3<Float>
    /// Mean OKLab chroma of the pixels of the subject and of the background (unlike the chroma of the mean, this does not
    /// drop when the colors of a group differ in hue).
    public var subjectChroma: Double
    public var backgroundChroma: Double
    /// Share of the subject (0...1) whose color is common in the background.
    public var blendShare: Double

    public init(subjectShare: Double, subject: SIMD3<Float>, background: SIMD3<Float>, subjectChroma: Double,
                backgroundChroma: Double, blendShare: Double) {
        self.subjectShare = subjectShare
        self.subject = subject
        self.background = background
        self.subjectChroma = subjectChroma
        self.backgroundChroma = backgroundChroma
        self.blendShare = blendShare
    }

    /// Subject lightness minus background lightness (OKLab L; + = the subject is lighter).
    public var lightnessContrast: Double { Double(subject.x - background.x) }
    /// Distance between the a/b of the two means (OKLab): how different their colors are, apart from lightness.
    public var colorContrast: Double {
        let d = subject - background
        return Double((d.y * d.y + d.z * d.z).squareRoot())
    }
    /// The mean colors, to show as swatches.
    public var subjectColor: SRGBColor { SRGBColor(oklab: subject).clamped }
    public var backgroundColor: SRGBColor { SRGBColor(oklab: background).clamped }

    /// The OKLab hue angle (degrees) of the subject's mean color; nil when that is nearly neutral.
    public var subjectHueAngle: Double? {
        guard (subject.y * subject.y + subject.z * subject.z).squareRoot() >= Self.minimumSubjectChroma else { return nil }
        return ColorMath.normalizeDegrees(Double(atan2(subject.z, subject.y)) * 180 / .pi)
    }

    public var verdict: Verdict {
        guard Self.subjectShareRange.contains(subjectShare) else { return .unknown }
        let lightness = abs(lightnessContrast), color = colorContrast
        if blendShare >= Self.blendsIn || (lightness < Self.weakLightness && color < Self.weakColor) { return .weak }
        if blendShare < Self.standsOut && (lightness >= Self.strongLightness || color >= Self.strongColor) { return .strong }
        return .moderate
    }

    /// How the subject differs from the background, e.g. "lighter, warmer and more saturated"; nil when it does not.
    public var relation: String? {
        var parts: [String] = []
        if abs(lightnessContrast) >= 0.03 { parts.append(lightnessContrast > 0 ? "lighter" : "darker") }
        // Warm is toward orange (OKLab hue about 60°), cool toward blue.
        let d = subject - background
        let warmth = Double(d.y) * 0.5 + Double(d.z) * 0.866
        if abs(warmth) >= 0.015 { parts.append(warmth > 0 ? "warmer" : "cooler") }
        let chroma = subjectChroma - backgroundChroma
        if abs(chroma) >= 0.015 { parts.append(chroma > 0 ? "more saturated" : "duller") }
        guard let last = parts.popLast() else { return nil }
        return parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
    }

    /// How much a pixel belongs to the subject: a smoothstep of its map value over 0.15...0.85, as the Subject Map shows it.
    public static func subjectWeight(_ saliency: Float) -> Float {
        let t = min(1, max(0, (saliency - 0.15) / 0.7))
        return t * t * (3 - 2 * t)
    }

    /// How much a pixel counts as subject and as background: the core of the subject (weight 0.5 and up) and what is
    /// clearly outside it (below 0.02); the edge in between counts as neither.
    static func weights(_ saliency: Float) -> (subject: Float, background: Float) {
        let w = subjectWeight(saliency)
        return (w >= 0.5 ? w : 0, w < 0.02 ? 1 : 0)
    }

    /// Checks `lab` (one OKLab color per pixel) against `saliency` (the attention map at the same size).
    public static func check(lab: [SIMD3<Float>], saliency: [Float]) -> SeparationCheck {
        precondition(lab.count == saliency.count)
        var sums = (subject: SIMD3<Float>.zero, background: SIMD3<Float>.zero)
        var chroma = (subject: 0.0, background: 0.0)
        var mass = (subject: 0.0, background: 0.0)
        var histogram = [Float](repeating: 0, count: Bins.count)
        for (p, s) in zip(lab, saliency) {
            let (w, rest) = weights(s)
            let c = Double((p.y * p.y + p.z * p.z).squareRoot())
            sums.subject += w * p
            sums.background += rest * p
            chroma.subject += Double(w) * c
            chroma.background += Double(rest) * c
            mass.subject += Double(w)
            mass.background += Double(rest)
            if rest > 0 { histogram[Bins.index(of: p)] += rest }
        }
        guard mass.subject > 0, mass.background > 0 else {
            return SeparationCheck(subjectShare: mass.subject / Double(max(1, lab.count)), subject: .zero, background: .zero,
                                   subjectChroma: 0, backgroundChroma: 0, blendShare: 0)
        }
        // A subject color blends in when the background has at least 1 % of its pixels within about ±0.05 L and ±0.03 a/b.
        let threshold = Float(mass.background) * 0.01
        var blended = 0.0
        for (p, s) in zip(lab, saliency) {
            let w = weights(s).subject
            guard w > 0 else { continue }
            if Bins.neighborhoodMass(of: p, in: histogram) >= threshold { blended += Double(w) }
        }
        return SeparationCheck(subjectShare: mass.subject / Double(lab.count),
                               subject: sums.subject / Float(mass.subject), background: sums.background / Float(mass.background),
                               subjectChroma: chroma.subject / mass.subject, backgroundChroma: chroma.background / mass.background,
                               blendShare: blended / mass.subject)
    }

    /// For each of `colors` (OKLab), the share (0...1) of the pixels nearest to it that are subject: 1 for a color only
    /// the subject has, 0 for one only the background has. A color without pixels gets 0.
    public static func subjectFractions(lab: [SIMD3<Float>], saliency: [Float], colors: [SIMD3<Float>]) -> [Double] {
        guard !colors.isEmpty else { return [] }
        var subject = [Double](repeating: 0, count: colors.count), total = subject
        for (p, s) in zip(lab, saliency) {
            var best = 0, bestDistance = Float.infinity
            for (i, c) in colors.enumerated() {
                let d = simd_distance_squared(p, c)
                if d < bestDistance { best = i; bestDistance = d }
            }
            let (w, rest) = weights(s)
            subject[best] += Double(w)
            total[best] += Double(w + rest)
        }
        return zip(subject, total).map { $1 > 0 ? $0 / $1 : 0 }
    }

    /// A color counts as background when at most this share of its pixels is subject.
    public static let backgroundFraction = 0.3

    /// The sRGB hue a background color is aimed at so it stands further apart from the subject: on the OKLab hue circle it
    /// is pushed `push` degrees away from `subjectAngle` (the subject's OKLab hue), but not beyond `enough` degrees from
    /// it; a color that is that far already keeps its hue.
    public static func separatedHue(of color: SRGBColor, fromSubjectAngle subjectAngle: Double, push: Double = 30,
                                    enough: Double = 90) -> Double {
        let lab = color.oklab
        let angle = Double(atan2(lab.z, lab.y)) * 180 / .pi
        let d = ColorMath.signedAngle(from: subjectAngle, to: angle)
        guard abs(d) < enough else { return color.hsb.h }
        let target = subjectAngle + (d < 0 ? -1 : 1) * min(abs(d) + push, enough)
        let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
        let radians = Float(target * .pi / 180)
        return SRGBColor(oklab: SIMD3(lab.x, chroma * cos(radians), chroma * sin(radians))).hsb.h
    }

    /// A coarse OKLab grid for the background's colors.
    private enum Bins {
        static let lightness = 20, ab = 32
        static let count = lightness * ab * ab
        static func cell(_ p: SIMD3<Float>) -> (l: Int, a: Int, b: Int) {
            func clamp(_ v: Int, _ n: Int) -> Int { min(n - 1, max(0, v)) }
            return (clamp(Int(p.x * Float(lightness)), lightness),
                    clamp(Int((p.y + 0.32) / 0.02), ab), clamp(Int((p.z + 0.32) / 0.02), ab))
        }
        static func index(of p: SIMD3<Float>) -> Int {
            let c = cell(p)
            return (c.l * ab + c.a) * ab + c.b
        }
        /// The mass in the cell of `p` and its 26 neighbors.
        static func neighborhoodMass(of p: SIMD3<Float>, in histogram: [Float]) -> Float {
            let c = cell(p)
            var sum: Float = 0
            for l in max(0, c.l - 1)...min(lightness - 1, c.l + 1) {
                for a in max(0, c.a - 1)...min(ab - 1, c.a + 1) {
                    for b in max(0, c.b - 1)...min(ab - 1, c.b + 1) { sum += histogram[(l * ab + a) * ab + b] }
                }
            }
            return sum
        }
    }
}
