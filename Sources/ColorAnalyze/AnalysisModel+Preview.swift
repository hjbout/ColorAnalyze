import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

@MainActor
extension AnalysisModel {
    // MARK: Preview of the suggestion

    /// How the preview is shown next to the original: right of a divider you can drag, or in a second photo below it.
    enum PreviewLayout: String, CaseIterable, Identifiable {
        case split = "Divider"
        case stacked = "Below"
        var id: String { rawValue }
    }
    /// True when the preview is drawn as a second photo below the original.
    var isStackedPreview: Bool { showPreview && previewImage != nil && afterImage == nil && previewLayout == .stacked }

    /// The suggestion as settings of the calibrated model, as suggested (amount 1), with the plan to apply them.
    func prediction() -> (settings: GradePreviewSettings, plan: GradePreview.Plan)? {
        let key = suggestionKey
        if let cache = predictionCache, cache.key == key {
            guard let settings = cache.settings, let plan = cache.plan else { return nil }
            return (settings, plan)
        }
        var result: (GradePreviewSettings, GradePreview.Plan)?
        if let grading = colorGrading {
            let settings = gradeSettings(for: currentChoices, grading: grading)
            result = (settings, GradePreview.Plan(settings))
        }
        predictionCache = (key, result?.0, result?.1)
        return result
    }

    /// A grading setup's suggestion as settings of the calibrated model, as suggested (amount 1).
    func gradeSettings(for setup: GradeVariant, grading: ColorGradingSuggestion.Suggestion) -> GradePreviewSettings {
        func tint(_ wheel: ColorGradingPreset.Wheel) -> GradePreviewSettings.Tint {
            .init(dxoHue: Double(wheel.hue), saturation: Double(wheel.saturation), luminance: Double(wheel.luminance))
        }
        var settings = GradePreviewSettings(shadows: tint(grading.preset.shadows), midtones: tint(grading.preset.midtones),
                                            highlights: tint(grading.preset.highlights), master: tint(grading.preset.master),
                                            balance: Double(grading.preset.balance),
                                            toneBlacks: Double(grading.toneBlacks), toneShadows: Double(grading.toneShadows))
        for channel in hslSuggestions(for: setup) { settings.hueShifts[channel.channel] = channel.hueShift }
        return settings
    }

    /// What the preview image applies; nil while it is off or when there is nothing to suggest yet. Changes with the
    /// markers, the harmony, the strength and the aim, and the preview follows.
    var previewSettings: GradePreviewSettings? {
        guard showPreview, var settings = prediction()?.settings else { return nil }
        settings.amount = previewAmount
        return settings
    }

    /// True while the preview is on and there is a suggestion: the colors "after" are then the predicted ones.
    var isPreviewActive: Bool { showPreview && afterImage == nil && prediction() != nil }

    /// A graded version is loaded, or the preview predicts one.
    var hasAfterColors: Bool { afterImage != nil || isPreviewActive }

    /// "After" for a graded version, "Predicted" for the preview.
    var afterLabel: String { afterImage == nil ? "Predicted" : "After" }

    /// The color a marker gets from the suggestion, as the calibrated model predicts PhotoLab will render it.
    func predictedColor(for marker: Marker) -> SRGBColor? {
        guard showPreview, let plan = prediction()?.plan else { return nil }
        let linear = marker.color.linear
        return SRGBColor(linear: plan.applyLinear(linear: linear, lab: ColorMath.linearToOKLab(linear))).clamped
    }

    func togglePreview() {
        guard afterImage == nil else { return }
        showPreview.toggle()
    }

    /// Renders the preview in the background. While a render runs, newer requests wait and only the newest is rendered
    /// next, so a drag shows a stream of frames that keeps up with it instead of one frame once it rests.
    func refreshPreview() {
        guard showPreview, afterImage == nil, let image, let settings = previewSettings else {
            pendingPreview = nil
            previewImage = nil
            if self.image == nil { previewSource = nil }
            return
        }
        pendingPreview = (image, settings)
        guard previewTask == nil else { return }   // the running loop picks it up
        previewTask = Task { await renderPendingPreviews() }
    }

    private func renderPendingPreviews() async {
        while let (image, settings) = pendingPreview {
            pendingPreview = nil
            let buffer: PixelBuffer
            if let source = previewSource, source.image === image.display {
                buffer = source.buffer
            } else {
                let display = image.display
                buffer = await Task.detached(priority: .userInitiated) {
                    PixelBuffer(image: display, maxDimension: max(display.width, display.height))
                }.value
                previewSource = (display, buffer)
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                GradePreview.render(buffer, settings: settings)
            }.value
            // Shown unless the preview was switched off or the photo changed in the meantime.
            if showPreview, afterImage == nil, self.image?.display === image.display { previewImage = rendered }
        }
        previewTask = nil
    }
}
