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
    var referenceThreshold: Float {
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
}
