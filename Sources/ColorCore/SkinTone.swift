import Foundation

/// Reference for skin tones on the hue wheel — the "skin tone line" of a vectorscope.
///
/// Human skin of every complexion sits in a narrow band of hues, orange-red to orange-yellow
/// (about 15°–35° on the sRGB hue circle), varying mostly in saturation and brightness.
/// Grading that pushes skin out of this band looks unnatural, so it is worth knowing which of the
/// dominant colors are skin-like and whether a grade moved them. These are approximations, not
/// a skin detector: a sand-colored wall or a wooden table can qualify too.
public enum SkinTone {
    /// Hue of the reference line, in sRGB degrees.
    public static let referenceHue = 25.0
    /// Degrees either side of the line that still read as skin.
    public static let hueTolerance = 12.0
    /// HSB saturation of skin-like colors: not grey, not fully saturated.
    public static let saturationRange: ClosedRange<Double> = 0.12...0.78
    /// HSB brightness below which a color is too dark to judge its hue.
    public static let minimumBrightness = 0.28

    public static var hueRange: ClosedRange<Double> {
        (referenceHue - hueTolerance)...(referenceHue + hueTolerance)
    }

    /// Signed hue distance in degrees from the line; positive is toward yellow, negative toward red.
    public static func offset(ofHue hue: Double) -> Double {
        ColorMath.signedAngle(from: referenceHue, to: hue)
    }

    public static func isSkinLike(_ color: SRGBColor) -> Bool {
        let hsb = color.hsb
        return abs(offset(ofHue: hsb.h)) <= hueTolerance
            && saturationRange.contains(hsb.s)
            && hsb.b >= minimumBrightness
    }

    /// Offset from the line for skin-like colors, nil for everything else.
    public static func offset(of color: SRGBColor) -> Double? {
        isSkinLike(color) ? offset(ofHue: color.hsb.h) : nil
    }

    /// What a grade did to a color with respect to the skin tone band.
    public enum Change: Equatable, Sendable {
        /// Skin-like before and after; `offset` is the hue offset of the graded color.
        case stays(offset: Double)
        /// Was skin-like, no longer is; `offset` is the hue offset of the graded color.
        case leaves(offset: Double)
        /// Was not skin-like, now is (e.g. a red wall pushed toward orange).
        case enters(offset: Double)
    }

    /// nil when neither color is skin-like.
    public static func change(from before: SRGBColor, to after: SRGBColor) -> Change? {
        let offset = offset(ofHue: after.hsb.h)
        switch (isSkinLike(before), isSkinLike(after)) {
        case (true, true): return .stays(offset: offset)
        case (true, false): return .leaves(offset: offset)
        case (false, true): return .enters(offset: offset)
        case (false, false): return nil
        }
    }

    /// "on the line", "+4° toward yellow", "-6° toward red".
    public static func describe(offset: Double) -> String {
        let degrees = Int(offset.rounded())
        guard abs(degrees) >= 2 else { return "on the line" }
        return "\(degrees > 0 ? "+" : "-")\(abs(degrees))° toward \(degrees > 0 ? "yellow" : "red")"
    }
}
