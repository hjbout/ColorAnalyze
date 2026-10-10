import CoreGraphics
import Foundation
import ImageIO
import simd

// Calibration helper for the preview: reads the chart (or a PhotoLab export of it), measures the patches in OKLab,
// compares with a baseline and with what GradePreview predicts.
//
//   analyze patches <image>                      → OKLab of every patch
//   analyze compare <baseline> <export> [flags]  → measured change per patch, next to the predicted change
//
// flags: --shadows HUE,SAT[,LUM] --midtones … --highlights … --master …   (PhotoLab's DxO hue, saturation, luminance)
//        --balance N                                                    (Color Grading Balance)
//        --shift channel:degrees,…  --hsl-sat channel:value,…  --hsl-lum channel:value,…   (HSL tool)
//        --amount N

let cell = 180, cols = 17, rows = 4

/// The measured patches of a chart: linear sRGB per patch, row-major.
struct Chart {
    var linear: [SIMD3<Float>]

    /// From an image of the chart (JPEG, TIFF …) or from the CSV that `dump` wrote for one.
    init(path: String) {
        if path.hasSuffix(".csv") {
            let lines = try! String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").dropFirst()
            linear = lines.map { line in
                let f = line.split(separator: ",").map { Float($0)! }
                return SIMD3(f[2], f[3], f[4])
            }
        } else {
            let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            let buffer = PixelBuffer(image: image, maxDimension: max(image.width, image.height))
            linear = (0..<(rows * cols)).map { patchLinear(buffer, row: $0 / cols, col: $0 % cols) }
        }
    }
}

func load(_ path: String) -> Chart { Chart(path: path) }

/// Average linear color of the middle of a patch.
func patchLinear(_ buffer: PixelBuffer, row: Int, col: Int) -> SIMD3<Float> {
    var sum = SIMD3<Float>.zero
    var n: Float = 0
    for y in (row * cell + 40)..<(row * cell + 140) {
        for x in (col * cell + 40)..<(col * cell + 140) {
            sum += buffer.linear[y * buffer.width + x]
            n += 1
        }
    }
    return sum / n
}

/// OKLab of a patch of a chart.
func patch(_ chart: Chart, row: Int, col: Int) -> SIMD3<Float> {
    ColorMath.linearToOKLab(chart.linear[row * cols + col])
}

func parseTint(_ text: String) -> GradePreviewSettings.Tint {
    let parts = text.split(separator: ",").compactMap { Double($0) }
    return .init(dxoHue: parts[0], saturation: parts[1], luminance: parts.count > 2 ? parts[2] : 0)
}

func parseChannels(_ text: String) -> [DxOChannel: Double] {
    var result: [DxOChannel: Double] = [:]
    for pair in text.split(separator: ",") {
        let kv = pair.split(separator: ":")
        if let channel = DxOChannel(rawValue: String(kv[0])), let value = Double(kv[1]) { result[channel] = value }
    }
    return result
}

/// The settings named by the flags from index `start` on.
func parseFlags(_ args: [String], from start: Int) -> GradePreviewSettings {
    var settings = GradePreviewSettings()
    var i = start
    while i < args.count {
        switch args[i] {
        case "--shadows": settings.shadows = parseTint(args[i + 1]); i += 2
        case "--midtones": settings.midtones = parseTint(args[i + 1]); i += 2
        case "--highlights": settings.highlights = parseTint(args[i + 1]); i += 2
        case "--master": settings.master = parseTint(args[i + 1]); i += 2
        case "--balance": settings.balance = Double(args[i + 1])!; i += 2
        case "--tone-blacks": settings.toneBlacks = Double(args[i + 1])!; i += 2
        case "--tone-shadows": settings.toneShadows = Double(args[i + 1])!; i += 2
        case "--amount": settings.amount = Double(args[i + 1])!; i += 2
        case "--shift": settings.hueShifts = parseChannels(args[i + 1]); i += 2
        case "--hsl-sat": settings.hslSaturation = parseChannels(args[i + 1]); i += 2
        case "--hsl-lum": settings.hslLuminance = parseChannels(args[i + 1]); i += 2
        default: i += 1
        }
    }
    return settings
}

func angle(_ lab: SIMD3<Float>) -> Double { ColorMath.normalizeDegrees(Double(atan2(lab.z, lab.y)) * 180 / .pi) }
func chroma(_ lab: SIMD3<Float>) -> Double { Double((lab.y * lab.y + lab.z * lab.z).squareRoot()) }
func hex(_ lab: SIMD3<Float>) -> String { SRGBColor(oklab: lab).hex }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: analyze patches <image> | compare <baseline> <export> [flags]"); exit(1) }

switch args[0] {
case "patches":
    let chart = load(args[1])
    for row in 0..<rows {
        for col in 0..<cols {
            let lab = patch(chart, row: row, col: col)
            print(String(format: "%d,%d,%@,L=%.4f,a=%.4f,b=%.4f", row, col, hex(lab), lab.x, lab.y, lab.z))
        }
    }
case "dump":
    // row,col,linear r g b,OKLab L a b
    let chart = load(args[1])
    print("row,col,lr,lg,lb,L,a,b")
    for row in 0..<rows {
        for col in 0..<cols {
            let lin = chart.linear[row * cols + col]
            let lab = ColorMath.linearToOKLab(lin)
            print(String(format: "%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f", row, col, lin.x, lin.y, lin.z, lab.x, lab.y, lab.z))
        }
    }
case "compare":
    let base = load(args[1]), export = load(args[2])
    let settings = parseFlags(args, from: 3)
    let plan = GradePreview.Plan(settings)
    print("row,col,base,export | measured dL dA dB dC dHue | predicted dL dA dB dC dHue")
    for row in 0..<rows {
        for col in 0..<cols {
            let a = patch(base, row: row, col: col), b = patch(export, row: row, col: col)
            let p = plan.apply(a)
            func delta(_ x: SIMD3<Float>) -> String {
                String(format: "%+.4f %+.4f %+.4f %+.4f %+6.1f", x.x - a.x, x.y - a.y, x.z - a.z, chroma(x) - chroma(a),
                       chroma(a) > 0.02 && chroma(x) > 0.02 ? ColorMath.signedAngle(from: angle(a), to: angle(x)) : 0)
            }
            print("\(row),\(col),\(hex(a)),\(hex(b)) | \(delta(b)) | \(delta(p))")
        }
    }
case "score":
    // mean and worst OKLab distance (×100) between what the preview predicts and what PhotoLab did, per row group
    let base = load(args[1]), export = load(args[2])
    let settings = parseFlags(args, from: 3)
    let plan = GradePreview.Plan(settings)
    func dist(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
        let d = a - b
        let squared: Float = d.x * d.x + d.y * d.y + d.z * d.z
        return Double(squared.squareRoot()) * 100
    }
    var groups: [(name: String, rows: ClosedRange<Int>)] = [("gray", 0...0), ("colors", 1...3)]
    var line = ""
    for group in groups {
        var err: [Double] = [], effect: [Double] = []
        for row in group.rows {
            for col in 0..<cols {
                let a = patch(base, row: row, col: col), b = patch(export, row: row, col: col)
                err.append(dist(plan.apply(a), b)); effect.append(dist(a, b))
            }
        }
        line += String(format: "%@: error mean %.2f max %.2f (effect mean %.2f)   ", group.name, err.reduce(0, +) / Double(err.count), err.max()!, effect.reduce(0, +) / Double(effect.count))
    }
    groups = []
    print(line)
case "pixels":
    // analyze pixels BASE GRADED out.csv [stride]: linear sRGB of both, for fitting outside Swift
    func readFull(_ path: String) -> PixelBuffer {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        return PixelBuffer(image: CGImageSourceCreateImageAtIndex(source, 0, nil)!, maxDimension: 700)
    }
    let a = readFull(args[1]), b = readFull(args[2])
    let stride = args.count > 4 ? Int(args[4])! : 7
    var out = "br,bg,bb,gr,gg,gb\n"
    var i = 0
    while i < a.width * a.height {
        let x = a.linear[i], y = b.linear[i]
        out += String(format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f\n", x.x, x.y, x.z, y.x, y.y, y.z)
        i += stride
    }
    try! out.write(toFile: args[3], atomically: true, encoding: .utf8)
case "photo":
    // A whole photo: the PhotoLab export without corrections, the export with them, and what the preview makes of the first.
    // Error = OKLab distance × 100 between prediction and export; effect = the same between baseline and export.
    func read(_ path: String) -> PixelBuffer {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        return PixelBuffer(image: CGImageSourceCreateImageAtIndex(source, 0, nil)!, maxDimension: 700)
    }
    let base = read(args[1]), graded = read(args[2])
    precondition(base.width == graded.width && base.height == graded.height, "sizes differ")
    let plan = GradePreview.Plan(parseFlags(args, from: 3))
    var errors: [Float] = [], effects: [Float] = []
    var residual = SIMD3<Float>.zero, shift = SIMD3<Float>.zero
    for i in 0..<(base.width * base.height) {
        let a = base.lab[i], b = graded.lab[i]
        let p = plan.applyLinear(linear: base.linear[i], lab: a)
        let predicted = ColorMath.linearToOKLab(p)
        errors.append(simd_length(predicted - b) * 100)
        effects.append(simd_length(a - b) * 100)
        residual += predicted - b
        shift += b - a
    }
    // by lightness and by chroma of the baseline pixel
    func bins(_ name: String, _ edges: [Float], _ key: (SIMD3<Float>) -> Float) {
        for k in 0..<(edges.count - 1) {
            var e = 0 as Float, f = 0 as Float, c = 0
            for i in 0..<errors.count where key(base.lab[i]) >= edges[k] && key(base.lab[i]) < edges[k + 1] { e += errors[i]; f += effects[i]; c += 1 }
            if c > 0 { print(String(format: "  %@ %.2f–%.2f: %5.1f%% of pixels, effect %.2f, error %.2f", name, edges[k], edges[k + 1], 100 * Float(c) / Float(errors.count), f / Float(c), e / Float(c))) }
        }
    }
    bins("L", [0, 0.2, 0.35, 0.5, 0.65, 0.8, 1.01]) { $0.x }
    bins("C", [0, 0.02, 0.05, 0.1, 0.5]) { ($0.y * $0.y + $0.z * $0.z).squareRoot() }
    // How well the predicted change points the way of the measured one: slope and cosine of measured onto predicted, per lightness band
    do {
        let edges: [Float] = [0, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.5, 0.65, 0.8, 1.01]
        for k in 0..<(edges.count - 1) {
            var mp: Float = 0, pp: Float = 0, mm: Float = 0, count: Float = 0
            var mmean = SIMD3<Float>.zero, pmean = SIMD3<Float>.zero
            for i in 0..<errors.count where base.lab[i].x >= edges[k] && base.lab[i].x < edges[k + 1] {
                let p = ColorMath.linearToOKLab(plan.applyLinear(linear: base.linear[i], lab: base.lab[i])) - base.lab[i]
                let m = graded.lab[i] - base.lab[i]
                mp += simd_dot(m, p); pp += simd_dot(p, p); mm += simd_dot(m, m)
                mmean += m; pmean += p; count += 1
            }
            mmean /= max(count, 1); pmean /= max(count, 1)
            if pp > 0 && mm > 0 { print(String(format: "      mean measured dL %+.4f dA %+.4f dB %+.4f | predicted dL %+.4f dA %+.4f dB %+.4f", mmean.x, mmean.y, mmean.z, pmean.x, pmean.y, pmean.z)) }
            if pp > 0 && mm > 0 { print(String(format: "  L %.2f–%.2f: measured = %.2f × predicted, cosine %.2f", edges[k], edges[k + 1], mp / pp, mp / (pp * mm).squareRoot())) }
        }
    }
    func stats(_ v: [Float]) -> String {
        let sorted = v.sorted()
        return String(format: "mean %.2f  median %.2f  p95 %.2f", v.reduce(0, +) / Float(v.count), sorted[v.count / 2], sorted[Int(Float(v.count) * 0.95)])
    }
    let n = Float(base.width * base.height)
    print("pixels \(base.width)x\(base.height)")
    print("effect (baseline vs PhotoLab): " + stats(effects))
    print("error  (preview  vs PhotoLab): " + stats(errors))
    print(String(format: "mean PhotoLab change dL %+.4f dA %+.4f dB %+.4f ; mean preview error dL %+.4f dA %+.4f dB %+.4f",
                 shift.x / n, shift.y / n, shift.z / n, residual.x / n, residual.y / n, residual.z / n))
default:
    print("unknown command")
}
