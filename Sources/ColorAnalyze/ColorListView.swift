import AppKit
import ColorCore
import SwiftUI

/// Remembers which color was selected when the mouse went down, before the list applies the click.
@MainActor private final class MouseDownMonitor {
    static let shared = MouseDownMonitor()
    private var monitor: Any?

    func start(_ model: AnalysisModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated { model.selectionAtMouseDown = model.selectedMarkerID }
            return event
        }
    }
}

/// Keys 1–9 toggle the color with that number. A monitor takes them before the list's type-to-select does, which
/// jumped to a row by its typed number only some of the time.
@MainActor private final class DigitKeyMonitor {
    static let shared = DigitKeyMonitor()
    private var monitor: Any?

    func start(_ model: AnalysisModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let used = MainActor.assumeIsolated { Self.handle(event, model) }
            return used ? nil : event
        }
    }

    private static func handle(_ event: NSEvent, _ model: AnalysisModel) -> Bool {
        guard event.window != nil, event.window === NSApp.keyWindow, !event.isARepeat,
              !(event.window?.firstResponder is NSText),
              let key = event.charactersIgnoringModifiers, key.count == 1, let number = Int(key) else { return false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .option {
            // ⌥1, ⌥2, ⌥4: the preview amount. Taken here as well, or the list reads the digit as a type-to-select first.
            guard [1, 2, 4].contains(number) else { return false }
            model.previewAmount = Double(number)
            return true
        }
        guard flags.isEmpty, (1...9).contains(number), model.markers.indices.contains(number - 1) else { return false }
        let id = model.markers[number - 1].id
        model.selectedMarkerID = model.selectedMarkerID == id ? nil : id
        return true
    }
}

struct ColorListView: View {
    @Environment(AnalysisModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let fit = model.harmony
        List(selection: $model.selectedMarkerID) {
            Section {
                ForEach(Array(model.markers.enumerated()), id: \.element.id) { index, marker in
                    ColorRow(number: index + 1, marker: marker, isProtected: model.isProtected(marker), protectionNote: model.protectionNote(for: marker), harmony: fit,
                             after: model.afterColor(for: marker), series: model.seriesInfo(for: marker), referenceTitle: model.referenceTitle, afterLabel: model.afterLabel)
                        .tag(marker.id)
                        // The whole row is the click target, also its empty parts and the text.
                        .contentShape(Rectangle())
                        .onHover { model.hover(marker.id, inside: $0) }
                        // A click selects the color; a plain click on the selected color deselects it, like a command-click.
                        .simultaneousGesture(TapGesture().onEnded {
                            // The row's trash button may just have removed the color.
                            guard model.markers.contains(where: { $0.id == marker.id }) else { return }
                            model.selectedMarkerID = model.selectionAtMouseDown == marker.id ? nil : marker.id
                        })
                        .contextMenu {
                            Button("Copy Hex") { copy(marker.color.hex) }
                            ReferenceMatchMenu(markerID: marker.id)
                        }
                }
                // The notes under the list are rows of their own, so they wrap and are never cut off (a Section footer is).
                if model.isWeighted || !model.markers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.isWeighted {
                            Text("Percentages are weighted toward the subject (\(model.weighting.title)), so the list favors what the viewer looks at.")
                        }
                        if !model.markers.isEmpty {
                            Text("DxO channels and target hues are approximations — use them as a starting point in the HSL tool (Color Wheel) and the Color Grading tool.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(model.markers.isEmpty ? "Colors" : "Colors (\(model.markers.count))")
            }
        }
        .listStyle(.inset)
        .onAppear {
            MouseDownMonitor.shared.start(model)
            DigitKeyMonitor.shared.start(model)
        }
    }
}

private struct ColorRow: View {
    @Environment(AnalysisModel.self) private var model
    let number: Int
    let marker: Marker
    let isProtected: Bool
    /// Set when the suggestions leave this color's hue alone.
    let protectionNote: String?
    let harmony: HarmonyFit?
    /// Color at the marker's position in the graded version, if one is loaded.
    let after: SRGBColor?
    /// How the color relates to the series palette, when that reference is shown.
    let series: SeriesRowInfo?
    /// "Series" or "Reference".
    let referenceTitle: String
    /// "After" for a graded version, "Predicted" for the preview.
    let afterLabel: String

    var body: some View {
        let color = marker.color
        let hsl = color.hsl
        let rgb = color.rgb255
        let channel = DxOMapping.channel(for: color)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                MarkerBadge(number: number, color: color, diameter: 22, isAccent: marker.isAccent)
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.swiftUIColor)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.2)))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        hexAndCopy(color)
                        if marker.isAccent { accentTag }
                    }
                    Text("RGB \(rgb.r) \(rgb.g) \(rgb.b)")
                    Text(String(format: "HSL %.0f° %.0f%% %.0f%%", hsl.h, hsl.s * 100, hsl.l * 100))
                }
                .font(.system(.caption, design: .monospaced))
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(String(format: "%.1f%%", marker.share * 100))
                        .font(.headline.monospacedDigit())
                    ProgressView(value: marker.share)
                        .frame(width: 56)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                GridRow {
                    gridLabel("DxO HSL")
                    // Leaves room for the buttons floating at the right.
                    Text(channel == .neutral ? "Neutral — use White Balance / Color Grading" : channel.displayName)
                        .padding(.trailing, 100)
                }
                GridRow {
                    gridLabel("Grading")
                    Text(String(format: "%@ (L* %.0f)", DxOMapping.tonalRange(for: color).displayName, color.lightness))
                }
                if let series {
                    GridRow {
                        gridLabel(referenceTitle)
                        let note = seriesRowNote(series, noun: referenceTitle.lowercased())
                        Text(note.text).foregroundStyle(note.color)
                    }
                }
                if color.isOutsideSRGB {
                    let p3 = color.displayP3RGB255
                    GridRow {
                        gridLabel("Gamut")
                        Text("Outside sRGB · Display P3 \(p3.r) \(p3.g) \(p3.b)")
                            .foregroundStyle(.orange)
                            .help("The photo's color is more saturated than sRGB can show: the hex and RGB above are clipped to sRGB, the Display P3 values are what the photo has.")
                    }
                }
                if let offset = SkinTone.offset(of: color) {
                    GridRow {
                        gridLabel("Skin tone")
                        Text("In range · \(SkinTone.describe(offset: offset))")
                    }
                }
                if let protectionNote {
                    GridRow {
                        gridLabel("Protected")
                        Text(protectionNote)
                            .foregroundStyle(.orange)
                    }
                } else if let shift = marker.targetShift(harmony: harmony), channel != .neutral {
                    GridRow {
                        gridLabel("Harmony")
                        Text(shiftDescription(hue: color.hsb.h, shift: shift, channel: channel))
                            .foregroundStyle(abs(shift) < 3 ? .green : .primary)
                    }
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The buttons float at the top right of the details, so the lines below them can run the full width.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    protectButton
                    Button {
                        model.removeMarker(marker.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove marker")
                }
            }

            if model.selectedMarkerID == marker.id {
                HStack(spacing: 8) {
                    Text("Sample size").font(.caption).foregroundStyle(.secondary)
                    ResettableSlider(
                        value: Binding(get: { marker.sampleRadius }, set: { model.setSampleRadius($0, for: marker.id) }),
                        range: AnalysisModel.sampleRadiusRange, resetValue: AnalysisModel.defaultSampleRadius)
                        .frame(maxWidth: .infinity)
                        .help("How far around its spot this color is averaged. Double-click to return to the default.")
                    Text(String(format: "%.1f%%", marker.sampleRadius * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
            }

            if let after {
                afterSummary(before: color, after: after)
            }
        }
        .padding(.vertical, 6)
    }

    private func hexAndCopy(_ color: SRGBColor) -> some View {
        HStack(spacing: 4) {
            Text(color.hex)
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(1)
                .fixedSize()
            Button {
                copy(color.hex)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy hex")
        }
    }

    private var accentTag: some View {
        Text("Accent")
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .background(Capsule().fill(Color.yellow.opacity(0.3)))
            .help("A small, striking color found by the accent search, not by its share of the photo")
    }

    /// An orange "Protected" label when the color keeps its hue, a faint open lock when it does not.
    /// A label of the details grid, as wide as the widest of them ("Protected"), so the texts beside them stay put.
    private func gridLabel(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            Text("Protected").hidden()
            Text(text).foregroundStyle(.secondary)
        }
    }

    private var protectButton: some View {
        Button {
            // The click must not also select the row: the row's own tap may arrive after this action, so the selection is put back afterwards.
            let selected = model.selectedMarkerID
            model.toggleProtected(marker.id)
            DispatchQueue.main.async { model.selectedMarkerID = selected }
        } label: {
            if isProtected {
                Label("Protected", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.orange))
            } else {
                Image(systemName: "lock.open")
                    .foregroundStyle(.secondary)
                    .opacity(0.6)
            }
        }
        .buttonStyle(.borderless)
        .help(isProtected ? "Unprotect color" : "Protect color (keep its hue)")
    }

    private func afterSummary(before: SRGBColor, after: SRGBColor) -> some View {
        let b = before.hsl, a = after.hsl
        let chromatic = before.chroma >= DxOMapping.neutralChroma && after.chroma >= DxOMapping.neutralChroma
        let hueText = chromatic ? signedRounded(ColorMath.signedAngle(from: b.h, to: a.h), unit: "°") : "—"
        return HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(after.swiftUIColor)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(afterLabel) \(after.hex)")
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                Text("Δ hue \(hueText) · sat \(signedRounded((a.s - b.s) * 100, unit: "%")) · L* \(signedRounded(after.lightness - before.lightness))")
                    .font(.caption)
                if let was = marker.targetShift(fromHue: before.hsb.h, harmony: harmony),
                   let now = marker.targetShift(fromHue: after.hsb.h, harmony: harmony), chromatic {
                    Text("Harmony shift \(signedRounded(was, unit: "°")) → \(signedRounded(now, unit: "°"))")
                        .font(.caption)
                        .foregroundStyle(abs(now) < abs(was) - 0.5 ? .green : abs(now) > abs(was) + 0.5 ? .red : .secondary)
                }
                if let change = SkinTone.change(from: before, to: after) {
                    let note = skinChangeNote(change)
                    Text(note.text)
                        .font(.caption)
                        .foregroundStyle(note.color)
                }
            }
        }
        .padding(.top, 2)
    }

    private func shiftDescription(hue: Double, shift: Double, channel: DxOChannel) -> String {
        if abs(shift) < 3 { return "On target (\(Int(hue.rounded()))°)" }
        let target = ColorMath.normalizeDegrees(hue + shift)
        return String(format: "%@: hue %+.0f° → %.0f°", channel.displayName, shift, target)
    }
}

/// "palette 3 (#7AAA25) · hue -4° · sat +3% · L* +1" for the list and the report.
func seriesRowNote(_ info: SeriesRowInfo, noun: String = "series") -> (text: String, color: Color) {
    switch info {
    case .unmatched:
        return ("No close color in the \(noun) palette", .orange)
    case .match(let m, let hex, let chosen):
        var parts = [chosen ? "→ palette \(m.index + 1) (\(hex), chosen)" : "≈ palette \(m.index + 1) (\(hex))"]
        if let hue = m.hueShift, abs(hue) >= 1 { parts.append("hue \(signedRounded(hue, unit: "°"))") }
        if abs(m.saturationChange) >= 2 { parts.append("sat \(signedRounded(m.saturationChange, unit: "%"))") }
        if abs(m.lightnessChange) >= 1 { parts.append("L* \(signedRounded(m.lightnessChange))") }
        let close = parts.count == 1
        return (parts.joined(separator: " · ") + (close ? " · already close" : ""), close ? .green : .primary)
    }
}

/// How a grade moved a color with respect to the skin tone band, for the list and the report.
func skinChangeNote(_ change: SkinTone.Change) -> (text: String, color: Color) {
    switch change {
    case .stays(let offset): ("Skin tone: still in range (\(SkinTone.describe(offset: offset)))", .green)
    case .leaves(let offset): ("Skin tone: left the range (\(SkinTone.describe(offset: offset)))", .red)
    case .enters(let offset): ("Skin tone: now in range (\(SkinTone.describe(offset: offset)))", .orange)
    }
}

/// "+8°", "-3%", "0" — never "-0".
func signedRounded(_ value: Double, unit: String = "") -> String {
    let n = Int(value.rounded())
    return n == 0 ? "0\(unit)" : String(format: "%+d%@", n, unit)
}

private func copy(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
