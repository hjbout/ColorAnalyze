import CoreGraphics
import Foundation

public struct DominantColor: Sendable {
    /// Cluster centroid in OKLab.
    public var centroid: SIMD3<Float>
    /// Fraction of the image assigned to this cluster (0...1).
    public var share: Double
    /// Center of the largest homogeneous patch, normalized with a top-left origin.
    public var location: CGPoint
    /// Found by the accent search (a small, striking color) and not by share.
    public var isAccent = false
}

public enum DominantColorAnalyzer {
    /// OKLab distance below which over-clustered colors are merged.
    public static let mergeThreshold: Float = 0.05
    /// Patch-search window, as a fraction of the short side.
    public static let windowFraction = 0.06
    /// Patches scoring at least this fraction of the best one count as equally good.
    public static let nearBestFraction = 0.97
    /// Independent k-means runs per analysis; the tightest one is kept.
    public static let restarts = 5

    /// Finds up to `count` dominant colors, sorted by share (largest first).
    /// `weights` (one per pixel, e.g. 1 + strength × saliency) make the subject count
    /// more: they steer the clusters, the shares and where the markers land.
    public static func analyze(_ buffer: PixelBuffer, count: Int, accents: Int = 0, weights: [Float]? = nil) -> [DominantColor] {
        let n = buffer.lab.count
        guard n > 0, count > 0 else { return [] }
        guard accents > 0 else { return dominant(buffer, count: count, weights: weights) }

        // The accents come out of the same number of colors: the dominant ones are found first, then each accent is the
        // most striking color they leave out. An accent that is not there (a photo without one) is left to a dominant color.
        var colors = dominant(buffer, count: max(1, count - accents), weights: weights)
        var found: [DominantColor] = []
        while found.count < min(accents, count - 1),
              let accent = findAccent(in: buffer, existing: (colors + found).map(\.centroid), weights: weights) {
            found.append(accent)
        }
        if found.count < accents {
            colors = dominant(buffer, count: count - found.count, weights: weights)
        }
        return colors + found
    }

    static func dominant(_ buffer: PixelBuffer, count: Int, weights: [Float]?) -> [DominantColor] {
        let n = buffer.lab.count

        // Over-cluster, then merge near-duplicates so a large gradient (sky) does not
        // take several slots at the expense of a small accent color.
        let km = KMeans.clusterBest(buffer.lab, weights: weights, k: min(count * 2, n), restarts: restarts)
        let totalMass = km.mass.reduce(0, +)
        let merged = mergeClose(centroids: km.centroids, mass: km.mass, threshold: mergeThreshold)
        let centroids = merged.centroids, mass = merged.mass
        let label = merged.label
        let kept = merged.ranked.prefix(count)
        let assignments = km.assignments.map { label[$0] }

        return kept.map { c in
            DominantColor(centroid: centroids[c],
                          share: mass[c] / totalMass,
                          location: bestLocation(of: c, assignments: assignments, weights: weights,
                                                 centroid: centroids[c], buffer: buffer))
        }
    }

    /// Assigns every pixel to its nearest color and returns each color's share (sums to 1).
    /// With `weights`, pixels count by weight instead of one each.
    public static func shares(of colors: [SIMD3<Float>], in buffer: PixelBuffer, weights: [Float]? = nil) -> [Double] {
        guard !colors.isEmpty, !buffer.lab.isEmpty else { return colors.map { _ in 0 } }
        var mass = [Double](repeating: 0, count: colors.count)
        for (i, p) in buffer.lab.enumerated() {
            mass[KMeans.nearest(p, in: colors)] += Double(weights?[i] ?? 1)
        }
        let total = mass.reduce(0, +)
        return mass.map { $0 / total }
    }

    /// Repeatedly merges the two closest clusters while they are closer than `threshold`
    /// (OKLab), averaging by mass. Returns the merged clusters, the merged index of every
    /// original cluster, and the survivors ranked by mass (largest first).
    static func mergeClose(centroids input: [SIMD3<Float>], mass inputMass: [Double], threshold: Float)
        -> (centroids: [SIMD3<Float>], mass: [Double], label: [Int], ranked: [Int]) {
        var centroids = input
        var mass = inputMass
        var label = Array(centroids.indices) // cluster → merged cluster
        var alive = Array(repeating: true, count: centroids.count)
        while let (a, b) = closestPair(centroids, alive: alive),
              ColorMath.distanceSquared(centroids[a], centroids[b]) < threshold * threshold {
            let total = Float(mass[a] + mass[b])
            centroids[a] = (centroids[a] * Float(mass[a]) + centroids[b] * Float(mass[b])) / total
            mass[a] += mass[b]
            alive[b] = false
            for i in label.indices where label[i] == b { label[i] = a }
        }
        let ranked = centroids.indices.filter { alive[$0] }.sorted { mass[$0] > mass[$1] }
        return (centroids, mass, label, ranked)
    }

    private static func closestPair(_ centroids: [SIMD3<Float>], alive: [Bool]) -> (Int, Int)? {
        var best: (Int, Int)?
        var bestD = Float.infinity
        for i in centroids.indices where alive[i] {
            for j in centroids.indices where j > i && alive[j] {
                let d = ColorMath.distanceSquared(centroids[i], centroids[j])
                if d < bestD {
                    bestD = d
                    best = (i, j)
                }
            }
        }
        return best
    }

    /// Pixel of cluster `c` whose surrounding window holds the most weight of `c`
    /// (pixels count one each without weights, so this is the largest homogeneous patch;
    /// with weights, patches on the subject win). Ties go to the pixel closest to the
    /// centroid. Parts of the window outside the image count as empty, so markers stay
    /// away from the edges.
    private static func bestLocation(of c: Int, assignments: [Int], weights: [Float]?, centroid: SIMD3<Float>,
                                     buffer: PixelBuffer) -> CGPoint {
        bestPatch(of: c, assignments: assignments, weights: weights, centroid: centroid, buffer: buffer).location
    }

    /// `bestLocation`, with the score of that spot: how much of the window around it the color holds (0...1 without weights).
    private static func bestPatch(of c: Int, assignments: [Int], weights: [Float]?, centroid: SIMD3<Float>,
                                  buffer: PixelBuffer) -> (location: CGPoint, fill: Double) {
        let w = buffer.width, h = buffer.height
        // Summed-area table with a zero border row/column.
        var sat = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                if assignments[y * w + x] == c { row += Double(weights?[y * w + x] ?? 1) }
                sat[(y + 1) * (w + 1) + x + 1] = sat[y * (w + 1) + x + 1] + row
            }
        }
        let half = max(1, Int((Double(min(w, h)) * windowFraction / 2).rounded()))
        let windowArea = Double((2 * half + 1) * (2 * half + 1))

        // Score every pixel of the cluster by how much of the cluster surrounds it.
        var scores = [Double](repeating: -1, count: w * h)
        var maxScore = 0.0
        var sumX = 0.0, sumY = 0.0, sumWeight = 0.0
        for y in 0..<h {
            let y0 = max(0, y - half), y1 = min(h, y + half + 1)
            for x in 0..<w where assignments[y * w + x] == c {
                let x0 = max(0, x - half), x1 = min(w, x + half + 1)
                let inside = sat[y1 * (w + 1) + x1] - sat[y0 * (w + 1) + x1]
                    - sat[y1 * (w + 1) + x0] + sat[y0 * (w + 1) + x0]
                let score = inside / windowArea
                scores[y * w + x] = score
                maxScore = max(maxScore, score)
                let weight = Double(weights?[y * w + x] ?? 1)
                sumX += weight * Double(x)
                sumY += weight * Double(y)
                sumWeight += weight
            }
        }

        // Among the (nearly) best patches take the one closest to the middle of the color's pixels:
        // on a flat backdrop every pixel scores the same, and the corner is a poor place for a marker.
        let cx = sumWeight > 0 ? sumX / sumWeight : Double(w) / 2, cy = sumWeight > 0 ? sumY / sumWeight : Double(h) / 2
        var best = (x: 0, y: 0)
        var bestDistance = Double.infinity
        var bestColorDistance = Float.infinity
        for y in 0..<h {
            for x in 0..<w where scores[y * w + x] >= maxScore * nearBestFraction && scores[y * w + x] >= 0 {
                let d = (Double(x) - cx) * (Double(x) - cx) + (Double(y) - cy) * (Double(y) - cy)
                let colorDistance = ColorMath.distanceSquared(buffer.lab[y * w + x], centroid)
                if d < bestDistance || (d == bestDistance && colorDistance < bestColorDistance) {
                    bestDistance = d
                    bestColorDistance = colorDistance
                    best = (x, y)
                }
            }
        }
        return (CGPoint(x: (Double(best.x) + 0.5) / Double(w), y: (Double(best.y) + 0.5) / Double(h)), maxScore)
    }
}

// MARK: Accents

extension DominantColorAnalyzer {
    /// OKLab distance from the colors already chosen beyond which a color counts as something else.
    public static let accentDistance: Float = 0.07
    /// OKLab chroma below which a color is too grey to be an accent.
    public static let accentMinimumChroma: Float = 0.06
    /// Share of the photo (pixels) an accent must cover at least: below it a color is a speck, grain or a glint.
    public static let accentMinimumShare = 0.0015
    /// How much of the patch window the color must fill around its best spot: a coherent patch, not scattered pixels.
    public static let accentMinimumFill = 0.35

    /// The most striking color the `existing` colors leave out: far from all of them, saturated, and a coherent patch of
    /// at least 0.15 % of the photo. Candidates are clusters of such pixels, scored by chroma² × distance × how well they
    /// fill their patch: size only has to clear the minimum, so a small vivid patch beats a big, milder one. nil when
    /// the photo has no such color.
    public static func findAccent(in buffer: PixelBuffer, existing: [SIMD3<Float>],
                                  weights: [Float]? = nil) -> DominantColor? {
        let n = buffer.lab.count
        guard n > 0, !existing.isEmpty else { return nil }

        var points: [SIMD3<Float>] = []
        var pointWeights: [Float] = []
        var pointIndex: [Int] = []
        var residual = [Float](repeating: 0, count: n)
        for (i, p) in buffer.lab.enumerated() {
            let chroma = (p.y * p.y + p.z * p.z).squareRoot()
            guard chroma > accentMinimumChroma else { continue }
            let d = ColorMath.distanceSquared(p, existing[KMeans.nearest(p, in: existing)]).squareRoot()
            guard d > accentDistance else { continue }
            let weight = chroma * chroma * d * (weights?[i] ?? 1)
            residual[i] = weight
            points.append(p)
            pointWeights.append(weight)
            pointIndex.append(i)
        }
        guard points.count >= max(4, Int(Double(n) * accentMinimumShare)) else { return nil }

        let km = KMeans.cluster(points, weights: pointWeights, k: min(8, points.count))
        let merged = mergeClose(centroids: km.centroids, mass: km.mass, threshold: mergeThreshold)
        var assignments = [Int](repeating: -1, count: n)
        for (k, i) in pointIndex.enumerated() { assignments[i] = merged.label[km.assignments[k]] }

        var counts = [Int: Int]()
        for a in assignments where a >= 0 { counts[a, default: 0] += 1 }

        var best: (cluster: Int, score: Double, location: CGPoint)?
        for cluster in merged.ranked.prefix(6) {
            guard Double(counts[cluster] ?? 0) >= Double(n) * accentMinimumShare else { continue }
            // Coherence is judged on plain pixels, whatever the weights say.
            let patch = bestPatch(of: cluster, assignments: assignments, weights: nil,
                                  centroid: merged.centroids[cluster], buffer: buffer)
            guard patch.fill >= accentMinimumFill else { continue }
            // Size only has to clear the minimums: a small vivid patch must beat a big, milder one (a sunset glow).
            let centroid = merged.centroids[cluster]
            let chroma = Double((centroid.y * centroid.y + centroid.z * centroid.z).squareRoot())
            let distance = Double(ColorMath.distanceSquared(centroid, existing[KMeans.nearest(centroid, in: existing)]).squareRoot())
            let score = chroma * chroma * distance * patch.fill
            if best == nil || score > best!.score {
                let location = bestLocation(of: cluster, assignments: assignments, weights: residual,
                                            centroid: merged.centroids[cluster], buffer: buffer)
                best = (cluster, score, location)
            }
        }
        guard let best else { return nil }
        return DominantColor(centroid: merged.centroids[best.cluster],
                             share: Double(counts[best.cluster] ?? 0) / Double(n),
                             location: best.location, isAccent: true)
    }
}

// MARK: Missing colors

extension DominantColorAnalyzer {
    /// OKLab distance from every existing color beyond which a pixel counts as "not represented yet".
    public static let missingDistance: Float = 0.08

    /// The color that the `existing` colors represent worst, with a place to put a marker on it.
    ///
    /// Every pixel further than `missingDistance` from all existing colors counts with its squared distance
    /// (times its weight, if any), so a large patch of a slightly different color and a small patch of a
    /// very different one — a red boat on blue water — both can win. The pixels are clustered and the
    /// heaviest cluster is returned; nil when everything is already close to a marker color.
    public static func findMissingColor(in buffer: PixelBuffer, existing: [SIMD3<Float>],
                                        weights: [Float]? = nil) -> DominantColor? {
        let n = buffer.lab.count
        guard n > 0 else { return nil }
        guard !existing.isEmpty else { return analyze(buffer, count: 1, weights: weights).first }

        var residual = [Float](repeating: 0, count: n)
        var points: [SIMD3<Float>] = []
        var pointWeights: [Float] = []
        var pointIndex: [Int] = []
        var total = 0.0
        for (i, p) in buffer.lab.enumerated() {
            let d = ColorMath.distanceSquared(p, existing[KMeans.nearest(p, in: existing)]).squareRoot()
            guard d > missingDistance else { continue }
            let weight = d * d * (weights?[i] ?? 1)
            residual[i] = weight
            points.append(p)
            pointWeights.append(weight)
            pointIndex.append(i)
            total += Double(weight)
        }
        // Nothing noteworthy left: less than a speck of the photo is off.
        guard points.count >= max(4, n / 2000) else { return nil }

        let km = KMeans.cluster(points, weights: pointWeights, k: min(6, points.count))
        let merged = mergeClose(centroids: km.centroids, mass: km.mass, threshold: mergeThreshold)
        guard let best = merged.ranked.first else { return nil }

        var assignments = [Int](repeating: -1, count: n)
        for (k, i) in pointIndex.enumerated() { assignments[i] = merged.label[km.assignments[k]] }
        let location = bestLocation(of: best, assignments: assignments, weights: residual,
                                    centroid: merged.centroids[best], buffer: buffer)
        let pixels = assignments.reduce(0) { $0 + ($1 == best ? 1 : 0) }
        return DominantColor(centroid: merged.centroids[best], share: Double(pixels) / Double(n), location: location)
    }
}
