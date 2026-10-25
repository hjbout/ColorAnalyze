import ColorCore
import SwiftUI

/// Maps hue/saturation to positions on the wheel. Hue 0° (red) sits at 3 o'clock and
/// hues run counter-clockwise, like the color grading wheels in Lightroom and DxO.
enum WheelGeometry {
    static let hueZeroAngle = 0.0
    static let counterClockwise = true

    static func point(hue: Double, saturation: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let a = (hueZeroAngle + (counterClockwise ? hue : -hue)) * .pi / 180
        return CGPoint(x: center.x + cos(a) * saturation * radius,
                       y: center.y - sin(a) * saturation * radius)
    }

    static func hue(at point: CGPoint, center: CGPoint) -> Double {
        let a = atan2(-(point.y - center.y), point.x - center.x) * 180 / .pi
        return ColorMath.normalizeDegrees(counterClockwise ? a - hueZeroAngle : hueZeroAngle - a)
    }

    /// Shared wheel bitmap for the window and the exported report.
    @MainActor private static let rgbWheel = renderWheel(size: 720, space: .rgb)
    @MainActor private static let rybWheel = renderWheel(size: 720, space: .ryb)
    @MainActor private static let dxoWheel = renderWheel(size: 720, space: .dxo)
    @MainActor private static let oklchWheel = renderWheel(size: 720, space: .oklch)
    @MainActor private static let labWheel = renderWheel(size: 720, space: .lab)
    @MainActor private static let munsellWheel = renderWheel(size: 720, space: .munsell)
    @MainActor private static let ittenWheel = renderWheel(size: 720, space: .itten)

    @MainActor static func wheelImage(for space: HueSpace) -> CGImage {
        switch space {
        case .rgb: rgbWheel
        case .ryb: rybWheel
        case .dxo: dxoWheel
        case .oklch: oklchWheel
        case .lab: labWheel
        case .munsell: munsellWheel
        case .itten: ittenWheel
        }
    }

    /// Position of a color's sRGB hue on the wheel of `space`.
    static func point(rgbHue: Double, space: HueSpace, saturation: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        // Colors outside the sRGB gamut have a saturation above 1: they sit just beyond the rim.
        point(hue: space.position(ofRGBHue: rgbHue), saturation: min(saturation, 1.1), center: center, radius: radius)
    }

    /// HSB disc at full brightness: angle = position on the wheel of `space`, saturation = radius.
    static func renderWheel(size: Int, space: HueSpace) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let c = Double(size) / 2
        let center = CGPoint(x: c, y: c)
        for y in 0..<size {
            for x in 0..<size {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let r = hypot(p.x - c, p.y - c)
                let alpha = min(1, max(0, c - r + 0.5))
                guard alpha > 0 else { continue }
                let rgb = SRGBColor.fromHSB(h: space.rgbHue(atPosition: hue(at: p, center: center)), s: min(1, r / c), b: 1)
                let i = (y * size + x) * 4
                bytes[i] = UInt8(rgb.r * alpha * 255)
                bytes[i + 1] = UInt8(rgb.g * alpha * 255)
                bytes[i + 2] = UInt8(rgb.b * alpha * 255)
                bytes[i + 3] = UInt8(alpha * 255)
            }
        }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }
}

/// The tabs under the wheel, in working order: choose the harmony, steer the grading, set it in PhotoLab.
enum PaneTab: String, CaseIterable, Identifiable {
    case harmony, grading, photoLab
    var id: Self { self }
    static let storageKey = "rightPaneTab"
}

/// Which markers the wheel shows once a graded version (or its prediction) exists.
enum WheelMarkerMode: String, CaseIterable, Identifiable {
    case colors, targets, both
    var id: Self { self }
    var title: String {
        switch self {
        case .colors: "Colors"
        case .targets: "Targets"
        case .both: "Both"
        }
    }
    var symbol: String {
        switch self {
        case .colors: "circle.fill"
        case .targets: "scope"
        case .both: "circle.circle"
        }
    }
    static let storageKey = "wheelMarkerMode"
}

struct ColorWheelView: View {
    @Environment(AnalysisModel.self) private var model
    @AppStorage(WheelMarkerMode.storageKey) private var markerMode: WheelMarkerMode = .both
    @AppStorage(PaneTab.storageKey) private var tab: PaneTab = .harmony

    /// The tab's name, with a warning sign when it holds a warning that is easy to miss.
    private func tabTitle(_ tab: PaneTab) -> String {
        switch tab {
        case .harmony: "Harmony"
        case .grading: model.whiteBalance.direction != nil ? "Grading ⚠︎" : "Grading"
        case .photoLab: model.effectiveGradingTarget != .emphasize && model.hslSuggestions.contains(where: \.isMixed)
            ? "PhotoLab ⚠︎" : "PhotoLab"
        }
    }

    var body: some View {
        @Bindable var model = model
        let fit = model.harmony
        let showColors = !model.hasAfterColors || markerMode != .targets
        let showTargets = model.hasAfterColors && markerMode != .colors
        VStack(spacing: 16) {
            GeometryReader { geo in
                // Leave room for the rotation handle, which sits 7% outside the rim at any angle.
                let side = min(geo.size.width, geo.size.height) - 68
                let radius = side / 2
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                ZStack {
                    Image(decorative: WheelGeometry.wheelImage(for: model.hueSpace), scale: 1)
                        .resizable()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.25), radius: 6)
                        .position(center)
                        .onTapGesture { model.selectedMarkerID = nil }

                    if model.showSkinTone {
                        SkinToneOverlay(space: model.hueSpace, center: center, radius: radius)
                            .allowsHitTesting(false)
                    }

                    if model.isSeriesReferenceShown {
                        SeriesReferenceOverlay(palette: model.seriesPalette, space: model.hueSpace,
                                               center: center, radius: radius)
                    }

                    if let fit {
                        HarmonyOverlay(fit: fit, markers: model.markers, center: center, radius: radius, showsShifts: showColors)
                            .allowsHitTesting(false)
                        rotationHandle(fit: fit, center: center, radius: radius)
                    }

                    if showColors && showTargets {
                        AfterTrails(markers: model.markers, afterColors: model.markers.map { model.afterColor(for: $0) },
                                    space: model.hueSpace, center: center, radius: radius)
                            .allowsHitTesting(false)
                    }

                    // The selected marker is linked to the series palette color it is closest to.
                    if let id = model.selectedMarkerID, let marker = model.markers.first(where: { $0.id == id }),
                       let match = model.seriesMatch(for: marker) {
                        let from = marker.color.hsb, to = model.seriesPalette[match.index].color.hsb
                        Path { path in
                            path.move(to: WheelGeometry.point(rgbHue: from.h, space: model.hueSpace, saturation: from.s,
                                                              center: center, radius: radius))
                            path.addLine(to: WheelGeometry.point(rgbHue: to.h, space: model.hueSpace, saturation: to.s,
                                                                 center: center, radius: radius))
                        }
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .allowsHitTesting(false)
                    }

                    ForEach(Array(model.markers.enumerated()), id: \.element.id) { index, marker in
                        let hsb = marker.color.hsb
                        if showColors {
                        MarkerBadge(number: index + 1, color: marker.color,
                                    diameter: 16 + 30 * sqrt(marker.share),
                                    isSelected: marker.id == model.selectedMarkerID, isAccent: marker.isAccent)
                            .position(WheelGeometry.point(rgbHue: hsb.h, space: model.hueSpace, saturation: hsb.s,
                                                          center: center, radius: radius))
                            // No .onHover here: it makes the rotation handle's drag stop working. Tapping a
                            // marker selects it, which shows its region; the list rows do support hover.
                            .onTapGesture {
                                model.selectedMarkerID = marker.id
                                model.releaseKeyboardFocus()
                            }
                            .help(String(format: "%@ · hue %.0f° · sat %.0f%%", marker.color.hex, hsb.h, hsb.s * 100))
                        }
                    }

                    if showTargets {
                        ForEach(Array(model.markers.enumerated()), id: \.element.id) { index, marker in
                            if let after = model.afterColor(for: marker) {
                                let hsb = after.hsb
                                let editable = model.canEditTargets && marker.color.chroma >= DxOMapping.neutralChroma
                                GhostBadge(number: index + 1, color: after,
                                           diameter: 16 + 30 * sqrt(marker.share), isManual: marker.targetHue != nil)
                                    .position(WheelGeometry.point(rgbHue: hsb.h, space: model.hueSpace, saturation: hsb.s,
                                                                  center: center, radius: radius))
                                    .allowsHitTesting(editable)
                                    .onTapGesture(count: 2) {
                                        guard marker.targetHue != nil else { return }
                                        model.registerMarkerUndo("Reset Target \(index + 1)")
                                        model.setTargetHue(nil, for: marker.id)
                                    }
                                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("wheel"))
                                        .onChanged { value in
                                            if model.draggingTargetID != marker.id {
                                                model.draggingTargetID = marker.id
                                                model.registerMarkerUndo("Move Target \(index + 1)")
                                            }
                                            let position = WheelGeometry.hue(at: value.location, center: center)
                                            model.setTargetHue(model.hueSpace.rgbHue(atPosition: position).rounded(), for: marker.id)
                                        }
                                        .onEnded { _ in model.draggingTargetID = nil })
                                    .help(editable ? "Drag to aim this color at another hue; double-click to reset" : "")
                            }
                        }
                    }
                }
                .coordinateSpace(.named("wheel"))
                .contentShape(Rectangle())
                .onTapGesture { model.selectedMarkerID = nil }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if model.hasAfterColors {
                    HStack(spacing: 2) {
                        ForEach(WheelMarkerMode.allCases) { mode in
                            let selected = markerMode == mode
                            Button {
                                markerMode = mode
                            } label: {
                                Image(systemName: mode.symbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 30, height: 22)
                                    .foregroundStyle(selected ? Color.white : Color.primary)
                                    .background(selected ? Color.accentColor : Color.clear, in: Capsule())
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(mode.title)
                            .accessibilityLabel(mode.title)
                        }
                    }
                    .padding(3)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .padding(.trailing, 20)
                    .help("Colors: the markers of the chosen colors. Targets: where grading moves them to. Both: the two, joined by trails.")
                }
            }

            LightnessStrip(markers: model.markers, selectedID: model.selectedMarkerID,
                           afterColors: model.markers.map { model.afterColor(for: $0) })
                .padding(.horizontal, 20)

            Picker("Panel", selection: $tab) {
                ForEach(PaneTab.allCases) { Text(tabTitle($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .help("Harmony: choose the harmony. Grading: steer the suggestion. PhotoLab: everything to set in PhotoLab (⌥⌘1, ⌥⌘2, ⌥⌘3).")

            ScrollView {
                Group {
                    switch tab {
                    case .harmony: harmonyTab(fit: fit)
                    case .grading: gradingTab
                    case .photoLab: photoLabTab
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func seriesFitView(_ fit: PhotoConsistency, after: PhotoConsistency?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label("\(model.referenceTitle) fit", systemImage: "diamond")
                    .font(.subheadline)
                ScoreBadge(score: fit.score)
                if let after {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScoreBadge(score: after.score)
                        .help("Fit of the graded version")
                }
                Spacer()
            }
            Text(fit.hasSuggestion ? "To match: " + (seriesSuggestion(fit) ?? "already matches the \(model.referenceNoun)")
                                   : "Too different from the \(model.referenceNoun) to suggest an alignment")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let after {
                Text(after.hasSuggestion ? (model.afterImage == nil ? "Predicted after grading, still: " : "After grading, still: ") + (seriesSuggestion(after) ?? "matches the \(model.referenceNoun)")
                                         : (model.afterImage == nil ? "Predicted after grading: still too different from the \(model.referenceNoun)"
                                                                    : "After grading: still too different from the \(model.referenceNoun)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("How well this photo's colors fit the palette of the \(model.referenceNoun), and a starting point for aligning it (hue in sRGB degrees).")
    }

    private func fitColor(_ deviation: Double) -> Color {
        deviation < 10 ? .green : deviation < 25 ? .orange : .red
    }

    private func rotationHandle(fit: HarmonyFit, center: CGPoint, radius: CGFloat) -> some View {
        let offset = fit.kind.offsets[0]
        let position = WheelGeometry.point(hue: fit.rotation + offset, saturation: 1.07, center: center, radius: radius)
        return Image(systemName: "diamond.fill")
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 2)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .position(position)
            .onTapGesture(count: 2) { model.harmonyRotationOverride = nil }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wheel")).onChanged { value in
                let hue = WheelGeometry.hue(at: value.location, center: center)
                model.harmonyRotationOverride = (hue - offset).rounded()
            })
            .help("Drag to rotate the harmony; double-click to reset")
    }

    /// Choosing the harmony: what the photo should become.
    @ViewBuilder
    private func harmonyTab(fit: HarmonyFit?) -> some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            IntentionField(title: "Intention", placeholder: "What should this photo feel like?",
                           text: $model.intention)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("Wheel").font(.subheadline).help("RGB is the ordinary sRGB hue circle. RYB is the artist's red–yellow–blue wheel, where the classic complements are red–green, orange–blue and yellow–violet. DxO is PhotoLab's own hue axis: the angles are the Hue numbers of its Color Grading and HSL wheels. OKLCH is a perceptual wheel: equal angles look like equal color steps.\n\nOn the DxO, RYB and OKLCH wheels the harmonies are computed in that wheel's terms, but hue shifts and target hues in the list stay in sRGB degrees.")
                    WheelSwatchPicker(selection: model.hueSpace) { space, remember in
                        model.chooseWheel(space, remember: remember)
                    }
                    .frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    Text("Targets").font(.subheadline).help("Targets: a color inside the sector around a target counts as on target and is not shifted.")
                    ResettableSlider(value: $model.harmonySector, range: 0...30, resetValue: 10)
                        .frame(maxWidth: .infinity)
                        .help("Double-click to return to ±10°")
                    Text(model.harmonySector < 0.5 ? "exact" : "±\(Int(model.harmonySector.rounded()))°")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                HStack(spacing: 12) {
                    Toggle("Skin tone line", isOn: $model.showSkinTone)
                        .help("Reference band for skin tones (sRGB hue ≈ 13°–37°). Skin-like colors in the list are marked whether or not the line is shown.")
                    Toggle("Protect skin tones", isOn: $model.protectSkin)
                        .help("Skin-like colors keep their hue: the grading suggestions do not aim them at the harmony. Right-click a color to override this for one color. Sand, wood or a red wall can look like skin to this rule of thumb.")
                    Spacer(minLength: 0)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 10) {
                Picker("Harmony", selection: $model.harmonyChoice) {
                    Text("Auto-detect").tag(HarmonyKind?.none)
                    Divider()
                    ForEach(HarmonyKind.allCases) { kind in
                        Text(kind.displayName).tag(HarmonyKind?.some(kind))
                    }
                }
                if let fit {
                    HStack {
                        Text("\(fit.kind.displayName)\(model.harmonyChoice == nil ? " (detected)" : "")")
                            .font(.headline)
                        Spacer()
                        Text(String(format: "fit ±%.0f°", fit.deviation))
                            .monospacedDigit()
                            .foregroundStyle(fitColor(fit.deviation))
                    }
                    if let after = model.afterHarmony {
                        HStack {
                            Text(model.afterImage == nil ? "Predicted after grading" : "After grading")
                                .font(.subheadline)
                            Spacer()
                            Text("fit ±\(Int(after.deviation.rounded()))° (\(signedRounded(after.deviation - fit.deviation, unit: "°")))")
                                .monospacedDigit()
                                .foregroundStyle(fitColor(after.deviation))
                        }
                    }
                    HStack {
                        Text("Target hues (RGB): " + fit.targetRGBHues.map { String(format: "%.0f°", $0) }.joined(separator: " · ")
                             + (fit.tolerance > 0 ? String(format: " · sector ±%.0f°", fit.tolerance) : " · exact hue"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.harmonyRotationOverride != nil {
                            Button("Reset Rotation") { model.harmonyRotationOverride = nil }
                                .controlSize(.small)
                        }
                    }
                } else if !model.markers.isEmpty {
                    Text("All colors are neutral — no harmony to detect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    if !model.seriesPalette.isEmpty {
                        Toggle("\(model.referenceTitle) palette", isOn: $model.showSeriesReference)
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .help(model.referencePhoto == nil
                                  ? "Show the shared palette of the series window as diamonds on the wheel and compare this photo's colors with it."
                                  : "Show the palette of the reference photo as diamonds on the wheel and compare this photo's colors with it.")
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Open Reference Photo…") { model.presentOpenReferencePanel() }
                        if let reference = model.referencePhoto {
                            Button("Remove Reference (\(reference.name))") { model.clearReference() }
                        }
                    } label: {
                        Label(model.referencePhoto?.name ?? "Reference photo", systemImage: "photo.on.rectangle")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(model.image == nil)
                    .help("Load a photo whose look you want to match: its colors become the reference palette on the wheel, in the list and for the Color Grading suggestion.")
                }
                if model.isSeriesReferenceShown, let seriesFit = model.seriesFit {
                    seriesFitView(seriesFit, after: model.afterSeriesFit)
                }
                ReferencePanelView()
            }
        }
    }

    /// The choices that steer the grading suggestion, with what they are predicted to achieve.
    @ViewBuilder
    private var gradingTab: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            whiteBalanceNote()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Aim at").help("Harmony: tint toward the harmony's hues. Series / Reference: toward that palette. Tints: strengthen the faint tint each tonal range already has.")
                    Picker("Aim at", selection: $model.gradingTarget) {
                        Text("Harmony").tag(AnalysisModel.GradingTarget.harmony)
                        if model.isSeriesReferenceShown {
                            Text(model.referenceTitle).tag(AnalysisModel.GradingTarget.series)
                        }
                        Text("Tints").tag(AnalysisModel.GradingTarget.emphasize)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if model.gradingFallsBackToTints {
                    Text("The colors are nearly neutral, so there is nothing to aim at: the grading strengthens the tints the photo already has.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Style").help("A creative direction on top of the harmony: the greys of the shadows and highlights take on a cast of their own, such as warm highlights over cool shadows.")
                    LivePreviewPicker(selection: model.gradingStyle,
                                      items: GradingStyle.allCases.map { ($0, $0.displayName) }) { style, remember in
                        if remember { model.gradingStyle = style } else { model.withoutRemembering { model.gradingStyle = style } }
                    }
                    .frame(maxWidth: .infinity)
                }
                do {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Amount:").help("How strongly the grading is applied: 1 as found, 0 none, 3 about twice the Strong of earlier versions. It scales the whole grading, the style and the hue turns included. The suggested tints, the target markers and the PhotoLab values follow.")
                        HStack(spacing: 8) {
                            ResettableSlider(value: $model.gradingAmount, range: 0...3, resetValue: 1)
                                .help("Double-click to return to 1")
                            Text(model.gradingAmount.formatted(.number.precision(.fractionLength(2))))
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                                .onTapGesture(count: 2) { model.gradingAmount = 1 }
                                .help("Double-click to return to 1")
                        }
                    }
                }
                if let hint = model.intentionStyle {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.secondary)
                        Text("Your intention says “\(hint.words.joined(separator: ", "))”: \(hint.style.displayName.lowercased())?")
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Use") { model.gradingStyle = hint.style }
                            .controlSize(.small)
                    }
                    .font(.caption)
                    .help("Suggested from the words of your Intention; nothing changes until you click Use.")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let grading = model.colorGrading {
                    if let fit = grading.fit {
                        Text(fit.after < fit.before - 0.5
                             ? "Predicted: the colors are \(Int(fit.before.rounded()))° from their target hues now, \(Int(fit.after.rounded()))° after this grading."
                             : model.gradingStyle != .neutral && fit.after > fit.before + 0.5
                             ? "Predicted: the colors are \(Int(fit.before.rounded()))° from their target hues now, \(Int(fit.after.rounded()))° with this style: the cast costs hue accuracy."
                             : "Predicted: no grading brings the colors closer to their target hues.")
                            .font(.caption)
                            .foregroundStyle(fit.after < fit.before - 0.5 ? Color.green : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("Weighted mean distance in sRGB hue, from the calibrated model of PhotoLab's Color Grading (see the README).")
                    }
                    previewControls
                } else {
                    Text("Needs colors with a harmony.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// A preview of the suggested tints and hue turns on the photo itself.
    @ViewBuilder
    private var previewControls: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 6) {
        HStack {
            Toggle("Preview on the photo", isOn: $model.showPreview)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.afterImage != nil)
                .help((model.afterImage != nil ? "Close the comparison with the graded version first: it has the divider.\n\n" : "")
                      + (model.showPreview && model.previewSettings?.isIdentity == true ? "The suggestion changes nothing to show.\n\n" : "")
                      + "Show the photo with the suggested Color Grading and HSL values applied, right of a divider you can drag or below the original (P). An approximation of the tints and hue turns, not PhotoLab's own rendering.")
            Spacer()
            if model.showPreview {
                Text("Amount").font(.caption).help("×1 is as suggested; ×2 and ×4 exaggerate the tints (not the hue turns), to see the direction of a small suggestion")
                Picker("Amount", selection: $model.previewAmount) {
                    Text("×1").tag(1.0)
                    Text("×2").tag(2.0)
                    Text("×4").tag(4.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
            }
        }
        if let caveats = model.previewSettings?.modelCaveats, !caveats.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The preview is less exact here than on the measured chart:")
                    ForEach(caveats, id: \.self) { Text("• " + $0).foregroundStyle(.secondary) }
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .help("The preview follows a model of PhotoLab measured on a chart (see the README). These parts of this suggestion lie outside what was measured or were only roughly fitted. Check them in PhotoLab.")
        }
        }
    }

    /// Everything to set in PhotoLab, in the order of its palettes: Color Grading, Selective Tone, HSL.
    @ViewBuilder
    private var photoLabTab: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Color Grading")
                        .font(.subheadline.weight(.semibold))
                        .help("A starting point, not a recipe: Hue and Saturation of the three wheels are chosen with a model of PhotoLab's Color Grading, measured on a chart (see the README), so that the dominant colors end up as close as possible to their target hues. The Amount in the Grading tab scales the Saturation. Check it in PhotoLab.")
                    Spacer()
                    Button("Export Preset…") { model.presentExportPanel(.dxoPreset) }
                        .controlSize(.small)
                        .disabled(model.colorGrading == nil)
                        .help("Save the suggested Color Grading as a DxO PhotoLab preset")
                }
                if let grading = model.colorGrading {
                    ForEach(grading.details, id: \.range) { detail in
                        gradingRow(detail.range.displayName, hue: detail.tintHue) {
                            if detail.reason == .tinted {
                                Text(detail.wheel.saturation > 0
                                     ? "Hue \(detail.wheel.hue) · Sat \(detail.wheel.saturation)"
                                         + (detail.wheel.luminance != 0 ? " · Lum \(detail.wheel.luminance)" : "")
                                     : "Lum \(detail.wheel.luminance)")
                                    .monospacedDigit()
                            } else {
                                Text(reasonText(detail.reason))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    let master = grading.preset.master
                    gradingRow("Master", hue: master.saturation > 0 ? DxOHue.toSRGB(Double(master.hue)) : nil) {
                        if master.saturation > 0 {
                            Text("Hue \(master.hue) · Sat \(master.saturation)")
                                .monospacedDigit()
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    gradingRow("Balance", hue: nil) {
                        Text("\(grading.preset.balance)")
                            .monospacedDigit()
                            .foregroundStyle(grading.preset.balance == 0 ? .secondary : .primary)
                    }
                } else {
                    Text("Needs colors with a harmony.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let grading = model.colorGrading {
                if grading.toneBlacks != 0 || grading.toneShadows != 0 {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selective Tone")
                            .font(.subheadline.weight(.semibold))
                        Text([grading.toneBlacks != 0 ? "Blacks \(grading.toneBlacks > 0 ? "+" : "")\(grading.toneBlacks)" : nil,
                              grading.toneShadows != 0 ? "Shadows \(grading.toneShadows > 0 ? "+" : "")\(grading.toneShadows)" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
                Divider()
                hslSection
            }
        }
    }

    /// One line of the Color Grading values: a swatch of the tint, the name, the values.
    private func gradingRow<Value: View>(_ name: String, hue: Double?, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(hue.map { SRGBColor.fromHSB(h: $0, s: 0.65, b: 0.95).swiftUIColor } ?? Color.clear)
                .overlay(Circle().strokeBorder(.secondary.opacity(0.5)))
                .frame(width: 12, height: 12)
            Text(name)
                .frame(width: 78, alignment: .leading)
            value()
            Spacer()
        }
        .font(.caption)
    }

    /// The Hue handle of each HSL channel in PhotoLab, in degrees on PhotoLab's own ring.
    @ViewBuilder
    private var hslSection: some View {
        let channels = model.hslSuggestions
        VStack(alignment: .leading, spacing: 8) {
            Text("HSL: Hue per channel")
                .font(.subheadline.weight(.semibold))
            if model.effectiveGradingTarget == .emphasize {
                Text("Aim at Harmony" + (model.isSeriesReferenceShown ? " or \(model.referenceTitle)" : "") + " in the Grading tab: there is no hue to turn toward while only the existing tints are strengthened.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if channels.isEmpty {
                Text("No channel needs a hue shift.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(channels, id: \.channel) { suggestion in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(SRGBColor.fromHSB(h: suggestion.channel.centerHue ?? 0, s: 0.75, b: 0.95).swiftUIColor)
                            .frame(width: 12, height: 12)
                        Text(suggestion.channel.displayName)
                            .frame(width: 62, alignment: .leading)
                        Text("Hue \(signedRounded(suggestion.hueShift, unit: "°"))"
                             + (suggestion.channel.direction(of: suggestion.hueShift).map { " → \($0.displayName.lowercased())" } ?? ""))
                            .monospacedDigit()
                        Text("colors " + suggestion.colors.map(String.init).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    if suggestion.isMixed {
                        Text("\(suggestion.channel.displayName): these colors want shifts from \(signedRounded(suggestion.range.lowerBound, unit: "°")) to \(signedRounded(suggestion.range.upperBound, unit: "°")); one handle cannot serve all of them.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .help("Degrees on PhotoLab's own hue ring, converted from the sRGB hue shifts in the list; accurate to a few degrees.\n\nTurn the Hue handle on the outer ring of PhotoLab's HSL wheel by this many degrees, toward the color named after the arrow (red → orange → yellow → green → cyan → blue → purple → magenta is a + turn, counter-clockwise on the ring). Saturation and Luminance you set by eye.")
    }

    private func reasonText(_ reason: ColorGradingSuggestion.Reason) -> String {
        switch reason {
        case .tinted: ""
        case .noColors: "no colors here"
        case .onTarget: "already on target"
        case .tooNeutral: "too neutral to tint"
        }
    }

    /// A hint when the nearly neutral parts of the photo lean to a color: grading comes after white balance.
    @ViewBuilder
    private func whiteBalanceNote() -> some View {
        let check = model.whiteBalance
        if let direction = check.direction, let advice = check.advice {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(check.verdict == .clear ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(check.verdict == .clear ? "Clear" : "Slight") \(direction) cast in the neutral areas (\(Int((check.neutralShare * 100).rounded())) % of the photo).")
                    Text("If they should be neutral, correct white balance first: \(advice). Then analyze again.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .help("Measured on the nearly neutral pixels (OKLab chroma below 0.035). A white wall at sunset is orange for a reason: this is a hint, not a verdict.")
        }
    }
}

/// The skin tone reference: a line at the reference hue inside a faint wedge covering the band
/// in which colors read as skin. Positions follow the active wheel (RGB or RYB).
struct SkinToneOverlay: View {
    let space: HueSpace
    let center: CGPoint
    let radius: CGFloat

    private let lineColor = Color(red: 1.0, green: 0.86, blue: 0.72)

    var body: some View {
        let range = SkinTone.hueRange
        let start = space.position(ofRGBHue: range.lowerBound)
        let span = ColorMath.signedAngle(from: start, to: space.position(ofRGBHue: range.upperBound))
        let rim = { (angle: Double) in WheelGeometry.point(hue: angle, saturation: 1, center: center, radius: radius) }
        let wedge = Path { path in
            path.move(to: center)
            for step in 0...12 {
                path.addLine(to: rim(start + span * Double(step) / 12))
            }
            path.closeSubpath()
        }
        ZStack {
            wedge.fill(lineColor.opacity(0.32))
            wedge.stroke(.white.opacity(0.55), lineWidth: 1)
            Path { path in
                path.move(to: center)
                path.addLine(to: WheelGeometry.point(rgbHue: SkinTone.referenceHue, space: space, saturation: 1,
                                                     center: center, radius: radius))
            }
            .stroke(lineColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .shadow(color: .black.opacity(0.65), radius: 1.5)
            Text("skin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.black.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(lineColor, in: Capsule())
                .position(WheelGeometry.point(rgbHue: SkinTone.referenceHue, space: space, saturation: 1.1,
                                              center: center, radius: radius))
        }
    }
}

/// The shared palette of the series as diamonds on the wheel: where this photo should land.
struct SeriesReferenceOverlay: View {
    let palette: [SharedColor]
    let space: HueSpace
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        ZStack {
            ForEach(Array(palette.enumerated()), id: \.offset) { index, shared in
                let hsb = shared.color.hsb
                ReferenceDiamond(number: index + 1, color: shared.color, size: 20 + 24 * sqrt(shared.share))
                    .position(WheelGeometry.point(rgbHue: hsb.h, space: space, saturation: hsb.s,
                                                  center: center, radius: radius))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A rotated square with a dashed rim, so it cannot be mistaken for a round marker.
struct ReferenceDiamond: View {
    let number: Int
    let color: SRGBColor
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.swiftUIColor)
                .frame(width: size * 0.72, height: size * 0.72)
                .rotationEffect(.degrees(45))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [4, 2]))
                        .frame(width: size * 0.72, height: size * 0.72)
                        .rotationEffect(.degrees(45))
                }
                .shadow(color: .black.opacity(0.5), radius: 2.5, y: 1)
            Text("\(number)")
                .font(.system(size: max(8, size * 0.32), weight: .bold, design: .rounded))
                .foregroundStyle(color.contrastingText)
        }
        .frame(width: size, height: size)
    }
}

/// Spokes at the harmony's target hues, plus an arc from each color to its nearest target.
struct HarmonyOverlay: View {
    let fit: HarmonyFit
    let markers: [Marker]
    let center: CGPoint
    let radius: CGFloat
    /// Draws the arc from each color to its target; off when the color markers are hidden, which the arcs start from.
    var showsShifts = true

    var body: some View {
        ZStack {
            Path { path in
                for hue in fit.targets {
                    path.move(to: center)
                    path.addLine(to: WheelGeometry.point(hue: hue, saturation: 1, center: center, radius: radius))
                }
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .shadow(color: .black.opacity(0.6), radius: 1.5)

            if fit.tolerance > 0 {
                // The sector around each target: colors inside it are on target. Drawn as a light fill with an edge in a dark and
                // a light line, so it shows on the pale middle and on the saturated rim alike.
                let wedges = Path { path in
                    for hue in fit.targets {
                        path.move(to: center)
                        let steps = max(2, Int(fit.tolerance))
                        for step in 0...steps {
                            let h = hue - fit.tolerance + 2 * fit.tolerance * Double(step) / Double(steps)
                            path.addLine(to: WheelGeometry.point(hue: h, saturation: 1, center: center, radius: radius))
                        }
                        path.closeSubpath()
                    }
                }
                wedges.fill(.white.opacity(0.30))
                wedges.stroke(.black.opacity(0.45), lineWidth: 2.5)
                wedges.stroke(.white.opacity(0.95), lineWidth: 1)
            }

            if showsShifts {
            Path { path in
                for marker in markers where DxOMapping.harmonyWeight(color: marker.color, share: 1) > 0 {
                    let hsb = marker.color.hsb
                    // From the color's position to its target's position, along the wheel the harmony lives on.
                    let start = fit.space.position(ofRGBHue: hsb.h)
                    let shift = marker.targetShift(harmony: fit) ?? 0
                    let delta = ColorMath.signedAngle(from: start, to: fit.space.position(ofRGBHue: hsb.h + shift))
                    guard abs(delta) >= 2 else { continue }
                    let steps = max(2, Int(abs(delta) / 2))
                    for step in 0...steps {
                        let p = WheelGeometry.point(hue: start + delta * Double(step) / Double(steps),
                                                    saturation: min(hsb.s, 1.1), center: center, radius: radius)
                        step == 0 ? path.move(to: p) : path.addLine(to: p)
                    }
                    let end = WheelGeometry.point(hue: start + delta, saturation: min(hsb.s, 1.1), center: center, radius: radius)
                    path.addEllipse(in: CGRect(x: end.x - 3, y: end.y - 3, width: 6, height: 6))
                }
            }
            .stroke(.black.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

/// CIE L* of each color on a black→white bar, split into DxO's tonal ranges.
struct LightnessStrip: View {
    let markers: [Marker]
    let selectedID: Marker.ID?
    /// Color at each marker's position in the graded version, if one is loaded (same order as `markers`).
    let afterColors: [SRGBColor?]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(height: 10)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    ForEach([33.0, 66.0], id: \.self) { l in
                        Rectangle().fill(.red.opacity(0.7))
                            .frame(width: 1, height: geo.size.height)
                            .position(x: geo.size.width * l / 100, y: geo.size.height / 2)
                    }
                    ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                        MarkerBadge(number: index + 1, color: marker.color, diameter: 18,
                                    isSelected: marker.id == selectedID)
                            .position(x: geo.size.width * min(100, max(0, marker.color.lightness)) / 100,
                                      y: geo.size.height / 2)
                        if index < afterColors.count, let after = afterColors[index] {
                            GhostBadge(number: index + 1, color: after, diameter: 14)
                                .position(x: geo.size.width * min(100, max(0, after.lightness)) / 100,
                                          y: geo.size.height / 2 + 9)
                        }
                    }
                }
            }
            .frame(height: 26)
            HStack {
                Text("Shadows")
                Spacer()
                Text("Midtones")
                Spacer()
                Text("Highlights")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

/// Arrows from each color's original position on the wheel to where it ended up after grading.
struct AfterTrails: View {
    let markers: [Marker]
    /// Color at each marker's position in the graded version (same order as `markers`).
    let afterColors: [SRGBColor?]
    let space: HueSpace
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        Path { path in
            for (marker, afterColor) in zip(markers, afterColors) {
                guard let after = afterColor else { continue }
                let b = marker.color.hsb, a = after.hsb
                let from = WheelGeometry.point(rgbHue: b.h, space: space, saturation: b.s, center: center, radius: radius)
                let to = WheelGeometry.point(rgbHue: a.h, space: space, saturation: a.s, center: center, radius: radius)
                let length = hypot(to.x - from.x, to.y - from.y)
                guard length > 6 else { continue }
                path.move(to: from)
                path.addLine(to: to)
                // Arrow head.
                let angle = atan2(to.y - from.y, to.x - from.x)
                for side in [-1.0, 1.0] {
                    path.move(to: to)
                    path.addLine(to: CGPoint(x: to.x - 9 * cos(angle + side * 0.45),
                                             y: to.y - 9 * sin(angle + side * 0.45)))
                }
            }
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .shadow(color: .black.opacity(0.7), radius: 1.5)
    }
}
