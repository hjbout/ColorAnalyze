import ColorCore
import SwiftUI

/// The series window: photos with their palettes and consistency on the left, every color on a
/// wheel in the middle, the shared palette on the right.
struct SeriesView: View {
    @Environment(SeriesModel.self) private var series
    @Environment(AnalysisModel.self) private var analyzer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var series = series
        Group {
            if series.items.isEmpty {
                emptyState
            } else {
                HSplitView {
                    SeriesPhotoList(open: openInAnalyzer)
                        .frame(minWidth: 380, idealWidth: 440, maxWidth: 560, maxHeight: .infinity)
                    SeriesWheelView()
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560, maxHeight: .infinity)
                    SeriesPaletteView()
                        .frame(minWidth: 340, idealWidth: 400, maxWidth: 520, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 640)
        .navigationTitle(series.title)
        .overlay {
            if series.isBusy {
                ProgressView("Analyzing \(min(series.progressDone + 1, max(1, series.progressTotal))) of \(series.progressTotal)…")
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            // A saved series dropped on its own: open it. Photos: add them.
            let saved = urls.filter { $0.pathExtension.lowercased() == "json" }
            if saved.count == 1, saved.count == urls.count {
                if series.confirmReplacingSeries() { series.openSeries(saved[0]) }
            } else {
                series.add(urls.filter { $0.pathExtension.lowercased() != "json" })
            }
            return !urls.isEmpty
        }
        .alert("Series", isPresented: Binding(
            get: { series.errorMessage != nil },
            set: { if !$0 { series.errorMessage = nil } }
        )) {
            Button("OK") { series.errorMessage = nil }
        } message: {
            Text(series.errorMessage ?? "")
        }
        .toolbar {
            // The series as a file.
            ToolbarItemGroup {
                Button {
                    series.presentOpenSeriesPanel()
                } label: {
                    Label("Open Series", systemImage: "folder")
                }
                .disabled(series.isBusy)
                .help("Open a saved series (⌃⌘O)")

                Button {
                    series.save()
                } label: {
                    Label("Save Series", systemImage: "square.and.arrow.down")
                }
                .disabled(series.items.isEmpty || series.isBusy)
                .help("Save the photo list and settings of this series (⌃⌘S)")
            }

            ToolbarGap()

            // Photos in the series.
            ToolbarItemGroup {
                Button {
                    series.presentOpenPanel()
                } label: {
                    Label("Add Photos", systemImage: "plus.rectangle.on.rectangle")
                }
                .disabled(series.isBusy)
                .help("Add photos to the series")

                Button {
                    if let id = series.selectedID { series.remove(id) }
                } label: {
                    Label("Remove Photo", systemImage: "minus.rectangle")
                }
                .disabled(series.selectedID == nil || series.isBusy)
                .help("Remove the selected photo from the series")
            }

            ToolbarGap()

            // Analysis: how the colors and the shared palette are found.
            ToolbarItemGroup {
                CountStepper(title: "Colors", value: $series.colorsPerPhoto, range: 3...10,
                             help: "Dominant colors found in each photo")
                    .disabled(series.items.isEmpty || series.isBusy)

                CountStepper(title: "Palette", value: $series.paletteSize, range: 2...12,
                             help: "Colors in the shared palette")
                    .disabled(series.items.isEmpty)

                Menu {
                    Picker("Subject Weighting", selection: $series.weighting) {
                        ForEach(Weighting.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Subject", systemImage: series.weighting == .off ? "viewfinder" : "viewfinder.circle.fill")
                }
                .disabled(series.isBusy)
                .help("Let the subject of each photo count more than its background")
            }

            ToolbarGap()

            // View.
            ToolbarItem {
                Toggle(isOn: $series.sortByScore) {
                    Label("Sort by Score", systemImage: "arrow.up.arrow.down")
                }
                .disabled(series.items.isEmpty)
                .help("List the least consistent photos first")
            }

            ToolbarGap()

            // Hand over.
            ToolbarItem {
                Menu {
                    Button("Overview as PNG…") { series.presentExportPanel(.reportPNG) }
                    Divider()
                    Button("Series as JSON…") { series.presentExportPanel(.json) }
                    Divider()
                    Button("Shared Palette as CSV…") { series.presentExportPanel(.paletteCSV) }
                    Button("Shared Palette as Swatches (.ase)…") { series.presentExportPanel(.paletteASE) }
                    Button("Photo Table as CSV…") { series.presentExportPanel(.photosCSV) }
                    Toggle("CSV for Excel (;)", isOn: $series.excelCSV)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(series.items.isEmpty || series.isBusy)
                .help("Export the palette and the per-photo table")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.square")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Drop the photos of a series here")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("The shared palette shows what the photos have in common, and each photo gets a score and a starting point for aligning it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack {
                Button("Add Photos…") { series.presentOpenPanel() }
                Button("Open Series…") { series.presentOpenSeriesPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func openInAnalyzer(_ url: URL) {
        openWindow(id: "main")
        analyzer.open(url)
    }
}

// MARK: - Photos

private struct SeriesPhotoList: View {
    @Environment(SeriesModel.self) private var series
    let open: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(series.displayItems) { item in
                    SeriesPhotoCard(item: item, consistency: series.consistency[item.id],
                                    isSelected: item.id == series.selectedID)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(item.url) }
                        .onTapGesture { series.selectedID = item.id }
                        .contextMenu {
                            Button("Open in Analyzer") { open(item.url) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                            Divider()
                            Button("Remove from Series") { series.remove(item.id) }
                        }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }
}

private struct SeriesPhotoCard: View {
    let item: SeriesItem
    let consistency: PhotoConsistency?
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(decorative: item.thumbnail, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 124, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.url.lastPathComponent)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let consistency { ScoreBadge(score: consistency.score) }
                }
                PaletteStrip(colors: item.colors)
                    .frame(height: 14)
                if let consistency {
                    Text(summary(consistency))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if consistency.hasSuggestion {
                        Text(seriesSuggestion(consistency) ?? "Matches the series")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(seriesSuggestion(consistency) == nil ? .green : .primary)
                            .help("A starting point for aligning this photo with the series: hue rotation, saturation and lightness change.")
                    } else {
                        Text("Too different from the series to suggest an alignment")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
    }

    private func summary(_ c: PhotoConsistency) -> String {
        String(format: "Δ %.3f · %.0f%% without a counterpart in the palette", c.meanDeltaE, c.unmatchedShare * 100)
    }
}

/// "Hue +4° · Saturation +6% · Lightness -2", or nil when the photo already fits.
func seriesSuggestion(_ c: PhotoConsistency) -> String? {
    var parts: [String] = []
    if let hue = c.hueShift, abs(hue) >= 1 { parts.append("Hue \(signedRounded(hue, unit: "°"))") }
    if abs(c.saturationChange) >= 2 { parts.append("Saturation \(signedRounded(c.saturationChange, unit: "%"))") }
    if abs(c.lightnessChange) >= 1 { parts.append("Lightness \(signedRounded(c.lightnessChange))") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

struct ScoreBadge: View {
    let score: Int

    var body: some View {
        Text("\(score)")
            .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(score >= 80 ? Color.green : score >= 60 ? Color.orange : Color.red, in: Capsule())
            .help("Consistency with the series palette (100 = identical colors)")
    }
}

/// A photo's dominant colors as one bar, each color as wide as its share.
struct PaletteStrip: View {
    let colors: [SeriesColor]

    var body: some View {
        GeometryReader { geo in
            let total = max(0.0001, colors.reduce(0) { $0 + $1.share })
            HStack(spacing: 0) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Rectangle()
                        .fill(color.color.swiftUIColor)
                        .frame(width: geo.size.width * color.share / total)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.2)))
        }
    }
}

// MARK: - Wheel

private struct SeriesWheelView: View {
    @Environment(SeriesModel.self) private var series

    var body: some View {
        @Bindable var series = series
        VStack(spacing: 14) {
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height) - 48
                let radius = side / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let space = series.hueSpace
                ZStack {
                    Image(decorative: WheelGeometry.wheelImage(for: space), scale: 1)
                        .resizable()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.25), radius: 6)
                        .position(center)

                    // Every color of every photo as a small dot. The selected photo is drawn on top of the
                    // palette badges, linked to the palette colors it was matched with.
                    ForEach(series.items.filter { $0.id != series.selectedID }) { item in
                        dots(for: item, selected: false, space: space, center: center, radius: radius)
                    }

                    ForEach(Array(series.palette.enumerated()), id: \.offset) { index, shared in
                        MarkerBadge(number: index + 1, color: shared.color, diameter: 22 + 30 * sqrt(shared.share))
                            .position(position(shared.color, space, center, radius))
                            .help(String(format: "%@ · in %d of %d photos", shared.color.hex, shared.presence, shared.photoCount))
                    }

                    if let item = series.items.first(where: { $0.id == series.selectedID }) {
                        if let matches = series.consistency[item.id]?.matches {
                            Path { path in
                                for (color, match) in zip(item.colors, matches) {
                                    guard let match, series.palette.indices.contains(match) else { continue }
                                    path.move(to: position(color.color, space, center, radius))
                                    path.addLine(to: position(series.palette[match].color, space, center, radius))
                                }
                            }
                            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .allowsHitTesting(false)
                        }
                        dots(for: item, selected: true, space: space, center: center, radius: radius)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Picker("Wheel", selection: $series.hueSpace) {
                ForEach(HueSpace.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            IntentionField(title: "Intention for the series", placeholder: "What should the series feel like?",
                           text: $series.intention)
                .padding(.horizontal, 24)

            VStack(spacing: 4) {
                if let average = series.averageScore {
                    Text("Average consistency \(average)")
                        .font(.headline)
                }
                Text("Large badges are the shared palette; small dots are the colors of each photo. Select a photo to see which palette colors it matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func dots(for item: SeriesItem, selected: Bool, space: HueSpace, center: CGPoint, radius: CGFloat) -> some View {
        let dimmed = series.selectedID != nil && !selected
        ForEach(Array(item.colors.enumerated()), id: \.offset) { _, color in
            let diameter = 7 + 14 * sqrt(color.share)
            Circle()
                .fill(color.color.swiftUIColor)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .white, lineWidth: selected ? 2.5 : 1))
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .opacity(dimmed ? 0.35 : 0.9)
                .position(position(color.color, space, center, radius))
                .allowsHitTesting(false)
        }
    }

    private func position(_ color: SRGBColor, _ space: HueSpace, _ center: CGPoint, _ radius: CGFloat) -> CGPoint {
        let hsb = color.hsb
        return WheelGeometry.point(rgbHue: hsb.h, space: space, saturation: hsb.s, center: center, radius: radius)
    }
}

// MARK: - Palette

private struct SeriesPaletteView: View {
    @Environment(SeriesModel.self) private var series

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Shared palette")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 8)
                if series.items.count < 2 {
                    Text("Add at least two photos to see what they share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                let maxShare = max(0.01, series.palette.map(\.share).max() ?? 0.01)
                ForEach(Array(series.palette.enumerated()), id: \.offset) { index, shared in
                    Divider()
                    PaletteRow(number: index + 1, shared: shared, maxShare: maxShare)
                        .padding(.vertical, 8)
                }
                Text("Presence counts the photos that have a color within a small distance of the palette color. DxO channels are approximations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
            .padding(14)
        }
    }
}

struct PaletteRow: View {
    let number: Int
    let shared: SharedColor
    let maxShare: Double

    var body: some View {
        let color = shared.color
        let hsl = color.hsl, rgb = color.rgb255
        let channel = DxOMapping.channel(for: color)
        HStack(alignment: .top, spacing: 10) {
            MarkerBadge(number: number, color: color, diameter: 22)
            RoundedRectangle(cornerRadius: 6)
                .fill(color.swiftUIColor)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.2)))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(color.hex)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text(String(format: "RGB %d %d %d · HSL %.0f° %.0f%% %.0f%%", rgb.r, rgb.g, rgb.b, hsl.h, hsl.s * 100, hsl.l * 100))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("DxO \(channel == .neutral ? "Neutral" : channel.displayName) · "
                     + String(format: "%@ (L* %.0f)", DxOMapping.tonalRange(for: color).displayName, color.lightness))
                    .font(.caption)
                if color.isOutsideSRGB {
                    let p3 = color.displayP3RGB255
                    Text("Outside sRGB · Display P3 \(p3.r) \(p3.g) \(p3.b)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("In \(shared.presence) of \(shared.photoCount) photos")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(shared.photoCount > 1 && Double(shared.presence) / Double(shared.photoCount) < 0.5 ? .orange : .green)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f%%", shared.share * 100))
                    .font(.headline.monospacedDigit())
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color.swiftUIColor).frame(width: max(4, 56 * shared.share / maxShare))
                }
                .frame(width: 56, height: 6)
            }
        }
    }
}
