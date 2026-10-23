import AppKit
import ColorCore
import Observation
import UniformTypeIdentifiers

@MainActor
extension AnalysisModel {
    // MARK: Marker editing

    /// The markers and the selection, as undo restores them.
    struct MarkerState: Sendable {
        var markers: [Marker]
        var selected: Marker.ID?
    }

    var markerState: MarkerState { MarkerState(markers: markers, selected: selectedMarkerID) }

    /// Makes the current markers the state that Undo returns to, under `name` ("Undo Move Marker 3").
    func registerMarkerUndo(_ name: String, state: MarkerState? = nil) {
        guard let undoManager else { return }
        let state = state ?? markerState
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreMarkers(state, name: name) }
        }
        undoManager.setActionName(name)
    }

    /// Puts earlier markers back. The state it replaces is registered as well, so Undo and Redo mirror each other.
    func restoreMarkers(_ state: MarkerState, name: String) {
        registerMarkerUndo(name)
        markers = state.markers
        selectedMarkerID = state.selected.flatMap { id in state.markers.contains { $0.id == id } ? id : nil }
        hoveredMarkerID = nil
        updateShares()
        isDirty = true
        showNotice(undoManager?.isRedoing == true ? "Redid \(name)" : "Undid \(name)")
    }

    /// Call when a drag on a marker starts; the undo step is recorded when the marker moves.
    func beginMarkerMove(_ id: Marker.ID) {
        releaseKeyboardFocus()
        pendingMoveUndo = ("Move Marker \(number(of: id))", markerState)
    }

    func endMarkerMove() {
        pendingMoveUndo = nil
    }

    /// Moves the selected marker by whole pixels of the displayed photo (arrow keys; ⇧ = 10).
    /// Returns false when no marker is selected, so the key can do its usual job.
    func nudgeSelectedMarker(dx: Int, dy: Int) -> Bool {
        guard let image, let id = selectedMarkerID, let i = markers.firstIndex(where: { $0.id == id }) else { return false }
        let now = Date()
        if lastNudge?.id != id || now.timeIntervalSince(lastNudge?.time ?? .distantPast) > 1.0 {
            registerMarkerUndo("Nudge Marker \(i + 1)")
        }
        lastNudge = (id, now)
        let location = markers[i].location
        moveMarkerWithoutUndo(id, to: CGPoint(x: location.x + Double(dx) / Double(image.display.width),
                                              y: location.y + Double(dy) / Double(image.display.height)))
        return true
    }

    func moveMarker(_ id: Marker.ID, to location: CGPoint) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        if let pending = pendingMoveUndo {
            registerMarkerUndo(pending.name, state: pending.state)
            pendingMoveUndo = nil
        }
        moveMarkerWithoutUndo(id, to: location)
    }

    func moveMarkerWithoutUndo(_ id: Marker.ID, to location: CGPoint) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = CGPoint(x: min(1, max(0, location.x)), y: min(1, max(0, location.y)))
        markers[i].location = clamped
        markers[i].color = sample(at: clamped, radius: markers[i].sampleRadius)
        updateShares()
        isDirty = true
    }

    /// Adds a marker on the color that no marker represents yet — a small subject or an accent that the
    /// automatic analysis passed over (a red boat on blue water). Every call finds the next one.
    @discardableResult
    func suggestMarker() -> Task<Void, Never> {
        guard let image, !isAnalyzing else { return Task {} }
        let existing = markers.map(\.color.oklab)
        let pixelWeights = weights
        return Task {
            let found = await Task.detached(priority: .userInitiated) {
                DominantColorAnalyzer.findMissingColor(in: image.analysis, existing: existing, weights: pixelWeights)
            }.value
            guard self.image?.url == image.url else { return }
            guard let found else {
                showNotice("Every part of the photo is already close to a marker color")
                return
            }
            addMarker(at: found.location, name: "Suggest Marker")
            showNotice("Added a marker on a color that was missing")
        }
    }

    func addMarker(at location: CGPoint, name: String = "Add Marker") {
        guard image != nil else { return }
        registerMarkerUndo(name)
        let marker = Marker(location: location, color: sample(at: location))
        markers.append(marker)
        selectedMarkerID = marker.id
        updateShares()
        isDirty = true
    }

    func removeMarker(_ id: Marker.ID?) {
        guard let id, markers.contains(where: { $0.id == id }) else { return }
        registerMarkerUndo("Remove Marker \(number(of: id))")
        markers.removeAll { $0.id == id }
        if selectedMarkerID == id { selectedMarkerID = nil }
        if hoveredMarkerID == id { hoveredMarkerID = nil }
        updateShares()
        isDirty = true
    }

    /// Protects a color (or lifts the protection): the suggestions then leave its hue where it is.
    func toggleProtected(_ id: Marker.ID) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let protect = !isProtected(markers[i])
        registerMarkerUndo(protect ? "Protect Color" : "Unprotect Color")
        // Back to automatic when the choice is what automatic would do anyway.
        markers[i].protection = protect == isAutomaticallyProtected(markers[i]) ? nil : protect
        isDirty = true
        refreshPreview()
    }

    /// True when the targets on the wheel can be dragged: they are predictions of a grading that aims at hues, not a loaded
    /// graded version, and not the plain strengthening of the existing tints.
    var canEditTargets: Bool { afterImage == nil && effectiveGradingTarget != .emphasize }

    /// Aims a color at `hue` (sRGB degrees) instead of at its automatic target, or back at the automatic one with nil.
    func setTargetHue(_ hue: Double?, for id: Marker.ID) {
        guard let i = markers.firstIndex(where: { $0.id == id }), markers[i].targetHue != hue else { return }
        markers[i].targetHue = hue
        isDirty = true
        refreshPreview()
    }

    func isAutomaticallyProtected(_ marker: Marker) -> Bool {
        protectSkin && SkinTone.offset(of: marker.color) != nil
    }

    /// True when the suggestions leave this color's hue alone: protected by hand, or a skin tone with automatic protection on.
    func isProtected(_ marker: Marker) -> Bool {
        marker.protection ?? isAutomaticallyProtected(marker)
    }

    /// Why a color is protected, for the list; nil when it is not.
    func protectionNote(for marker: Marker) -> String? {
        guard isProtected(marker), marker.targetHue == nil else { return nil }
        if marker.protection == true { return "Kept as it is: the suggestions do not aim it at the harmony" }
        return "Skin tone, kept as it is: the suggestions do not aim it at the harmony"
    }

    func number(of id: Marker.ID) -> Int {
        (markers.firstIndex { $0.id == id } ?? 0) + 1
    }

    func sample(at location: CGPoint, radius: Double = AnalysisModel.defaultSampleRadius) -> SRGBColor {
        image?.sampling.sample(at: location, radius: radius) ?? SRGBColor(r: 0, g: 0, b: 0)
    }

    /// Sets how far around its spot a color is averaged (nil = the default) and samples it again.
    func setSampleRadius(_ radius: Double?, for id: Marker.ID) {
        guard let i = markers.firstIndex(where: { $0.id == id }) else { return }
        let clamped = radius.map { min(Self.sampleRadiusRange.upperBound, max(Self.sampleRadiusRange.lowerBound, $0)) }
        guard clamped != markers[i].customSampleRadius else { return }
        // A drag on the slider is one undo step: only the first change after a pause registers one.
        let now = Date()
        if lastSampleRadiusChange.map({ now.timeIntervalSince($0) > 1 }) ?? true { registerMarkerUndo("Marker Size") }
        lastSampleRadiusChange = now
        markers[i].customSampleRadius = clamped
        markers[i].color = sample(at: markers[i].location, radius: markers[i].sampleRadius)
        updateShares()
        isDirty = true
        refreshPreview()
    }

    func updateShares() {
        guard let image else { return }
        let colors = markers.map(\.color.oklab)
        let area = DominantColorAnalyzer.shares(of: colors, in: image.analysis)
        let weighted = weights.map { DominantColorAnalyzer.shares(of: colors, in: image.analysis, weights: $0) } ?? area
        for i in markers.indices {
            markers[i].areaShare = area[i]
            markers[i].share = weighted[i]
        }
        refreshRegion()
    }

    func refreshRegion() {
        guard showRegions, let image, let id = highlightedMarkerID,
              let index = markers.firstIndex(where: { $0.id == id }) else {
            regionOverlay = nil
            regionCoverage = nil
            regionWeightedShare = nil
            return
        }
        let mask = RegionMask(colorAt: index, of: markers.map(\.color.oklab), in: image.analysis)
        regionOverlay = mask.overlayImage()
        regionCoverage = mask.coverage
        regionWeightedShare = isWeighted ? markers[index].share : nil
    }
}
