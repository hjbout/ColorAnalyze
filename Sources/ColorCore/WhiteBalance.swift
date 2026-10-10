import Foundation

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

    public init(neutralShare: Double, cast: Double, a: Double, b: Double) {
        self.neutralShare = neutralShare
        self.cast = cast
        self.a = a
        self.b = b
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
        var sumA = 0.0, sumB = 0.0, mass = 0.0, total = 0.0
        for (i, p) in buffer.lab.enumerated() {
            let w = Double(weights?[i] ?? 1)
            total += w
            guard lightnessRange.contains(p.x), (p.y * p.y + p.z * p.z).squareRoot() < neutralChroma else { continue }
            sumA += w * Double(p.y)
            sumB += w * Double(p.z)
            mass += w
        }
        guard mass > 0, total > 0 else { return WhiteBalanceCheck(neutralShare: 0, cast: 0, a: 0, b: 0) }
        let a = sumA / mass, b = sumB / mass
        return WhiteBalanceCheck(neutralShare: mass / total, cast: (a * a + b * b).squareRoot(), a: a, b: b)
    }
}
