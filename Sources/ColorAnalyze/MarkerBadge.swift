import ColorCore
import SwiftUI

extension SRGBColor {
    /// Drawn in Display P3, so colors outside the sRGB gamut show their real saturation on a wide-gamut display.
    var swiftUIColor: Color {
        let p3 = displayP3Components
        return Color(.displayP3, red: p3.r, green: p3.g, blue: p3.b)
    }
    /// OKLab lightness from which black digits read better than white ones with their dark halo.
    static let darkTextLightness: Float = 0.8
    /// True when black digits read better on this color than white ones: only on clearly light colors. On every mid-tone
    /// (browns, oranges, mid greens and blues, mid greys) white with a thin dark halo reads better, whatever WCAG 2's
    /// contrast ratio says (it favors black there, which looks muddy at the size of a marker number).
    var prefersDarkText: Bool { oklab.x >= Self.darkTextLightness }
    /// Black or white, whichever reads better on this color.
    var contrastingText: Color { prefersDarkText ? .black : .white }
}

/// A number readable on any fill: black digits plain, white digits with a thin dark halo. A light halo around black digits
/// blurs them on mid-tones (browns, oranges, mid greens), where black on its own is crisp.
struct BadgeNumber: View {
    let number: Int
    let color: SRGBColor
    let size: CGFloat

    var body: some View {
        let text = Text("\(number)").font(.system(size: size, weight: .heavy, design: .rounded))
        ZStack {
            if !color.prefersDarkText {
                let halo = Color.black.opacity(0.6)
                text.foregroundStyle(halo).offset(x: 0.7, y: 0)
                text.foregroundStyle(halo).offset(x: -0.7, y: 0)
                text.foregroundStyle(halo).offset(x: 0, y: 0.7)
                text.foregroundStyle(halo).offset(x: 0, y: -0.7)
            }
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
    /// A small, striking color found by the accent search: marked with a star.
    var isAccent = false

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
        .overlay(alignment: .topTrailing) {
            if isAccent {
                Image(systemName: "star.fill")
                    .font(.system(size: max(8, diameter * 0.4)))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .offset(x: diameter * 0.2, y: -diameter * 0.2)
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
