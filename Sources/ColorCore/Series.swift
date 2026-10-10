import Foundation

/// One dominant color of one photo in a series.
public struct SeriesColor: Sendable, Equatable {
    /// OKLab color.
    public var centroid: SIMD3<Float>
    /// Share of the photo (0...1).
    public var share: Double

    public init(centroid: SIMD3<Float>, share: Double) {
        self.centroid = centroid
        self.share = share
    }

    public var color: SRGBColor { SRGBColor(oklab: centroid) }
}

/// A color of the shared palette: what recurs across the series.
public struct SharedColor: Sendable, Equatable {
    public var centroid: SIMD3<Float>
    /// Share of the whole series (every photo counts equally), 0...1.
    public var share: Double
    /// Number of photos that have a color close to this one.
    public var presence: Int
    public var photoCount: Int

    public var color: SRGBColor { SRGBColor(oklab: centroid) }
}

/// How well one photo fits the series palette, with a starting point for aligning it.
public struct PhotoConsistency: Sendable, Equatable {
    /// Share-weighted OKLab distance of the photo's colors to the nearest palette color.
    public var meanDeltaE: Double
    /// 0...100, 100 = the photo's colors coincide with the shared palette.
    public var score: Int
    /// Share of the photo whose colors have no counterpart in the palette (e.g. a unique subject).
    public var unmatchedShare: Double
    /// False when too little of the photo matches the palette (see `minimumMatchedShare`) for the
    /// hue, saturation and lightness suggestions to mean anything.
    public var hasSuggestion: Bool
    /// Hue rotation in sRGB degrees that moves the photo's colors toward their palette colors;
    /// nil when there is no suggestion or too little of the photo is chromatic to say.
    public var hueShift: Double?
    /// Change of saturation (chroma) in percent: positive = the photo is less saturated than the series.
    public var saturationChange: Double
    /// Change of lightness in CIE L* points: positive = the photo is darker than the series.
    public var lightnessChange: Double
    /// Index into the palette for each of the photo's colors, nil when unmatched.
    public var matches: [Int?]
}

/// The palette color closest to one color, and what it takes to get there.
public struct SeriesMatch: Sendable, Equatable {
    /// Index into the palette.
    public var index: Int
    /// OKLab distance to the palette color.
    public var deltaE: Double
    /// Hue rotation in sRGB degrees; nil when either color is (nearly) neutral.
    public var hueShift: Double?
    /// Change of saturation (chroma) in percent: positive = the palette color is more saturated.
    public var saturationChange: Double
    /// Change of lightness in CIE L* points: positive = the palette color is lighter.
    public var lightnessChange: Double
}

public enum SeriesAnalyzer {
    /// OKLab distance within which two colors count as "the same color" across photos.
    public static let matchThreshold: Float = 0.12
    /// The same for a reference photo: it shows another scene, so a color's counterpart is simply the
    /// nearest reference color that is not very far away (about the "worst" distance).
    public static let referenceMatchThreshold: Float = 0.30
    /// Colors further than this from the palette all count as equally far off.
    public static let worstDeltaE = 0.30
    /// Mean distance at which the consistency score reaches 0.
    public static let scoreScale = 0.12
    /// Palette colors closer than this are merged.
    public static let mergeThreshold: Float = 0.05
    /// Share of a photo that must have a counterpart in the palette before alignment is suggested:
    /// for a photo that differs more, nearest-color pairs no longer follow the same hue family.
    public static let minimumMatchedShare = 0.6

    /// Clusters the dominant colors of all photos (weighted by share, every photo counting equally)
    /// into at most `size` shared colors, largest first.
    public static func sharedPalette(from photos: [[SeriesColor]], size: Int) -> [SharedColor] {
        var points: [SIMD3<Float>] = []
        var weights: [Float] = []
        for photo in photos {
            let total = photo.reduce(0) { $0 + $1.share }
            guard total > 0 else { continue }
            for color in photo {
                points.append(color.centroid)
                weights.append(Float(color.share / total))
            }
        }
        guard size > 0, !points.isEmpty else { return [] }

        let km = KMeans.cluster(points, weights: weights, k: min(size * 2, points.count))
        let merged = DominantColorAnalyzer.mergeClose(centroids: km.centroids, mass: km.mass, threshold: mergeThreshold)
        let totalMass = km.mass.reduce(0, +)
        return merged.ranked.prefix(size).map { index in
            let centroid = merged.centroids[index]
            let present = photos.filter { photo in
                photo.contains { distance($0.centroid, centroid) < Double(matchThreshold) }
            }.count
            return SharedColor(centroid: centroid, share: merged.mass[index] / totalMass,
                               presence: present, photoCount: photos.count)
        }
    }

    /// The palette color within `threshold` of `centroid` (OKLab), or nil when none is close
    /// enough — the color has no counterpart in the series.
    public static func match(_ centroid: SIMD3<Float>, against palette: [SharedColor],
                             threshold: Float = matchThreshold) -> SeriesMatch? {
        guard !palette.isEmpty else { return nil }
        let (index, d) = nearest(centroid, in: palette.map(\.centroid))
        guard d < Double(threshold) else { return nil }
        let color = SRGBColor(oklab: centroid), shared = palette[index].color
        let chromatic = color.chroma >= DxOMapping.neutralChroma && shared.chroma >= DxOMapping.neutralChroma
        return SeriesMatch(
            index: index, deltaE: d,
            hueShift: chromatic ? ColorMath.signedAngle(from: color.hsb.h, to: shared.hsb.h) : nil,
            saturationChange: color.chroma > 0 ? 100 * (shared.chroma - color.chroma) / color.chroma : 0,
            lightnessChange: shared.lightness - color.lightness)
    }

    public static func consistency(of colors: [SeriesColor], against palette: [SharedColor],
                                   threshold: Float = matchThreshold) -> PhotoConsistency {
        let total = colors.reduce(0) { $0 + $1.share }
        guard total > 0, !palette.isEmpty else {
            return PhotoConsistency(meanDeltaE: worstDeltaE, score: 0, unmatchedShare: 1, hasSuggestion: false,
                                    hueShift: nil, saturationChange: 0, lightnessChange: 0,
                                    matches: colors.map { _ in nil })
        }
        var weightedDistance = 0.0, unmatched = 0.0
        var matches: [Int?] = []
        // Sums over matched pairs.
        var sumWeight = 0.0, sumChromaPhoto = 0.0, sumChromaShift = 0.0, sumLightness = 0.0
        var sumSin = 0.0, sumCos = 0.0, sumHueWeight = 0.0

        for color in colors {
            let share = color.share / total
            let (index, d) = nearest(color.centroid, in: palette.map(\.centroid))
            weightedDistance += share * min(d, worstDeltaE)
            guard d < Double(threshold) else {
                unmatched += share
                matches.append(nil)
                continue
            }
            matches.append(index)
            let photo = color.color, shared = palette[index].color
            sumWeight += share
            sumChromaPhoto += share * photo.chroma
            sumChromaShift += share * (shared.chroma - photo.chroma)
            sumLightness += share * (shared.lightness - photo.lightness)
            if photo.chroma >= DxOMapping.neutralChroma, shared.chroma >= DxOMapping.neutralChroma {
                let weight = share * min(1, min(photo.chroma, shared.chroma) / 0.1)
                let angle = ColorMath.signedAngle(from: photo.hsb.h, to: shared.hsb.h) * .pi / 180
                sumSin += weight * sin(angle)
                sumCos += weight * cos(angle)
                sumHueWeight += weight
            }
        }

        let score = Int((100 * max(0, 1 - weightedDistance / scoreScale)).rounded())
        let reliable = 1 - unmatched >= minimumMatchedShare
        return PhotoConsistency(
            meanDeltaE: weightedDistance,
            score: score,
            unmatchedShare: unmatched,
            hasSuggestion: reliable,
            hueShift: reliable && sumHueWeight > 0.02 ? atan2(sumSin, sumCos) * 180 / .pi : nil,
            saturationChange: reliable && sumChromaPhoto > 0 ? 100 * sumChromaShift / sumChromaPhoto : 0,
            lightnessChange: reliable && sumWeight > 0 ? sumLightness / sumWeight : 0,
            matches: matches
        )
    }

    private static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
        Double(ColorMath.distanceSquared(a, b).squareRoot())
    }

    private static func nearest(_ p: SIMD3<Float>, in centroids: [SIMD3<Float>]) -> (Int, Double) {
        var best = 0
        var bestD = Double.infinity
        for (i, c) in centroids.enumerated() {
            let d = distance(p, c)
            if d < bestD {
                bestD = d
                best = i
            }
        }
        return (best, bestD)
    }
}
