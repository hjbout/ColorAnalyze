// Draws the ColorAnalyze app icon at every size an .iconset needs.
// Usage: make-icon <output .iconset directory>   (see scripts/make-icon.sh)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// HSB → RGB, hue in degrees.
func rgb(h: Double, s: Double, v: Double) -> (r: Double, g: Double, b: Double) {
    let c = v * s
    let hp = h.truncatingRemainder(dividingBy: 360) / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let (r, g, b): (Double, Double, Double)
    switch hp {
    case ..<1: (r, g, b) = (c, x, 0)
    case ..<2: (r, g, b) = (x, c, 0)
    case ..<3: (r, g, b) = (0, c, x)
    case ..<4: (r, g, b) = (0, x, c)
    case ..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return (r + v - c, g + v - c, b + v - c)
}

func color(_ c: (r: Double, g: Double, b: Double), alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [c.r, c.g, c.b, alpha])!
}

func gray(_ w: Double, alpha: Double = 1) -> CGColor {
    CGColor(colorSpace: space, components: [w, w, w, alpha])!
}

/// Squircle-ish tile (superellipse) like the macOS icon grid.
func tilePath(center: CGPoint, half: CGFloat, exponent n: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: center.x + copysign(pow(abs(c), 2 / n), c) * half,
                        y: center.y + copysign(pow(abs(s), 2 / n), s) * half)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// HSB disc at full brightness: hue = angle (counter-clockwise from 3 o'clock), saturation = radius.
func wheelImage(diameter d: Int) -> CGImage {
    var bytes = [UInt8](repeating: 0, count: d * d * 4)
    let c = Double(d) / 2
    for y in 0..<d {
        for x in 0..<d {
            let dx = Double(x) + 0.5 - c, dy = c - (Double(y) + 0.5)
            let r = hypot(dx, dy)
            let alpha = min(1, max(0, c - r + 0.5))
            guard alpha > 0 else { continue }
            var h = atan2(dy, dx) * 180 / .pi
            if h < 0 { h += 360 }
            let col = rgb(h: h, s: min(1, r / c), v: 1)
            let i = (y * d + x) * 4
            bytes[i] = UInt8(col.r * alpha * 255)
            bytes[i + 1] = UInt8(col.g * alpha * 255)
            bytes[i + 2] = UInt8(col.b * alpha * 255)
            bytes[i + 3] = UInt8(alpha * 255)
        }
    }
    return bytes.withUnsafeMutableBytes { raw in
        CGContext(data: raw.baseAddress, width: d, height: d, bitsPerComponent: 8, bytesPerRow: d * 4,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

/// Draws the icon in a 1024×1024 design space, scaled to `size` pixels.
func renderIcon(size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high

    let center = CGPoint(x: 512, y: 512)
    let tile = tilePath(center: center, half: 412)

    // Tile with soft drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: gray(0, alpha: 0.4))
    ctx.addPath(tile)
    ctx.setFillColor(gray(0.12))
    ctx.fillPath()
    ctx.restoreGState()

    // Dark gradient background and a faint top sheen.
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [
        color((0.21, 0.23, 0.30)), color((0.07, 0.08, 0.11)),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [gray(1, alpha: 0.14), gray(1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()

    // Color wheel.
    let radius: CGFloat = 310
    let wheelRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: gray(0, alpha: 0.5))
    ctx.draw(wheelImage(diameter: max(2, Int((radius * 2 * scale).rounded()))), in: wheelRect)
    ctx.restoreGState()
    ctx.setStrokeColor(gray(1, alpha: 0.55))
    ctx.setLineWidth(6)
    ctx.strokeEllipse(in: wheelRect.insetBy(dx: 3, dy: 3))

    func point(hue: Double, saturation: Double) -> CGPoint {
        let a = hue * .pi / 180
        return CGPoint(x: center.x + cos(a) * saturation * radius, y: center.y + sin(a) * saturation * radius)
    }

    // Harmony spokes (square harmony, rotated).
    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [30, 22])
    ctx.setLineWidth(9)
    ctx.setStrokeColor(gray(1, alpha: 0.92))
    ctx.setShadow(offset: .zero, blur: 7, color: gray(0, alpha: 0.55))
    for hue in stride(from: 22.0, to: 360, by: 90) {
        ctx.move(to: center)
        ctx.addLine(to: point(hue: hue, saturation: 1))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // Markers: sampled colors, placed like the app places them.
    let markers: [(hue: Double, saturation: Double, diameter: CGFloat)] = [
        (30, 0.70, 138), (205, 0.60, 112), (118, 0.84, 94), (292, 0.50, 80),
    ]
    for m in markers {
        let p = point(hue: m.hue, saturation: m.saturation)
        let rect = CGRect(x: p.x - m.diameter / 2, y: p.y - m.diameter / 2, width: m.diameter, height: m.diameter)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -7), blur: 16, color: gray(0, alpha: 0.55))
        ctx.setFillColor(color(rgb(h: m.hue, s: min(1, m.saturation + 0.12), v: 0.93)))
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()
        ctx.setStrokeColor(gray(1))
        ctx.setLineWidth(m.diameter * 0.095)
        ctx.strokeEllipse(in: rect.insetBy(dx: m.diameter * 0.0475, dy: m.diameter * 0.0475))
    }

    // Thin light edge on the tile.
    ctx.addPath(tile)
    ctx.setStrokeColor(gray(1, alpha: 0.16))
    ctx.setLineWidth(3)
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("Could not write \(url.path)\n".utf8))
        exit(1)
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let files: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for file in files {
    writePNG(renderIcon(size: file.pixels), to: out.appendingPathComponent(file.name + ".png"))
}
print("Wrote \(files.count) images to \(out.path)")
