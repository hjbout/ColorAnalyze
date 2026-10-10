import AppKit
import ColorCore
import SwiftUI

/// Everything the PNG report shows, captured at export time.
struct ReportData {
    var title: String
    var date: Date
    var before: CGImage
    var after: CGImage?
    var markers: [Marker]
    /// Color at each marker's position in the graded version (same order as `markers`).
    var afterColors: [SRGBColor?]
    var harmony: HarmonyFit?
    var harmonyIsAutoDetected: Bool
    var afterHarmony: HarmonyFit?
    /// "Moderate" / "Strong" when subject weighting was used for the shares.
    var weighting: String?
    var hueSpace: HueSpace = .rgb
    var showSkinTone = true
    /// The series palette drawn as a reference on the wheel; empty when there is none or it is hidden.
    var seriesPalette: [SharedColor] = []
    /// "Series" or "Reference": what the palette comes from.
    var referenceTitle = "Series"
    /// How each marker relates to the series palette (same order as `markers`; empty without a palette).
    var seriesInfos: [SeriesRowInfo?] = []
    var seriesFit: PhotoConsistency?
    var afterSeriesFit: PhotoConsistency?
    /// What the photo should feel like, as noted before choosing a harmony.
    var intention: String?
}

enum ReportError: LocalizedError {
    case noPhoto
    case renderFailed
    case noGrading

    var errorDescription: String? {
        switch self {
        case .noPhoto: "There is no photo to report on."
        case .renderFailed: "The report image could not be rendered."
        case .noGrading: "There is no grading to suggest yet: the photo needs colors with a harmony."
        }
    }
}

@MainActor
enum ReportRenderer {
    /// 2× so the list text stays sharp when the report is zoomed or printed.
    static let scale: CGFloat = 2

    static func pngData(for data: ReportData) -> Data? {
        let renderer = ImageRenderer(content: ReportView(data: data).environment(\.colorScheme, .light))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

extension ReportRenderer {
    static func pngData(for data: SeriesReportData) -> Data? {
        let renderer = ImageRenderer(content: SeriesReportView(data: data).environment(\.colorScheme, .light))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Static layout of the window: photo(s) on the left, color list in the middle, wheel on the right.
struct ReportView: View {
    let data: ReportData

    private let photoWidth: CGFloat = 560
    private let wheelSide: CGFloat = 480
    private let listWidth: CGFloat = 600
    private let spacing: CGFloat = 28
    private let margin: CGFloat = 36

    private var wheelColumnWidth: CGFloat { wheelSide + 40 }
    private var totalWidth: CGFloat { photoWidth + wheelColumnWidth + listWidth + 2 * spacing + 2 * margin }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            HStack(alignment: .top, spacing: spacing) {
                photos.frame(width: photoWidth)
                list.frame(width: listWidth)
                wheelColumn.frame(width: wheelColumnWidth)
            }
            footer
        }
        .padding(margin)
        .frame(width: totalWidth, alignment: .topLeading)
        .background(Color.white)
    }

    // MARK: Header & footer

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(data.title)
                    .font(.system(size: 28, weight: .bold))
                Text("\(data.markers.count) dominant colors · \(data.date.formatted(date: .long, time: .shortened))"
                     + (data.weighting.map { " · weighted toward the subject (\($0.lowercased()))" } ?? ""))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                if let intention = data.intention {
                    Text("Intention: “\(intention)”")
                        .font(.system(size: 15).italic())
                        .padding(.top, 4)
                }
            }
            Spacer()
            if let fit = data.harmony {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(fit.kind.displayName)\(data.harmonyIsAutoDetected ? " (detected)" : "")"
                         + (data.hueSpace == .rgb ? "" : " · \(data.hueSpace.displayName) wheel"))
                        .font(.system(size: 20, weight: .semibold))
                    HStack(spacing: 8) {
                        Text("fit ±\(Int(fit.deviation.rounded()))°")
                            .foregroundStyle(fitColor(fit.deviation))
                        if let after = data.afterHarmony {
                            Text("→ after grading ±\(Int(after.deviation.rounded()))°")
                                .foregroundStyle(fitColor(after.deviation))
                        }
                    }
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    if let seriesFit = data.seriesFit {
                        HStack(spacing: 8) {
                            Text("\(data.referenceTitle) fit \(seriesFit.score)")
                                .foregroundStyle(scoreColor(seriesFit.score))
                            if let after = data.afterSeriesFit {
                                Text("→ after grading \(after.score)")
                                    .foregroundStyle(scoreColor(after.score))
                            }
                        }
                        .font(.system(size: 14, weight: .medium).monospacedDigit())
                    }
                    Text("Target hues (RGB) " + fit.targetRGBHues.map { "\(Int($0.rounded()))°" }.joined(separator: " · ")
                         + (fit.tolerance > 0 ? " · sector ±\(Int(fit.tolerance.rounded()))°" : " · exact hue"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        Text("Generated by ColorAnalyze. DxO channels, tonal ranges and hue targets are approximations — a starting point for color grading, not exact settings.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 80 ? .green : score >= 60 ? .orange : .red
    }

    private func fitColor(_ deviation: Double) -> Color {
        deviation < 10 ? .green : deviation < 25 ? .orange : .red
    }

    // MARK: Photos

    private var photos: some View {
        let maxHeight: CGFloat = data.after == nil ? 760 : 380
        return VStack(spacing: 16) {
            ReportPhoto(image: data.before, markers: data.markers, colors: data.markers.map(\.color),
                        label: data.after == nil ? nil : "Before",
                        maxSize: CGSize(width: photoWidth, height: maxHeight))
            if let after = data.after {
                ReportPhoto(image: after, markers: data.markers,
                            colors: zip(data.markers, data.afterColors).map { $1 ?? $0.color },
                            label: "After", maxSize: CGSize(width: photoWidth, height: maxHeight))
            }
        }
    }

    // MARK: Wheel

    private var wheelColumn: some View {
        let side = wheelSide
        let box = wheelColumnWidth
        let center = CGPoint(x: box / 2, y: box / 2)
        let radius = side / 2
        return VStack(spacing: 18) {
            ZStack {
                Image(decorative: WheelGeometry.wheelImage(for: data.hueSpace), scale: 1)
                    .resizable()
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(0.25), radius: 6)
                if data.showSkinTone {
                    SkinToneOverlay(space: data.hueSpace, center: center, radius: radius)
                }
                if !data.seriesPalette.isEmpty {
                    SeriesReferenceOverlay(palette: data.seriesPalette, space: data.hueSpace, center: center, radius: radius)
                }
                if let fit = data.harmony {
                    HarmonyOverlay(fit: fit, markers: data.markers, center: center, radius: radius)
                }
                if data.after != nil {
                    AfterTrails(markers: data.markers, afterColors: data.afterColors, space: data.hueSpace,
                                center: center, radius: radius)
                }
                ForEach(Array(data.markers.enumerated()), id: \.element.id) { index, marker in
                    let hsb = marker.color.hsb
                    MarkerBadge(number: index + 1, color: marker.color, diameter: 16 + 30 * sqrt(marker.share))
                        .position(WheelGeometry.point(rgbHue: hsb.h, space: data.hueSpace, saturation: hsb.s,
                                                      center: center, radius: radius))
                }
                ForEach(Array(data.markers.enumerated()), id: \.element.id) { index, marker in
                    if let after = data.afterColors[index] {
                        let hsb = after.hsb
                        GhostBadge(number: index + 1, color: after, diameter: 16 + 30 * sqrt(marker.share))
                            .position(WheelGeometry.point(rgbHue: hsb.h, space: data.hueSpace, saturation: hsb.s,
                                                          center: center, radius: radius))
                    }
                }
            }
            .frame(width: box, height: box)

            LightnessStrip(markers: data.markers, selectedID: nil, afterColors: data.afterColors)
                .frame(width: side)
        }
    }

    // MARK: List

    private var list: some View {
        let maxShare = max(0.01, data.markers.map(\.share).max() ?? 0.01)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Colors")
                .font(.system(size: 17, weight: .semibold))
                .padding(.bottom, 8)
            ForEach(Array(data.markers.enumerated()), id: \.element.id) { index, marker in
                Divider()
                ReportRow(number: index + 1, marker: marker, after: data.afterColors[index],
                          harmony: data.harmony, maxShare: maxShare,
                          seriesInfo: index < data.seriesInfos.count ? data.seriesInfos[index] : nil,
                          referenceTitle: data.referenceTitle)
                    .padding(.vertical, 9)
            }
        }
    }
}

private struct ReportPhoto: View {
    let image: CGImage
    let markers: [Marker]
    /// Marker colors to show on this photo (same order as `markers`).
    let colors: [SRGBColor]
    let label: String?
    let maxSize: CGSize

    var body: some View {
        let scale = min(maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if let label {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.85), in: Capsule())
                            .padding(8)
                    }
                }
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                MarkerBadge(number: index + 1, color: colors[index], diameter: 24)
                    .position(x: marker.location.x * size.width, y: marker.location.y * size.height)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity)
    }
}

private struct ReportRow: View {
    let number: Int
    let marker: Marker
    let after: SRGBColor?
    let harmony: HarmonyFit?
    let maxShare: Double
    var seriesInfo: SeriesRowInfo?
    var referenceTitle = "Series"

    var body: some View {
        let color = marker.color
        let hsl = color.hsl
        let rgb = color.rgb255
        let channel = DxOMapping.channel(for: color)
        HStack(alignment: .top, spacing: 12) {
            MarkerBadge(number: number, color: color, diameter: 24)
            RoundedRectangle(cornerRadius: 6)
                .fill(color.swiftUIColor)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.2)))
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(color.hex)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Text(String(format: "RGB %d %d %d · HSL %.0f° %.0f%% %.0f%%", rgb.r, rgb.g, rgb.b,
                            hsl.h, hsl.s * 100, hsl.l * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("DxO \(channel == .neutral ? "Neutral (use White Balance / Color Grading)" : channel.displayName) · "
                     + String(format: "%@ (L* %.0f)", DxOMapping.tonalRange(for: color).displayName, color.lightness))
                    .font(.system(size: 12))
                if let seriesInfo {
                    let note = seriesRowNote(seriesInfo, noun: referenceTitle.lowercased())
                    Text("\(referenceTitle): " + note.text)
                        .font(.system(size: 12))
                        .foregroundStyle(note.color)
                }
                if color.isOutsideSRGB {
                    let p3 = color.displayP3RGB255
                    Text("Outside sRGB: Display P3 \(p3.r) \(p3.g) \(p3.b) (hex is clipped)")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
                if let offset = SkinTone.offset(of: color) {
                    Text("Skin tone: in range (\(SkinTone.describe(offset: offset)))")
                        .font(.system(size: 12))
                }
                if let harmony, channel != .neutral {
                    let shift = harmony.shift(for: color.hsb.h)
                    Text(abs(shift) < 3
                         ? "Harmony: on target (\(Int(color.hsb.h.rounded()))°)"
                         : "Harmony: hue \(signedRounded(shift, unit: "°")) → \(Int(ColorMath.normalizeDegrees(color.hsb.h + shift).rounded()))°")
                        .font(.system(size: 12))
                        .foregroundStyle(abs(shift) < 3 ? .green : .primary)
                }
                if let after {
                    afterLine(before: color, after: after)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 5) {
                Text(String(format: "%.1f%%", marker.share * 100))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.1))
                    Capsule().fill(color.swiftUIColor)
                        .frame(width: max(4, 70 * marker.share / maxShare))
                }
                .frame(width: 70, height: 6)
            }
        }
    }

    private func afterLine(before: SRGBColor, after: SRGBColor) -> some View {
        let b = before.hsl, a = after.hsl
        let chromatic = before.chroma >= DxOMapping.neutralChroma && after.chroma >= DxOMapping.neutralChroma
        let hue = chromatic ? signedRounded(ColorMath.signedAngle(from: b.h, to: a.h), unit: "°") : "—"
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(after.swiftUIColor)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .frame(width: 14, height: 14)
                Text("After \(after.hex) · Δ hue \(hue) · sat \(signedRounded((a.s - b.s) * 100, unit: "%")) · L* \(signedRounded(after.lightness - before.lightness))")
                    .font(.system(size: 12))
                if let harmony, chromatic {
                    let was = harmony.shift(for: before.hsb.h), now = harmony.shift(for: after.hsb.h)
                    Text("→ \(signedRounded(was, unit: "°")) to \(signedRounded(now, unit: "°"))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(abs(now) < abs(was) - 0.5 ? .green : abs(now) > abs(was) + 0.5 ? .red : .secondary)
                }
            }
            if let change = SkinTone.change(from: before, to: after) {
                let note = skinChangeNote(change)
                Text(note.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(note.color)
                    .padding(.leading, 20)
            }
        }
    }
}
