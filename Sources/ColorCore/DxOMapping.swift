import Foundation

/// Channels of DxO PhotoLab's HSL tool (Color Wheel), plus `neutral` for colors
/// with too little chroma to be steered there.
public enum DxOChannel: String, CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, magenta, neutral

    public var displayName: String { rawValue.capitalized }

    /// The channel a hue turn of `degrees` moves this channel's colors toward: the next one in PhotoLab's order
    /// (red → orange → yellow → green → cyan → blue → purple → magenta → red) for a positive turn, the previous one for a
    /// negative one. nil for neutral or no turn.
    public func direction(of degrees: Double) -> DxOChannel? {
        let order: [DxOChannel] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .magenta]
        guard let i = order.firstIndex(of: self), degrees != 0 else { return nil }
        return order[(i + (degrees > 0 ? 1 : order.count - 1)) % order.count]
    }

    /// Approximate channel centers on the sRGB hue circle. DxO lets you widen or
    /// move the source range, so the exact hue is reported alongside.
    public var centerHue: Double? {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .cyan: 180
        case .blue: 240
        case .purple: 270
        case .magenta: 300
        case .neutral: nil
        }
    }
}

/// Tonal ranges of DxO PhotoLab's Color Grading tool.
public enum TonalRange: String, Sendable {
    case shadows, midtones, highlights

    public var displayName: String { rawValue.capitalized }
}

public enum DxOMapping {
    /// OKLab chroma below which a color is treated as neutral.
    public static let neutralChroma = 0.03

    /// The HSL channel of DxO PhotoLab the color falls in, using the slices stored in its sidecars
    /// (see `DxOHue`). Nearly grey colors are `.neutral`.
    public static func channel(for color: SRGBColor) -> DxOChannel {
        guard color.chroma >= neutralChroma else { return .neutral }
        guard let hue = DxOHue.hue(of: color) else { return .neutral }
        return DxOHue.channel(atDxOHue: hue)
    }

    public static func tonalRange(for color: SRGBColor) -> TonalRange {
        tonalRange(lightness: color.lightness)
    }

    public static func tonalRange(lightness: Double) -> TonalRange {
        switch lightness {
        case ..<33: .shadows
        case ..<66: .midtones
        default: .highlights
        }
    }

    /// Weight of a color in harmony detection: area × how chromatic it is.
    public static func harmonyWeight(color: SRGBColor, share: Double) -> Double {
        guard color.chroma >= neutralChroma else { return 0 }
        return share * min(1, color.chroma / 0.1)
    }
}
