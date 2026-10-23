import Foundation

public enum HarmonyKind: String, CaseIterable, Identifiable, Sendable {
    case monochromatic, analogous, analogousAccent, complementary, splitComplementary, triadic, tetradic, square

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .monochromatic: "Monochromatic"
        case .analogous: "Analogous"
        case .analogousAccent: "Analogous + accent"
        case .complementary: "Complementary"
        case .splitComplementary: "Split-complementary"
        case .triadic: "Triadic"
        case .tetradic: "Tetradic (rectangle)"
        case .square: "Square"
        }
    }

    /// Target hues relative to the rotation.
    public var offsets: [Double] {
        switch self {
        case .monochromatic: [0]
        case .analogous: [-30, 0, 30]
        case .analogousAccent: [-30, 0, 30, 180]
        case .complementary: [0, 180]
        case .splitComplementary: [0, 150, 210]
        case .triadic: [0, 120, 240]
        case .tetradic: [0, 60, 180, 240]
        case .square: [0, 90, 180, 270]
        }
    }
}

public struct HarmonyInput: Sendable {
    public var hue: Double
    public var weight: Double

    public init(hue: Double, weight: Double) {
        self.hue = hue
        self.weight = weight
    }
}

/// The color wheel a harmony is computed on.
///
/// `rgb` is the sRGB/HSB hue circle (complement of red is cyan). DxO's own hue axis differs from it (see `DxOHue`).
/// `ryb` is the traditional artist's red–yellow–blue wheel used by Adobe Color's "artistic" wheel
/// and most color-theory teaching (complements: red–green, orange–blue, yellow–violet).
/// `dxo` is PhotoLab's own hue axis (HSV hue in Rec.2020, the axis of its Color Grading and HSL wheels, see `DxOHue`):
/// a hue on it is the Hue number PhotoLab shows, and a harmony drawn on it is a harmony in PhotoLab's terms (its
/// complement is +180° on PhotoLab's own wheel). A color's position is that of the pure color with its sRGB hue, so a
/// pale color sits up to about 9° from where PhotoLab would measure it.
/// `oklch` is the hue angle of OKLCH (the polar form of OKLab), a perceptual wheel: equal steps look like equal steps of
/// color, so green and yellow are not stretched as on the sRGB circle, and harmony angles mean what they say. A color is
/// placed at the OKLab hue of the pure color with its sRGB hue.
/// Colors never change; only the *position* of a hue on the wheel does, via a piecewise-linear
/// map through the anchors of the 12-step artist's wheel (or, for `dxo` and `oklch`, through one point per degree).
public enum HueSpace: String, CaseIterable, Identifiable, Sendable {
    case rgb, ryb, dxo, oklch, lab, munsell, itten

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .rgb: "RGB"
        case .ryb: "RYB"
        case .dxo: "DxO"
        case .oklch: "OKLCH"
        case .lab: "CIELAB"
        case .munsell: "Munsell"
        case .itten: "Itten"
        }
    }

    /// The hue of the pure color at each whole sRGB degree 0...360 on a wheel that is a function of it, rising
    /// (the last is the first plus 360).
    private static func anchors(_ hueOfPureColor: (Double) -> Double) -> [Double] {
        let raw = (0...360).map { hueOfPureColor(Double($0)) }
        var values = [raw[0]]
        var turns = 0.0
        for i in 1..<360 {
            // A drop of more than half a turn is the wrap past 360°; a small dip is a flat stretch of the function
            // (blue, on the OKLab circle) and must not become a turn.
            if raw[i] < raw[i - 1] - 180 { turns += 360 }
            values.append(max(raw[i] + turns, values[i - 1] + 1e-4))
        }
        values.append(raw[0] + 360)
        return values
    }
    /// PhotoLab hue of the pure color, and its OKLab hue angle.
    private static let dxoAnchors = anchors { DxOHue.fromSRGB($0) }
    private static let oklchAnchors = anchors { hue in
        let lab = SRGBColor.fromHSB(h: hue, s: 1, b: 1).oklab
        return ColorMath.normalizeDegrees(Double(atan2(lab.z, lab.y)) * 180 / .pi)
    }
    /// CIELAB hue angle (atan2 of b*, a*, D65) of the pure color.
    private static let labAnchors = anchors { hue in
        let l = SRGBColor.fromHSB(h: hue, s: 1, b: 1).linear
        let x = (0.4124564 * l.x + 0.3575761 * l.y + 0.1804375 * l.z) / 0.95047
        let y = 0.2126729 * l.x + 0.7151522 * l.y + 0.0721750 * l.z
        let z = (0.0193339 * l.x + 0.1191920 * l.y + 0.9503041 * l.z) / 1.08883
        func f(_ t: Float) -> Float { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        return ColorMath.normalizeDegrees(Double(atan2(200 * (f(y) - f(z)), 500 * (f(x) - f(y)))) * 180 / .pi)
    }
    /// sRGB hue of the 40 Munsell hues 2.5R … 10RP (steps of 2.5, i.e. 9° on the wheel, 5R at 18°) at value 6 and the highest
    /// chroma (up to 10) that fits sRGB, from the Munsell renotation (Python ), and their position on the wheel.
    private static let munsellRGBAnchors: [Double] = [0.0, 5.1, 12.9, 19.2, 25.9, 31.9, 37.8, 44.0, 45.7, 50.6, 55.3, 63.0, 70.6, 89.8, 116.6, 149.8, 158.6, 165.0, 170.2, 174.8, 179.9, 184.7, 189.0, 192.8, 193.7, 199.2, 200.5, 209.1, 217.0, 232.6, 249.5, 264.2, 276.4, 293.9, 308.8, 320.9, 332.2, 339.2, 345.8, 351.8, 357.9, 360.0]
    private static let munsellAnchors: [Double] = [20.6, 27.0, 36.0, 45.0, 54.0, 63.0, 72.0, 81.0, 90.0, 99.0, 108.0, 117.0, 126.0, 135.0, 144.0, 153.0, 162.0, 171.0, 180.0, 189.0, 198.0, 207.0, 216.0, 225.0, 234.0, 243.0, 252.0, 261.0, 270.0, 279.0, 288.0, 297.0, 306.0, 315.0, 324.0, 333.0, 342.0, 351.0, 360.0, 369.0, 378.0, 380.6]
    /// sRGB hue of the twelve colors of Itten's printed wheel (red, red-orange, orange, yellow-orange, yellow, yellow-green,
    /// green, blue-green, blue, blue-violet, violet, red-violet; 30° apart, red at 0°). Itten's yellow is warm, his
    /// blue is a deep ultramarine and his green sits nearer yellow than the sRGB green does.
    private static let ittenRGBAnchors: [Double] = [0, 12, 28, 41, 55, 90, 130, 185, 220, 255, 285, 325, 355, 360]
    private static let ittenAnchors: [Double] = [8.8, 30, 60, 90, 120, 150, 180, 210, 240, 270, 300, 330, 360, 368.8]
    private static let degreeAnchors: [Double] = (0...360).map(Double.init)

    /// sRGB hue (°) and its position on the RYB wheel (°) for red, orange, yellow, green,
    /// cyan, blue, violet and magenta; both lists are increasing and end at 360.
    private static let rgbAnchors: [Double] = [0, 30, 60, 120, 180, 240, 270, 300, 360]
    private static let rybAnchors: [Double] = [0, 60, 120, 180, 210, 240, 300, 330, 360]

    /// Position (degrees, 0...360) of an sRGB hue on this wheel.
    public func position(ofRGBHue hue: Double) -> Double {
        switch self {
        case .rgb: ColorMath.normalizeDegrees(hue)
        case .ryb: Self.interpolate(ColorMath.normalizeDegrees(hue), from: Self.rgbAnchors, to: Self.rybAnchors)
        case .dxo: Self.interpolate(ColorMath.normalizeDegrees(hue), from: Self.degreeAnchors, to: Self.dxoAnchors)
        case .oklch: Self.interpolate(ColorMath.normalizeDegrees(hue), from: Self.degreeAnchors, to: Self.oklchAnchors)
        case .lab: Self.interpolate(ColorMath.normalizeDegrees(hue), from: Self.degreeAnchors, to: Self.labAnchors)
        case .munsell: Self.interpolate(ColorMath.normalizeDegrees(hue), from: Self.munsellRGBAnchors, to: Self.munsellAnchors)
        case .itten: Self.interpolate(ColorMath.normalizeDegrees(hue), from: Self.ittenRGBAnchors, to: Self.ittenAnchors)
        }
    }

    /// sRGB hue (degrees, 0...360) at a position on this wheel.
    public func rgbHue(atPosition position: Double) -> Double {
        switch self {
        case .rgb:
            return ColorMath.normalizeDegrees(position)
        case .ryb:
            return Self.interpolate(ColorMath.normalizeDegrees(position), from: Self.rybAnchors, to: Self.rgbAnchors)
        case .dxo:
            return Self.inverse(position, anchors: Self.dxoAnchors)
        case .oklch:
            return Self.inverse(position, anchors: Self.oklchAnchors)
        case .lab:
            return Self.inverse(position, anchors: Self.labAnchors)
        case .munsell:
            return Self.inverse(position, anchors: Self.munsellAnchors, to: Self.munsellRGBAnchors)
        case .itten:
            return Self.inverse(position, anchors: Self.ittenAnchors, to: Self.ittenRGBAnchors)
        }
    }

    private static func inverse(_ position: Double, anchors: [Double], to: [Double]? = nil) -> Double {
        var v = ColorMath.normalizeDegrees(position)
        if v < anchors[0] { v += 360 }
        return interpolate(v, from: anchors, to: to ?? degreeAnchors)
    }

    private static func interpolate(_ v: Double, from xs: [Double], to ys: [Double]) -> Double {
        var i = 1
        while i < xs.count - 1, v > xs[i] { i += 1 }
        let t = (v - xs[i - 1]) / (xs[i] - xs[i - 1])
        return ColorMath.normalizeDegrees(ys[i - 1] + t * (ys[i] - ys[i - 1]))
    }
}

public struct HarmonyFit: Sendable, Equatable {
    public var kind: HarmonyKind
    /// Position of the template's first target on the wheel of `space`, in degrees.
    public var rotation: Double
    /// Weighted RMS distance of the colors to their nearest target, in degrees on the wheel of `space`.
    public var deviation: Double
    public var space: HueSpace
    /// Half-width of the sector around each target, in degrees on the wheel of `space`. A color inside a sector is on
    /// target (distance 0, no shift); outside it counts by its distance to the sector's edge. 0 = the exact hue.
    public var tolerance: Double

    public init(kind: HarmonyKind, rotation: Double, deviation: Double, space: HueSpace = .rgb, tolerance: Double = 0) {
        self.kind = kind
        self.rotation = rotation
        self.deviation = deviation
        self.space = space
        self.tolerance = tolerance
    }

    /// Target positions on the wheel of `space`, in degrees (what the overlay draws).
    public var targets: [Double] {
        kind.offsets.map { ColorMath.normalizeDegrees(rotation + $0) }
    }

    /// The same targets as sRGB hues.
    public var targetRGBHues: [Double] {
        targets.map { space.rgbHue(atPosition: $0) }
    }

    /// Signed distance (degrees on the wheel of `space`) from an sRGB hue to its nearest target.
    public func signedDistance(from rgbHue: Double) -> Double {
        Self.signedDistance(from: space.position(ofRGBHue: rgbHue), targets: targets, tolerance: tolerance)
    }

    /// Signed hue shift in **sRGB degrees** that moves `rgbHue` onto its nearest target,
    /// whichever wheel the harmony was computed on.
    public func shift(for rgbHue: Double) -> Double {
        let position = space.position(ofRGBHue: rgbHue)
        guard let target = targets.min(by: {
            abs(ColorMath.signedAngle(from: position, to: $0)) < abs(ColorMath.signedAngle(from: position, to: $1))
        }) else { return 0 }
        let distance = ColorMath.signedAngle(from: position, to: target)
        guard abs(distance) > tolerance else { return 0 }   // inside the sector: nothing to do
        // Move to the near edge of the sector, not to its middle.
        let edge = target - (distance < 0 ? -tolerance : tolerance)
        return ColorMath.signedAngle(from: rgbHue, to: space.rgbHue(atPosition: ColorMath.normalizeDegrees(edge)))
    }

    /// Signed distance to the nearest target's sector (0 inside it).
    static func signedDistance(from position: Double, targets: [Double], tolerance: Double = 0) -> Double {
        let d = targets.map { ColorMath.signedAngle(from: position, to: $0) }
            .min { abs($0) < abs($1) } ?? 0
        return abs(d) <= tolerance ? 0 : d - (d < 0 ? -tolerance : tolerance)
    }
}

public enum HarmonyDetector {
    /// Penalty per extra target hue (degrees²), so simpler harmonies win when the fit is similar.
    public static let complexityPenalty = 50.0

    /// Best rotation of `kind` for the given (sRGB) hues on the wheel of `space`,
    /// or nil if there are no weighted inputs.
    public static func fit(_ kind: HarmonyKind, to inputs: [HarmonyInput], space: HueSpace = .rgb,
                           tolerance: Double = 0) -> HarmonyFit? {
        let weighted = weightedPositions(inputs, space: space)
        guard !weighted.isEmpty else { return nil }
        var best = HarmonyFit(kind: kind, rotation: 0, deviation: .infinity, space: space, tolerance: tolerance)
        for rotation in stride(from: 0.0, to: 360.0, by: 1.0) {
            let fit = evaluate(kind, rotation: rotation, weighted: weighted, space: space, tolerance: tolerance)
            if fit.deviation < best.deviation { best = fit }
        }
        return best
    }

    /// Fit of `kind` at a fixed rotation (e.g. after the user rotated the overlay).
    public static func evaluate(_ kind: HarmonyKind, rotation: Double, inputs: [HarmonyInput],
                                space: HueSpace = .rgb, tolerance: Double = 0) -> HarmonyFit? {
        let weighted = weightedPositions(inputs, space: space)
        guard !weighted.isEmpty else { return nil }
        return evaluate(kind, rotation: rotation, weighted: weighted, space: space, tolerance: tolerance)
    }

    /// The harmony that best explains the hues, preferring simpler templates.
    public static func detect(_ inputs: [HarmonyInput], space: HueSpace = .rgb, tolerance: Double = 0) -> HarmonyFit? {
        HarmonyKind.allCases
            .compactMap { kind in fit(kind, to: inputs, space: space, tolerance: tolerance).map { (fit: $0, cost: cost(of: $0)) } }
            .min { $0.cost < $1.cost }?.fit
    }

    private static func cost(of fit: HarmonyFit) -> Double {
        fit.deviation * fit.deviation + complexityPenalty * Double(fit.kind.offsets.count - 1)
    }

    /// Wheel positions with their weights; zero-weight inputs are dropped.
    private static func weightedPositions(_ inputs: [HarmonyInput], space: HueSpace) -> [(position: Double, weight: Double)] {
        inputs.filter { $0.weight > 0 }.map { (space.position(ofRGBHue: $0.hue), $0.weight) }
    }

    private static func evaluate(_ kind: HarmonyKind, rotation: Double, weighted: [(position: Double, weight: Double)],
                                 space: HueSpace, tolerance: Double) -> HarmonyFit {
        var fit = HarmonyFit(kind: kind, rotation: ColorMath.normalizeDegrees(rotation), deviation: 0, space: space,
                             tolerance: tolerance)
        let targets = fit.targets
        var sum = 0.0, total = 0.0
        for item in weighted {
            let d = HarmonyFit.signedDistance(from: item.position, targets: targets, tolerance: tolerance)
            sum += item.weight * d * d
            total += item.weight
        }
        fit.deviation = (sum / total).squareRoot()
        return fit
    }
}
