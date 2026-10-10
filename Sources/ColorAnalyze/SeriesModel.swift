import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

/// One photo of the series: a thumbnail and its dominant colors. The analysis buffer (and the
/// subject map, if weighting is on) are kept so that changing the number of colors does not
/// need to read the photo again.
struct SeriesItem: Identifiable, @unchecked Sendable {
    var id = UUID()
    let url: URL
    let thumbnail: CGImage
    let analysis: PixelBuffer
    var saliency: [Float]?
    var colors: [SeriesColor]
}

enum SeriesExportKind {
    case reportPNG, json, paletteCSV, photosCSV, paletteASE

    var contentType: UTType {
        switch self {
        case .reportPNG: .png
        case .json: .json
        case .paletteCSV, .photosCSV: .commaSeparatedText
        case .paletteASE: UTType(filenameExtension: AdobeSwatchExchange.fileExtension) ?? .data
        }
    }

    var fileExtension: String {
        switch self {
        case .reportPNG: "png"
        case .json: "json"
        case .paletteCSV, .photosCSV: "csv"
        case .paletteASE: AdobeSwatchExchange.fileExtension
        }
    }

    var fileName: String {
        switch self {
        case .reportPNG: "Series overview"
        case .json: "Series"
        case .paletteCSV, .paletteASE: "Series palette"
        case .photosCSV: "Series photos"
        }
    }

    var message: String {
        switch self {
        case .reportPNG: "Export a PNG overview with the shared palette, the wheel and every photo's score"
        case .json: "Export the shared palette and every photo's consistency as JSON"
        case .paletteCSV: "Export the shared palette as CSV (one row per color)"
        case .paletteASE: "Export the shared palette as an Adobe Swatch Exchange file (.ase) for Photoshop, Illustrator, Affinity and others"
        case .photosCSV: "Export the per-photo table as CSV (one row per photo)"
        }
    }
}

/// Analyzes several photos and derives the palette they share, plus how well each photo fits it.
@Observable @MainActor
final class SeriesModel {
    private(set) var items: [SeriesItem] = []
    private(set) var palette: [SharedColor] = []
    private(set) var consistency: [SeriesItem.ID: PhotoConsistency] = [:]
    private(set) var isBusy = false
    private(set) var progressDone = 0
    private(set) var progressTotal = 0
    var errorMessage: String?
    var selectedID: SeriesItem.ID?

    /// What the series should feel like, written down before choosing a harmony. Saved with the series.
    var intention = "" {
        didSet { if intention != oldValue { markEdited() } }
    }

    /// The file this series was saved to or opened from.
    private(set) var fileURL: URL?
    /// True when the series differs from what is saved in `fileURL` (or was never saved).
    private(set) var isDirty = false
    @ObservationIgnored private var isRestoring = false

    /// Wheel the colors are plotted on (RGB or the artist's RYB wheel).
    var hueSpace = HueSpace.rgb {
        didSet { if hueSpace != oldValue { markEdited() } }
    }
    /// Lists the least consistent photos first.
    var sortByScore = false {
        didSet { if sortByScore != oldValue { markEdited() } }
    }
    /// Write CSV with `;` and decimal commas (Dutch Excel).
    var excelCSV = false

    var colorsPerPhoto = 5 {
        didSet { if colorsPerPhoto != oldValue { reanalyze(); markEdited() } }
    }
    var paletteSize = 6 {
        didSet { if paletteSize != oldValue { recompute(); markEdited() } }
    }
    var weighting = Weighting.off {
        didSet { if weighting != oldValue { reanalyze(); markEdited() } }
    }

    private func markEdited() {
        if !isRestoring { isDirty = true }
    }

    /// The name of the saved series without its extension, or "Series".
    var baseName: String {
        var name = "Series"
        if let fileURL {
            name = fileURL.lastPathComponent
            for suffix in [".coloranalyze-series.json", ".json"] where name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                break
            }
        }
        return name
    }

    /// Window title: file name, number of photos, and whether there are unsaved changes.
    var title: String {
        baseName + (items.isEmpty ? "" : " — \(items.count) photos") + (isDirty && !items.isEmpty ? " — Edited" : "")
    }

    /// Incremented to ask the app to show the series window (used by the command line).
    private(set) var windowRequest = 0

    var displayItems: [SeriesItem] {
        guard sortByScore else { return items }
        return items.sorted { (consistency[$0.id]?.score ?? 0) < (consistency[$1.id]?.score ?? 0) }
    }

    var averageScore: Int? {
        guard !consistency.isEmpty else { return nil }
        return Int((Double(consistency.values.reduce(0) { $0 + $1.score }) / Double(consistency.count)).rounded())
    }

    func requestWindow() { windowRequest += 1 }

    // MARK: Adding and removing photos

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose the photos of the series (or a folder of photos)"
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// Analyzes every photo in a folder (subfolders are not searched).
    func presentOpenFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder with the photos of the series"
        panel.prompt = "Analyze Folder"
        if panel.runModal() == .OK {
            add(panel.urls)
        }
    }

    /// Adds photos (skipping ones already in the series) and returns a task that finishes when they are analyzed.
    @discardableResult
    func add(_ urls: [URL]) -> Task<Void, Never> {
        let known = Set(items.map(\.url))
        // Folders stand for the photos in them.
        let photos = ImageFolder.expand(urls)
        if photos.isEmpty, !urls.isEmpty {
            errorMessage = "No photos found. A folder is searched for photos directly in it, not in its subfolders."
        }
        let new = photos.filter { !known.contains($0) }
        guard !new.isEmpty else { return Task {} }
        return Task { await load(new) }
    }

    func remove(_ id: SeriesItem.ID) {
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        markEdited()
        recompute()
    }

    func removeAll() {
        items = []
        selectedID = nil
        markEdited()
        recompute()
    }

    private func load(_ urls: [URL]) async {
        let count = colorsPerPhoto
        let strength = weighting.strength
        isBusy = true
        progressDone = 0
        progressTotal = urls.count
        var loaded = [SeriesItem?](repeating: nil, count: urls.count)
        var failed: [String] = []

        // A few photos at a time: RAW decoding is the slow part.
        await withTaskGroup(of: (Int, SeriesItem?).self) { group in
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    (index, await Task.detached(priority: .userInitiated) {
                        try? Self.loadItem(url: url, count: count, strength: strength)
                    }.value)
                }
            }
            for _ in 0..<min(3, urls.count) { enqueue() }
            for await (index, item) in group {
                loaded[index] = item
                progressDone += 1
                enqueue()
            }
        }
        for (url, item) in zip(urls, loaded) {
            if let item { items.append(item) } else { failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty {
            errorMessage = "Could not read: " + failed.joined(separator: ", ")
        }
        if loaded.contains(where: { $0 != nil }) { markEdited() }
        recompute()
        isBusy = false
    }

    // MARK: Analysis

    nonisolated private static func loadItem(url: URL, count: Int, strength: Float) throws -> SeriesItem {
        let image = try ImageLoader.load(url: url)
        let saliency = strength > 0
            ? try? Saliency.attentionMap(for: image.display, width: image.analysis.width, height: image.analysis.height)
            : nil
        return SeriesItem(url: url, thumbnail: thumbnail(of: image.display, maxDimension: 360),
                          analysis: image.analysis, saliency: saliency,
                          colors: dominantColors(in: image.analysis, saliency: saliency, count: count, strength: strength))
    }

    nonisolated private static func dominantColors(in buffer: PixelBuffer, saliency: [Float]?, count: Int,
                                                   strength: Float) -> [SeriesColor] {
        let weights = strength > 0 ? saliency.map { Saliency.weights(for: $0, strength: strength) } : nil
        return DominantColorAnalyzer.analyze(buffer, count: count, weights: weights)
            .map { SeriesColor(centroid: $0.centroid, share: $0.share) }
    }

    nonisolated private static func thumbnail(of image: CGImage, maxDimension: Int) -> CGImage {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Re-derives every photo's colors after the number of colors or the weighting changed.
    private func reanalyze() {
        guard !items.isEmpty, !isBusy else { return }
        let count = colorsPerPhoto
        let strength = weighting.strength
        isBusy = true
        progressDone = 0
        progressTotal = items.count
        Task {
            var updated = items
            for index in updated.indices {
                let item = updated[index]
                if strength > 0, item.saliency == nil {
                    // The subject map needs the photo itself: read it again.
                    let url = item.url
                    if var fresh = await Task.detached(priority: .userInitiated, operation: {
                        try? Self.loadItem(url: url, count: count, strength: strength)
                    }).value {
                        fresh.id = item.id
                        updated[index] = fresh
                    }
                } else {
                    let colors = await Task.detached(priority: .userInitiated) {
                        Self.dominantColors(in: item.analysis, saliency: item.saliency, count: count, strength: strength)
                    }.value
                    updated[index].colors = colors
                }
                progressDone += 1
            }
            items = updated
            recompute()
            isBusy = false
        }
    }

    private func recompute() {
        palette = SeriesAnalyzer.sharedPalette(from: items.map(\.colors), size: paletteSize)
        consistency = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, SeriesAnalyzer.consistency(of: $0.colors, against: palette))
        })
    }

    // MARK: Saving and opening

    func makeFile(savedIn folder: URL) -> SeriesFile {
        SeriesFile(colorsPerPhoto: colorsPerPhoto, paletteSize: paletteSize,
                   weighting: weighting == .off ? nil : weighting.rawValue,
                   hueSpace: hueSpace == .rgb ? nil : hueSpace.rawValue,
                   sortByScore: sortByScore ? true : nil,
                   intention: intention,
                   photos: SeriesFile.photos(items.map(\.url), savedIn: folder))
    }

    /// Writes the series to `url` (which becomes the series' file).
    func save(to url: URL) throws {
        guard !items.isEmpty else { throw ReportError.noPhoto }
        try makeFile(savedIn: url.deletingLastPathComponent()).write(to: url)
        fileURL = url
        isDirty = false
    }

    /// Saves to the current file, or asks where to save when there is none yet.
    func save() {
        if let fileURL {
            write(to: fileURL)
        } else {
            presentSavePanel()
        }
    }

    func presentSavePanel() {
        guard let first = items.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? SeriesFile.defaultFileName
        panel.directoryURL = (fileURL ?? first.url).deletingLastPathComponent()
        panel.message = "Save the list of photos and the settings of this series"
        if panel.runModal() == .OK, let url = panel.url { write(to: url) }
    }

    private func write(to url: URL) {
        do {
            try save(to: url)
        } catch {
            errorMessage = "Could not save the series: \(error.localizedDescription)"
        }
    }

    func presentOpenSeriesPanel() {
        guard confirmReplacingSeries() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a saved series"
        if panel.runModal() == .OK, let url = panel.url { openSeries(url) }
    }

    /// Asks before a series with unsaved changes is replaced.
    func confirmReplacingSeries() -> Bool {
        guard isDirty, !items.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace the current series?"
        alert.informativeText = "\(title) has changes that are not saved."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Replaces the series with a saved one: settings first, then every photo is read and analyzed again.
    @discardableResult
    func openSeries(_ url: URL) -> Task<Void, Never> {
        Task {
            do {
                let file = try SeriesFile.read(from: url)
                isRestoring = true
                items = []
                selectedID = nil
                colorsPerPhoto = min(10, max(3, file.colorsPerPhoto))
                paletteSize = min(12, max(2, file.paletteSize))
                weighting = file.weighting.flatMap(Weighting.init(rawValue:)) ?? .off
                hueSpace = file.hueSpace.flatMap(HueSpace.init(rawValue:)) ?? .rgb
                sortByScore = file.sortByScore ?? false
                intention = file.intention ?? ""
                recompute()
                let resolved = file.resolvedPhotos(folder: url.deletingLastPathComponent())
                await load(resolved.found)
                isRestoring = false
                fileURL = url
                isDirty = !resolved.missing.isEmpty
                if !resolved.missing.isEmpty {
                    let n = resolved.missing.count
                    errorMessage = "\(n) \(n == 1 ? "photo" : "photos") of this series could not be found and "
                        + "\(n == 1 ? "was" : "were") left out: " + resolved.missing.joined(separator: ", ")
                        + ". Save the series to forget \(n == 1 ? "it" : "them")."
                }
            } catch {
                isRestoring = false
                errorMessage = "Could not open the series: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Export

    func seriesExport() -> SeriesExport? {
        guard !items.isEmpty else { return nil }
        return SeriesExport(
            intention: intention,
            settings: .init(colorsPerPhoto: colorsPerPhoto, paletteSize: paletteSize,
                            weighting: weighting == .off ? nil : weighting.rawValue),
            palette: palette,
            photos: items.map { ($0.url.lastPathComponent, $0.url.path, $0.colors) }
        )
    }

    /// Everything the PNG overview shows, in the order the photos are listed on screen.
    func reportData() -> SeriesReportData? {
        guard !items.isEmpty else { return nil }
        return SeriesReportData(
            date: Date(),
            photos: displayItems.map { item in
                SeriesReportData.Photo(
                    name: item.url.lastPathComponent,
                    thumbnail: item.thumbnail,
                    colors: item.colors,
                    consistency: consistency[item.id] ?? SeriesAnalyzer.consistency(of: item.colors, against: palette))
            },
            palette: palette,
            colorsPerPhoto: colorsPerPhoto,
            weighting: weighting == .off ? nil : weighting.title,
            hueSpace: hueSpace,
            averageScore: averageScore,
            intention: Intention.cleaned(intention)
        )
    }

    func export(to url: URL, kind: SeriesExportKind) throws {
        if kind == .reportPNG {
            guard let data = reportData() else { throw ReportError.noPhoto }
            guard let png = ReportRenderer.pngData(for: data) else { throw ReportError.renderFailed }
            try png.write(to: url, options: .atomic)
            return
        }
        if kind == .paletteASE {
            guard !palette.isEmpty else { throw ReportError.noPhoto }
            let swatches = palette.enumerated().map { ("\($0.offset + 1) – \($0.element.color.hex)", $0.element.color) }
            try AdobeSwatchExchange.data(groupName: baseName + " – ColorAnalyze", swatches: swatches).write(to: url, options: .atomic)
            return
        }
        guard let export = seriesExport() else { throw ReportError.noPhoto }
        let style: ColorExport.CSVStyle = excelCSV ? .europeanExcel : .standard
        switch kind {
        case .reportPNG, .paletteASE: break
        case .json: try export.json().write(to: url, options: .atomic)
        case .paletteCSV: try Data(export.paletteCSV(style: style).utf8).write(to: url, options: .atomic)
        case .photosCSV: try Data(export.photosCSV(style: style).utf8).write(to: url, options: .atomic)
        }
    }

    func presentExportPanel(_ kind: SeriesExportKind) {
        guard let first = items.first else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind.contentType]
        panel.nameFieldStringValue = kind.fileName + "." + kind.fileExtension
        panel.directoryURL = first.url.deletingLastPathComponent()
        panel.message = kind.message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export(to: url, kind: kind)
        } catch {
            errorMessage = "Could not export: \(error.localizedDescription)"
        }
    }
}
