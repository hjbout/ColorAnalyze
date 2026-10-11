import ColorCore
import SwiftUI

extension SRGBColor {
    /// Drawn in Display P3, so colors outside the sRGB gamut show their real saturation on a wide-gamut display.
    var swiftUIColor: Color {
        let p3 = displayP3Components
        return Color(.displayP3, red: p3.r, green: p3.g, blue: p3.b)
    }
    /// WCAG 2 relative luminance (the sRGB curve proper).
    private var wcagLuminance: Double {
        let l = linear
        return Double(0.2126 * l.x + 0.7152 * l.y + 0.0722 * l.z)
    }
    /// True when black digits read better on this color than white ones: whichever has the higher WCAG contrast ratio, so
    /// the digits always reach at least 4.5:1 (an APCA-style preference for white on mid-tones left some oranges, greens
    /// and cyans at 3:1 while black would have given 7:1).
    var prefersDarkText: Bool {
        let w = wcagLuminance
        return (w + 0.05) / 0.05 >= 1.05 / (w + 0.05)
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
        let halo = color.contrastingHalo.opacity(0.7)
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
    /// The target was set by hand: marked with an extra ring in the accent color.
    var isManual = false

    var body: some View {
        ZStack {
            Circle().fill(color.swiftUIColor)
            Circle().strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5)
            BadgeNumber(number: number, color: color, size: max(9, diameter * 0.42))
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if isManual {
                Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: diameter + 7, height: diameter + 7)
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}
