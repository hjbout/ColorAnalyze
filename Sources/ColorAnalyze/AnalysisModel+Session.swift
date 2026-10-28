import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

@MainActor
extension AnalysisModel {
    // MARK: Session

    func makeSession() -> Session? {
        guard let image else { return nil }
        return Session(
            photo: image.url.lastPathComponent,
            graded: afterImage?.url.path,
            colorCount: colorCount,
            weighting: weighting == .off ? nil : weighting.rawValue,
            markers: markers.map { .init(x: $0.location.x, y: $0.location.y, hex: $0.color.hex, isProtected: $0.protection, targetHue: $0.targetHue, referenceIndex: $0.referenceIndex, sampleRadius: $0.customSampleRadius, isAccent: $0.isAccent ? true : nil) },
            harmony: harmonyChoice?.rawValue,
            harmonyRotation: harmonyRotationOverride,
            hueSpace: hueSpace == .rgb ? nil : hueSpace.rawValue,
            compareMode: afterImage == nil ? nil : compareMode.rawValue,
            splitPosition: afterImage == nil ? nil : splitPosition,
            intention: intention,
            reference: referencePhoto?.url.path,
            variants: variants.isEmpty ? nil : variants.map(\.session),
            accents: accentCount == 0 ? nil : accentCount
        )
    }

    /// Writes the session as JSON next to the photo.
    func saveSession() {
        guard let image, let session = makeSession() else { return }
        let sidecar = Session.sidecarURL(for: image.url)
        do {
            try session.write(to: sidecar)
            isDirty = false
            showNotice("Saved session as \(sidecar.lastPathComponent)")
        } catch {
            errorMessage = "Could not save the session next to the photo: \(error.localizedDescription)"
        }
    }

    func savedSession(for photo: URL) -> Session? {
        let sidecar = Session.sidecarURL(for: photo)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return nil }
        do {
            return try Session.read(from: sidecar)
        } catch {
            errorMessage = "Could not restore the saved session (\(error.localizedDescription)). The photo was analyzed again."
            return nil
        }
    }

    /// Re-creates markers from a saved session. Colors are sampled from the photo again.
    func restore(_ session: Session, photo: URL, graded override: URL?) async {
        suppressRemembering += 1
        defer { suppressRemembering -= 1 }
        isRestoring = true
        colorCount = min(12, max(3, session.colorCount))
        accentCount = min(3, max(0, session.accents ?? 0))
        weighting = session.weighting.flatMap(Weighting.init(rawValue:)) ?? .off
        isRestoring = false
        await prepareWeights()
        hueSpace = session.hueSpace.flatMap(HueSpace.init(rawValue:)) ?? .rgb
        intention = session.intention ?? ""
        variants = (session.variants ?? []).compactMap(GradeVariant.init(session:))
        harmonyChoice = session.harmony.flatMap(HarmonyKind.init(rawValue:))
        harmonyRotationOverride = session.harmonyRotation
        markers = session.markers.map { saved in
            let location = CGPoint(x: min(1, max(0, saved.x)), y: min(1, max(0, saved.y)))
            let radius = saved.sampleRadius.map {
                min(Self.sampleRadiusRange.upperBound, max(Self.sampleRadiusRange.lowerBound, $0))
            }
            var marker = Marker(location: location, color: sample(at: location, radius: radius ?? Self.defaultSampleRadius))
            marker.customSampleRadius = radius
            marker.protection = saved.isProtected
            marker.targetHue = saved.targetHue
            marker.referenceIndex = saved.referenceIndex
            marker.isAccent = saved.isAccent ?? false
            return marker
        }
        selectedMarkerID = nil
        hoveredMarkerID = nil
        ignoreHoverUntil = Date().addingTimeInterval(0.6)
        updateShares()
        isAnalyzing = false
        refreshPreview()

        if let gradedURL = override ?? session.gradedURL(photoFolder: photo.deletingLastPathComponent()) {
            await loadGraded(gradedURL, markDirty: false)
            if afterImage != nil {
                compareMode = session.compareMode.flatMap(CompareMode.init(rawValue:)) ?? .split
                splitPosition = session.splitPosition ?? 0.5
            }
        }
        // The reference the photo was aimed at; one that is missing leaves the current reference alone.
        var missingReference: String?
        if let reference = session.reference {
            if let referenceURL = session.referenceURL(photoFolder: photo.deletingLastPathComponent()) {
                await openReference(referenceURL, keepChoices: true).value
            } else {
                missingReference = URL(fileURLWithPath: reference).lastPathComponent
            }
        }
        isDirty = false
        showNotice(missingReference.map { "Restored the saved session; the reference photo \($0) was not found" }
                   ?? "Restored the saved session")
    }

    func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(for: .seconds(5))
            if notice == text { notice = nil }
        }
    }

    // MARK: Report export

    func reportData() -> ReportData? {
        guard let image else { return nil }
        return ReportData(
            title: image.url.lastPathComponent,
            date: Date(),
            before: image.display,
            after: afterImage?.display,
            markers: markers,
            afterColors: markers.map { afterImage == nil ? nil : afterColor(for: $0) },
            harmony: harmony,
            harmonyIsAutoDetected: harmonyChoice == nil,
            afterHarmony: afterImage == nil ? nil : afterHarmony,
            weighting: isWeighted ? weighting.title : nil,
            hueSpace: hueSpace,
            showSkinTone: showSkinTone,
            seriesPalette: isSeriesReferenceShown ? seriesPalette : [],
            referenceTitle: referenceTitle,
            seriesInfos: markers.map { seriesInfo(for: $0) },
            seriesFit: seriesFit,
            afterSeriesFit: afterImage == nil ? nil : afterSeriesFit,
            intention: Intention.cleaned(intention)
        )
    }

    func exportReport(to url: URL) throws {
        guard let data = reportData() else { throw ReportError.noPhoto }
        guard let png = ReportRenderer.pngData(for: data) else { throw ReportError.renderFailed }
        try png.write(to: url, options: .atomic)
    }

    /// The color list with the context needed to interpret it (harmony, graded version).
    func colorExport() -> ColorExport? {
        guard let image else { return nil }
        let fit = harmony
        let records = markers.enumerated().map { index, marker in
            ColorRecord(number: index + 1, location: marker.location, color: marker.color, share: marker.share,
                        areaShare: isWeighted ? marker.areaShare : nil,
                        after: afterImage == nil ? nil : afterColor(for: marker), harmony: fit, targetHue: marker.targetHue)
        }
        return ColorExport(
            photo: image.url.lastPathComponent,
            graded: afterImage?.url.path,
            weighting: isWeighted ? weighting.rawValue : nil,
            intention: intention,
            harmony: fit.map { .init(fit: $0, autoDetected: harmonyChoice == nil, fitAfter: afterImage == nil ? nil : afterHarmony) },
            whiteBalance: whiteBalance.verdict == .unknown ? nil : .init(whiteBalance),
            colors: records
        )
    }

    func exportColors(to url: URL, format: ExportFormat) throws {
        guard let export = colorExport() else { throw ReportError.noPhoto }
        switch format {
        case .colorsCSV: try Data(export.csv().utf8).write(to: url, options: .atomic)
        case .colorsCSVExcel: try Data(export.csv(style: .europeanExcel).utf8).write(to: url, options: .atomic)
        case .colorsJSON: try export.json().write(to: url, options: .atomic)
        case .reportPNG: try exportReport(to: url)
        case .swatches:
            let swatches = markers.enumerated().map { ("\($0.offset + 1) – \($0.element.color.hex)", $0.element.color) }
            let group = (image?.url.deletingPathExtension().lastPathComponent ?? "Photo") + " – ColorAnalyze"
            try AdobeSwatchExchange.data(groupName: group, swatches: swatches).write(to: url, options: .atomic)
        case .palettePNG:
            guard let image, let png = ReportRenderer.pngData(for: PaletteData(
                title: image.url.lastPathComponent,
                subtitle: "\(markers.count) dominant colors · " + Date().formatted(date: .long, time: .shortened),
                entries: markers.enumerated().map { .init(number: $0.offset + 1, color: $0.element.color, share: $0.element.share) }
            )) else { throw ReportError.renderFailed }
            try png.write(to: url, options: .atomic)
        case .dxoPreset:
            guard let grading = colorGrading else { throw ReportError.noGrading }
            try Data(grading.preset.luaText().utf8).write(to: url, options: .atomic)
        }
    }

    /// Applies the grading as the preview shows it (style, amounts, hand-set targets, protected colors) to the photo at its
    /// full resolution and saves it in the photo's color space, with its metadata.
    func presentGradedPhotoPanel(_ format: GradedPhotoExport.Format) {
        guard let image else { return }
        guard var settings = prediction()?.settings else { errorMessage = ReportError.noGrading.localizedDescription; return }
        settings.amount = previewAmount
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = image.url.deletingPathExtension().lastPathComponent + " – graded." + format.fileExtension
        panel.directoryURL = image.url.deletingLastPathComponent()
        panel.message = (format == .tiff ? "Save the graded photo as a 16-bit TIFF" : "Save the graded photo as a JPEG")
            + ", in the color space of the original and with its metadata."
            + (previewAmount == 1 ? "" : " The preview amount ×\(previewAmount.formatted()) is applied.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = image.url, graded = settings
        showNotice("Rendering \(url.lastPathComponent)…")
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try GradedPhotoExport.write(photo: source, settings: graded, format: format, to: url)
                }.value
                showNotice("Exported \(url.lastPathComponent)")
            } catch {
                errorMessage = "Could not export the graded photo: \(error.localizedDescription)"
            }
        }
    }

    func presentExportPanel(_ format: ExportFormat) {
        guard let image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = image.url.deletingPathExtension().lastPathComponent + format.fileNameSuffix + "." + format.fileExtension
        panel.directoryURL = (format == .dxoPreset ? DxOLocations.colorGradingPresetsFolder() : nil)
            ?? image.url.deletingLastPathComponent()
        panel.message = format.panelMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportColors(to: url, format: format)
            showNotice("Exported \(url.lastPathComponent)")
        } catch {
            errorMessage = "Could not export \(format.shortName): \(error.localizedDescription)"
        }
    }
}
