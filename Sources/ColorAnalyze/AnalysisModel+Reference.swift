import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

@MainActor
extension AnalysisModel {
    // MARK: Reference palette (a series or a single reference photo)

    /// A photo with a look worth copying. Its palette is used like the series palette: diamonds on the wheel,
    /// a match per color in the list and an aim for the Color Grading suggestion.
    struct ReferencePhoto {
        var url: URL
        var palette: [SharedColor]
        /// The decoded reference, shown in the reference panel.
        var image: LoadedImage
        /// Per palette color, the overlay that dims everything but the area of that color, and the share it covers.
        var regionOverlays: [CGImage?]
        var regionCoverage: [Double]
        var name: String { url.lastPathComponent }
    }

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
    func openReference(_ url: URL, keepChoices: Bool = false) -> Task<Void, Never> {
        let count = colorCount
        return Task {
            do {
                let reference = try await Task.detached(priority: .userInitiated) { () -> ReferencePhoto in
                    let loaded = try ImageLoader.load(url: url)
                    let colors = DominantColorAnalyzer.analyze(loaded.analysis, count: count, weights: nil)
                        .map { SeriesColor(centroid: $0.centroid, share: $0.share) }
                    let palette = SeriesAnalyzer.sharedPalette(from: [colors], size: count)
                    let masks = palette.indices.map { RegionMask(colorAt: $0, of: palette.map(\.centroid), in: loaded.analysis) }
                    return ReferencePhoto(url: url, palette: palette, image: loaded,
                                          regionOverlays: masks.map { $0.overlayImage() },
                                          regionCoverage: masks.map(\.coverage))
                }.value
                // The choices refer to the palette of the old reference; a restored session brings its own.
                if !keepChoices { clearReferenceChoices() }
                hoveredReferenceIndex = nil
                referencePhoto = reference
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
        hoveredReferenceIndex = nil
        clearReferenceChoices()
        isDirty = true
        showNotice("Removed the reference photo")
    }

    // MARK: Matching a color with a chosen reference color

    private func clearReferenceChoices() {
        for i in markers.indices { markers[i].referenceIndex = nil }
    }

    /// The reference palette color chosen by hand for `marker`, when it is still in the palette.
    func chosenReferenceIndex(for marker: Marker) -> Int? {
        guard let referencePhoto, let index = marker.referenceIndex, referencePhoto.palette.indices.contains(index) else { return nil }
        return index
    }

    /// Matches a color with palette color `index` of the reference photo, or with the nearest one again for nil.
    func setReferenceIndex(_ index: Int?, for id: Marker.ID) {
        guard let i = markers.firstIndex(where: { $0.id == id }), markers[i].referenceIndex != index else { return }
        registerMarkerUndo(index == nil ? "Match Reference Color Automatically" : "Match Reference Color")
        markers[i].referenceIndex = index
        isDirty = true
        refreshPreview()
        if let index { showNotice("Color \(i + 1) is matched with reference color \(index + 1)") }
    }

    /// The reference palette color nearest to the pixel of the reference photo at `location` (0...1, top-left origin).
    func referenceIndex(atPixel location: CGPoint) -> Int? {
        guard let referencePhoto, !referencePhoto.palette.isEmpty else { return nil }
        let color = referencePhoto.image.sampling.sample(at: location, radius: Self.defaultSampleRadius)
        return KMeans.nearest(color.oklab, in: referencePhoto.palette.map(\.centroid))
    }

    /// The reference color to light up: the one under the pointer, else the one the highlighted color is matched with.
    var highlightedReferenceIndex: Int? {
        guard let referencePhoto else { return nil }
        if let index = hoveredReferenceIndex, referencePhoto.palette.indices.contains(index) { return index }
        guard isSeriesReferenceShown, let id = highlightedMarkerID, let marker = markers.first(where: { $0.id == id }) else { return nil }
        return seriesMatch(for: marker)?.index
    }

    // MARK: Series reference

    var seriesPalette: [SharedColor] { referencePhoto?.palette ?? series?.palette ?? [] }

    /// True when there is a series palette and the reference is switched on.
    var isSeriesReferenceShown: Bool { showSeriesReference && !seriesPalette.isEmpty }

    /// Series photos share a scene or a look, so colors must be close to match; a reference photo is another scene.
    var referenceThreshold: Float {
        referencePhoto == nil ? SeriesAnalyzer.matchThreshold : SeriesAnalyzer.referenceMatchThreshold
    }

    func seriesMatch(for marker: Marker) -> SeriesMatch? {
        guard isSeriesReferenceShown else { return nil }
        if let index = chosenReferenceIndex(for: marker) {
            return SeriesAnalyzer.match(marker.color.oklab, against: seriesPalette, forcedIndex: index)
        }
        return SeriesAnalyzer.match(marker.color.oklab, against: seriesPalette, threshold: referenceThreshold)
    }

    func seriesInfo(for marker: Marker) -> SeriesRowInfo? {
        guard isSeriesReferenceShown else { return nil }
        guard let match = seriesMatch(for: marker) else { return .unmatched }
        return .match(match, paletteHex: seriesPalette[match.index].color.hex, chosen: chosenReferenceIndex(for: marker) != nil)
    }

    /// How well the photo's colors fit the series palette, with a starting point for aligning it.
    var seriesFit: PhotoConsistency? {
        guard isSeriesReferenceShown, !markers.isEmpty else { return nil }
        return SeriesAnalyzer.consistency(of: markers.map { SeriesColor(centroid: $0.color.oklab, share: max($0.share, 1e-4)) },
                                          against: seriesPalette, threshold: referenceThreshold,
                                          forced: markers.map(chosenReferenceIndex(for:)))
    }

    /// The same for the graded version: its colors at the marker positions, weighted by the original shares.
    var afterSeriesFit: PhotoConsistency? {
        guard hasAfterColors, isSeriesReferenceShown, !markers.isEmpty else { return nil }
        return SeriesAnalyzer.consistency(
            of: markers.map { SeriesColor(centroid: (afterColor(for: $0) ?? $0.color).oklab, share: max($0.share, 1e-4)) },
            against: seriesPalette, threshold: referenceThreshold, forced: markers.map(chosenReferenceIndex(for:)))
    }
}
