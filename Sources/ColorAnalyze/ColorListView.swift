import AppKit
import ColorCore
import SwiftUI

struct ColorListView: View {
    @Environment(AnalysisModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let fit = model.harmony
        List(selection: $model.selectedMarkerID) {
            Section {
                ForEach(Array(model.markers.enumerated()), id: \.element.id) { index, marker in
                    ColorRow(number: index + 1, marker: marker, harmony: fit,
                             after: model.afterColor(for: marker), series: model.seriesInfo(for: marker), referenceTitle: model.referenceTitle, afterLabel: model.afterLabel)
                        .tag(marker.id)
                        .onHover { model.hover(marker.id, inside: $0) }
                        .contextMenu {
                            Button("Copy Hex") { copy(marker.color.hex) }
                            Button(marker.isProtected ? "Unprotect Color" : "Protect Color (keep its hue)") { model.toggleProtected(marker.id) }
                            Button("Remove Marker") { model.removeMarker(marker.id) }
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
    }
}

private struct ColorRow: View {
    let number: Int
    let marker: Marker
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
                MarkerBadge(number: number, color: color, diameter: 22)
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.swiftUIColor)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.2)))
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(color.hex)
                            .font(.system(.body, design: .monospaced).weight(.semibold))
                            .textSelection(.enabled)
                        Button {
                            copy(color.hex)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy hex")
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
                    Text("DxO HSL").foregroundStyle(.secondary)
                    Text(channel == .neutral ? "Neutral — use White Balance / Color Grading" : channel.displayName)
                }
                GridRow {
                    Text("Grading").foregroundStyle(.secondary)
                    Text(String(format: "%@ (L* %.0f)", DxOMapping.tonalRange(for: color).displayName, color.lightness))
                }
                if let series {
                    GridRow {
                        Text(referenceTitle).foregroundStyle(.secondary)
                        let note = seriesRowNote(series, noun: referenceTitle.lowercased())
                        Text(note.text).foregroundStyle(note.color)
                    }
                }
                if color.isOutsideSRGB {
                    let p3 = color.displayP3RGB255
                    GridRow {
                        Text("Gamut").foregroundStyle(.secondary)
                        Text("Outside sRGB · Display P3 \(p3.r) \(p3.g) \(p3.b)")
                            .foregroundStyle(.orange)
                            .help("The photo's color is more saturated than sRGB can show: the hex and RGB above are clipped to sRGB, the Display P3 values are what the photo has.")
                    }
                }
                if let offset = SkinTone.offset(of: color) {
                    GridRow {
                        Text("Skin tone").foregroundStyle(.secondary)
                        Text("In range · \(SkinTone.describe(offset: offset))")
                    }
                }
                if marker.isProtected {
                    GridRow {
                        Text("Protected").foregroundStyle(.secondary)
                        Text("Kept as it is: the suggestions do not aim it at the harmony")
                            .foregroundStyle(.orange)
                    }
                } else if let harmony, channel != .neutral {
                    let shift = harmony.shift(for: color.hsb.h)
                    GridRow {
                        Text("Harmony").foregroundStyle(.secondary)
                        Text(shiftDescription(hue: color.hsb.h, shift: shift, channel: channel))
                            .foregroundStyle(abs(shift) < 3 ? .green : .primary)
                    }
                }
            }
            .font(.caption)

            if let after {
                afterSummary(before: color, after: after)
            }
        }
        .padding(.vertical, 6)
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
                if let harmony, chromatic {
                    let was = harmony.shift(for: before.hsb.h), now = harmony.shift(for: after.hsb.h)
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
    case .match(let m, let hex):
        var parts = ["≈ palette \(m.index + 1) (\(hex))"]
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
