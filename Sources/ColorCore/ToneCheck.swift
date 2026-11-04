import Foundation

/// A check of the tones before any color work: clipped channels, the black and white point, and the tonal range. Like the
/// white balance check it comes first, because a grade cannot bring back what is clipped, and a photo without a real black
/// or white looks flat whatever its colors do. The findings are hints: a misty landscape has no black for a reason.
public struct ToneCheck: Sendable, Equatable {
    public enum Verdict: String, Sendable { case ok, slight, clear, unknown }

    public struct Finding: Sendable, Equatable {
        public enum Kind: String, Sendable { case blownHighlights, clippedChannel, crushedShadows, noBlack, noWhite, narrowRange }
        public var kind: Kind
        public var severity: Verdict
        /// What is the matter, e.g. "Highlights blown: 2.3 % of the photo is pure white".
        public var text: String
        /// What to try in PhotoLab.
        public var advice: String
    }

    /// Share of the pixels (0...1) whose red, green, blue channel is clipped at white, and at black.
    public var clippedHigh: [Double]
    public var clippedLow: [Double]
    /// Share of the pixels clipped in all three channels: blown to white, crushed to black.
    public var blown: Double
    public var crushed: Double
    /// OKLab lightness at the 0.5th and 99.5th percentile, and the mean.
    public var blackPoint: Double
    public var whitePoint: Double
    public var meanLightness: Double

    public var range: Double { whitePoint - blackPoint }

    /// Linear values at or beyond which a channel counts as clipped (about 254.5 and 0.5 of 255 in sRGB).
    public static let highClip: Float = 0.991, lowClip: Float = 0.00015

    public init(clippedHigh: [Double], clippedLow: [Double], blown: Double, crushed: Double, blackPoint: Double,
                whitePoint: Double, meanLightness: Double) {
        self.clippedHigh = clippedHigh
        self.clippedLow = clippedLow
        self.blown = blown
        self.crushed = crushed
        self.blackPoint = blackPoint
        self.whitePoint = whitePoint
        self.meanLightness = meanLightness
    }

    /// Checks `pixels` (linear sRGB, extended: values beyond 0...1 are clipped in an sRGB export too).
    public static func check(_ pixels: [SIMD3<Float>]) -> ToneCheck {
        let n = Double(max(1, pixels.count))
        var high = [0.0, 0.0, 0.0], low = [0.0, 0.0, 0.0]
        var blown = 0.0, crushed = 0.0
        var lightness: [Float] = []
        lightness.reserveCapacity(pixels.count)
        for p in pixels {
            let h = (p.x >= highClip, p.y >= highClip, p.z >= highClip)
            let l = (p.x <= lowClip, p.y <= lowClip, p.z <= lowClip)
            if h.0 { high[0] += 1 }
            if h.1 { high[1] += 1 }
            if h.2 { high[2] += 1 }
            if l.0 { low[0] += 1 }
            if l.1 { low[1] += 1 }
            if l.2 { low[2] += 1 }
            if h.0 && h.1 && h.2 { blown += 1 }
            if l.0 && l.1 && l.2 { crushed += 1 }
            lightness.append(ColorMath.linearToOKLab(SIMD3(max(0, min(1, p.x)), max(0, min(1, p.y)), max(0, min(1, p.z)))).x)
        }
        lightness.sort()
        func percentile(_ q: Double) -> Double {
            lightness.isEmpty ? 0 : Double(lightness[min(lightness.count - 1, Int(Double(lightness.count - 1) * q))])
        }
        return ToneCheck(clippedHigh: high.map { $0 / n }, clippedLow: low.map { $0 / n }, blown: blown / n, crushed: crushed / n,
                         blackPoint: percentile(0.005), whitePoint: percentile(0.995),
                         meanLightness: Double(lightness.reduce(0, +)) / n)
    }

    /// Checks every `step`-th pixel of `buffer` in both directions (small clipped areas get lost in a small copy), each first
    /// passed through `transform` (linear, OKLab → linear) when given.
    public static func check(_ buffer: PixelBuffer, step: Int = 2,
                             transform: ((SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>)? = nil) -> ToneCheck {
        let step = max(1, step)
        var pixels: [SIMD3<Float>] = []
        pixels.reserveCapacity((buffer.width / step + 1) * (buffer.height / step + 1))
        for y in stride(from: 0, to: buffer.height, by: step) {
            for x in stride(from: 0, to: buffer.width, by: step) {
                let i = y * buffer.width + x
                pixels.append(transform?(buffer.linear[i], buffer.lab[i]) ?? buffer.linear[i])
            }
        }
        return check(pixels)
    }

    /// The findings, worst first. `softTones` (an intention that asks for a low light–dark contrast) leaves out the ones
    /// about a missing black or white and a narrow range: a lifted, soft look is then the point.
    public func findings(softTones: Bool = false) -> [Finding] {
        var result: [Finding] = []
        func percent(_ v: Double) -> String { v < 0.1 ? String(format: "%.2f %%", v * 100) : String(format: "%.1f %%", v * 100) }
        if blown >= 0.005 {
            result.append(Finding(kind: .blownHighlights, severity: blown >= 0.03 ? .clear : .slight,
                                  text: "Highlights blown: \(percent(blown)) of the photo is pure white.",
                                  advice: "Lower Highlights or Whites (Light palette), or recover them from the RAW, before grading: a grade cannot bring back detail that is gone."))
        }
        // A channel clipped where the others are not: a saturated color has run out of range and lost its gradation.
        let names = ["red", "green", "blue"]
        let channelOnly = (0..<3).map { clippedHigh[$0] - blown }
        if let worst = channelOnly.indices.max(by: { channelOnly[$0] < channelOnly[$1] }), channelOnly[worst] >= 0.01 {
            result.append(Finding(kind: .clippedChannel, severity: channelOnly[worst] >= 0.05 ? .clear : .slight,
                                  text: "The \(names[worst]) channel is clipped on \(percent(channelOnly[worst])) of the photo: a saturated color has lost its gradation.",
                                  advice: "Lower the Saturation or Luminance of that color in the HSL palette, or export in a wide-gamut space."))
        }
        if crushed >= 0.02 {
            result.append(Finding(kind: .crushedShadows, severity: crushed >= 0.08 ? .clear : .slight,
                                  text: "Shadows crushed: \(percent(crushed)) of the photo is pure black.",
                                  advice: "Raise Blacks or Shadows (Light palette) if there should be detail there."))
        }
        if !softTones {
            if blackPoint > 0.25 {
                result.append(Finding(kind: .noBlack, severity: blackPoint > 0.35 ? .clear : .slight,
                                      text: String(format: "No deep black: the darkest tones sit at lightness %.0f.", blackPoint * 100),
                                      advice: "Lower Blacks (Light palette) for depth, unless a lifted, faded look is what you want."))
            }
            if whitePoint < 0.8 {
                result.append(Finding(kind: .noWhite, severity: whitePoint < 0.7 ? .clear : .slight,
                                      text: String(format: "No bright white: the lightest tones reach lightness %.0f.", whitePoint * 100),
                                      advice: "Raise Whites or Exposure (Light palette), unless the photo is meant to be low key."))
            }
            if range < 0.5, blackPoint <= 0.25, whitePoint >= 0.8 {
                result.append(Finding(kind: .narrowRange, severity: .slight,
                                      text: String(format: "Narrow tonal range: %.0f to %.0f.", blackPoint * 100, whitePoint * 100),
                                      advice: "Contrast or an S-curve (Light palette) gives the photo more depth."))
            }
        }
        return result.sorted { ($0.severity == .clear ? 0 : 1) < ($1.severity == .clear ? 0 : 1) }
    }

    public func verdict(softTones: Bool = false) -> Verdict {
        let found = findings(softTones: softTones)
        return found.contains { $0.severity == .clear } ? .clear : found.isEmpty ? .ok : .slight
    }

    /// The tonal range in words, e.g. "black 4 · white 98 · mean 52".
    public var summary: String {
        String(format: "black %.0f · white %.0f · mean %.0f", blackPoint * 100, whitePoint * 100, meanLightness * 100)
    }
}
