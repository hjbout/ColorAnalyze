import Foundation

/// The contrasts of a photo after Johannes Itten, measured on its pixels in OKLab. A harmony template only says how the
/// hues are ordered on the wheel; what a photo looks like depends at least as much on how light against dark, warm against
/// cool, vivid against muted and large against small its colors are. Itten names seven contrasts; the six that can be
/// read from the pixels are here (simultaneous contrast is an effect in the eye, not a property of the colors).
///
/// Every contrast has a strength from 0 (absent) to 1 (as strong as it gets in photographs) and a short reading. The
/// strengths describe the photo; none of them is better high or low, that depends on what the photo should feel like.
public struct ContrastProfile: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case lightDark, warmCool, saturation, hue, complementary, `extension`
        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .lightDark: "Light–dark"
            case .warmCool: "Warm–cool"
            case .saturation: "Saturation"
            case .hue: "Hue"
            case .complementary: "Complementary"
            case .extension: "Extension"
            }
        }

        /// What the contrast is, for a tooltip.
        public var explanation: String {
            switch self {
            case .lightDark: "Itten's light–dark contrast: the tonal range from the darkest to the lightest parts (OKLab lightness, 5th to 95th percentile). Low is flat or misty, high is graphic."
            case .warmCool: "Itten's cold–warm contrast: how evenly the color is split between warm hues (red, orange, yellow) and cool ones (green-cyan, blue, violet). High when both are strongly present."
            case .saturation: "How saturated the colors are: the median and the 97th percentile of OKLab chroma together, the typical color and the strongest. Itten's contrast of saturation (vivid against muted) shows in the gap between them in the reading, and in Extension."
            case .hue: "Itten's contrast of hue: how many different hues the photo has and how evenly spread they are, from the chroma-weighted spread of hue. Low for one hue family, high for many."
            case .complementary: "Itten's complementary contrast: how much of the color sits in hue families opposite each other (150°–180° apart on the OKLab hue circle)."
            case .extension: "Itten's contrast of extension (quantity): a small area of strong color held against a large area. High when a small patch is much more saturated than the photo as a whole."
            }
        }
    }

    /// OKLab chroma below which a pixel counts as neutral for the hue-based contrasts.
    public static let neutralChroma: Float = 0.03
    /// Twelve hue families of 30° on the OKLab hue circle.
    public static let familyCount = 12

    /// OKLab lightness at the 5th and 95th percentile, and the mean.
    public var darkLightness: Double
    public var lightLightness: Double
    public var meanLightness: Double
    /// Median and 97th percentile of OKLab chroma over all pixels.
    public var medianChroma: Double
    public var vividChroma: Double
    /// Share of the color (chroma-weighted, of the chromatic pixels) that is warm; nil without color.
    public var warmShare: Double?
    /// Share of the photo's pixels that are chromatic.
    public var chromaticShare: Double
    /// Chroma-weighted share of each of the twelve hue families (summing to 1), and the share of the photo's pixels in each.
    public var familyWeights: [Double]
    public var familyAreas: [Double]
    /// Mean chroma of the pixels in each family.
    public var familyChroma: [Double]
    /// Mean chroma of all pixels.
    public var meanChroma: Double

    // MARK: Strengths

    public func strength(_ kind: Kind) -> Double {
        switch kind {
        case .lightDark: return clamp((lightLightness - darkLightness - 0.2) / 0.55)
        case .warmCool:
            guard let warm = warmShare else { return 0 }
            // Balance of the two, scaled down when little of the photo has color at all.
            return clamp(2 * min(warm, 1 - warm)) * clamp(chromaticShare / 0.3)
        // How saturated the colors are: the typical color and the strongest ones together.
        case .saturation: return clamp(((medianChroma + vividChroma) / 2 - 0.02) / 0.13)
        case .hue:
            guard chromaticShare > 0 else { return 0 }
            return hueSpread * clamp(chromaticShare / 0.3)
        case .complementary:
            var sum = 0.0
            for i in 0..<Self.familyCount {
                for j in (i + 1)..<Self.familyCount where Self.familyDistance(i, j) >= 5 {
                    sum += familyWeights[i] * familyWeights[j]
                }
            }
            // Two equal halves exactly opposite give 0.25.
            return clamp(4 * sum) * clamp(chromaticShare / 0.3)
        case .extension:
            guard let accent else { return 0 }
            return clamp((accent.ratio - 1.3) / 2)
        }
    }

    /// The chroma-weighted circular spread of hue, 0 (one hue) to 1 (evenly spread).
    public var hueSpread: Double {
        var x = 0.0, y = 0.0
        for (i, w) in familyWeights.enumerated() {
            let a = (Double(i) + 0.5) * 30 * .pi / 180
            x += w * cos(a)
            y += w * sin(a)
        }
        return clamp(1 - (x * x + y * y).squareRoot())
    }

    /// The hue families that hold at least 8 % of the color, largest first.
    public var mainFamilies: [Int] {
        familyWeights.indices.filter { familyWeights[$0] >= 0.08 }.sorted { familyWeights[$0] > familyWeights[$1] }
    }

    /// The strongest small, vivid family: at most 12 % of the photo (and at least 0.3 %, so no stray pixels), and how
    /// many times the photo's mean chroma it has.
    public var accent: (family: Int, area: Double, ratio: Double)? {
        guard meanChroma > 0.005 else { return nil }
        return familyAreas.indices
            .filter { familyAreas[$0] >= 0.003 && familyAreas[$0] <= 0.12 }
            .map { (family: $0, area: familyAreas[$0], ratio: familyChroma[$0] / meanChroma) }
            .max { $0.ratio < $1.ratio }
    }

    /// A short reading of a contrast, e.g. "tonal range 0.12–0.91 · low key".
    public func reading(_ kind: Kind) -> String {
        switch kind {
        case .lightDark:
            let key = meanLightness < 0.42 ? " · low key" : meanLightness > 0.72 ? " · high key" : ""
            return String(format: "range %.0f–%.0f%@", darkLightness * 100, lightLightness * 100, key)
        case .warmCool:
            guard let warm = warmShare, chromaticShare >= 0.02 else { return "hardly any color" }
            return "warm \(Self.percent(warm)) · cool \(Self.percent(1 - warm))"
        case .saturation:
            let level = medianChroma < 0.04 ? "muted" : medianChroma > 0.1 ? "vivid" : "moderate"
            return String(format: "%@ overall, peaks at %.0f", level, vividChroma * 100)
        case .hue:
            let families = mainFamilies
            guard !families.isEmpty, chromaticShare >= 0.02 else { return "hardly any color" }
            return families.prefix(4).map { Self.familyName($0) }.joined(separator: ", ")
                + (families.count > 4 ? " +\(families.count - 4)" : "")
        case .complementary:
            let pairs = mainFamilies.flatMap { i in mainFamilies.filter { $0 > i && Self.familyDistance(i, $0) >= 5 }.map { (i, $0) } }
            guard let pair = pairs.max(by: { familyWeights[$0.0] * familyWeights[$0.1] < familyWeights[$1.0] * familyWeights[$1.1] })
            else { return "no opposite hues" }
            return "\(Self.familyName(pair.0)) against \(Self.familyName(pair.1))"
        case .extension:
            guard let accent, strength(.extension) > 0 else { return "no small vivid patch" }
            return String(format: "%@ on %@ of the photo, %.1f× as saturated", Self.familyName(accent.family),
                          Self.percent(accent.area), accent.ratio)
        }
    }

    // MARK: Against an intention

    /// How a strength stands toward what an intention asks: there, half way, or the other way.
    public enum AimStatus: String, Sendable { case met, partly, opposite }

    /// High is met from 60, low up to 35; between them is half way.
    public static func status(of strength: Double, toward aim: Intention.ContrastAim) -> AimStatus {
        switch aim {
        case .high: strength >= 0.6 ? .met : strength >= 0.35 ? .partly : .opposite
        case .low: strength <= 0.35 ? .met : strength <= 0.6 ? .partly : .opposite
        }
    }

    /// Whether a grading moves a strength toward the aim (+1), away from it (−1) or hardly (0, less than 3 points).
    public static func progress(from before: Double, to after: Double, toward aim: Intention.ContrastAim) -> Int {
        let delta = (after - before) * (aim == .high ? 1 : -1)
        return delta > 0.03 ? 1 : delta < -0.03 ? -1 : 0
    }

    // MARK: Measuring

    /// The profile of `lab` (one OKLab color per pixel).
    public init(lab: [SIMD3<Float>]) {
        let n = max(1, lab.count)
        var lightness = lab.map(\.x)
        lightness.sort()
        var chromas = lab.map { ($0.y * $0.y + $0.z * $0.z).squareRoot() }
        let meanChroma = chromas.reduce(0, +) / Float(n)
        var weights = [Double](repeating: 0, count: Self.familyCount)
        var areas = weights, chromaSums = weights
        var warm = 0.0, total = 0.0, chromatic = 0
        for (p, c) in zip(lab, chromas) where c >= Self.neutralChroma {
            let angle = ColorMath.normalizeDegrees(Double(atan2(p.z, p.y)) * 180 / .pi)
            let family = min(Self.familyCount - 1, Int(angle / 30))
            weights[family] += Double(c)
            areas[family] += 1
            chromaSums[family] += Double(c)
            // Warm is the half of the circle around OKLab hue 50° (between red and yellow): magenta-red to yellow.
            if cos((angle - 50) * .pi / 180) > 0 { warm += Double(c) }
            total += Double(c)
            chromatic += 1
        }
        chromas.sort()
        func percentile(_ values: [Float], _ p: Double) -> Double {
            values.isEmpty ? 0 : Double(values[min(values.count - 1, Int(Double(values.count - 1) * p))])
        }
        darkLightness = percentile(lightness, 0.05)
        lightLightness = percentile(lightness, 0.95)
        meanLightness = Double(lightness.reduce(0, +)) / Double(n)
        medianChroma = percentile(chromas, 0.5)
        vividChroma = percentile(chromas, 0.97)
        self.meanChroma = Double(meanChroma)
        chromaticShare = Double(chromatic) / Double(n)
        warmShare = total > 0 ? warm / total : nil
        familyWeights = total > 0 ? weights.map { $0 / total } : weights
        familyChroma = zip(chromaSums, areas).map { $1 > 0 ? $0 / $1 : 0 }
        familyAreas = areas.map { $0 / Double(n) }
    }

    // MARK: Helpers

    /// Steps between two families around the circle (0...6).
    static func familyDistance(_ i: Int, _ j: Int) -> Int {
        let d = abs(i - j) % familyCount
        return min(d, familyCount - d)
    }

    /// Names of the twelve families of 30° on the OKLab hue circle, from 0°. In sRGB hue they cover about 341°–8°, 8°–28°,
    /// 28°–45°, 45°–73°, 73°–134°, 134°–171°, 171°–187°, 187°–204°, 204°–226°, 226°–262°, 262°–305° and 305°–341°.
    static let familyNames = ["red", "red-orange", "orange", "yellow", "yellow-green", "green", "cyan", "sky blue",
                              "azure", "blue", "violet", "magenta"]

    public static func familyName(_ family: Int) -> String { familyNames[family] }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }

    private func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
}
