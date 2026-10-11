import Foundation
import simd

/// A creative direction for the grading, on top of bringing the colors to their targets: tonal ranges are given a cast of
/// their own (warm highlights over cool shadows, teal and orange) or a lift (faded blacks).
public enum GradingStyle: String, CaseIterable, Identifiable, Sendable {
    case neutral, warmHighlights, coolHighlights, tealOrange, warmOverall, coolOverall, faded
    case complementary, monochrome, goldenHour, blueHour

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .neutral: "Neutral"
        case .warmHighlights: "Warm highlights, cool shadows"
        case .coolHighlights: "Cool highlights, warm shadows"
        case .tealOrange: "Teal & orange (cinematic)"
        case .warmOverall: "Warm overall"
        case .coolOverall: "Cool overall"
        case .faded: "Faded (lighter shadows)"
        case .complementary: "Complementary split (from the photo's colors)"
        case .monochrome: "Monochrome (one hue throughout)"
        case .goldenHour: "Golden hour (warm light, cool shade)"
        case .blueHour: "Blue hour (deep blue, soft warmth)"
        }
    }

    /// sRGB hues of the casts.
    static let coolHue = 225.0, warmHue = 35.0, tealHue = 190.0, orangeHue = 40.0, goldenHue = 38.0, blueHourHue = 235.0

    /// What a style wants of a grey at the middle of a tonal range: a cast of `hue` with `scale` times the basic chroma
    /// (no hue: stay neutral), and its OKLab lightness raised by `lift`.
    struct Probe {
        var range: TonalRange
        var lightness: Float
        var hue: Double?
        var scale: Float = 1
        var lift: Float = 0
    }

    /// The sRGB hue the photo's colors lean to (weighted circular mean), which the styles that follow the photo build on.
    static func dominantHue(of inputs: [ColorGradingSuggestion.Input]) -> Double? {
        var s = 0.0, c = 0.0
        for input in inputs where input.color.chroma >= DxOMapping.neutralChroma && input.share > 0 {
            let weight = input.share * Double(min(1, input.color.chroma / 0.1))
            let angle = input.color.hsb.h * .pi / 180
            s += weight * sin(angle)
            c += weight * cos(angle)
        }
        guard s != 0 || c != 0 else { return nil }
        return ColorMath.normalizeDegrees(atan2(s, c) * 180 / .pi)
    }

    /// True when the casts of the style follow the photo's dominant hue instead of fixed hues.
    var followsPhoto: Bool { self == .complementary || self == .monochrome }

    func probes(dominantHue: Double?) -> [Probe] {
        let dark: Float = 0.25, mid: Float = 0.55, light: Float = 0.82
        switch self {
        case .neutral: return []
        // The lights lean into the photo's own hue and the shadows take the opposite one; a photo without color falls back to teal & orange.
        case .complementary:
            let hue = dominantHue ?? Self.orangeHue
            return [Probe(range: .shadows, lightness: dark, hue: ColorMath.normalizeDegrees(hue + 180), scale: 1.3),
                    Probe(range: .highlights, lightness: light, hue: hue, scale: 1.3)]
        // One hue in all ranges, kept light: it unifies the photo without turning it into a filter.
        case .monochrome:
            guard let hue = dominantHue else { return [] }
            return [Probe(range: .shadows, lightness: dark, hue: hue, scale: 0.8),
                    Probe(range: .midtones, lightness: mid, hue: hue, scale: 0.8),
                    Probe(range: .highlights, lightness: light, hue: hue, scale: 0.8)]
        case .goldenHour: return [Probe(range: .shadows, lightness: dark, hue: Self.coolHue, scale: 0.6),
                                  Probe(range: .midtones, lightness: mid, hue: Self.goldenHue, scale: 0.8),
                                  Probe(range: .highlights, lightness: light, hue: Self.goldenHue, scale: 1.5)]
        case .blueHour: return [Probe(range: .shadows, lightness: dark, hue: Self.blueHourHue, scale: 1.5),
                                Probe(range: .midtones, lightness: mid, hue: Self.blueHourHue, scale: 0.9),
                                Probe(range: .highlights, lightness: light, hue: Self.warmHue, scale: 0.5)]
        case .warmHighlights: return [Probe(range: .shadows, lightness: dark, hue: Self.coolHue),
                                      Probe(range: .highlights, lightness: light, hue: Self.warmHue)]
        case .coolHighlights: return [Probe(range: .shadows, lightness: dark, hue: Self.warmHue),
                                      Probe(range: .highlights, lightness: light, hue: Self.coolHue)]
        case .tealOrange: return [Probe(range: .shadows, lightness: dark, hue: Self.tealHue, scale: 1.6),
                                  Probe(range: .highlights, lightness: light, hue: Self.orangeHue, scale: 1.6)]
        case .warmOverall: return [Probe(range: .shadows, lightness: dark, hue: Self.warmHue),
                                   Probe(range: .midtones, lightness: mid, hue: Self.warmHue),
                                   Probe(range: .highlights, lightness: light, hue: Self.warmHue)]
        case .coolOverall: return [Probe(range: .shadows, lightness: dark, hue: Self.coolHue),
                                   Probe(range: .midtones, lightness: mid, hue: Self.coolHue),
                                   Probe(range: .highlights, lightness: light, hue: Self.coolHue)]
        // The darks raised and nothing else, with the Blacks and Shadows sliders of the Light palette: the Color Grading wheels
        // cannot lift black (every curve of that model is 0 at black).
        case .faded: return [Probe(range: .shadows, lightness: 0.06, hue: nil, lift: 0.07),
                             Probe(range: .shadows, lightness: 0.12, hue: nil, lift: 0.06),
                             Probe(range: .shadows, lightness: dark, hue: nil, lift: 0.04),
                             // ... while the middle and the lights stay where they are.
                             Probe(range: .midtones, lightness: mid, hue: nil, lift: 0),
                             Probe(range: .highlights, lightness: light, hue: nil, lift: 0)]
        }
    }

    /// The hue (sRGB degrees) the style wants for a range, nil where it has no opinion.
    func castHue(for range: TonalRange, dominantHue: Double? = nil) -> Double? {
        probes(dominantHue: dominantHue).first { $0.range == range && $0.hue != nil }?.hue
    }

    /// How much the style counts against the hue fit of the colors. An overall cast is the point of its style: a photo
    /// that is "warm overall" with its colors in place is no cast at all.
    var weight: Double { usesMaster ? 4 : 1 }

    /// True when the cast is laid over the whole photo by the Master wheel, next to the three ranges.
    var usesMaster: Bool { self == .warmOverall || self == .coolOverall }

    /// The ranges the style has an opinion about.
    func ranges(dominantHue: Double? = nil) -> Set<TonalRange> { Set(probes(dominantHue: dominantHue).map(\.range)) }

    /// True when the style lifts the darks, which it does with the Blacks and Shadows sliders of the Light palette.
    var usesTone: Bool { self == .faded }
}

extension ColorGradingSuggestion {
    /// The suggestion, refined with the calibrated model of PhotoLab's Color Grading (`GradePreview`): Hue, Saturation and
    /// Luminance of the three wheels, and Balance, are chosen so that the dominant colors, as that model predicts PhotoLab will render them, end up
    /// as close as possible to the hues they should have — while a color keeps its lightness and most of its chroma and
    /// the saturation stays within the strength. The plain heuristic (`suggest`) is the starting point, so the result
    /// is never worse than it by this measure.
    public static func optimized(from inputs: [Input], strength: Strength, style: GradingStyle = .neutral) -> Suggestion {
        let seed = suggest(from: inputs, strength: strength)
        let dominant = style.followsPhoto ? GradingStyle.dominantHue(of: inputs) : nil
        let problem = GradingProblem(inputs: inputs, cap: strength.maxSaturation, style: style)
        guard !problem.items.isEmpty || style != .neutral else { return seed }   // nothing with a hue to aim at

        // Ranges that have colors with a hue can be tinted, and those the style has an opinion about; the others stay as they are.
        var active = seed.details.enumerated().filter { $0.element.reason == .tinted || $0.element.reason == .onTarget }.map(\.offset)
        for (index, range) in [TonalRange.shadows, .midtones, .highlights].enumerated()
        where style.ranges(dominantHue: dominant).contains(range) && !active.contains(index) { active.append(index) }
        active.sort()
        guard !active.isEmpty else { return seed }

        // Starting points: the heuristic, and a gentle tint toward the mean target of each range.
        var seedParameters: [Double] = []
        for wheel in [seed.preset.shadows, seed.preset.midtones, seed.preset.highlights] {
            seedParameters += [Double(wheel.hue), Double(wheel.saturation), 0]
        }
        seedParameters += [0, 0, 0, 0, 0]   // Balance, Hue and Saturation of Master, Blacks and Shadows of the Light palette
        var gentle = [Double](repeating: 0, count: GradingProblem.parameterCount)
        if style.usesMaster, let hue = style.probes(dominantHue: dominant).first?.hue {
            // The Master wheel carries the cast of the whole photo: first find what it takes on its own (without the ranges,
            // which would only cancel part of it), then let the ranges adjust the colors on top.
            var start = [Double](repeating: 0, count: GradingProblem.parameterCount)
            start[10] = DxOHue.fromSRGB(hue); start[11] = strength.maxSaturation / 2
            let master = problem.search(from: start, active: [], extras: false, master: true).x
            seedParameters[10] = master[10]; seedParameters[11] = master[11]
            gentle[10] = master[10]; gentle[11] = master[11]
        }
        for r in active {
            let styled = style.castHue(for: tonalRange(at: r), dominantHue: dominant).map { DxOHue.fromSRGB($0) }
            gentle[3 * r] = problem.meanTargetHue(range: tonalRange(at: r)) ?? styled ?? seedParameters[3 * r]
            gentle[3 * r + 1] = strength.maxSaturation / 3
        }
        let zero = [Double](repeating: 0, count: GradingProblem.parameterCount)
        var best = (x: zero, cost: problem.cost(zero))
        for start in [seedParameters, gentle] {
            let found = problem.search(from: start, active: active, extras: false, master: style.usesMaster, tone: style.usesTone)
            if found.cost < best.cost { best = found }
        }
        // Luminance and Balance only when they earn their place: in the model they mostly trade a little hue error for
        // lightness, and a Lum of −3 or a Balance of 6 is noise in the preset, not a decision.
        let withExtras = problem.search(from: best.x, active: active, master: style.usesMaster, tone: style.usesTone)
        let plainFit = problem.meanErrors(best.x).after, extraFit = problem.meanErrors(withExtras.x).after
        if withExtras.cost < best.cost * 0.95 && extraFit < plainFit - 1 {
            best = withExtras
        }

        // Whole numbers, like PhotoLab's fields.
        var x = best.x
        for r in 0..<3 {
            x[3 * r] = (x[3 * r].rounded().truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
            x[3 * r + 1] = x[3 * r + 1].rounded()
            if x[3 * r + 1] < 1 { x[3 * r + 1] = 0 }
            x[3 * r + 2] = x[3 * r + 2].rounded()
            if abs(x[3 * r + 2]) < 1 { x[3 * r + 2] = 0 }
        }
        x[9] = x[9].rounded()
        if abs(x[9]) < 1 { x[9] = 0 }
        x[10] = (x[10].rounded().truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        x[11] = x[11].rounded()
        if x[11] < 1 { x[11] = 0 }
        for index in [12, 13] {
            x[index] = x[index].rounded()
            if abs(x[index]) < 1 { x[index] = 0 }
        }
        let finalCost = problem.cost(x)
        let baseline = problem.cost(zero)
        if finalCost > baseline * 0.99 { x = zero }   // not worth a tint

        var preset = ColorGradingPreset()
        var details: [RangeDetail] = []
        for (r, old) in seed.details.enumerated() {
            let wheel = x[3 * r + 1] > 0 || x[3 * r + 2] != 0
                ? ColorGradingPreset.Wheel(hue: x[3 * r + 1] > 0 ? Int(x[3 * r]) : 0, saturation: Int(x[3 * r + 1]),
                                           luminance: Int(x[3 * r + 2])) : .neutral
            let tinted = x[3 * r + 1] > 0 || x[3 * r + 2] != 0
            switch old.range {
            case .shadows: preset.shadows = wheel
            case .midtones: preset.midtones = wheel
            case .highlights: preset.highlights = wheel
            }
            var detail = old
            detail.wheel = wheel
            if tinted {
                detail.reason = .tinted
                detail.tintHue = x[3 * r + 1] > 0 ? DxOHue.toSRGB(Double(wheel.hue)) : nil
            } else {
                detail.tintHue = nil
                if detail.reason == .tinted { detail.reason = .onTarget }
            }
            details.append(detail)
        }
        preset.balance = Int(x[9])
        if x[11] > 0 { preset.master = ColorGradingPreset.Wheel(hue: Int(x[10]), saturation: Int(x[11]), luminance: 0) }
        let (before, after) = problem.meanErrors(x)
        var suggestion = Suggestion(preset: preset, details: details, fit: Fit(before: before, after: after))
        suggestion.toneBlacks = Int(x[12])
        suggestion.toneShadows = Int(x[13])
        return suggestion
    }

    private static func tonalRange(at index: Int) -> TonalRange { [TonalRange.shadows, .midtones, .highlights][index] }
}

/// The dominant colors and the cost of a grading for them.
struct GradingProblem {
    struct Item {
        var linear: SIMD3<Float>
        var lab: SIMD3<Float>
        var hue: Double
        var chroma: Float
        var lightness: Float
        var target: Double
        var weight: Double
        var range: TonalRange
    }

    /// Hue, Saturation and Luminance of each range wheel, then Balance, Hue and Saturation of the Master wheel, and Blacks and Shadows of the Light palette.
    static let parameterCount = 14
    /// Blacks and Shadows of the Light palette may move this far: twice the strength's Saturation (60 at Moderate).
    static func maximumTone(_ cap: Double) -> Double { 2 * cap }
    /// Luminance may move as far as the strength allows Saturation; Balance up to this far.
    static let maximumBalance = 50.0

    let items: [Item]
    let style: GradingStyle
    /// Greys at the middle of the shadows and of the highlights, with the cast the style wants them to get.
    let probes: [(linear: SIMD3<Float>, lab: SIMD3<Float>, target: SIMD2<Float>, lift: Float)]
    /// Colors without a hue (greys): they have no target, but a tint must not turn them into a cast.
    let neutrals: [(linear: SIMD3<Float>, lab: SIMD3<Float>, weight: Double)]
    let totalWeight: Double
    let cap: Double

    init(inputs: [ColorGradingSuggestion.Input], cap: Double, style: GradingStyle = .neutral) {
        self.style = style
        var probes: [(linear: SIMD3<Float>, lab: SIMD3<Float>, target: SIMD2<Float>, lift: Float)] = []
        // A cast of this chroma is clearly visible without being a color filter; it scales with the strength.
        let chroma = Float(0.012 * cap / 30)
        for probe in style.probes(dominantHue: style.followsPhoto ? GradingStyle.dominantHue(of: inputs) : nil) {
            var target = SIMD2<Float>.zero
            if let hue = probe.hue {
                // The OKLab angle of the pure color with this sRGB hue is the direction the cast has to take.
                let pure = SRGBColor.fromHSB(h: hue, s: 1, b: 1).oklab
                let length = (pure.y * pure.y + pure.z * pure.z).squareRoot()
                target = SIMD2(pure.y, pure.z) / length * chroma * probe.scale
            }
            let lab = SIMD3<Float>(probe.lightness, 0, 0)
            probes.append((ColorMath.okLabToLinear(lab), lab, target, probe.lift * Float(min(1, cap / 30))))
        }
        self.probes = probes
        var items: [Item] = []
        var neutrals: [(linear: SIMD3<Float>, lab: SIMD3<Float>, weight: Double)] = []
        for input in inputs where input.color.chroma < DxOMapping.neutralChroma && input.share > 0 {
            let linear = input.color.linear
            neutrals.append((linear, ColorMath.linearToOKLab(linear), input.share))
        }
        self.neutrals = neutrals
        for input in inputs where input.color.chroma >= DxOMapping.neutralChroma {
            let weight = input.share * min(1, input.color.chroma / 0.1)
            guard weight > 0 else { continue }
            let linear = input.color.linear
            let lab = ColorMath.linearToOKLab(linear)
            items.append(Item(linear: linear, lab: lab, hue: input.color.hsb.h, chroma: (lab.y * lab.y + lab.z * lab.z).squareRoot(),
                              lightness: lab.x, target: input.targetHue, weight: weight, range: DxOMapping.tonalRange(for: input.color)))
        }
        self.items = items
        self.totalWeight = items.reduce(0) { $0 + $1.weight }
        self.cap = cap
    }

    /// Circular mean of the targets of the colors in a range, as PhotoLab hue; nil without colors.
    func meanTargetHue(range: TonalRange) -> Double? {
        var s = 0.0, c = 0.0
        for item in items where item.range == range {
            s += item.weight * sin(item.target * .pi / 180)
            c += item.weight * cos(item.target * .pi / 180)
        }
        guard s != 0 || c != 0 else { return nil }
        return DxOHue.fromSRGB(ColorMath.normalizeDegrees(atan2(s, c) * 180 / .pi))
    }

    func settings(_ x: [Double]) -> GradePreviewSettings {
        func tint(_ r: Int) -> GradePreviewSettings.Tint { .init(dxoHue: x[3 * r], saturation: x[3 * r + 1], luminance: x[3 * r + 2]) }
        return GradePreviewSettings(shadows: tint(0), midtones: tint(1), highlights: tint(2), master: .init(dxoHue: x[10], saturation: x[11]), balance: x[9], toneBlacks: x[12], toneShadows: x[13])
    }

    /// Distance in hue (degrees) of one item's graded color from its target; a color that lost its hue counts as 45°.
    private func hueError(_ item: Item, plan: GradePreview.Plan) -> (error: Double, chroma: Float, lightness: Float) {
        let linear = plan.applyLinear(linear: item.linear, lab: item.lab)
        let lab = ColorMath.linearToOKLab(linear)
        let color = SRGBColor(linear: linear).clamped
        let hsb = color.hsb
        let error = hsb.s < 0.03 ? 45 : abs(ColorMath.signedAngle(from: hsb.h, to: item.target))
        return (error, (lab.y * lab.y + lab.z * lab.z).squareRoot(), lab.x)
    }

    /// What is minimized: hue distance to the targets, with penalties for losing chroma or changing lightness,
    /// and a small one for the saturation itself.
    func cost(_ x: [Double]) -> Double {
        let plan = GradePreview.Plan(settings(x))
        var total = 0.0
        for item in items {
            let after = hueError(item, plan: plan)
            let dChroma = Double(after.chroma - item.chroma) / Double(max(item.chroma, 0.05))
            let dLight = Double(after.lightness - item.lightness) / 0.1
            let e = after.error / 30
            total += item.weight * (e * e + dChroma * dChroma + 0.5 * dLight * dLight)
        }
        // A grey that picks up chroma 0.03 (a visible cast) costs as much as 30° of hue error.
        for neutral in neutrals {
            let lab = ColorMath.linearToOKLab(plan.applyLinear(linear: neutral.linear, lab: neutral.lab))
            let cast = Double((lab.y * lab.y + lab.z * lab.z).squareRoot()) / 0.03
            total += neutral.weight * 0.5 * cast * cast
        }
        // The style: the greys of the shadows and of the highlights should take on their cast.
        let styleWeight = max(totalWeight, 0.5)
        for probe in probes {
            let lab = ColorMath.linearToOKLab(plan.applyLinear(linear: probe.linear, lab: probe.lab))
            let miss = Double(simd_length(SIMD2(lab.y, lab.z) - probe.target)) / 0.03
            let lift = Double(lab.x - probe.lab.x - probe.lift) / 0.03
            total += styleWeight * style.weight * (miss * miss + lift * lift)
        }
        var regularization = 0.0
        for r in 0..<3 { regularization += pow(x[3 * r + 1] / max(cap, 1), 2) + 2 * pow(x[3 * r + 2] / max(cap, 1), 2) }
        regularization += 2 * pow(x[9] / Self.maximumBalance, 2) + pow(x[11] / max(cap, 1), 2)
        regularization += 0.5 * (pow(x[12] / Self.maximumTone(cap), 2) + pow(x[13] / Self.maximumTone(cap), 2))
        return total + 0.02 * totalWeight * regularization
    }

    /// Weighted mean hue distance to the targets, before any grading and with the grading `x`.
    func meanErrors(_ x: [Double]) -> (before: Double, after: Double) {
        guard totalWeight > 0 else { return (0, 0) }
        let none = GradePreview.Plan(GradePreviewSettings()), graded = GradePreview.Plan(settings(x))
        var before = 0.0, after = 0.0
        for item in items {
            before += item.weight * hueError(item, plan: none).error
            after += item.weight * hueError(item, plan: graded).error
        }
        return (before / totalWeight, after / totalWeight)
    }

    /// Pattern search over the parameters of the active wheels (and Balance): try steps up and down, keep what lowers the cost,
    /// halve the steps.
    func search(from start: [Double], active: [Int], extras: Bool = true, master: Bool = false, tone: Bool = false) -> (x: [Double], cost: Double) {
        var x = start
        for r in 0..<3 where !active.contains(r) { x[3 * r + 1] = 0; x[3 * r + 2] = 0 }
        for r in active {
            x[3 * r + 1] = min(max(x[3 * r + 1], 0), cap)
            x[3 * r + 2] = extras ? min(max(x[3 * r + 2], -cap), cap) : 0
        }
        if !extras { x[9] = 0 }
        if !master { x[10] = 0; x[11] = 0 } else { x[11] = min(max(x[11], 0), cap) }
        if !tone { x[12] = 0; x[13] = 0 }
        var best = cost(x)
        var hueStep = 30.0, satStep = max(cap / 4, 1)
        while hueStep >= 1 {
            var improved = true
            var rounds = 0
            while improved, rounds < 20 {
                improved = false
                rounds += 1
                var moves: [(Int, Double)] = []
                for r in active {
                    moves += [(3 * r, hueStep), (3 * r, -hueStep), (3 * r + 1, satStep), (3 * r + 1, -satStep)]
                    if extras { moves += [(3 * r + 2, satStep), (3 * r + 2, -satStep)] }
                }
                if extras { moves += [(9, satStep * 2), (9, -satStep * 2)] }
                if master { moves += [(10, hueStep), (10, -hueStep), (11, satStep), (11, -satStep)] }
                if tone { moves += [(12, satStep * 2), (12, -satStep * 2), (13, satStep * 2), (13, -satStep * 2)] }
                for (index, step) in moves {
                    var y = x
                    y[index] += step
                    switch index {
                    case 9: y[index] = min(max(y[index], -Self.maximumBalance), Self.maximumBalance)
                    case 10: y[index] = ColorMath.normalizeDegrees(y[index])
                    case 11: y[index] = min(max(y[index], 0), cap)
                    case 12, 13: y[index] = min(max(y[index], -Self.maximumTone(cap)), Self.maximumTone(cap))
                    case _ where index % 3 == 0: y[index] = ColorMath.normalizeDegrees(y[index])
                    case _ where index % 3 == 1: y[index] = min(max(y[index], 0), cap)
                    default: y[index] = min(max(y[index], -cap), cap)
                    }
                    let c = cost(y)
                    if c < best - 1e-9 { x = y; best = c; improved = true }
                }
            }
            hueStep /= 2
            satStep = max(satStep / 2, 0.5)
        }
        return (x, best)
    }
}
