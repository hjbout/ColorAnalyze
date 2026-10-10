import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Calibration chart: row 0 neutral ramp, rows 1-3 hue patches at three saturation/brightness levels.
let cell = 180, cols = 17, rows = 4
let W = cell * cols, H = cell * rows
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func hsb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let c = v * s, hp = h / 60, x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)), m = v - c
    let (r, g, b): (Double, Double, Double)
    switch Int(hp) % 6 {
    case 0: (r, g, b) = (c, x, 0); case 1: (r, g, b) = (x, c, 0); case 2: (r, g, b) = (0, c, x)
    case 3: (r, g, b) = (0, x, c); case 4: (r, g, b) = (x, 0, c); default: (r, g, b) = (c, 0, x)
    }
    return (r + m, g + m, b + m)
}
let hues: [Double] = [0, 15, 30, 45, 60, 90, 120, 150, 180, 210, 240, 255, 270, 285, 300, 330, 345]
let levels: [(Double, Double)] = [(0.7, 0.8), (0.6, 0.45), (0.35, 0.95)]
var manifest = ""
for row in 0..<rows {
    for col in 0..<cols {
        let color: (Double, Double, Double)
        if row == 0 {
            let v = Double(min(255, col * 16)) / 255
            color = (v, v, v)
            manifest += "gray,\(row),\(col),\(min(255, col * 16))\n"
        } else {
            let (s, v) = levels[row - 1]
            color = hsb(hues[col], s, v)
            manifest += "hue,\(row),\(col),\(hues[col]),\(s),\(v)\n"
        }
        // y is up in CoreGraphics: row 0 at the top.
        ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(color.0), CGFloat(color.1), CGFloat(color.2), 1])!)
        ctx.fill(CGRect(x: col * cell, y: H - (row + 1) * cell, width: cell, height: cell))
    }
}
try! manifest.write(toFile: "manifest.csv", atomically: true, encoding: .utf8)
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "images/chart.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
CGImageDestinationFinalize(dest)
print("chart \(W)x\(H)")
