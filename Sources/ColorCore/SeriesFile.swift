import Foundation

/// A saved series: which photos belong to it and how it was analyzed. Colors are not stored — they
/// are derived again when the series is opened, so they always match the current analysis.
public struct SeriesFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let defaultFileName = "Series.coloranalyze-series.json"

    public struct Photo: Codable, Sendable, Equatable {
        /// Absolute path when the series was saved.
        public var path: String
        /// Path relative to the folder of the series file, so a moved folder keeps working.
        public var relativePath: String?

        public init(path: String, relativePath: String? = nil) {
            self.path = path
            self.relativePath = relativePath
        }
    }

    public var version = SeriesFile.currentVersion
    public var savedAt: Date
    public var colorsPerPhoto: Int
    public var paletteSize: Int
    /// Subject weighting ("moderate", "strong"); nil = off.
    public var weighting: String?
    /// `HueSpace` raw value of the wheel; nil = RGB.
    public var hueSpace: String?
    public var sortByScore: Bool?
    /// What the series should feel like.
    public var intention: String?
    public var photos: [Photo]

    public init(savedAt: Date = Date(), colorsPerPhoto: Int, paletteSize: Int, weighting: String? = nil,
                hueSpace: String? = nil, sortByScore: Bool? = nil, intention: String? = nil, photos: [Photo]) {
        self.savedAt = savedAt
        self.colorsPerPhoto = colorsPerPhoto
        self.paletteSize = paletteSize
        self.weighting = weighting
        self.hueSpace = hueSpace
        self.sortByScore = sortByScore
        self.intention = Intention.cleaned(intention)
        self.photos = photos
    }

    public enum FileError: LocalizedError {
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .newerVersion(let v):
                "The series was saved by a newer version of ColorAnalyze (format \(v))."
            }
        }
    }

    /// Builds the photo list for a series file saved in `folder`.
    public static func photos(_ urls: [URL], savedIn folder: URL) -> [Photo] {
        urls.map { Photo(path: $0.path, relativePath: relativePath(of: $0, from: folder)) }
    }

    /// `/a/b/c/x.jpg` from `/a/b` → `c/x.jpg`; from `/a/d` → `../b/c/x.jpg`.
    public static func relativePath(of file: URL, from folder: URL) -> String {
        let f = file.standardizedFileURL.pathComponents
        let d = folder.standardizedFileURL.pathComponents
        var common = 0
        while common < d.count, common < f.count - 1, f[common] == d[common] { common += 1 }
        return (Array(repeating: "..", count: d.count - common) + f[common...]).joined(separator: "/")
    }

    /// Finds every photo: at its saved path, then relative to the series file, then by name next to it.
    public func resolvedPhotos(folder: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) })
        -> (found: [URL], missing: [String]) {
        var found: [URL] = []
        var missing: [String] = []
        for photo in photos {
            let absolute = URL(fileURLWithPath: photo.path)
            var candidates = [absolute]
            if let relative = photo.relativePath {
                candidates.append(folder.appendingPathComponent(relative).standardizedFileURL)
            }
            candidates.append(folder.appendingPathComponent(absolute.lastPathComponent))
            if let url = candidates.first(where: fileExists) {
                found.append(url)
            } else {
                missing.append(absolute.lastPathComponent)
            }
        }
        return (found, missing)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> SeriesFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(SeriesFile.self, from: Data(contentsOf: url))
        guard file.version <= currentVersion else { throw FileError.newerVersion(file.version) }
        return file
    }
}
