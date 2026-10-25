import ColorCore
import SwiftUI

struct ContentView: View {
    @Environment(AnalysisModel.self) private var model
    @Environment(SeriesModel.self) private var series
    @Environment(\.openWindow) private var openWindow
    /// The window's undo manager: Edit ▸ Undo / Redo for marker changes (and for typing in text fields).
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        HSplitView {
            PhotoMarkerView()
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            // The wheel and the list keep the width they have at the smallest window; a bigger window gives the photo more room.
            ColorListView()
                .frame(minWidth: 360, idealWidth: 360, maxWidth: 360, maxHeight: .infinity)
            ColorWheelView()
                .frame(minWidth: 360, idealWidth: 360, maxWidth: 360, maxHeight: .infinity)
        }
        .frame(minWidth: 1100, minHeight: 640)
        .onChange(of: series.windowRequest) { openWindow(id: "series") }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .navigationTitle(model.image.map { $0.url.lastPathComponent + (model.isDirty ? " — Edited" : "") } ?? "ColorAnalyze")
        .overlay {
            if model.isAnalyzing {
                ProgressView("Analyzing…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
        .alert("Cannot Open Photo", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .toolbar {
            // File: open, keep, hand over.
            ToolbarItemGroup {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a photo (⌘O)")

                Button {
                    model.saveSession()
                } label: {
                    Label("Save Session", systemImage: "square.and.arrow.down")
                }
                .disabled(model.image == nil)
                .help("Save markers and settings next to the photo (⌘S)")

                Menu {
                    Button("Report as PNG…") { model.presentExportPanel(.reportPNG) }
                    Divider()
                    Button("Color List as CSV…") { model.presentExportPanel(.colorsCSV) }
                    Button("Color List as CSV for Excel (;)…") { model.presentExportPanel(.colorsCSVExcel) }
                    Button("Color List as JSON…") { model.presentExportPanel(.colorsJSON) }
                    Divider()
                    Button("Palette as Swatches (.ase)…") { model.presentExportPanel(.swatches) }
                    Button("Palette as PNG…") { model.presentExportPanel(.palettePNG) }
                    Divider()
                    Button("DxO Color Grading Preset…") { model.presentExportPanel(.dxoPreset) }
                        .disabled(model.colorGrading == nil)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(model.image == nil)
                .help("Export a PNG report, or the color list as CSV or JSON")
            }

            ToolbarGap()

            // Analysis: how the colors are found.
            ToolbarItemGroup {
                CountStepper(title: "Colors", value: $model.colorCount, range: 3...12,
                             help: "Number of dominant colors to find")
                    .disabled(model.image == nil)

                Menu {
                    Picker("Subject Weighting", selection: $model.weighting) {
                        ForEach(Weighting.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Show Subject Map", isOn: $model.showSaliency)
                } label: {
                    Label("Subject", systemImage: model.weighting == .off ? "viewfinder" : "viewfinder.circle.fill")
                }
                .disabled(model.image == nil)
                .help("Let the subject count more than the background. Changing the weighting re-analyzes the photo and resets the markers.")
            }

            ToolbarGap()

            // View: what the photo shows.
            ToolbarItemGroup {
                Menu {
                    Button("Fit Photo") { model.fitPhoto() }
                    Button("Actual Pixels") { model.zoomToActualPixels() }
                    Divider()
                    Button("Zoom In") { model.zoomIn() }
                    Button("Zoom Out") { model.zoomOut() }
                        .disabled(!model.viewport.isZoomed)
                    Divider()
                    ForEach([2, 4, 8, 16], id: \.self) { level in
                        Button("\(level)×") { model.setZoomLevel(CGFloat(level)) }
                    }
                } label: {
                    Label(model.zoomLabel, systemImage: "magnifyingglass")
                }
                .disabled(model.image == nil)
                .help("Zoom level (⌘+ / ⌘− / ⌘0). Pinch or ⌘-scroll zooms; scroll or drag moves the photo.")

                if model.afterImage != nil {
                    Picker("View", selection: $model.compareMode) {
                        ForEach(CompareMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help("Show the original, the graded version, or a split (\\ toggles)")

                    Button {
                        model.clearGraded()
                    } label: {
                        Label("Close Comparison", systemImage: "xmark.circle")
                    }
                    .help("Close the graded version")
                }
            }

            ToolbarGap()

            // Markers: edit the sampled colors.
            ToolbarItemGroup {
                Button {
                    model.addMarker(at: CGPoint(x: 0.5, y: 0.5))
                } label: {
                    Label("Add Marker", systemImage: "plus.circle")
                }
                .disabled(model.image == nil)
                .help("Add a marker (or double-click the photo)")

                Button {
                    model.suggestMarker()
                } label: {
                    Label("Suggest Marker", systemImage: "wand.and.stars")
                }
                .disabled(model.image == nil || model.isAnalyzing)
                .help("Add a marker on the color that no marker represents yet — a small subject or accent the analysis passed over (⌥⌘M)")

                if model.selectedMarkerID != nil {
                    Button {
                        model.removeMarker(model.selectedMarkerID)
                    } label: {
                        Label("Remove Marker", systemImage: "minus.circle")
                    }
                    .keyboardShortcut(.delete, modifiers: [])
                    .help("Remove the selected marker (⌫)")
                }
            }

            ToolbarGap()

            // Another window.
            ToolbarItem {
                Button {
                    openWindow(id: "series")
                } label: {
                    Label("Series", systemImage: "square.grid.3x3")
                }
                .help("Analyze several photos together and compare them with a shared palette (⇧⌘S)")
            }
        }
    }
}
