import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

struct Marker: Identifiable, Equatable {
    let id = UUID()
    /// Normalized position in the photo, top-left origin.
    var location: CGPoint
    var color: SRGBColor
    /// Share of the photo closest to this color. With subject weighting on, pixels count by weight.
    var share: Double = 0
    /// Plain pixel share, without weighting.
    var areaShare: Double = 0
    /// Set by hand: true = leave this color as it is (the grading suggestions aim it at its own hue instead of at the
    /// harmony), false = never protect it; nil = decided automatically (skin tones, when that is switched on).
    var protection: Bool?
}

/// How much more the subject of the photo counts than the background.
/// Width of the sector around each harmony target (Matsuda): colors inside it need no shift.
enum HarmonySector: String, CaseIterable, Identifiable {
    case exact, narrow, wide

    var id: String { rawValue }
    var title: String {
        switch self {
        case .exact: "Exact hue"
        case .narrow: "Sector ±10°"
        case .wide: "Sector ±20°"
        }
    }
    /// Half-width in degrees.
    var tolerance: Double {
        switch self {
        case .exact: 0
        case .narrow: 10
        case .wide: 20
        }
    }
}

enum Weighting: String, CaseIterable, Identifiable {
    case off, moderate, strong

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Weight of the most salient pixel is `1 + strength`; the background stays near 1.
    var strength: Float {
        switch self {
        case .off: 0
        case .moderate: 4
        case .strong: 12
        }
    }
}

enum ExportFormat {
    case reportPNG, colorsCSV, colorsCSVExcel, colorsJSON, dxoPreset, swatches, palettePNG

    var contentType: UTType {
        switch self {
        case .reportPNG: .png
        case .colorsCSV, .colorsCSVExcel: .commaSeparatedText
        case .colorsJSON: .json
        case .dxoPreset: UTType(filenameExtension: ColorGradingPreset.fileExtension) ?? .data
        case .swatches: UTType(filenameExtension: AdobeSwatchExchange.fileExtension) ?? .data
        case .palettePNG: .png
        }
    }

    /// Appended to the photo's name in the save dialog.
    var fileNameSuffix: String {
        switch self {
        case .colorsCSVExcel: " colors (Excel)"
        case .dxoPreset: " – ColorAnalyze"
        case .swatches, .palettePNG: " palette"
        default: " colors"
        }
    }

    var fileExtension: String {
        switch self {
        case .reportPNG: "png"
        case .colorsCSV, .colorsCSVExcel: "csv"
        case .colorsJSON: "json"
        case .dxoPreset: ColorGradingPreset.fileExtension
        case .swatches: AdobeSwatchExchange.fileExtension
        case .palettePNG: "png"
        }
    }

    var shortName: String {
        switch self {
        case .reportPNG: "the report"
        case .colorsCSV: "the color list as CSV"
        case .colorsCSVExcel: "the color list as CSV for Excel"
        case .colorsJSON: "the color list as JSON"
        case .dxoPreset: "the DxO Color Grading preset"
        case .swatches: "the palette as swatches"
        case .palettePNG: "the palette image"
        }
    }

    var panelMessage: String {
        switch self {
        case .reportPNG: "Export a PNG report with the photo, color wheel and color list"
        case .colorsCSV: "Export the color list as CSV (comma separated, one row per color)"
        case .colorsCSVExcel: "Export the color list as CSV for Excel with a Dutch locale (semicolon separated, decimal comma)"
        case .colorsJSON: "Export the color list as JSON, including the harmony"
        case .dxoPreset: "Save a DxO PhotoLab Color Grading preset. In PhotoLab's Color Grading presets folder it shows up in the preset list."
        case .swatches: "Export the colors as an Adobe Swatch Exchange file (.ase) for Photoshop, Illustrator, Affinity and others"
        case .palettePNG: "Export the palette as an image: a bar as wide as each color's share, and a card per color"
        }
    }

    /// Colors go to CSV or JSON depending on the file extension (used by the command line).
    static func forColorList(at url: URL) -> ExportFormat {
        switch url.pathExtension.lowercased() {
        case "json": .colorsJSON
        case AdobeSwatchExchange.fileExtension: .swatches
        case "png": .palettePNG
        default: .colorsCSV
        }
    }
}

/// How one color of the current photo relates to the series palette.
enum SeriesRowInfo {
    case match(SeriesMatch, paletteHex: String)
    case unmatched
}

enum CompareMode: String, CaseIterable, Identifiable {
    case before = "Before"
    case split = "Split"
    case after = "After"

    var id: String { rawValue }
}

@Observable @MainActor
final class AnalysisModel {
    var image: LoadedImage?
    var isAnalyzing = false
    var errorMessage: String?

    var markers: [Marker] = []
    var selectedMarkerID: Marker.ID? {
        didSet { if selectedMarkerID != oldValue { refreshRegion() } }
    }

    /// Ends text editing (the intention field keeps the keyboard otherwise), so arrow keys can nudge the
    /// selected marker. Called when the user picks or drags a marker.
    func releaseKeyboardFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    /// Marker under the pointer in any pane; takes precedence over the selection for the region overlay.
    var hoveredMarkerID: Marker.ID? {
        didSet { if hoveredMarkerID != oldValue { refreshRegion() } }
    }


    // MARK: State of the extensions (stored properties cannot live in an extension)

    /// How strongly the suggested tints are applied (the saturation of a wheel whose colors are 30° or more off).
    var gradingStrength = ColorGradingSuggestion.Strength(rawValue: UserDefaults.standard.string(forKey: "gradingStrength") ?? "")
        ?? .moderate {
        didSet { if rememberGradingStrength { UserDefaults.standard.set(gradingStrength.rawValue, forKey: "gradingStrength") } }
    }

    @ObservationIgnored var rememberGradingStrength = true

    /// A creative direction on top of the harmony: warm highlights over cool shadows, or the reverse. Remembered.
    var gradingStyle = (AnalysisModel.remembered("gradingStyle") as String?).flatMap(GradingStyle.init(rawValue:)) ?? .neutral {
        didSet { if gradingStyle != oldValue { remember(gradingStyle.rawValue, as: "gradingStyle") } }
    }

    var gradingTarget = GradingTarget.harmony

    @ObservationIgnored var gradingCache: (key: Int, grading: ColorGradingSuggestion.Suggestion?)?

    @ObservationIgnored var predictionCache: (key: Int, settings: GradePreviewSettings?, plan: GradePreview.Plan?)?

    @ObservationIgnored var whiteBalanceCache: (key: String, check: WhiteBalanceCheck)?

    /// Overrides the series palette while it is set. Stays when another photo is opened, so one reference can
    /// serve a whole batch; it is not part of the saved session.
    var referencePhoto: ReferencePhoto?

    /// Shows the photo with the suggested Color Grading tints and HSL hue turns applied (right of the divider).
    var showPreview = AnalysisModel.remembered("showPreview") ?? false {
        didSet {
            if showPreview != oldValue { remember(showPreview, as: "showPreview"); refreshPreview() }
        }
    }

    var previewLayout = (AnalysisModel.remembered("previewLayout") as String?).flatMap(PreviewLayout.init(rawValue:)) ?? .split {
        didSet { if previewLayout != oldValue { remember(previewLayout.rawValue, as: "previewLayout") } }
    }

    /// 1 = as suggested; 2 and 4 exaggerate, because a suggestion of a few points is hard to see.
    var previewAmount = AnalysisModel.remembered("previewAmount") ?? 1.0 {
        didSet { if previewAmount != oldValue { remember(previewAmount, as: "previewAmount"); refreshPreview() } }
    }

    var previewImage: CGImage?

    @ObservationIgnored var previewTask: Task<Void, Never>?

    @ObservationIgnored var previewGeneration = 0

    /// The window's undo manager (Edit ▸ Undo / Redo, ⌘Z / ⇧⌘Z); handed over by the main view.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 200 }
    }

    /// Marker state at the start of the current drag, recorded as one undo step once the marker really moves.
    @ObservationIgnored var pendingMoveUndo: (name: String, state: MarkerState)?

    /// Last arrow-key nudge: keys pressed one after the other on the same marker are one undo step.
    @ObservationIgnored var lastNudge: (id: Marker.ID, time: Date)?

    /// Skin-like colors are protected by themselves when this is on, unless protection was set by hand. Remembered.
    var protectSkin = AnalysisModel.remembered("protectSkin") ?? true {
        didSet {
            if protectSkin != oldValue { remember(protectSkin, as: "protectSkin"); isDirty = true; refreshPreview() }
        }
    }

    // MARK: Remembered settings
    //
    // Colors, wheel, subject weighting, skin tone line, Color Grading strength and preview are remembered between launches
    // (UserDefaults). A saved session of a photo overrides them for that photo, and a setting given on the command line
    // applies to that run only: neither changes what is remembered.

    @ObservationIgnored var suppressRemembering = 0
    /// Runs `body` with changes to the settings not remembered.
    func withoutRemembering(_ body: () -> Void) {
        suppressRemembering += 1
        body()
        suppressRemembering -= 1
    }
    func remember(_ value: Any, as key: String) {
        if suppressRemembering == 0 { UserDefaults.standard.set(value, forKey: "setting." + key) }
    }
    static func remembered<T>(_ key: String) -> T? { UserDefaults.standard.object(forKey: "setting." + key) as? T }

    var colorCount = AnalysisModel.remembered("colorCount").map { min(12, max(3, $0)) } ?? 6 {
        didSet {
            if colorCount != oldValue { remember(colorCount, as: "colorCount") }
            if colorCount != oldValue, !isRestoring { analyze() }
        }
    }

    /// nil = detect automatically.
    var harmonyChoice: HarmonyKind? {
        didSet {
            harmonyRotationOverride = nil
            isDirty = true
        }
    }
    /// The wheel the harmony is computed and drawn on: RGB or the artist's RYB wheel.
    /// How wide the harmony's targets are: a color inside the sector counts as on target. Remembered.
    var harmonySector = (AnalysisModel.remembered("harmonySector") as String?).flatMap(HarmonySector.init(rawValue:)) ?? .narrow {
        didSet { if harmonySector != oldValue { remember(harmonySector.rawValue, as: "harmonySector") } }
    }

    var hueSpace = (AnalysisModel.remembered("hueSpace") as String?).flatMap(HueSpace.init(rawValue:)) ?? .rgb {
        didSet {
            if hueSpace != oldValue {
                remember(hueSpace.rawValue, as: "hueSpace")
                harmonyRotationOverride = nil // a rotation only makes sense on the wheel it was set on
                isDirty = true
            }
        }
    }
    /// Set when the user rotates the overlay on the wheel.
    var harmonyRotationOverride: Double? {
        didSet { isDirty = true }
    }

    /// Lets the subject of the photo count more than the background when finding colors,
    /// computing shares and placing markers. Changing it re-analyzes the photo.
    var weighting = (AnalysisModel.remembered("weighting") as String?).flatMap(Weighting.init(rawValue:)) ?? .off {
        didSet {
            if weighting != oldValue { remember(weighting.rawValue, as: "weighting") }
            if weighting != oldValue, !isRestoring { analyze() }
        }
    }
    /// The series window's model; its shared palette is shown as a reference on the wheel.
    @ObservationIgnored weak var series: SeriesModel?
    /// Shows the series palette on the wheel and compares the colors with it. A view preference.
    var showSeriesReference = UserDefaults.standard.object(forKey: "showSeriesPalette") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSeriesReference, forKey: "showSeriesPalette") }
    }

    /// Draws the skin tone line and band on the wheel. A view preference, remembered between launches.
    var showSkinTone = UserDefaults.standard.object(forKey: "showSkinToneLine") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showSkinTone, forKey: "showSkinToneLine") }
    }
    /// Darkens everything but the detected subject, to show what the weighting is based on.
    var showSaliency = false {
        didSet { if showSaliency != oldValue { refreshSaliencyOverlay() } }
    }
    var saliencyOverlay: CGImage?
    /// True when the current shares and markers were computed with subject weights.
    var isWeighted = false
    @ObservationIgnored var weights: [Float]?
    @ObservationIgnored var saliency: [Float]?
    @ObservationIgnored var saliencyFailed = false

    /// What the photo should feel like, written down before choosing a harmony. Saved in the session.
    var intention = "" {
        didSet { if intention != oldValue { isDirty = true } }
    }

    /// True when the markers, harmony or comparison differ from what is saved next to the photo.
    var isDirty = false
    /// Short status message ("Saved …"), cleared after a few seconds.
    var notice: String?
    @ObservationIgnored var isRestoring = false

    // MARK: Zoom

    /// Zoom and pan of the photo in its pane. Reset when another photo is opened.
    var viewport = PhotoViewport()
    /// Pan offset when the current background drag started (view state).
    @ObservationIgnored var panStart: CGSize?
    /// Zoom at which one image pixel is one point on screen; kept up to date by the photo pane.
    @ObservationIgnored var actualPixelsZoom: CGFloat = 1

    func zoomIn() { viewport.zoom(by: PhotoViewport.step) }
    func zoomOut() { viewport.zoom(by: 1 / PhotoViewport.step) }
    func fitPhoto() { viewport.fit() }
    func zoomToActualPixels() { viewport.setZoom(actualPixelsZoom) }
    func setZoomLevel(_ zoom: CGFloat) { viewport.setZoom(zoom) }

    /// "Fit", "2×", "7.5×"
    var zoomLabel: String {
        viewport.isZoomed ? String(format: viewport.zoom >= 10 || viewport.zoom.rounded() == viewport.zoom ? "%.0f×" : "%.1f×", viewport.zoom) : "Fit"
    }

    /// Marker location when the current drag started (view state; SwiftUI's @State
    /// is a macro that the Command Line Tools cannot expand).
    @ObservationIgnored var dragStart: CGPoint?

    /// Selected color when the mouse last went down in the color list (view state, see `dragStart`).
    @ObservationIgnored var selectionAtMouseDown: Marker.ID?

    /// Marker sample radius as a fraction of the photo's short side.
    let sampleRadius = 0.015

    // MARK: Region overlay

    var showRegions = true {
        didSet { if showRegions != oldValue { refreshRegion() } }
    }
    /// Dims everything except the pixels that belong to the hovered/selected marker's color.
    var regionOverlay: CGImage?
    /// Share of the photo covered by the highlighted region (0...1).
    var regionCoverage: Double?
    /// Same region as a share of the subject-weighted photo; nil when weighting is off.
    var regionWeightedShare: Double?

    var highlightedMarkerID: Marker.ID? { hoveredMarkerID ?? selectedMarkerID }

    /// Pointer entered or left a marker or list row.
    func hover(_ id: Marker.ID, inside: Bool) {
        if inside {
            hoveredMarkerID = id
        } else if hoveredMarkerID == id {
            hoveredMarkerID = nil
        }
    }

    // MARK: Before / after

    /// A graded version of the same photo (e.g. a DxO export), sampled at the marker positions.
    var afterImage: LoadedImage?
    var compareMode = CompareMode.split
    /// Position of the split divider, 0...1 across the photo.
    var splitPosition = 0.5

    /// True when the graded version is cropped or framed differently, so marker positions
    /// no longer point at the same content.
    var afterAspectMismatch: Bool {
        guard let image, let afterImage else { return false }
        let a = Double(image.display.width) / Double(image.display.height)
        let b = Double(afterImage.display.width) / Double(afterImage.display.height)
        return abs(a - b) / a > 0.01
    }

    /// Color of the graded version at the marker's position.
    func afterColor(for marker: Marker) -> SRGBColor? {
        if let afterImage { return afterImage.sampling.sample(at: marker.location, radius: sampleRadius) }
        return predictedColor(for: marker)
    }

    /// Color the marker should show given the photo currently on screen.
    func displayColor(for marker: Marker) -> SRGBColor {
        compareMode == .after ? (afterColor(for: marker) ?? marker.color) : marker.color
    }

    // MARK: Loading & analysis

    func presentOpenPanel(graded: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = graded ? "Choose the graded version of this photo (same framing)" : "Choose a photo to analyze"
        if panel.runModal() == .OK, let url = panel.url {
            if graded {
                openGraded(url)
            } else {
                open(url)
            }
        }
    }

    /// Opens a photo and restores its saved session if there is one, otherwise analyzes it.
    /// `graded` takes precedence over the graded version stored in a session.
    /// The returned task finishes when loading, analysis and restore are done.
    @discardableResult
    func open(_ url: URL, graded: URL? = nil, weighting weightingOverride: Weighting? = nil) -> Task<Void, Never> {
        isAnalyzing = true
        return Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try ImageLoader.load(url: url)
                }.value
                image = loaded
                undoManager?.removeAllActions(withTarget: self)
                afterImage = nil
                intention = ""
                viewport.fit()
                saliency = nil
                saliencyFailed = false
                saliencyOverlay = nil
                setWeights(nil)
                compareMode = .split
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                if showSaliency { refreshSaliencyOverlay() }
                if let session = savedSession(for: url) {
                    await restore(session, photo: url, graded: graded)
                    if let weightingOverride, weightingOverride != weighting {
                        setWeighting(weightingOverride)
                        await runAnalysis(markDirty: true)
                    }
                } else {
                    if let weightingOverride { setWeighting(weightingOverride) }
                    await runAnalysis(markDirty: false)
                    if let graded { await loadGraded(graded, markDirty: false) }
                }
                // The markers of the previous photo must not come back on this one.
                undoManager?.removeAllActions(withTarget: self)
            } catch {
                isAnalyzing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func openGraded(_ url: URL) {
        guard image != nil else { return }
        Task { await loadGraded(url, markDirty: true) }
    }

    func loadGraded(_ url: URL, markDirty: Bool) async {
        do {
            afterImage = try await Task.detached(priority: .userInitiated) {
                try ImageLoader.load(url: url)
            }.value
            compareMode = .split
            splitPosition = 0.5
            showPreview = false   // the graded version is the real thing; the divider is theirs now
            if markDirty { isDirty = true }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Flips between the original and the graded version (split → after → before → after …).
    func toggleBeforeAfter() {
        guard afterImage != nil else { return }
        compareMode = compareMode == .after ? .before : .after
    }

    func clearGraded() {
        guard afterImage != nil else { return }
        afterImage = nil
        compareMode = .before
        isDirty = true
    }

    /// Re-runs the analysis, replacing all markers.
    func analyze() {
        Task { await runAnalysis(markDirty: true) }
    }

    func runAnalysis(markDirty: Bool) async {
        guard let image else { return }
        isAnalyzing = true
        let count = colorCount
        await prepareWeights()
        let pixelWeights = weights
        let found = await Task.detached(priority: .userInitiated) {
            DominantColorAnalyzer.analyze(image.analysis, count: count, weights: pixelWeights)
        }.value
        guard self.image?.url == image.url else { return }
        // A new analysis replaces hand-placed markers; Undo brings them back. Opening a photo is not undoable.
        if markDirty, !markers.isEmpty { registerMarkerUndo("Re-analyze") }
        markers = found.map { Marker(location: $0.location, color: sample(at: $0.location)) }
        selectedMarkerID = nil
        hoveredMarkerID = nil
        harmonyRotationOverride = nil
        updateShares()
        isAnalyzing = false
        isDirty = markDirty
        refreshPreview()   // a preview remembered from the last run
    }

    // MARK: Subject weighting

    /// Changes the weighting without re-analyzing (the caller does that).
    func setWeighting(_ value: Weighting) {
        isRestoring = true
        withoutRemembering { weighting = value }   // a weighting given for one photo (command line, session) is not a preference
        isRestoring = false
    }

    func setWeights(_ value: [Float]?) {
        weights = value
        isWeighted = value != nil
    }

    /// Computes the pixel weights for the current weighting (detecting the subject if needed).
    func prepareWeights() async {
        guard weighting != .off, let map = await ensureSaliency() else {
            setWeights(nil)
            return
        }
        setWeights(Saliency.weights(for: map, strength: weighting.strength))
    }

    /// Detects the subject once per photo, at the resolution used for analysis.
    func ensureSaliency() async -> [Float]? {
        if let saliency { return saliency }
        guard let image, !saliencyFailed else { return nil }
        let (width, height) = (image.analysis.width, image.analysis.height)
        let map = await Task.detached(priority: .userInitiated) {
            try? Saliency.attentionMap(for: image.display, width: width, height: height)
        }.value
        guard self.image?.url == image.url else { return nil }
        if let map {
            saliency = map
        } else {
            saliencyFailed = true
            errorMessage = "The subject of the photo could not be detected, so the colors are not weighted."
        }
        return map
    }

    func refreshSaliencyOverlay() {
        guard showSaliency else {
            saliencyOverlay = nil
            return
        }
        Task {
            guard let map = await ensureSaliency(), let image, showSaliency else { return }
            saliencyOverlay = Saliency.spotlightImage(map: map, width: image.analysis.width, height: image.analysis.height)
        }
    }

}
