import CoreGraphics
import Foundation

/// One row of the color list, with the same values the app shows.
public struct ColorRecord: Codable, Sendable, Equatable {
    public struct After: Codable, Sendable, Equatable {
        public var hex: String
        public var red: Int
        public var green: Int
        public var blue: Int
        /// Change in hue in degrees (-180...180); nil when either color is neutral.
        public var hueChange: Double?
        /// Change in HSL saturation, in percentage points.
        public var saturationChange: Double
        /// Change in HSL lightness, in percentage points.
        public var lightnessChange: Double
        /// Change in CIE L*.
        public var lStarChange: Double
        /// Hue shift still needed to reach the harmony target; nil for neutral colors or without a harmony.
        public var harmonyShift: Double?
        /// Hue offset from the skin tone line in degrees (+ toward yellow); only for skin-like colors.
        public var skinToneOffset: Double?
    }

    public var number: Int
    public var hex: String
    public var red: Int
    public var green: Int
    public var blue: Int
    /// HSL hue in degrees, saturation and lightness in percent.
    public var hue: Double
    public var saturation: Double
    public var lightness: Double
    /// CIE L* (0...100).
    public var lStar: Double
    /// Share of the photo closest to this color, in percent. With subject weighting on, pixels
    /// count by weight, so this is the share of the *weighted* photo.
    public var coveragePercent: Double
    /// Plain pixel share in percent; only present when subject weighting is on.
    public var areaPercent: Double?
    /// Marker position, normalized (0...1) with a top-left origin.
    public var x: Double
    public var y: Double
    /// DxO PhotoLab HSL channel ("Red", "Orange", … or "Neutral").
    public var dxoChannel: String
    /// DxO Color Grading range ("Shadows", "Midtones", "Highlights").
    public var tonalRange: String
    /// Hue of the nearest harmony target; nil for neutral colors or without a harmony.
    public var harmonyTargetHue: Double?
    /// Signed hue shift in degrees that moves this color onto the target.
    public var harmonyShift: Double?
    /// Hue offset from the skin tone line in degrees (+ toward yellow); only for skin-like colors.
    public var skinToneOffset: Double?
    /// Display P3 values (0–255) of a color outside the sRGB gamut, whose `hex` and `red`/`green`/`blue`
    /// are clipped to sRGB; nil for colors inside sRGB.
    public var displayP3: [Int]?
    public var after: After?

    /// Builds a record from a marker. `after` is the color at the same position in the graded version.
    public init(number: Int, location: CGPoint, color: SRGBColor, share: Double, areaShare: Double? = nil,
                after: SRGBColor? = nil, harmony: HarmonyFit? = nil) {
        let rgb = color.rgb255, hsl = color.hsl
        let channel = DxOMapping.channel(for: color)
        let shift = (channel == .neutral) ? nil : harmony?.shift(for: color.hsb.h)

        self.number = number
        hex = color.hex
        red = rgb.r
        green = rgb.g
        blue = rgb.b
        hue = Self.round(hsl.h, 1)
        saturation = Self.round(hsl.s * 100, 1)
        lightness = Self.round(hsl.l * 100, 1)
        lStar = Self.round(color.lightness, 1)
        coveragePercent = Self.round(share * 100, 2)
        areaPercent = areaShare.map { Self.round($0 * 100, 2) }
        x = Self.round(Double(location.x), 4)
        y = Self.round(Double(location.y), 4)
        dxoChannel = channel.displayName
        tonalRange = DxOMapping.tonalRange(for: color).displayName
        harmonyShift = shift.map { Self.round($0, 1) }
        harmonyTargetHue = shift.map { Self.round(ColorMath.normalizeDegrees(color.hsb.h + $0), 1) }
        skinToneOffset = SkinTone.offset(of: color).map { Self.round($0, 1) }
        displayP3 = color.isOutsideSRGB ? { let p3 = color.displayP3RGB255; return [p3.r, p3.g, p3.b] }() : nil

        self.after = after.map { after in
            let a = after.hsl, a255 = after.rgb255
            let chromatic = color.chroma >= DxOMapping.neutralChroma && after.chroma >= DxOMapping.neutralChroma
            return After(
                hex: after.hex, red: a255.r, green: a255.g, blue: a255.b,
                hueChange: chromatic ? Self.round(ColorMath.signedAngle(from: hsl.h, to: a.h), 1) : nil,
                saturationChange: Self.round((a.s - hsl.s) * 100, 1),
                lightnessChange: Self.round((a.l - hsl.l) * 100, 1),
                lStarChange: Self.round(after.lightness - color.lightness, 1),
                harmonyShift: chromatic ? harmony.map { Self.round($0.shift(for: after.hsb.h), 1) } : nil,
                skinToneOffset: SkinTone.offset(of: after).map { Self.round($0, 1) }
            )
        }
    }

    private static func round(_ value: Double, _ decimals: Int) -> Double {
        let f = pow(10, Double(decimals))
        let r = (value * f).rounded() / f
        return r == 0 ? 0 : r // no "-0"
    }
}

/// The color list plus the context needed to interpret it, ready to write as CSV or JSON.
public struct ColorExport: Codable, Sendable, Equatable {
    public struct Harmony: Codable, Sendable, Equatable {
        public var kind: String
        public var autoDetected: Bool
        /// Wheel the harmony was computed on: "rgb" (DxO's wheel) or "ryb" (artist's wheel).
        public var hueSpace: String
        /// Position of the first target on that wheel, in degrees.
        public var rotation: Double
        /// Target hues as sRGB hues (degrees), whichever wheel was used.
        public var targetHues: [Double]
        /// Weighted RMS hue distance of the colors to their targets, in degrees.
        public var fit: Double
        /// Same measure for the graded version.
        public var fitAfter: Double?

        public init(fit: HarmonyFit, autoDetected: Bool, fitAfter: HarmonyFit?) {
            kind = fit.kind.displayName
            self.autoDetected = autoDetected
            hueSpace = fit.space.rawValue
            rotation = fit.rotation
            targetHues = fit.targetRGBHues.map { ($0 * 10).rounded() / 10 }
            self.fit = (fit.deviation * 10).rounded() / 10
            self.fitAfter = fitAfter.map { ($0.deviation * 10).rounded() / 10 }
        }
    }

    public var photo: String
    public var graded: String?
    public var exportedAt: Date
    /// Subject weighting used for `coveragePercent` ("moderate", "strong"); nil when off.
    public var weighting: String?
    /// What the photo should feel like, as noted before choosing a harmony; nil when empty.
    public var intention: String?
    public var harmony: Harmony?
    public var colors: [ColorRecord]

    public init(photo: String, graded: String? = nil, exportedAt: Date = Date(), weighting: String? = nil,
                intention: String? = nil, harmony: Harmony? = nil, colors: [ColorRecord]) {
        self.photo = photo
        self.graded = graded
        self.exportedAt = exportedAt
        self.weighting = weighting
        self.intention = Intention.cleaned(intention)
        self.harmony = harmony
        self.colors = colors
    }

    // MARK: JSON

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    // MARK: CSV

    public enum CSVStyle: Sendable {
        /// Comma separator, `.` decimals — what most tools and Excel with an English locale expect.
        case standard
        /// Semicolon separator, `,` decimals — what Excel expects with a Dutch (or other continental European) locale.
        case europeanExcel

        var delimiter: Character { self == .standard ? "," : ";" }
        var decimalSeparator: String { self == .standard ? "." : "," }
    }

    /// One header row and one row per color, CRLF line ends, RFC 4180 quoting.
    /// The `after_*` columns are only present when a graded version was compared, and
    /// `area_pct` (plain pixel share) only when subject weighting is on, and the `*skin_tone_offset`
    /// columns only when some color is skin-like, and `p3_*` (Display P3 values) only when some color
    /// lies outside the sRGB gamut.
    public func csv(style: CSVStyle = .standard) -> String {
        let includeAfter = colors.contains { $0.after != nil }
        let includeArea = colors.contains { $0.areaPercent != nil }
        let includeSkin = colors.contains { $0.skinToneOffset != nil || $0.after?.skinToneOffset != nil }
        let includeP3 = colors.contains { $0.displayP3 != nil }
        let areaColumn = 10 // right after coverage_pct
        let n: (Double?) -> String = { Self.num($0, decimalSeparator: style.decimalSeparator) }
        var header = ["number", "hex", "red", "green", "blue", "hue", "saturation_pct", "lightness_pct",
                      "cie_l", "coverage_pct", "x", "y", "dxo_channel", "tonal_range",
                      "harmony_target_hue", "harmony_shift"]
        if includeArea { header.insert("area_pct", at: areaColumn) }
        if includeSkin { header.append("skin_tone_offset") }
        if includeP3 { header += ["p3_red", "p3_green", "p3_blue"] }
        if includeAfter {
            header += ["after_hex", "after_red", "after_green", "after_blue", "delta_hue",
                       "delta_saturation_pct", "delta_lightness_pct", "delta_cie_l", "after_harmony_shift"]
            if includeSkin { header.append("after_skin_tone_offset") }
        }
        let line: ([String]) -> String = { row in
            row.map { Self.field($0, delimiter: style.delimiter) }.joined(separator: String(style.delimiter))
        }
        var lines = [line(header)]
        for c in colors {
            var row = [String(c.number), c.hex, String(c.red), String(c.green), String(c.blue),
                       n(c.hue), n(c.saturation), n(c.lightness), n(c.lStar),
                       n(c.coveragePercent), n(c.x), n(c.y), c.dxoChannel, c.tonalRange,
                       n(c.harmonyTargetHue), n(c.harmonyShift)]
            if includeArea { row.insert(n(c.areaPercent), at: areaColumn) }
            if includeSkin { row.append(n(c.skinToneOffset)) }
            if includeP3 { row += c.displayP3.map { $0.map(String.init) } ?? ["", "", ""] }
            if includeAfter {
                if let a = c.after {
                    row += [a.hex, String(a.red), String(a.green), String(a.blue), n(a.hueChange),
                            n(a.saturationChange), n(a.lightnessChange), n(a.lStarChange),
                            n(a.harmonyShift)]
                    if includeSkin { row.append(n(a.skinToneOffset)) }
                } else {
                    row += Array(repeating: "", count: includeSkin ? 10 : 9)
                }
            }
            lines.append(line(row))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Shortest form with the given decimal separator regardless of the user's locale; empty for nil.
    static func num(_ value: Double?, decimalSeparator: String = ".") -> String {
        guard let value else { return "" }
        var s = String(format: "%.4f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return decimalSeparator == "." ? s : s.replacingOccurrences(of: ".", with: decimalSeparator)
    }

    static func field(_ value: String, delimiter: Character = ",") -> String {
        guard value.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
