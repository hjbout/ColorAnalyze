import AppKit
import ColorCore
import SwiftUI

@main
struct ColorAnalyzeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ColorAnalyze", id: "main") {
            ContentView()
                .environment(delegate.model)
                .environment(delegate.series)
        }
        .commands {
            SeriesCommands(series: delegate.series)
            CommandGroup(replacing: .newItem) {
                Button("Open…") { delegate.model.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Open Graded Version…") { delegate.model.presentOpenPanel(graded: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Session") { delegate.model.saveSession() }
                    .keyboardShortcut("s")
                Button("Export Report as PNG…") { delegate.model.presentExportPanel(.reportPNG) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export Color List as CSV…") { delegate.model.presentExportPanel(.colorsCSV) }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                Button("Export Color List as CSV for Excel (;)…") { delegate.model.presentExportPanel(.colorsCSVExcel) }
                    .keyboardShortcut("e", modifiers: [.command, .control])
                Button("Export Color List as JSON…") { delegate.model.presentExportPanel(.colorsJSON) }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                Button("Export Color Palette as Swatches (.ase)…") { delegate.model.presentExportPanel(.swatches) }
                Button("Export Color Palette as PNG…") { delegate.model.presentExportPanel(.palettePNG) }
                Button("Export DxO Color Grading Preset…") { delegate.model.presentExportPanel(.dxoPreset) }
            }
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Zoom In") { delegate.model.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { delegate.model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Fit Photo") { delegate.model.fitPhoto() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Actual Pixels") { delegate.model.zoomToActualPixels() }
                    .keyboardShortcut("1", modifiers: .command)
                Divider()
            }
            CommandMenu("Analysis") {
                Button("Suggest Marker for a Missing Color") { delegate.model.suggestMarker() }
                    .keyboardShortcut("m", modifiers: [.command, .option])
                Button("Deselect Color") { delegate.model.selectedMarkerID = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(delegate.model.selectedMarkerID == nil)
                Divider()
                Picker("Subject Weighting", selection: Bindable(delegate.model).weighting) {
                    ForEach(Weighting.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show Subject Map", isOn: Bindable(delegate.model).showSaliency)
                    .keyboardShortcut("m", modifiers: [])
                Toggle("Show Skin Tone Line", isOn: Bindable(delegate.model).showSkinTone)
                Toggle("Show Series Palette", isOn: Bindable(delegate.model).showSeriesReference)
                Picker("Color Wheel", selection: Bindable(delegate.model).hueSpace) {
                    ForEach(HueSpace.allCases) { Text($0.displayName).tag($0) }
                }
            }
            CommandMenu("Compare") {
                Button("Open Reference Photo…") { delegate.model.presentOpenReferencePanel() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Remove Reference Photo") { delegate.model.clearReference() }
                    .disabled(delegate.model.referencePhoto == nil)
                Divider()
                Button("Toggle Before / After") { delegate.model.toggleBeforeAfter() }
                    .keyboardShortcut("\\", modifiers: [])
                Button("Toggle Regions") { delegate.model.showRegions.toggle() }
                    .keyboardShortcut("g", modifiers: [])
                Button("Toggle Preview of the Suggestion") { delegate.model.togglePreview() }
                    .keyboardShortcut("p", modifiers: [])
                Toggle("Show Preview Below the Original", isOn: Binding(
                    get: { delegate.model.previewLayout == .stacked },
                    set: { delegate.model.previewLayout = $0 ? .stacked : .split }))
                Divider()
                Button("Close Comparison") { delegate.model.clearGraded() }
            }
        }

        Window("Series", id: "series") {
            SeriesView()
                .environment(delegate.series)
                .environment(delegate.model)
        }
    }
}

/// Menu items that open the series window.
struct SeriesCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let series: SeriesModel

    var body: some Commands {
        CommandMenu("Series") {
            Button("Show Series Window") { openWindow(id: "series") }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Analyze Series…") {
                openWindow(id: "series")
                series.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            Button("Analyze Folder…") {
                openWindow(id: "series")
                series.presentOpenFolderPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .option, .shift])
            Divider()
            Button("Open Series…") {
                openWindow(id: "series")
                series.presentOpenSeriesPanel()
            }
            .keyboardShortcut("o", modifiers: [.command, .control])
            Button("Save Series") { series.save() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Save Series As…") { series.presentSavePanel() }
                .keyboardShortcut("s", modifiers: [.command, .control, .shift])
            Divider()
            Button("Export Series Overview as PNG…") { series.presentExportPanel(.reportPNG) }
                .keyboardShortcut("e", modifiers: [.command, .shift, .control])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AnalysisModel()
    let series = SeriesModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.series = series
        // Needed when started via `swift run` (no bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // `ColorAnalyze photo.jpg [--graded graded.jpg] [--reference look.jpg] [--add-missing N] [--export-report report.png]
        //     [--export-colors list.csv|list.json] [--export-colors-excel list.csv]
        //     [--weighting off|moderate|strong] [--wheel rgb|ryb|dxo|oklch] [--intention "warm, calm"]
        //     [--export-dxo-preset grading.preset] [--grading-strength subtle|moderate|strong] [--grading-style neutral|warm-highlights|cool-highlights|teal-orange|warm-overall|cool-overall|faded]
        //     [--grading-target harmony|series|reference] [--protect 2,5] [--harmony-sector exact|narrow|wide]`
        // `ColorAnalyze --series a.jpg b.jpg … [--series-colors N] [--palette-size N]
        //     [--export-series palette.csv|series.json] [--export-series-photos photos.csv]
        //     [--export-series-report overview.png]`
        // `ColorAnalyze --open-series saved.json [--save-series new.json] …` opens a saved series.
        // Photos listed in --series are added to it.
        // With an export option the files are written and the app quits, which is handy for batch use.
        let argv = Array(CommandLine.arguments.dropFirst())
        var i = 0
        func value() -> String? {
            guard i < argv.count else { return nil }
            defer { i += 1 }
            return argv[i]
        }
        var photo: String?, graded: String?, report: String?, reference: String?
        var photoColors: Int?
        var protectedNumbers: [Int] = []
        var sector: HarmonySector?
        var problems: [String] = []
        /// Parses an enum-like option value; a wrong one is reported instead of silently ignored.
        func choice<T>(_ option: String, _ parse: (String) -> T?) -> T? {
            guard let text = value() else { problems.append("\(option) needs a value"); return nil }
            if let result = parse(text) { return result }
            problems.append("\(option): unknown value “\(text)”")
            return nil
        }
        var addMissing = 0
        var weighting: Weighting?
        var wheel: HueSpace?
        var colors: [(path: String, format: ExportFormat?)] = []
        var seriesFiles: [String] = []
        var seriesExports: [(path: String, kind: SeriesExportKind)] = []
        var colorsPerPhoto: Int?, paletteSize: Int?
        var openSeriesPath: String?, saveSeriesPath: String?
        var intention: String?
        var gradingStrength: ColorGradingSuggestion.Strength?
        var gradingStyle: GradingStyle?
        var gradingTarget: AnalysisModel.GradingTarget?
        while i < argv.count {
            let arg = argv[i]
            i += 1
            switch arg {
            case "--graded": graded = value()
            case "--reference": reference = value()
            case "--add-missing": addMissing = min(12, max(0, value().flatMap(Int.init) ?? 0))
            case "--protect":
                protectedNumbers = choice(arg) { text in
                    let numbers = text.split(separator: ",").compactMap { Int($0) }
                    return numbers.count == text.split(separator: ",").count ? numbers : nil
                } ?? []
            case "--harmony-sector": sector = choice(arg) { HarmonySector(rawValue: $0.lowercased()) }
            case "--colors": photoColors = choice(arg) { Int($0).flatMap { (3...12).contains($0) ? $0 : nil } }
            case "--weighting": weighting = choice(arg) { Weighting(rawValue: $0.lowercased()) }
            case "--wheel": wheel = choice(arg) { HueSpace(rawValue: $0.lowercased()) }
            case "--export-report": report = value()
            case "--export-colors": if let path = value() { colors.append((path, nil)) }
            case "--export-colors-excel": if let path = value() { colors.append((path, .colorsCSVExcel)) }
            case "--export-dxo-preset": if let path = value() { colors.append((path, .dxoPreset)) }
            case "--grading-strength":
                gradingStrength = choice(arg) { ColorGradingSuggestion.Strength(rawValue: $0.lowercased()) }
            case "--grading-style":
                gradingStyle = choice(arg) { text in
                    GradingStyle.allCases.first { $0.rawValue.lowercased() == text.lowercased().replacingOccurrences(of: "-", with: "") }
                }
            case "--grading-target":
                gradingTarget = choice(arg) { $0.lowercased() == "reference" ? .series : AnalysisModel.GradingTarget(rawValue: $0.lowercased()) }
            case "--series":
                while i < argv.count, !argv[i].hasPrefix("--") {
                    seriesFiles.append(argv[i])
                    i += 1
                }
            case "--intention": intention = value()
            case "--open-series": openSeriesPath = value()
            case "--save-series": saveSeriesPath = value()
            case "--series-colors": colorsPerPhoto = value().flatMap(Int.init)
            case "--palette-size": paletteSize = value().flatMap(Int.init)
            case "--export-series":
                if let path = value() { let lower = path.lowercased()
                    seriesExports.append((path, lower.hasSuffix(".json") ? .json
                                          : lower.hasSuffix("." + AdobeSwatchExchange.fileExtension) ? .paletteASE : .paletteCSV)) }
            case "--export-series-report":
                if let path = value() { seriesExports.append((path, .reportPNG)) }
            case "--export-series-photos":
                if let path = value() { seriesExports.append((path, .photosCSV)) }
            default:
                if arg.hasPrefix("-") { problems.append("unknown option \(arg)") }
                else if photo == nil { photo = arg }
                else { problems.append("unexpected argument \(arg)") }
            }
        }

        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        let hasExports = report != nil || !colors.isEmpty || !seriesExports.isEmpty || saveSeriesPath != nil
        var tasks: [Task<Void, Never>] = []
        // Batch runs must not depend on what was last chosen in the window: start from the defaults.
        if hasExports {
            model.withoutRemembering {
                model.colorCount = 6
                model.hueSpace = .rgb
                model.harmonySector = .narrow
                model.weighting = .off
                model.gradingStyle = .neutral
                model.showPreview = false
            }
            model.useGradingStrength(.moderate)
        }
        for path in [photo, graded, reference].compactMap({ $0 }) + seriesFiles + [openSeriesPath].compactMap({ $0 })
        where !exists(path) { problems.append("file not found: \(path)") }
        if hasExports, !problems.isEmpty {
            for problem in problems { FileHandle.standardError.write(Data("ColorAnalyze: \(problem)\n".utf8)) }
            exit(2)
        }
        if let photoColors { model.withoutRemembering { model.colorCount = photoColors } }
        if let sector { model.withoutRemembering { model.harmonySector = sector } }
        let openedPhoto = photo.flatMap { exists($0) ? $0 : nil }
        if let openedPhoto {
            tasks.append(model.open(URL(fileURLWithPath: openedPhoto),
                                    graded: graded.flatMap { exists($0) ? URL(fileURLWithPath: $0) : nil },
                                    weighting: weighting))
            // After the photo is open, so the reference palette has the photo's number of colors.
            if let reference, exists(reference), let photoTask = tasks.last {
                tasks.append(Task {
                    await photoTask.value
                    await model.openReference(URL(fileURLWithPath: reference)).value
                })
            }
        }
        let seriesURLs = seriesFiles.filter(exists).map { URL(fileURLWithPath: $0) }
        let openedSeries = openSeriesPath.flatMap { exists($0) ? URL(fileURLWithPath: $0) : nil }
        let openTask = openedSeries.map { series.openSeries($0) }
        if let openTask { tasks.append(openTask) }
        if !seriesURLs.isEmpty {
            if let colorsPerPhoto { series.colorsPerPhoto = min(10, max(3, colorsPerPhoto)) }
            if let paletteSize { series.paletteSize = min(12, max(2, paletteSize)) }
            if let weighting { series.weighting = weighting }
            // After a saved series has been read, so its photos come first.
            tasks.append(Task {
                if let openTask { await openTask.value }
                await series.add(seriesURLs).value
            })
        }
        guard !tasks.isEmpty else { return }

        Task {
            for task in tasks { await task.value }
            // Settings given on the command line apply once everything is loaded.
            if let wheel {
                model.withoutRemembering { model.hueSpace = wheel }
                series.hueSpace = wheel
            }
            if let intention {
                model.intention = intention
                series.intention = intention
            }
            for _ in 0..<addMissing { await model.suggestMarker().value }
            for number in protectedNumbers where model.markers.indices.contains(number - 1) && !model.markers[number - 1].isProtected {
                model.toggleProtected(model.markers[number - 1].id)
            }
            if let gradingStrength { model.useGradingStrength(gradingStrength) }
            if let gradingStyle { model.withoutRemembering { model.gradingStyle = gradingStyle } }
            if let gradingTarget { model.gradingTarget = gradingTarget }
            guard hasExports else {
                if !seriesURLs.isEmpty || openedSeries != nil { series.requestWindow() }
                return
            }
            do {
                if openedPhoto != nil {
                    if let report { try model.exportReport(to: URL(fileURLWithPath: report)) }
                    for (path, format) in colors {
                        let url = URL(fileURLWithPath: path)
                        try model.exportColors(to: url, format: format ?? .forColorList(at: url))
                    }
                }
                for (path, kind) in seriesExports {
                    try series.export(to: URL(fileURLWithPath: path), kind: kind)
                }
                if let saveSeriesPath { try series.save(to: URL(fileURLWithPath: saveSeriesPath)) }
            } catch {
                FileHandle.standardError.write(Data("Export failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
            NSApp.terminate(nil)
        }
    }

    /// Finder "Open With" and drops on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
