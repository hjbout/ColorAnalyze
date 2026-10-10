import ColorCore
import SwiftUI

extension SRGBColor {
    /// Drawn in Display P3, so colors outside the sRGB gamut show their real saturation on a wide-gamut display.
    var swiftUIColor: Color {
        let p3 = displayP3Components
        return Color(.displayP3, red: p3.r, green: p3.g, blue: p3.b)
    }
    /// Screen luminance as APCA defines it (the sRGB channels to the power 2.4, weighted).
    private var apcaLuminance: Double {
        0.2126729 * pow(r, 2.4) + 0.7151522 * pow(g, 2.4) + 0.0721750 * pow(b, 2.4)
    }
    /// WCAG 2 relative luminance (the sRGB curve proper).
    private var wcagLuminance: Double {
        let l = linear
        return Double(0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z)
    }
    /// True when black digits read better on this color than white ones.
    ///
    /// The contrast is judged with APCA (the perceptual model for WCAG 3, which accounts for the fact that white text on
    /// a mid-tone looks clearer than the same contrast ratio of black text, the reason WCAG 2 picks black on mid greens
    /// that read better with white). WCAG 2 still guards the result: the choice must keep at least 3:1, the minimum for
    /// large or bold text, unless the other one cannot.
    var prefersDarkText: Bool {
        let y = max(0, apcaLuminance)
        // Lc of black text on this background, and of white text (magnitudes).
        let black = max(0, (pow(y, 0.56) - 0.0) * 1.14 - 0.027)
        let white = max(0, (1.0 - pow(y, 0.65)) * 1.14 - 0.027)
        let dark = black > white
        let w = wcagLuminance
        let blackRatio = (w + 0.05) / 0.05, whiteRatio = 1.05 / (w + 0.05)
        if dark, blackRatio < 3, whiteRatio >= 3 { return false }
        if !dark, whiteRatio < 3, blackRatio >= 3 { return true }
        return dark
    }
    /// Black or white, whichever reads better on this color.
    var contrastingText: Color { prefersDarkText ? .black : .white }
    /// The opposite, as a thin halo around the digits.
    var contrastingHalo: Color { prefersDarkText ? .white : .black }
}

/// A number with a thin halo, readable on any fill.
struct BadgeNumber: View {
    let number: Int
    let color: SRGBColor
    let size: CGFloat

    var body: some View {
        let halo = color.contrastingHalo.opacity(0.55)
        let text = Text("\(number)").font(.system(size: size, weight: .heavy, design: .rounded))
        ZStack {
            text.foregroundStyle(halo).offset(x: 0.7, y: 0)
            text.foregroundStyle(halo).offset(x: -0.7, y: 0)
            text.foregroundStyle(halo).offset(x: 0, y: 0.7)
            text.foregroundStyle(halo).offset(x: 0, y: -0.7)
            text.foregroundStyle(color.contrastingText)
        }
    }
}

/// The marker look shared by the photo, wheel and list.
struct MarkerBadge: View {
    let number: Int
    let color: SRGBColor
    var diameter: CGFloat = 26
    var isSelected = false

    var body: some View {
        ZStack {
            Circle().fill(color.swiftUIColor)
            Circle().strokeBorder(.white, lineWidth: isSelected ? 3 : 2)
            Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5)
            BadgeNumber(number: number, color: color, size: max(10, diameter * 0.46))
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if isSelected {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: diameter + 8, height: diameter + 8)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}

/// Marker look for the graded ("after") color: a dashed ring instead of a solid one.
struct GhostBadge: View {
    let number: Int
    let color: SRGBColor
    var diameter: CGFloat = 26

    var body: some View {
        ZStack {
            Circle().fill(color.swiftUIColor)
            Circle().strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5)
            BadgeNumber(number: number, color: color, size: max(9, diameter * 0.42))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}
