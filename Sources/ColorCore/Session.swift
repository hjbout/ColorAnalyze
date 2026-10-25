import Foundation

/// Everything needed to restore an analysis: marker positions, harmony choice and the
/// graded version. Stored as JSON next to the photo (`IMG_0001.CR3.coloranalyze.json`),
/// so it travels with the photo and survives re-opening it.
public struct Session: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let fileExtension = "coloranalyze.json"

    public struct Marker: Codable, Sendable, Equatable {
        /// Normalized position in the photo, top-left origin.
        public var x: Double
        public var y: Double
        /// Color at save time. Informational: colors are re-sampled from the photo on restore.
        public var hex: String
        /// True for a color the grading suggestions should leave alone; nil (absent) = not protected.
        public var isProtected: Bool?
        /// sRGB hue the color was aimed at by hand; nil = the automatic target.
        public var targetHue: Double?
        /// Number (0-based) of the reference palette color chosen by hand for this color; nil = the nearest one.
        public var referenceIndex: Int?
        /// Radius the color is averaged over, as a fraction of the photo's short side; nil = the default.
        public var sampleRadius: Double?

        public init(x: Double, y: Double, hex: String, isProtected: Bool? = nil, targetHue: Double? = nil,
                    referenceIndex: Int? = nil, sampleRadius: Double? = nil) {
            self.sampleRadius = sampleRadius
            self.targetHue = targetHue
            self.referenceIndex = referenceIndex
            self.x = x
            self.y = y
            self.hex = hex
            self.isProtected = isProtected
        }
    }

    /// A pinned grading setup to come back to and compare: the choices that steer the suggestion.
    public struct Variant: Codable, Sendable, Equatable {
        /// `GradingStyle` raw value.
        public var style: String
        public var amount: Double
        /// `GradingTarget` raw value ("harmony", "series", "emphasize").
        public var target: String
        /// `HarmonyKind` raw value; nil = auto-detect.
        public var harmony: String?
        /// Rotation of the harmony on the wheel, when it was turned by hand.
        public var harmonyRotation: Double?
        /// Predicted hue distance of the colors to their targets, before and after, when the variant was pinned.
        public var fitBefore: Double?
        public var fitAfter: Double?

        public init(style: String, amount: Double, target: String, harmony: String? = nil, harmonyRotation: Double? = nil,
                    fitBefore: Double? = nil, fitAfter: Double? = nil) {
            self.style = style
            self.amount = amount
            self.target = target
            self.harmony = harmony
            self.harmonyRotation = harmonyRotation
            self.fitBefore = fitBefore
            self.fitAfter = fitAfter
        }
    }

    public var version = Session.currentVersion
    public var savedAt: Date
    /// File name of the photo, as a sanity check.
    public var photo: String
    /// Absolute path of the graded version, if one was loaded.
    public var graded: String?
    public var colorCount: Int
    /// Subject weighting ("moderate", "strong"); nil = off.
    public var weighting: String?
    public var markers: [Marker]
    /// `HarmonyKind` raw value; nil = auto-detect.
    public var harmony: String?
    /// Rotation of the harmony on the wheel named by `hueSpace`.
    public var harmonyRotation: Double?
    /// `HueSpace` raw value of the wheel the harmony is computed on; nil = RGB.
    public var hueSpace: String?
    public var compareMode: String?
    public var splitPosition: Double?
    /// What the photo should feel like, written down before choosing a harmony.
    public var intention: String?
    /// Absolute path of the reference photo whose palette the photo is aimed at, if one was loaded.
    public var reference: String?
    /// Pinned grading variants, in the order they were pinned; nil = none.
    public var variants: [Variant]?

    public init(savedAt: Date = Date(), photo: String, graded: String? = nil, colorCount: Int,
                weighting: String? = nil, markers: [Marker], harmony: String? = nil, harmonyRotation: Double? = nil,
                hueSpace: String? = nil, compareMode: String? = nil, splitPosition: Double? = nil,
                intention: String? = nil, reference: String? = nil, variants: [Variant]? = nil) {
        self.savedAt = savedAt
        self.photo = photo
        self.graded = graded
        self.colorCount = colorCount
        self.weighting = weighting
        self.markers = markers
        self.harmony = harmony
        self.harmonyRotation = harmonyRotation
        self.hueSpace = hueSpace
        self.compareMode = compareMode
        self.splitPosition = splitPosition
        self.intention = Intention.cleaned(intention)
        self.reference = reference
        self.variants = variants
    }

    public enum SessionError: LocalizedError {
        case newerVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .newerVersion(let v):
                "The saved session was made by a newer version of ColorAnalyze (format \(v))."
            }
        }
    }

    /// `photo.heic` → `photo.heic.coloranalyze.json` in the same folder.
    public static func sidecarURL(for photo: URL) -> URL {
        photo.appendingPathExtension(fileExtension)
    }

    /// Where to look for the graded file: the saved path, then the photo's folder.
    public func gradedURL(photoFolder: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        Self.resolve(graded, photoFolder: photoFolder, fileExists: fileExists)
    }

    /// Where to look for the reference photo: the saved path, then the photo's folder.
    public func referenceURL(photoFolder: URL, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL? {
        Self.resolve(reference, photoFolder: photoFolder, fileExists: fileExists)
    }

    private static func resolve(_ path: String?, photoFolder: URL, fileExists: (URL) -> Bool) -> URL? {
        guard let path else { return nil }
        let saved = URL(fileURLWithPath: path)
        if fileExists(saved) { return saved }
        let sibling = photoFolder.appendingPathComponent(saved.lastPathComponent)
        return fileExists(sibling) ? sibling : nil
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Session {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(Session.self, from: Data(contentsOf: url))
        guard session.version <= currentVersion else { throw SessionError.newerVersion(session.version) }
        return session
    }
}
