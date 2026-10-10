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
}

/// How much more the subject of the photo counts than the background.
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
    private(set) var image: LoadedImage?
    private(set) var isAnalyzing = false
    var errorMessage: String?

    private(set) var markers: [Marker] = []
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

    // MARK: Remembered settings
    //
    // Colors, wheel, subject weighting, skin tone line, Color Grading strength and preview are remembered between launches
    // (UserDefaults). A saved session of a photo overrides them for that photo, and a setting given on the command line
    // applies to that run only: neither changes what is remembered.

    @ObservationIgnored private var suppressRemembering = 0
    /// Runs `body` with changes to the settings not remembered.
    func withoutRemembering(_ body: () -> Void) {
        suppressRemembering += 1
        body()
        suppressRemembering -= 1
    }
    private func remember(_ value: Any, as key: String) {
        if suppressRemembering == 0 { UserDefaults.standard.set(value, forKey: "setting." + key) }
    }
    private static func remembered<T>(_ key: String) -> T? { UserDefaults.standard.object(forKey: "setting." + key) as? T }

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
    private(set) var saliencyOverlay: CGImage?
    /// True when the current shares and markers were computed with subject weights.
    private(set) var isWeighted = false
    @ObservationIgnored private var weights: [Float]?
    @ObservationIgnored private var saliency: [Float]?
    @ObservationIgnored private var saliencyFailed = false

    /// What the photo should feel like, written down before choosing a harmony. Saved in the session.
    var intention = "" {
        didSet { if intention != oldValue { isDirty = true } }
    }

    /// True when the markers, harmony or comparison differ from what is saved next to the photo.
    private(set) var isDirty = false
    /// Short status message ("Saved …"), cleared after a few seconds.
    private(set) var notice: String?
    @ObservationIgnored private var isRestoring = false

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

    /// Marker sample radius as a fraction of the photo's short side.
    let sampleRadius = 0.015

    // MARK: Region overlay

    var showRegions = true {
        didSet { if showRegions != oldValue { refreshRegion() } }
    }
    /// Dims everything except the pixels that belong to the hovered/selected marker's color.
    private(set) var regionOverlay: CGImage?
    /// Share of the photo covered by the highlighted region (0...1).
    private(set) var regionCoverage: Double?
    /// Same region as a share of the subject-weighted photo; nil when weighting is off.
    private(set) var regionWeightedShare: Double?

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
    private(set) var afterImage: LoadedImage?
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

    private func loadGraded(_ url: URL, markDirty: Bool) async {
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

    private func runAnalysis(markDirty: Bool) async {
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
    private func setWeighting(_ value: Weighting) {
        isRestoring = true
        withoutRemembering { weighting = value }   // a weighting given for one photo (command line, session) is not a preference
        isRestoring = false
    }

    private func setWeights(_ value: [Float]?) {
        weights = value
        isWeighted = value != nil
    }

    /// Computes the pixel weights for the current weighting (detecting the subject if needed).
    private func prepareWeights() async {
        guard weighting != .off, let map = await ensureSaliency() else {
            setWeights(nil)
            return
        }
        setWeights(Saliency.weights(for: map, strength: weighting.strength))
    }

    /// Detects the subject once per photo, at the resolution used for analysis.
    private func ensureSaliency() async -> [Float]? {
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

    private func refreshSaliencyOverlay() {
        guard showSaliency else {
            saliencyOverlay = nil
            return
        }
        Task {
            guard let map = await ensureSaliency(), let image, showSaliency else { return }
            saliencyOverlay = Saliency.spotlightImage(map: map, width: image.analysis.width, height: image.analysis.height)
        }
    }

    // MARK: Session

    func makeSession() -> Session? {
        guard let image else { return nil }
        return Session(
            photo: image.url.lastPathComponent,
            graded: afterImage?.url.path,
            colorCount: colorCount,
            weighting: weighting == .off ? nil : weighting.rawValue,
            markers: markers.map { .init(x: $0.location.x, y: $0.location.y, hex: $0.color.hex) },
            harmony: harmonyChoice?.rawValue,
            harmonyRotation: harmonyRotationOverride,
            hueSpace: hueSpace == .rgb ? nil : hueSpace.rawValue,
            compareMode: afterImage == nil ? nil : compareMode.rawValue,
            splitPosition: afterImage == nil ? nil : splitPosition,
            intention: intention,
            reference: referencePhoto?.url.path
        )
    }

    /// Writes the session as JSON next to the photo.
    func saveSession() {
        guard let image, let session = makeSession() else { return }
        let sidecar = Session.sidecarURL(for: image.url)
        do {
            try session.write(to: sidecar)
            isDirty = false
            showNotice("Saved session as \(sidecar.lastPathComponent)")
        } catch {
            errorMessage = "Could not save the session next to the photo: \(error.localizedDescription)"
        }
    }

    private func savedSession(for photo: URL) -> Session? {
        let sidecar = Session.sidecarURL(for: photo)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        do {
            return try Session.read(from: sidecar)
        } catch {
            errorMessage = "Could not restore the saved session (\(error.localizedDescription)). The photo was analyzed again."
            return nil
        }
    }

    /// Re-creates markers from a saved session. Colors are sampled from the photo again.
    private func restore(_ session: Session, photo: URL, graded override: URL?) async {
        suppressRemembering += 1
        defer { suppressRemembering -= 1 }
        isRestoring = true
        colorCount = min(12, max(3, session.colorCount))
        weighting = session.weighting.flatMap(Weighting.init(rawValue:)) ?? .off
        isRestoring = false
        await prepareWeights()
        hueSpace = session.hueSpace.flatMap(HueSpace.init(rawValue:)) ?? .rgb
        intention = session.intention ?? ""
        harmonyChoice = session.harmony.flatMap(HarmonyKind.init(rawValue:))
        harmonyRotationOverride = session.harmonyRotation
        markers = session.markers.map { saved in
            let location = CGPoint(x: min(1, max(0, saved.x)), y: min(1, max(0, saved.y)))
            return Marker(location: location, color: sample(at: location))
        }
        selectedMarkerID = nil
        hoveredMarkerID = nil
        updateShares()
        isAnalyzing = false
        refreshPreview()

        if let gradedURL = override ?? session.gradedURL(photoFolder: photo.deletingLastPathComponent()) {
            await loadGraded(gradedURL, markDirty: false)
            if afterImage != nil {
                compareMode = session.compareMode.flatMap(CompareMode.init(rawValue:)) ?? .split
                splitPosition = session.splitPosition ?? 0.5
            }
        }
        // The reference the photo was aimed at; one that is missing leaves the current reference alone.
        var missingReference: String?
        if let reference = session.reference {
            if let referenceURL = session.referenceURL(photoFolder: photo.deletingLastPathComponent()) {
                await openReference(referenceURL).value
            } else {
                missingReference = URL(fileURLWithPath: reference).lastPathComponent
            }
        }
        isDirty = false
        showNotice(missingReference.map { "Restored the saved session; the reference photo \($0) was not found" }
                   ?? "Restored the saved session")
    }

    private func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == text { notice = nil }
        }
    }

    // MARK: Report export

    func reportData() -> ReportData? {
        guard let image else { return nil }
        return ReportData(
            title: image.url.lastPathComponent,
            date: Date(),
            before: image.display,
            after: afterImage?.display,
            markers: markers,
            afterColors: markers.map { afterImage == nil ? nil : afterColor(for: $0) },
            harmony: harmony,
            harmonyIsAutoDetected: harmonyChoice == nil,
            afterHarmony: afterImage == nil ? nil : afterHarmony,
            weighting: isWeighted ? weighting.title : nil,
            hueSpace: hueSpace,
            showSkinTone: showSkinTone,
            seriesPalette: isSeriesReferenceShown ? seriesPalette : [],
            referenceTitle: referenceTitle,
            seriesInfos: markers.map { seriesInfo(for: $0) },
            seriesFit: seriesFit,
            afterSeriesFit: afterImage == nil ? nil : afterSeriesFit,
            intention: Intention.cleaned(intention)
        )
    }

    func exportReport(to url: URL) throws {
        guard let data = reportData() else { throw ReportError.noPhoto }
        guard let png = ReportRenderer.pngData(for: data) else { throw ReportError.renderFailed }
        try png.write(to: url, options: .atomic)
    }

    /// The color list with the context needed to interpret it (harmony, graded version).
    func colorExport() -> ColorExport? {
        guard let image else { return nil }
        let fit = harmony
        let records = markers.enumerated().map { index, marker in
            ColorRecord(number: index + 1, location: marker.location, color: marker.color, share: marker.share,
                        areaShare: isWeighted ? marker.areaShare : nil,
                        after: afterColor(for: marker), harmony: fit)
        }
        return ColorExport(
            photo: image.url.lastPathComponent,
            graded: afterImage?.url.path,
            weighting: isWeighted ? weighting.rawValue : nil,
            intention: intention,
            harmony: fit.map { .init(fit: $0, autoDetected: harmonyChoice == nil, fitAfter: afterHarmony) },
            colors: records
        )
    }

    func exportColors(to url: URL, format: ExportFormat) throws {
        guard let export = colorExport() else { throw ReportError.noPhoto }
        switch format {
        case .colorsCSV: try Data(export.csv().utf8).write(to: url, options: .atomic)
        case .colorsCSVExcel: try Data(export.csv(style: .europeanExcel).utf8).write(to: url, options: .atomic)
        case .colorsJSON: try export.json().write(to: url, options: .atomic)
        case .reportPNG: try exportReport(to: url)
        case .swatches:
            let swatches = markers.enumerated().map { ("\($0.offset + 1) – \($0.element.color.hex)", $0.element.color) }
            let group = (image?.url.deletingPathExtension().lastPathComponent ?? "Photo") + " – ColorAnalyze"
            try AdobeSwatchExchange.data(groupName: group, swatches: swatches).write(to: url, options: .atomic)
        case .palettePNG:
            guard let image, let png = ReportRenderer.pngData(for: PaletteData(
                title: image.url.lastPathComponent,
                subtitle: "\(markers.count) dominant colors · " + Date().formatted(date: .long, time: .shortened),
                entries: markers.enumerated().map { .init(number: $0.offset + 1, color: $0.element.color, share: $0.element.share) }
            )) else { throw ReportError.renderFailed }
            try png.write(to: url, options: .atomic)
        case .dxoPreset:
            guard let grading = colorGrading else { throw ReportError.noGrading }
            try Data(grading.preset.luaText().utf8).write(to: url, options: .atomic)
        }
    }

    func presentExportPanel(_ format: ExportFormat) {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = image.url.deletingPathExtension().lastPathComponent + format.fileNameSuffix + "." + format.fileExtension
        panel.directoryURL = (format == .dxoPreset ? DxOLocations.colorGradingPresetsFolder() : nil)
            ?? image.url.deletingLastPathComponent()
        panel.message = format.panelMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportColors(to: url, format: format)
            showNotice("Exported \(url.lastPathComponent)")
        } catch {
            errorMessage = "Could not export \(format.shortName): \(error.localizedDescription)"
        }
    }

    // MARK: Marker editing

    /// The markers and the selection, as undo restores them.
    private struct MarkerState: Sendable {
        var markers: [Marker]
        var selected: Marker.ID?
    }

    /// The window's undo manager (Edit ▸ Undo / Redo, ⌘Z / ⇧⌘Z); handed over by the main view.
    @ObservationIgnored weak var undoManager: UndoManager? {
        didSet { undoManager?.levelsOfUndo = 200 }
    }
    /// Marker state at the start of the current drag, recorded as one undo step once the marker really moves.
    @ObservationIgnored private var pendingMoveUndo: (name: String, state: MarkerState)?

    private var markerState: MarkerState { MarkerState(markers: markers, selected: selectedMarkerID) }

    /// Makes the current markers the state that Undo returns to, under `name` ("Undo Move Marker 3").
    private func registerMarkerUndo(_ name: String, state: MarkerState? = nil) {
        guard let undoManager else { return }
        let state = state ?? markerState
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreMarkers(state, name: name) }
        }
        undoManager.setActionName(name)
    }

    /// Puts earlier markers back. The state it replaces is registered as well, so Undo and Redo mirror each other.
    private func restoreMarkers(_ state: MarkerState, name: String) {
        registerMarkerUndo(name)
        markers = state.markers
        selectedMarkerID = state.selected.flatMap { id in state.markers.contains { $0.id == id } ? id : nil }
        hoveredMarkerID = nil
        updateShares()
        isDirty = true
        showNotice(undoManager?.isRedoing == true ? "Redid \(name)" : "Undid \(name)")
    }

    /// Call when a drag on a marker starts; the undo step is recorded when the marker moves.
    func beginMarkerMove(_ id: Marker.ID) {
        releaseKeyboardFocus()
        pendingMoveUndo = ("Move Marker \(number(of: id))", markerState)
    }

    func endMarkerMove() {
        pendingMoveUndo = nil
    }

    /// Last arrow-key nudge: keys pressed one after the other on the same marker are one undo step.
    @ObservationIgnored private var lastNudge: (id: Marker.ID, time: Date)?

    /// Moves the selected marker by whole pixels of the displayed photo (arrow keys; ⇧ = 10).
    /// Returns false when no marker is selected, so the key can do its usual job.
    func nudgeSelectedMarker(dx: Int, dy: Int) -> Bool {
        guard let image, let id = selectedMarkerID, let i = markers.firstIndex(where: { $0.id == id }) else { return false }
        let now = Date()
        if lastNudge?.id != id || now.timeIntervalSince(lastNudge?.time ?? .distantPast) > 1.0 {
            registerMarkerUndo("Nudge Marker \(i + 1)")
        }
        lastNudge = (id, now)
        let location = markers[i].location
        moveMarkerWithoutUndo(id, to: CGPoint(x: location.x + Double(dx) / Double(image.display.width),
                                              y: location.y + Double(dy) / Double(image.display.height)))
        return true
    }

    func moveMarker(_ id: Marker.ID, to location: CGPoint) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        if let pending = pendingMoveUndo {
            registerMarkerUndo(pending.name, state: pending.state)
            pendingMoveUndo = nil
        }
        moveMarkerWithoutUndo(id, to: location)
    }

    private func moveMarkerWithoutUndo(_ id: Marker.ID, to location: CGPoint) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = CGPoint(x: min(1, max(0, location.x)), y: min(1, max(0, location.y)))
        markers[i].location = clamped
        markers[i].color = sample(at: clamped)
        updateShares()
        isDirty = true
    }

    /// Adds a marker on the color that no marker represents yet — a small subject or an accent that the
    /// automatic analysis passed over (a red boat on blue water). Every call finds the next one.
    @discardableResult
    func suggestMarker() -> Task<Void, Never> {
        guard let image, !isAnalyzing else { return Task {} }
        let existing = markers.map(\.color.oklab)
        let pixelWeights = weights
        return Task {
            let found = await Task.detached(priority: .userInitiated) {
                DominantColorAnalyzer.findMissingColor(in: image.analysis, existing: existing, weights: pixelWeights)
            }.value
            guard self.image?.url == image.url else { return }
            guard let found else {
                showNotice("Every part of the photo is already close to a marker color")
                return
            }
            addMarker(at: found.location, name: "Suggest Marker")
            showNotice("Added a marker on a color that was missing")
        }
    }

    func addMarker(at location: CGPoint, name: String = "Add Marker") {
        guard image != nil else { return }
        registerMarkerUndo(name)
        let marker = Marker(location: location, color: sample(at: location))
        markers.append(marker)
        selectedMarkerID = marker.id
        updateShares()
        isDirty = true
    }

    func removeMarker(_ id: Marker.ID?) {
        guard let id, markers.contains(where: { $0.id == id }) else { return }
        registerMarkerUndo("Remove Marker \(number(of: id))")
        markers.removeAll { $0.id == id }
        if selectedMarkerID == id { selectedMarkerID = nil }
        if hoveredMarkerID == id { hoveredMarkerID = nil }
        updateShares()
        isDirty = true
    }

    func number(of id: Marker.ID) -> Int {
        (markers.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func sample(at location: CGPoint) -> SRGBColor {
        image?.sampling.sample(at: location, radius: sampleRadius) ?? SRGBColor(r: 0, g: 0, b: 0)
    }

    private func updateShares() {
        guard let image else { return }
        let colors = markers.map(\.color.oklab)
        let area = DominantColorAnalyzer.shares(of: colors, in: image.analysis)
        let weighted = weights.map { DominantColorAnalyzer.shares(of: colors, in: image.analysis, weights: $0) } ?? area
        for i in markers.indices {
            markers[i].areaShare = area[i]
            markers[i].share = weighted[i]
        }
        refreshRegion()
    }

    private func refreshRegion() {
        guard showRegions, let image, let id = highlightedMarkerID,
              let index = markers.firstIndex(where: { $0.id == id }) else {
            regionOverlay = nil
            regionCoverage = nil
            regionWeightedShare = nil
            return
        }
        let mask = RegionMask(colorAt: index, of: markers.map(\.color.oklab), in: image.analysis)
        regionOverlay = mask.overlayImage()
        regionCoverage = mask.coverage
        regionWeightedShare = isWeighted ? markers[index].share : nil
    }

    // MARK: DxO Color Grading

    /// What the suggested Color Grading preset aims at.
    enum GradingTarget: String, CaseIterable, Identifiable {
        /// Toward the harmony's target hues.
        case harmony
        /// Toward the matching colors of the series palette.
        case series
        /// Strengthen the faint tint each tonal range already has (for photos without real colors).
        case emphasize
        var id: String { rawValue }
    }

    /// How strongly the suggested tints are applied (the saturation of a wheel whose colors are 30° or more off).
    var gradingStrength = ColorGradingSuggestion.Strength(rawValue: UserDefaults.standard.string(forKey: "gradingStrength") ?? "")
        ?? .moderate {
        didSet { if rememberGradingStrength { UserDefaults.standard.set(gradingStrength.rawValue, forKey: "gradingStrength") } }
    }
    @ObservationIgnored private var rememberGradingStrength = true

    /// Sets the strength for this run only (command line); the remembered preference is left alone.
    func useGradingStrength(_ strength: ColorGradingSuggestion.Strength) {
        rememberGradingStrength = false
        gradingStrength = strength
        rememberGradingStrength = true
    }
    /// A creative direction on top of the harmony: warm highlights over cool shadows, or the reverse. Remembered.
    var gradingStyle = (AnalysisModel.remembered("gradingStyle") as String?).flatMap(GradingStyle.init(rawValue:)) ?? .neutral {
        didSet { if gradingStyle != oldValue { remember(gradingStyle.rawValue, as: "gradingStyle") } }
    }
    /// The style the intention points to (*warme avond* → warm highlights), when it is not the one chosen.
    var intentionStyle: (style: GradingStyle, words: [String])? {
        guard let suggestion = Intention.suggestedStyle(for: intention), suggestion.style != gradingStyle else { return nil }
        return suggestion
    }
    var gradingTarget = GradingTarget.harmony

    /// Where the grading really aims: the series palette only when it is available and shown, and the
    /// existing tints when there is no harmony to aim at (a photo of fog, dusk or in black and white).
    var effectiveGradingTarget: GradingTarget {
        switch gradingTarget {
        case .emphasize: return .emphasize
        case .series where isSeriesReferenceShown: return .series
        default: return harmony == nil ? .emphasize : .harmony
        }
    }

    /// True when "Harmony" or "Series" was chosen but the grading falls back to the existing tints.
    var gradingFallsBackToTints: Bool {
        gradingTarget != .emphasize && effectiveGradingTarget == .emphasize
    }

    /// Per tonal range, the tint that brings the photo's colors closest to the harmony (or the series palette), found with
    /// the calibrated model of PhotoLab's Color Grading. The result is kept until something it depends on changes.
    var colorGrading: ColorGradingSuggestion.Suggestion? {
        let key = suggestionKey
        if let cache = gradingCache, cache.key == key { return cache.grading }
        let grading = computeColorGrading()
        gradingCache = (key, grading)
        return grading
    }

    @ObservationIgnored private var gradingCache: (key: Int, grading: ColorGradingSuggestion.Suggestion?)?
    @ObservationIgnored private var predictionCache: (key: Int, settings: GradePreviewSettings?, plan: GradePreview.Plan?)?

    /// Everything the suggestion depends on, as one number: the markers, the harmony and the aim.
    private var suggestionKey: Int {
        var hasher = Hasher()
        for marker in markers {
            hasher.combine(marker.color.hex)
            hasher.combine(Int((marker.share * 10_000).rounded()))
        }
        hasher.combine(harmonyChoice?.rawValue)
        hasher.combine(harmonyRotationOverride)
        hasher.combine(hueSpace.rawValue)
        hasher.combine(gradingStrength.rawValue)
        hasher.combine(gradingStyle.rawValue)
        hasher.combine(gradingTarget.rawValue)
        hasher.combine(isSeriesReferenceShown)
        hasher.combine(referencePhoto?.url.path)
        for color in seriesPalette { hasher.combine(color.color.hex) }
        return hasher.finalize()
    }

    private func computeColorGrading() -> ColorGradingSuggestion.Suggestion? {
        guard !markers.isEmpty else { return nil }
        var inputs: [ColorGradingSuggestion.Input] = []
        switch effectiveGradingTarget {
        case .emphasize:
            return ColorGradingSuggestion.emphasize(markers.map { ($0.color, $0.share) }, strength: gradingStrength)
        case .harmony:
            guard let fit = harmony else { return nil }
            inputs = markers.map {
                let hue = $0.color.hsb.h
                return .init(color: $0.color, share: $0.share, targetHue: hue + fit.shift(for: hue))
            }
        case .series:
            for marker in markers {
                if marker.color.chroma < DxOMapping.neutralChroma {
                    // Greys have no target, but the grading must not tint them.
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h))
                } else if let shift = seriesMatch(for: marker)?.hueShift {
                    inputs.append(.init(color: marker.color, share: marker.share, targetHue: marker.color.hsb.h + shift))
                }
            }
        }
        return ColorGradingSuggestion.optimized(from: inputs, strength: gradingStrength, style: gradingStyle)
    }

    /// Per channel of PhotoLab's HSL tool, how far its Hue handle should turn (degrees on PhotoLab's ring;
    /// + = counter-clockwise), aimed like the Color Grading suggestion: at the harmony or at the reference
    /// palette. Nothing when the grading only strengthens the existing tints: there is no target to turn toward.
    var hslSuggestions: [HSLSuggestion.Channel] {
        guard !markers.isEmpty else { return [] }
        let aim = effectiveGradingTarget
        let fit = harmony
        return HSLSuggestion.channels(from: markers.enumerated().map { index, marker in
            let shift: Double? = switch aim {
            case .harmony: fit?.shift(for: marker.color.hsb.h)
            case .series: seriesMatch(for: marker)?.hueShift
            case .emphasize: nil
            }
            return HSLSuggestion.Input(number: index + 1, color: marker.color, share: marker.share, hueShift: shift)
        })
    }

    // MARK: Preview of the suggestion

    /// Shows the photo with the suggested Color Grading tints and HSL hue turns applied (right of the divider).
    var showPreview = AnalysisModel.remembered("showPreview") ?? false {
        didSet {
            if showPreview != oldValue { remember(showPreview, as: "showPreview"); refreshPreview() }
        }
    }
    /// How the preview is shown next to the original: right of a divider you can drag, or in a second photo below it.
    enum PreviewLayout: String, CaseIterable, Identifiable {
        case split = "Divider"
        case stacked = "Below"
        var id: String { rawValue }
    }
    var previewLayout = (AnalysisModel.remembered("previewLayout") as String?).flatMap(PreviewLayout.init(rawValue:)) ?? .split {
        didSet { if previewLayout != oldValue { remember(previewLayout.rawValue, as: "previewLayout") } }
    }
    /// True when the preview is drawn as a second photo below the original.
    var isStackedPreview: Bool { showPreview && previewImage != nil && afterImage == nil && previewLayout == .stacked }
    /// 1 = as suggested; 2 and 4 exaggerate, because a suggestion of a few points is hard to see.
    var previewAmount = AnalysisModel.remembered("previewAmount") ?? 1.0 {
        didSet { if previewAmount != oldValue { remember(previewAmount, as: "previewAmount"); refreshPreview() } }
    }
    private(set) var previewImage: CGImage?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewGeneration = 0

    /// The suggestion as settings of the calibrated model, as suggested (amount 1), with the plan to apply them.
    private func prediction() -> (settings: GradePreviewSettings, plan: GradePreview.Plan)? {
        let key = suggestionKey
        if let cache = predictionCache, cache.key == key {
            guard let settings = cache.settings, let plan = cache.plan else { return nil }
            return (settings, plan)
        }
        var result: (GradePreviewSettings, GradePreview.Plan)?
        if let grading = colorGrading {
            func tint(_ wheel: ColorGradingPreset.Wheel) -> GradePreviewSettings.Tint {
                .init(dxoHue: Double(wheel.hue), saturation: Double(wheel.saturation), luminance: Double(wheel.luminance))
            }
            var settings = GradePreviewSettings(shadows: tint(grading.preset.shadows), midtones: tint(grading.preset.midtones),
                                                highlights: tint(grading.preset.highlights), master: tint(grading.preset.master),
                                                balance: Double(grading.preset.balance),
                                                toneBlacks: Double(grading.toneBlacks), toneShadows: Double(grading.toneShadows))
            for channel in hslSuggestions { settings.hueShifts[channel.channel] = channel.hueShift }
            result = (settings, GradePreview.Plan(settings))
        }
        predictionCache = (key, result?.0, result?.1)
        return result
    }

    /// What the preview image applies; nil while it is off or when there is nothing to suggest yet. Changes with the
    /// markers, the harmony, the strength and the aim, and the preview follows.
    var previewSettings: GradePreviewSettings? {
        guard showPreview, var settings = prediction()?.settings else { return nil }
        settings.amount = previewAmount
        return settings
    }

    /// True while the preview is on and there is a suggestion: the colors "after" are then the predicted ones.
    var isPreviewActive: Bool { showPreview && afterImage == nil && prediction() != nil }

    /// A graded version is loaded, or the preview predicts one.
    var hasAfterColors: Bool { afterImage != nil || isPreviewActive }

    /// "After" for a graded version, "Predicted" for the preview.
    var afterLabel: String { afterImage == nil ? "Predicted" : "After" }

    /// The color a marker gets from the suggestion, as the calibrated model predicts PhotoLab will render it.
    private func predictedColor(for marker: Marker) -> SRGBColor? {
        guard showPreview, let plan = prediction()?.plan else { return nil }
        let linear = marker.color.linear
        return SRGBColor(linear: plan.applyLinear(linear: linear, lab: ColorMath.linearToOKLab(linear))).clamped
    }

    func togglePreview() {
        guard afterImage == nil else { return }
        showPreview.toggle()
    }

    /// Renders the preview in the background; a newer request replaces an older one.
    func refreshPreview() {
        previewTask?.cancel()
        guard showPreview, afterImage == nil, let image, let settings = previewSettings else {
            previewImage = nil
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        let source = image.display
        previewTask = Task {
            // Dragging a marker changes the settings all the time: render once it rests.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let rendered = await Task.detached(priority: .userInitiated) {
                GradePreview.render(source, settings: settings)
            }.value
            guard generation == previewGeneration else { return }
            previewImage = rendered
        }
    }

    // MARK: Reference palette (a series or a single reference photo)

    /// A photo with a look worth copying. Its palette is used like the series palette: diamonds on the wheel,
    /// a match per color in the list and an aim for the Color Grading suggestion.
    struct ReferencePhoto {
        var url: URL
        var palette: [SharedColor]
        var name: String { url.lastPathComponent }
    }

    /// Overrides the series palette while it is set. Stays when another photo is opened, so one reference can
    /// serve a whole batch; it is not part of the saved session.
    private(set) var referencePhoto: ReferencePhoto?

    /// "Reference" or "Series": what the palette on the wheel comes from.
    var referenceTitle: String { referencePhoto == nil ? "Series" : "Reference" }
    var referenceNoun: String { referencePhoto == nil ? "series" : "reference" }

    func presentOpenReferencePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo whose colors you want to match"
        if panel.runModal() == .OK, let url = panel.url { openReference(url) }
    }

    /// Analyzes `url` and uses its dominant colors as the reference palette (as many colors as the current setting).
    @discardableResult
    func openReference(_ url: URL) -> Task<Void, Never> {
        let count = colorCount
        return Task {
            do {
                let palette = try await Task.detached(priority: .userInitiated) { () -> [SharedColor] in
                    let loaded = try ImageLoader.load(url: url)
                    let colors = DominantColorAnalyzer.analyze(loaded.analysis, count: count, weights: nil)
                        .map { SeriesColor(centroid: $0.centroid, share: $0.share) }
                    return SeriesAnalyzer.sharedPalette(from: [colors], size: count)
                }.value
                referencePhoto = ReferencePhoto(url: url, palette: palette)
                showSeriesReference = true
                isDirty = true
                showNotice("Reference: \(url.lastPathComponent)")
            } catch {
                errorMessage = "Could not open the reference photo: \(error.localizedDescription)"
            }
        }
    }

    func clearReference() {
        guard referencePhoto != nil else { return }
        referencePhoto = nil
        isDirty = true
        showNotice("Removed the reference photo")
    }

    // MARK: Series reference

    var seriesPalette: [SharedColor] { referencePhoto?.palette ?? series?.palette ?? [] }

    /// True when there is a series palette and the reference is switched on.
    var isSeriesReferenceShown: Bool { showSeriesReference && !seriesPalette.isEmpty }

    /// Series photos share a scene or a look, so colors must be close to match; a reference photo is another scene.
    private var referenceThreshold: Float {
        referencePhoto == nil ? SeriesAnalyzer.matchThreshold : SeriesAnalyzer.referenceMatchThreshold
    }

    func seriesMatch(for marker: Marker) -> SeriesMatch? {
        isSeriesReferenceShown ? SeriesAnalyzer.match(marker.color.oklab, against: seriesPalette, threshold: referenceThreshold) : nil
    }

    func seriesInfo(for marker: Marker) -> SeriesRowInfo? {
        guard isSeriesReferenceShown else { return nil }
        guard let match = seriesMatch(for: marker) else { return .unmatched }
        return .match(match, paletteHex: seriesPalette[match.index].color.hex)
    }

    /// How well the photo's colors fit the series palette, with a starting point for aligning it.
    var seriesFit: PhotoConsistency? {
        guard isSeriesReferenceShown, !markers.isEmpty else { return nil }
        return SeriesAnalyzer.consistency(of: markers.map { SeriesColor(centroid: $0.color.oklab, share: max($0.share, 1e-4)) },
                                          against: seriesPalette, threshold: referenceThreshold)
    }

    /// The same for the graded version: its colors at the marker positions, weighted by the original shares.
    var afterSeriesFit: PhotoConsistency? {
        guard hasAfterColors, isSeriesReferenceShown, !markers.isEmpty else { return nil }
        return SeriesAnalyzer.consistency(
            of: markers.map { SeriesColor(centroid: (afterColor(for: $0) ?? $0.color).oklab, share: max($0.share, 1e-4)) },
            against: seriesPalette, threshold: referenceThreshold)
    }

    // MARK: Harmony

    private var harmonyInputs: [HarmonyInput] {
        markers.map {
            HarmonyInput(hue: $0.color.hsb.h, weight: DxOMapping.harmonyWeight(color: $0.color, share: $0.share))
        }
    }

    var harmony: HarmonyFit? {
        let inputs = harmonyInputs
        let kind = harmonyChoice ?? HarmonyDetector.detect(inputs, space: hueSpace)?.kind
        guard let kind else { return nil }
        if let rotation = harmonyRotationOverride {
            return HarmonyDetector.evaluate(kind, rotation: rotation, inputs: inputs, space: hueSpace)
                ?? HarmonyFit(kind: kind, rotation: rotation, deviation: 0, space: hueSpace)
        }
        return HarmonyDetector.fit(kind, to: inputs, space: hueSpace)
            ?? HarmonyFit(kind: kind, rotation: 0, deviation: 0, space: hueSpace)
    }

    /// How well the graded version matches the same harmony targets as the original.
    var afterHarmony: HarmonyFit? {
        guard hasAfterColors, let fit = harmony else { return nil }
        let inputs = markers.compactMap { marker in
            afterColor(for: marker).map {
                HarmonyInput(hue: $0.hsb.h, weight: DxOMapping.harmonyWeight(color: $0, share: marker.share))
            }
        }
        return HarmonyDetector.evaluate(fit.kind, rotation: fit.rotation, inputs: inputs, space: fit.space)
    }
}
