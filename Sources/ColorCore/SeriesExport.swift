import Foundation

/// The result of a series analysis in a form that can be written as JSON or CSV.
public struct SeriesExport: Codable, Sendable, Equatable {
    public struct Settings: Codable, Sendable, Equatable {
        public var colorsPerPhoto: Int
        public var paletteSize: Int
        /// "moderate" / "strong"; nil when subject weighting is off.
        public var weighting: String?

        public init(colorsPerPhoto: Int, paletteSize: Int, weighting: String? = nil) {
            self.colorsPerPhoto = colorsPerPhoto
            self.paletteSize = paletteSize
            self.weighting = weighting
        }
    }

    public struct PaletteColor: Codable, Sendable, Equatable {
        public var number: Int
        public var hex: String
        public var red: Int
        public var green: Int
        public var blue: Int
        /// HSL hue in degrees, saturation and lightness in percent.
        public var hue: Double
        public var saturation: Double
        public var lightness: Double
        public var lStar: Double
        /// Share of the series, in percent.
        public var sharePercent: Double
        /// Number of photos that contain a color close to this one.
        public var presence: Int
        public var photoCount: Int
        public var dxoChannel: String
        public var tonalRange: String
        /// Display P3 values (0–255) when the color lies outside sRGB (hex and RGB are then clipped).
        public var displayP3: [Int]?
    }

    public struct PhotoColor: Codable, Sendable, Equatable {
        public var hex: String
        public var sharePercent: Double
        /// Number of the matching palette color, nil when the photo's color has no counterpart.
        public var paletteNumber: Int?
    }

    public struct Photo: Codable, Sendable, Equatable {
        public var name: String
        public var path: String
        public var score: Int
        public var meanDeltaE: Double
        public var unmatchedPercent: Double
        /// Hue rotation (sRGB degrees) that moves the photo toward the palette; nil when not measurable.
        public var hueShift: Double?
        /// Saturation change in percent (+ = the photo is less saturated than the series); nil when the
        /// photo is too different from the series for a suggestion.
        public var saturationChangePercent: Double?
        /// Lightness change in CIE L* points (+ = the photo is darker than the series); nil like above.
        public var lightnessChange: Double?
        public var colors: [PhotoColor]
    }

    public var exportedAt: Date
    /// What the series should feel like; nil when empty.
    public var intention: String?
    public var settings: Settings
    public var palette: [PaletteColor]
    public var photos: [Photo]

    public init(exportedAt: Date = Date(), intention: String? = nil, settings: Settings, palette: [PaletteColor],
                photos: [Photo]) {
        self.exportedAt = exportedAt
        self.intention = Intention.cleaned(intention)
        self.settings = settings
        self.palette = palette
        self.photos = photos
    }

    /// Builds the export from analysis results. `photos` holds each photo's name, path and colors.
    public init(exportedAt: Date = Date(), intention: String? = nil, settings: Settings, palette: [SharedColor],
                photos: [(name: String, path: String, colors: [SeriesColor])]) {
        func round(_ v: Double, _ decimals: Int) -> Double {
            let f = pow(10, Double(decimals))
            let r = (v * f).rounded() / f
            return r == 0 ? 0 : r
        }
        let paletteColors = palette.enumerated().map { index, shared -> PaletteColor in
            let c = shared.color, rgb = c.rgb255, hsl = c.hsl
            return PaletteColor(number: index + 1, hex: c.hex, red: rgb.r, green: rgb.g, blue: rgb.b,
                                hue: round(hsl.h, 1), saturation: round(hsl.s * 100, 1),
                                lightness: round(hsl.l * 100, 1), lStar: round(c.lightness, 1),
                                sharePercent: round(shared.share * 100, 2), presence: shared.presence,
                                photoCount: shared.photoCount, dxoChannel: DxOMapping.channel(for: c).displayName,
                                tonalRange: DxOMapping.tonalRange(for: c).displayName,
                                displayP3: c.isOutsideSRGB ? { let p3 = c.displayP3RGB255; return [p3.r, p3.g, p3.b] }() : nil)
        }
        let items = photos.map { photo -> Photo in
            let consistency = SeriesAnalyzer.consistency(of: photo.colors, against: palette)
            let total = photo.colors.reduce(0) { $0 + $1.share }
            let colors = zip(photo.colors, consistency.matches).map { color, match in
                PhotoColor(hex: color.color.hex,
                           sharePercent: round(total > 0 ? color.share / total * 100 : 0, 2),
                           paletteNumber: match.map { $0 + 1 })
            }
            return Photo(name: photo.name, path: photo.path, score: consistency.score,
                         meanDeltaE: round(consistency.meanDeltaE, 4),
                         unmatchedPercent: round(consistency.unmatchedShare * 100, 1),
                         hueShift: consistency.hueShift.map { round($0, 1) },
                         saturationChangePercent: consistency.hasSuggestion ? round(consistency.saturationChange, 1) : nil,
                         lightnessChange: consistency.hasSuggestion ? round(consistency.lightnessChange, 1) : nil,
                         colors: colors)
        }
        self.init(exportedAt: exportedAt, intention: intention, settings: settings, palette: paletteColors, photos: items)
    }

    // MARK: JSON

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    // MARK: CSV

    /// One row per shared palette color.
    public func paletteCSV(style: ColorExport.CSVStyle = .standard) -> String {
        let n: (Double?) -> String = { ColorExport.num($0, decimalSeparator: style.decimalSeparator) }
        let includeP3 = palette.contains { $0.displayP3 != nil }
        var header = ["number", "hex", "red", "green", "blue", "hue", "saturation_pct", "lightness_pct", "cie_l",
                      "share_pct", "presence", "photo_count", "dxo_channel", "tonal_range"]
        if includeP3 { header += ["p3_red", "p3_green", "p3_blue"] }
        let rows = palette.map { c -> [String] in
            var row = [String(c.number), c.hex, String(c.red), String(c.green), String(c.blue), n(c.hue), n(c.saturation),
                       n(c.lightness), n(c.lStar), n(c.sharePercent), String(c.presence), String(c.photoCount),
                       c.dxoChannel, c.tonalRange]
            if includeP3 { row += c.displayP3.map { $0.map(String.init) } ?? ["", "", ""] }
            return row
        }
        return Self.csv([header] + rows, style: style)
    }

    /// One row per photo: consistency, the suggested alignment and the photo's own colors.
    public func photosCSV(style: ColorExport.CSVStyle = .standard) -> String {
        let n: (Double?) -> String = { ColorExport.num($0, decimalSeparator: style.decimalSeparator) }
        let header = ["name", "path", "score", "mean_delta_e", "unmatched_pct", "hue_shift",
                      "saturation_change_pct", "lightness_change", "colors"]
        let rows = photos.map { p in
            [p.name, p.path, String(p.score), n(p.meanDeltaE), n(p.unmatchedPercent), n(p.hueShift),
             n(p.saturationChangePercent), n(p.lightnessChange), p.colors.map(\.hex).joined(separator: " ")]
        }
        return Self.csv([header] + rows, style: style)
    }

    private static func csv(_ rows: [[String]], style: ColorExport.CSVStyle) -> String {
        rows.map { row in
            row.map { ColorExport.field($0, delimiter: style.delimiter) }.joined(separator: String(style.delimiter))
        }.joined(separator: "\r\n") + "\r\n"
    }
}
