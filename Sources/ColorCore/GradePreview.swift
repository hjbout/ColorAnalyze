import CoreGraphics
import Foundation

/// What a preview of the suggested grading applies.
public struct GradePreviewSettings: Sendable, Equatable {
    /// One Color Grading wheel: PhotoLab's Hue (DxO degrees), Saturation (0...100) and Luminance (-100...100).
    public struct Tint: Sendable, Equatable {
        public var dxoHue: Double
        public var saturation: Double
        public var luminance: Double

        public init(dxoHue: Double = 0, saturation: Double = 0, luminance: Double = 0) {
            self.dxoHue = dxoHue
            self.saturation = saturation
            self.luminance = luminance
        }

        var isNeutral: Bool { saturation == 0 && luminance == 0 }
    }

    public var shadows = Tint()
    public var midtones = Tint()
    public var highlights = Tint()
    /// The Global wheel of Color Grading.
    public var master = Tint()
    /// Color Grading Balance (-100...100): positive lets the highlights reach further into the darks.
    public var balance = 0.0
    /// Selective Tone of PhotoLab's Light palette (-100...100): Blacks and Shadows.
    public var toneBlacks = 0.0
    public var toneShadows = 0.0
    /// HSL tool: turn of the Hue handle per channel, degrees on PhotoLab's ring (+ = counter-clockwise).
    public var hueShifts: [DxOChannel: Double] = [:]
    /// HSL tool: Saturation and Luminance per channel (-100...100).
    public var hslSaturation: [DxOChannel: Double] = [:]
    public var hslLuminance: [DxOChannel: Double] = [:]
    /// 1 = as suggested; more exaggerates the tints, to make a small suggestion visible. Hue turns are always
    /// as suggested: they are large enough to see, and four times a turn of 30° is no preview of anything.
    public var amount = 1.0

    public init(shadows: Tint = Tint(), midtones: Tint = Tint(), highlights: Tint = Tint(),
                hueShifts: [DxOChannel: Double] = [:], amount: Double = 1,
                master: Tint = Tint(), balance: Double = 0,
                hslSaturation: [DxOChannel: Double] = [:], hslLuminance: [DxOChannel: Double] = [:],
                toneBlacks: Double = 0, toneShadows: Double = 0) {
        self.toneBlacks = toneBlacks
        self.toneShadows = toneShadows
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.hueShifts = hueShifts
        self.amount = amount
        self.master = master
        self.balance = balance
        self.hslSaturation = hslSaturation
        self.hslLuminance = hslLuminance
    }

    /// True when applying the settings would change nothing.
    public var isIdentity: Bool {
        [shadows, midtones, highlights, master].allSatisfy { $0.isNeutral } && toneBlacks == 0 && toneShadows == 0
            && hueShifts.values.allSatisfy { abs($0) < 0.01 }
            && hslSaturation.values.allSatisfy { abs($0) < 0.01 }
            && hslLuminance.values.allSatisfy { abs($0) < 0.01 }
    }
}

/// What the suggested Color Grading and HSL values do to a photo, to judge their direction and character before
/// touching PhotoLab. The Color Grading part is calibrated against PhotoLab 10.1 (see `GradePreviewTables.swift` and the
/// README): in linear light with Rec.2020 primaries every tonal range adds to each channel a curve of that channel's own
/// value, in a direction that turns with the hue. The HSL part is calibrated the same way: a hue turn rotates the hue of a
/// color (HSV hue in Rec.2020), weighted by DxO's channel fades, at constant lightness.
public enum GradePreview {
    /// Everything about the settings that does not depend on the pixel, so a pixel costs little.
    public struct Plan {
        /// Per wheel (shadows, midtones, highlights, master): what a channel gets at the top of its curve (the hue
        /// direction times the saturation), and the Luminance as a fraction.
        let tintVectors: [SIMD3<Float>]
        let luminances: [Float]
        /// The Master wheel's own curves per channel (hue interpolated from the measured table); empty without a Master tint.
        let masterGrids: [[Float]]
        /// Selective Tone: the new mean value of a pixel as a function of its mean value (fine grid), empty without tone changes.
        let toneGrid: [Float]
        let hasWheels: Bool
        let hasHueShift: Bool
        let hasHSLScale: Bool
        /// The curves of the four wheels on a fine grid: the tint curves (they follow Balance) and the Luminance curves.
        let tintGrids: [[Float]]
        let luminanceGrids: [[Float]]
        /// Turn of the hue per whole degree of PhotoLab hue, from the channel fades and the shifts (empty without shifts).
        let hueDeltas: [Float]
        /// HSL Saturation and Luminance per whole degree of PhotoLab hue, as fractions (empty without them).
        let saturationScales: [Float]
        let luminanceScales: [Float]

        static let gridSize = 1024
        // Shared by all plans: building them per plan would make a plan too expensive for an optimizer that tries thousands.
        static let encodeTable: [Float] = (0...4096).map { Float(ColorMath.linearToSRGB(Double($0) / 4096)) }
        static let decodeTable: [Float] = (0...4096).map { Float(ColorMath.sRGBToLinear(Double($0) / 4096)) }
        static func grid(_ nodes: [Float]) -> [Float] {
            (0...gridSize).map { GradePreview.interpolate(Float($0) / Float(gridSize), nodes: GradePreview.curveNodes, values: nodes) }
        }
        /// The curve of each tonal range on a fine grid over 0...1, then the Master curve.
        static let curveGrid: [[Float]] = GradePreview.curves.map(grid) + [grid(GradePreview.masterTintCurve)]
        static let luminanceGrid: [[Float]] = GradePreview.luminanceCurves.map(grid) + [grid(GradePreview.masterLuminanceCurve)]

        /// A negative Luminance moves a little less than a positive one (measured: about 7%).
        static let negativeLuminanceGain: Float = 0.93

        public init(_ settings: GradePreviewSettings) {
            let wheels = [settings.shadows, settings.midtones, settings.highlights, settings.master]
            func vector(_ tint: GradePreviewSettings.Tint) -> SIMD3<Float> {
                guard tint.saturation != 0 else { return .zero }
                return Float(tint.saturation / 100 * settings.amount) * GradePreview.direction(forHue: tint.dxoHue)
            }
            var vectors = wheels.map(vector)
            // Master is not one direction times one curve: it has its own curve per channel and hue (see GradePreviewMasterTable).
            if settings.master.saturation != 0 {
                masterGrids = GradePreview.masterChannelGrids(hue: Float(ColorMath.normalizeDegrees(settings.master.dxoHue)),
                                                              scale: Float(settings.master.saturation / 100 * settings.amount))
                vectors[3] = .zero
            } else {
                masterGrids = []
            }
            tintVectors = vectors
            luminances = wheels.map { tint in
                let l = Float(tint.luminance / 100 * settings.amount)
                return l < 0 ? l * Self.negativeLuminanceGain : l
            }
            if settings.toneBlacks != 0 || settings.toneShadows != 0 {
                toneGrid = Self.toneGrid(blacks: Float(settings.toneBlacks / 100), shadows: Float(settings.toneShadows / 100))
            } else {
                toneGrid = []
            }
            hasWheels = tintVectors.contains { $0 != .zero } || luminances.contains { $0 != 0 } || !masterGrids.isEmpty
            if settings.balance == 0 {
                tintGrids = Self.curveGrid
                luminanceGrids = Self.luminanceGrid
            } else {
                tintGrids = Self.balanced(Self.curveGrid, balance: Float(settings.balance))
                luminanceGrids = Self.balanced(Self.luminanceGrid, balance: Float(settings.balance))
            }

            let shifts = settings.hueShifts.filter { abs($0.value) >= 0.01 }
            hasHueShift = !shifts.isEmpty
            // PhotoLab's hue is the HSV hue in Rec.2020 (see `DxOHue.hue(of:)`): the channel fades apply to it directly.
            hueDeltas = Self.perDegree(shifts)

            let saturations = settings.hslSaturation.filter { abs($0.value) >= 0.01 }
            let luminances = settings.hslLuminance.filter { abs($0.value) >= 0.01 }
            hasHSLScale = !saturations.isEmpty || !luminances.isEmpty
            saturationScales = Self.perDegree(saturations.mapValues { $0 / 100 })
            luminanceScales = Self.perDegree(luminances.mapValues { $0 / 100 })
        }

        /// Selective Tone of the Light palette: the three channels are scaled by the gain of their mean (a colored pixel keeps its
        /// hue and chroma, as measured).
        private func toned(_ linear: SIMD3<Float>) -> SIMD3<Float> {
            let mean = (linear.x + linear.y + linear.z) / 3
            guard mean > 1e-7 else { return linear }
            let position = min(1, max(0, mean)) * Float(Self.gridSize)
            let i = min(Self.gridSize - 1, Int(position)), t = position - Float(i)
            let out = toneGrid[i] * (1 - t) + toneGrid[i + 1] * t
            return linear * (out / mean)
        }

        /// New value of a grey as a function of its value, from the measured +100 and -100 curves of Blacks and Shadows
        /// (amounts -1...1), on the fine grid.
        static func toneGrid(blacks: Float, shadows: Float) -> [Float] {
            let nodes = GradePreview.toneNodes
            func delta(_ amount: Float, plus: [Float], minus: [Float], _ x: Float) -> Float {
                guard amount != 0 else { return 0 }
                let table = amount > 0 ? plus : minus
                return abs(amount) * GradePreview.interpolate(x, nodes: nodes, values: table)
            }
            return (0...gridSize).map { index in
                let x = Float(index) / Float(gridSize)
                return max(0, x + delta(blacks, plus: GradePreview.blacksPlus, minus: GradePreview.blacksMinus, x)
                              + delta(shadows, plus: GradePreview.shadowsPlus, minus: GradePreview.shadowsMinus, x))
            }
        }

        /// Sum over the channel fades of `membership × value`, for every whole degree of hue.
        private static func perDegree(_ values: [DxOChannel: Double]) -> [Float] {
            guard !values.isEmpty else { return [] }
            return (0..<360).map { hue in
                var total = 0.0
                for slice in DxOHue.slices {
                    if let value = values[slice.channel] { total += slice.membership(of: Double(hue)) * value }
                }
                return Float(total)
            }
        }

        /// Balance leaves the sum of the three ranges alone and moves how they divide it: each range's share is
        /// read at a channel value shifted by Balance (in x^`balanceGamma`).
        static func balanced(_ grids: [[Float]], balance: Float) -> [[Float]] {
            let n = gridSize
            let gamma = GradePreview.balanceGamma, shift = GradePreview.balanceStep * balance
            var out = grids
            let total = (0...n).map { grids[0][$0] + grids[1][$0] + grids[2][$0] }
            for i in 0...n {
                let x = Float(i) / Float(n)
                let moved = min(1, max(0, powf(x, gamma) + shift))
                let position = powf(moved, 1 / gamma) * Float(n)
                let j = min(n - 1, Int(position)), t = position - Float(j)
                func at(_ r: Int) -> Float { grids[r][j] * (1 - t) + grids[r][j + 1] * t }
                let sum = at(0) + at(1) + at(2)
                for r in 0..<3 {
                    let share: Float = sum > 1e-6 ? at(r) / sum : (r == (x < 0.5 ? 0 : 2) ? 1 : 0)
                    out[r][i] = total[i] * share
                }
            }
            return out
        }

        /// The graded OKLab color of a pixel given as OKLab.
        public func apply(_ lab: SIMD3<Float>) -> SIMD3<Float> {
            guard hasWheels || hasHueShift || hasHSLScale || !toneGrid.isEmpty else { return lab }
            return ColorMath.linearToOKLab(applyLinear(linear: ColorMath.okLabToLinear(lab), lab: lab))
        }

        /// The graded color of a pixel, as linear sRGB; `linear` and `lab` are the same color.
        public func applyLinear(linear input: SIMD3<Float>, lab: SIMD3<Float>) -> SIMD3<Float> {
            var linear = input
            if !toneGrid.isEmpty { linear = toned(linear) }
            if hasHueShift { linear = turnedHue(linear: linear, lab: lab) }
            if hasHSLScale { linear = scaled(linear: linear, lab: lab) }
            if hasWheels {
                var x = Self.multiply(GradePreview.toWide, linear)
                var added = SIMD3<Float>.zero
                if !masterGrids.isEmpty {
                    added += SIMD3(curve(masterGrids[0], x.x), curve(masterGrids[1], x.y), curve(masterGrids[2], x.z))
                }
                for wheel in 0..<4 {
                    let v = tintVectors[wheel], l = luminances[wheel]
                    if v != .zero {
                        added += SIMD3(curve(tintGrids[wheel], x.x) * v.x, curve(tintGrids[wheel], x.y) * v.y, curve(tintGrids[wheel], x.z) * v.z)
                    }
                    if l != 0 {
                        added += SIMD3(curve(luminanceGrids[wheel], x.x), curve(luminanceGrids[wheel], x.y), curve(luminanceGrids[wheel], x.z)) * l
                    }
                }
                x += added
                linear = Self.multiply(GradePreview.fromWide, x)
            }
            return linear
        }

        private func curve(_ grid: [Float], _ x: Float) -> Float {
            let position = min(1, max(0, x)) * Float(Self.gridSize)
            let i = min(Self.gridSize - 1, Int(position))
            let t = position - Float(i)
            return grid[i] * (1 - t) + grid[i + 1] * t
        }

        private static func multiply(_ m: [[Float]], _ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
                  m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
                  m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z)
        }

        /// HSV hue (degrees) and chroma of the pixel in Rec.2020, as PhotoLab measures them; nil for greys.
        private func hueAndChroma(linear: SIMD3<Float>) -> (hue: Float, chroma: Float)? {
            let wide = Self.multiply(GradePreview.toWide, linear)
            let r = encode(wide.x), g = encode(wide.y), b = encode(wide.z)
            let high = max(r, g, b), low = min(r, g, b)
            let chroma = high - low
            guard chroma > 0.02, high > 0 else { return nil }
            var hue: Float
            if high == r { hue = (g - b) / chroma } else if high == g { hue = 2 + (b - r) / chroma } else { hue = 4 + (r - g) / chroma }
            hue *= 60
            if hue < 0 { hue += 360 }
            return (hue, chroma)
        }

        private static func at(_ table: [Float], hue: Float) -> Float {
            guard !table.isEmpty else { return 0 }
            let position = hue.truncatingRemainder(dividingBy: 360)
            let lower = Int(position) % 360, upper = (lower + 1) % 360, t = position - Float(Int(position))
            return table[lower] * (1 - t) + table[upper] * t
        }

        // Measured with PhotoLab 10.1 (calibration/, H1 and H2). Saturation scales the OKLab chroma by 1 + the factor and
        // the result is clipped to sRGB, as the export is. Luminance moves OKLab lightness toward white (or black) by a share
        // of the headroom that grows with the chroma of the color: a color with little chroma hardly moves.
        static let lightnessGain: Float = 0.562, lightnessChromaPower: Float = 1.256, darkeningHeadroom: Float = 0.837
        static let lightnessChroma: Float = -0.105

        /// HSL Saturation and Luminance of the channel the pixel's hue belongs to (nearly-grey colors move less).
        private func scaled(linear: SIMD3<Float>, lab: SIMD3<Float>) -> SIMD3<Float> {
            guard let (hue, chroma) = hueAndChroma(linear: linear) else { return linear }
            let s = Self.at(saturationScales, hue: hue), l = Self.at(luminanceScales, hue: hue)
            guard abs(s) > 1e-4 || abs(l) > 1e-4 else { return linear }
            let weight = Self.smooth(0.02, 0.1, chroma)
            let c = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            var lightness = lab.x
            if l != 0 {
                let headroom = l >= 0 ? 1 - lab.x : lab.x * Self.darkeningHeadroom
                lightness += l * headroom * Self.lightnessGain * powf(max(c, 1e-6) / 0.15, Self.lightnessChromaPower) * weight
            }
            let scale = max(0, 1 + (s + l * Self.lightnessChroma) * weight)
            let result = ColorMath.okLabToLinear(SIMD3(lightness, lab.y * scale, lab.z * scale))
            return SIMD3(min(1, max(0, result.x)), min(1, max(0, result.y)), min(1, max(0, result.z)))
        }

        /// Turns the hue of the pixel (HSV hue in Rec.2020, as PhotoLab measures it) by the delta of its hue,
        /// keeping HSV saturation and brightness, and puts the pixel's OKLab lightness back: PhotoLab's hue turn does
        /// not make a color lighter or darker (a plain HSV rotation would, e.g. red → orange).
        private func turnedHue(linear: SIMD3<Float>, lab: SIMD3<Float>) -> SIMD3<Float> {
            let wide = Self.multiply(GradePreview.toWide, linear)
            let r = encode(wide.x), g = encode(wide.y), b = encode(wide.z)
            let high = max(r, g, b), low = min(r, g, b)
            let chroma = high - low
            guard chroma > 0.02, high > 0 else { return linear }                  // greys have no hue to turn
            var hue: Float
            if high == r { hue = (g - b) / chroma } else if high == g { hue = 2 + (b - r) / chroma } else { hue = 4 + (r - g) / chroma }
            hue = hue * 60
            if hue < 0 { hue += 360 }
            let position = hue.truncatingRemainder(dividingBy: 360)
            let lower = Int(position) % 360, upper = (lower + 1) % 360, t = position - Float(Int(position))
            let delta = hueDeltas[lower] * (1 - t) + hueDeltas[upper] * t
            guard abs(delta) > 0.05 else { return linear }
            let weight = Self.smooth(0.02, 0.1, chroma)                           // nearly-grey colors move less
            var turned = position + delta * weight
            turned = turned.truncatingRemainder(dividingBy: 360)
            if turned < 0 { turned += 360 }
            // HSV → RGB with the same saturation and value.
            let sector = turned / 60
            let c = chroma, x = c * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1)), m = low
            let (r2, g2, b2): (Float, Float, Float)
            switch Int(sector) {
            case 0: (r2, g2, b2) = (c, x, 0)
            case 1: (r2, g2, b2) = (x, c, 0)
            case 2: (r2, g2, b2) = (0, c, x)
            case 3: (r2, g2, b2) = (0, x, c)
            case 4: (r2, g2, b2) = (x, 0, c)
            default: (r2, g2, b2) = (c, 0, x)
            }
            let rotated = Self.multiply(GradePreview.fromWide, SIMD3(decode(r2 + m), decode(g2 + m), decode(b2 + m)))
            let rotatedLab = ColorMath.linearToOKLab(rotated)
            return ColorMath.okLabToLinear(SIMD3(lab.x, rotatedLab.y, rotatedLab.z))
        }

        private func encode(_ linear: Float) -> Float { Self.encodeTable[Int(min(1, max(0, linear)) * 4096)] }
        private func decode(_ encoded: Float) -> Float { Self.decodeTable[Int(min(1, max(0, encoded)) * 4096)] }

        static func smooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
            let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
            return t * t * (3 - 2 * t)
        }
    }

    /// What the Master wheel adds to each channel as a function of the channel's value, at this hue: the measured table
    /// interpolated around the circle (cubic Hermite, as for the directions), then spread over the fine grid. `scale` = Saturation/100.
    static func masterChannelGrids(hue: Float, scale: Float) -> [[Float]] {
        let nodes = masterHues, n = nodes.count
        var i = n - 1
        var q = hue + 360
        if hue >= nodes[0] {
            q = hue
            for k in 0..<n where nodes[k] <= hue { i = k }
        }
        func nodeHue(_ k: Int) -> Float {
            let m = ((k % n) + n) % n
            return nodes[m] + 360 * Float((k - m) / n)
        }
        func index(_ k: Int) -> Int { ((k % n) + n) % n }
        let h0 = nodeHue(i), h1 = nodeHue(i + 1), span = h1 - h0, t = (q - h0) / span
        let t2 = t * t, t3 = t2 * t
        let a = 2 * t3 - 3 * t2 + 1, b = t3 - 2 * t2 + t, c = -2 * t3 + 3 * t2, d = t3 - t2
        let d0 = (h1 - nodeHue(i - 1)), d1 = (nodeHue(i + 2) - h0)
        let size = Plan.gridSize
        return (0..<3).map { channel in
            // Value at each of the 17 nodes, then linear in between.
            let atNodes: [Float] = (0..<curveNodes.count).map { node in
                func v(_ k: Int) -> Float { masterTable[index(k)][channel][node] }
                let m0 = (v(i + 1) - v(i - 1)) / d0 * span
                let m1 = (v(i + 2) - v(i)) / d1 * span
                return (a * v(i) + b * m0 + c * v(i + 1) + d * m1) * scale
            }
            return (0...size).map { interpolate(Float($0) / Float(size), nodes: curveNodes, values: atNodes) }
        }
    }

    /// Piecewise-linear value at `x` of the function given at `nodes` (ascending).
    static func interpolate(_ x: Float, nodes: [Float], values: [Float]) -> Float {
        guard let last = nodes.last, x < last else { return values.last ?? 0 }
        var i = 1
        while i < nodes.count - 1, x > nodes[i] { i += 1 }
        let t = (x - nodes[i - 1]) / (nodes[i] - nodes[i - 1])
        return values[i - 1] + t * (values[i] - values[i - 1])
    }

    /// The direction a tint with PhotoLab Hue `hue` pushes the (red, green, blue) channels, normalised so that
    /// blue (231) pushes the blue channel by 1: cubic interpolation between the ten measured hues, around the circle.
    public static func direction(forHue hue: Double) -> SIMD3<Float> {
        let nodes = hueNodes, vectors = hueVectors, n = nodes.count
        let h = Float(ColorMath.normalizeDegrees(hue))
        // The segment [nodes[i], nodes[i + 1]) that holds h; before the first node it is the last one, wrapped around.
        var i = n - 1
        var q = h + 360
        if h >= nodes[0] {
            q = h
            for k in 0..<n where nodes[k] <= h { i = k }
        }
        func nodeHue(_ k: Int) -> Float {
            let m = ((k % n) + n) % n
            return nodes[m] + 360 * Float((k - m) / n)
        }
        func vector(_ k: Int) -> SIMD3<Float> {
            let m = ((k % n) + n) % n
            return SIMD3(vectors[m][0], vectors[m][1], vectors[m][2])
        }
        let h0 = nodeHue(i), h1 = nodeHue(i + 1), span = h1 - h0, t = (q - h0) / span
        // Cubic Hermite with tangents from the neighbouring nodes (the nodes are not evenly spaced).
        let m0 = (vector(i + 1) - vector(i - 1)) / (h1 - nodeHue(i - 1)) * span
        let m1 = (vector(i + 2) - vector(i)) / (nodeHue(i + 2) - h0) * span
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * vector(i) + (t3 - 2 * t2 + t) * m0
            + (-2 * t3 + 3 * t2) * vector(i + 1) + (t3 - t2) * m1
    }

    /// Renders `source` with the settings. The result has the size of the source.
    public static func render(_ source: CGImage, settings: GradePreviewSettings) -> CGImage? {
        let buffer = PixelBuffer(image: source, maxDimension: max(source.width, source.height))
        let plan = Plan(settings)
        let w = buffer.width, h = buffer.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rowBytes = context.bytesPerRow
        // linear → 8-bit sRGB through a table: a power function per pixel would dominate the cost.
        let encode: [UInt8] = (0...4096).map { UInt8(min(255, max(0, (ColorMath.linearToSRGB(Double($0) / 4096) * 255).rounded()))) }
        func byte(_ v: Float) -> UInt8 { encode[Int(min(1, max(0, v)) * 4096)] }

        for y in 0..<h {
            for x in 0..<w {
                let graded = plan.applyLinear(linear: buffer.linear[y * w + x], lab: buffer.lab[y * w + x])
                let offset = y * rowBytes + x * 4
                data[offset] = byte(graded.x)
                data[offset + 1] = byte(graded.y)
                data[offset + 2] = byte(graded.z)
                data[offset + 3] = 255
            }
        }
        return context.makeImage()
    }
}
