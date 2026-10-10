import Foundation

/// Deterministic generator so re-analyzing the same photo gives the same markers.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

public struct KMeansResult: Sendable {
    public var centroids: [SIMD3<Float>]
    /// Cluster index per input point.
    public var assignments: [Int]
    /// Number of points per cluster.
    public var counts: [Int]
    /// Summed weight per cluster (equals `counts` for unweighted input).
    public var mass: [Double]
}

public enum KMeans {
    /// k-means++ clustering. Empty clusters are dropped from the result.
    /// `weights` (one per point, > 0) make some points count more, both when picking
    /// the starting colors and when averaging a cluster.
    public static func cluster(_ points: [SIMD3<Float>], weights: [Float]? = nil, k: Int, maxIterations: Int = 20,
                               seed: UInt64 = 0x00C0_10C0) -> KMeansResult {
        guard !points.isEmpty, k > 0 else {
            return KMeansResult(centroids: [], assignments: [], counts: [], mass: [])
        }
        let w = weights ?? [Float](repeating: 1, count: points.count)
        precondition(w.count == points.count, "one weight per point")
        var rng = SplitMix64(seed: seed)
        var centroids = seedPlusPlus(points, weights: w, k: min(k, points.count), rng: &rng)
        var assignments = [Int](repeating: 0, count: points.count)

        for iteration in 0..<maxIterations {
            var changed = false
            for (i, p) in points.enumerated() {
                let c = nearest(p, in: centroids)
                if c != assignments[i] {
                    assignments[i] = c
                    changed = true
                }
            }
            var sums = [SIMD3<Float>](repeating: .zero, count: centroids.count)
            var mass = [Float](repeating: 0, count: centroids.count)
            for (i, p) in points.enumerated() {
                sums[assignments[i]] += p * w[i]
                mass[assignments[i]] += w[i]
            }
            for c in centroids.indices where mass[c] > 0 {
                centroids[c] = sums[c] / mass[c]
            }
            if !changed && iteration > 0 { break }
        }

        var counts = [Int](repeating: 0, count: centroids.count)
        var mass = [Double](repeating: 0, count: centroids.count)
        for (i, a) in assignments.enumerated() {
            counts[a] += 1
            mass[a] += Double(w[i])
        }
        let kept = centroids.indices.filter { counts[$0] > 0 }
        if kept.count == centroids.count {
            return KMeansResult(centroids: centroids, assignments: assignments, counts: counts, mass: mass)
        }
        var remap = [Int](repeating: -1, count: centroids.count)
        for (newIndex, old) in kept.enumerated() { remap[old] = newIndex }
        return KMeansResult(centroids: kept.map { centroids[$0] },
                            assignments: assignments.map { remap[$0] },
                            counts: kept.map { counts[$0] },
                            mass: kept.map { mass[$0] })
    }

    public static func nearest(_ p: SIMD3<Float>, in centroids: [SIMD3<Float>]) -> Int {
        var best = 0
        var bestD = Float.infinity
        for (j, c) in centroids.enumerated() {
            let d = ColorMath.distanceSquared(p, c)
            if d < bestD {
                bestD = d
                best = j
            }
        }
        return best
    }

    private static func seedPlusPlus(_ points: [SIMD3<Float>], weights: [Float], k: Int,
                                     rng: inout SplitMix64) -> [SIMD3<Float>] {
        var centroids = [points[Int.random(in: 0..<points.count, using: &rng)]]
        var dist = points.map { ColorMath.distanceSquared($0, centroids[0]) }
        while centroids.count < k {
            let total = zip(dist, weights).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            guard total > 0 else { break } // fewer distinct colors than k
            var target = Float.random(in: 0..<total, using: &rng)
            var chosen = points.count - 1
            for (i, d) in dist.enumerated() {
                target -= d * weights[i]
                if target < 0 {
                    chosen = i
                    break
                }
            }
            let c = points[chosen]
            centroids.append(c)
            for i in points.indices {
                dist[i] = min(dist[i], ColorMath.distanceSquared(points[i], c))
            }
        }
        return centroids
    }
}
