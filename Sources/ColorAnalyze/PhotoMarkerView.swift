import ColorCore
import SwiftUI

/// The photo with draggable markers. Double-click adds a marker. With a graded version
/// loaded, shows before / after / split; hovering or selecting a marker dims everything
/// outside the region of that color. The photo can be zoomed (pinch, ⌘-scroll, buttons, menu)
/// and moved (scroll or drag) so markers can be placed precisely.
struct PhotoMarkerView: View {
    @Environment(AnalysisModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if let image = model.image {
                // With the preview below the original, each of the two photos gets half of the pane and the same view of the photo.
                let stacked = model.isStackedPreview
                let gap: CGFloat = 8
                let pane = stacked ? CGSize(width: geo.size.width, height: max(1, (geo.size.height - gap) / 2)) : geo.size
                let imageSize = CGSize(width: image.display.width, height: image.display.height)
                let fit = fittedRect(imageSize, in: pane)
                let viewport = model.viewport.clamped(photoFit: fit.size, pane: pane)
                let rect = viewport.photoRect(photoFit: fit.size, pane: pane)
                let visible = rect.intersection(CGRect(origin: .zero, size: pane))
                let zoomed = viewport.isZoomed
                let previewActive = model.showPreview && model.previewImage != nil && model.afterImage == nil
                VStack(spacing: gap) {
                ZStack(alignment: .topLeading) {
                    photo(image: image, size: rect.size, pixelScale: rect.width / imageSize.width,
                          fit: fit.size, pane: pane)
                        .position(x: rect.midX, y: rect.midY)

                    comparisonTags(visible: visible, previewActive: previewActive, stacked: stacked)

                    if (model.afterImage != nil && model.compareMode == .split) || (previewActive && !stacked) {
                        splitDivider(in: rect, visible: visible)
                    }

                    ForEach(Array(model.markers.enumerated()), id: \.element.id) { index, marker in
                        MarkerBadge(number: index + 1, color: model.displayColor(for: marker),
                                    diameter: zoomed ? 20 : 26, isSelected: marker.id == model.selectedMarkerID)
                            .position(x: rect.minX + marker.location.x * rect.width,
                                      y: rect.minY + marker.location.y * rect.height)
                            // No .onHover here: with it, marker and divider drags stop working.
                            // The region still shows while a marker is selected or dragged.
                            .gesture(dragGesture(for: marker, in: rect))
                            .contextMenu {
                                ReferenceMatchMenu(markerID: marker.id)
                                Button(model.isProtected(marker) ? "Unprotect Color \(index + 1)" : "Protect Color \(index + 1) (keep its hue)") { model.toggleProtected(marker.id) }
                                Button("Remove Marker \(index + 1)") { model.removeMarker(marker.id) }
                            }
                            .help("Drag to sample another part of the photo")
                    }

                    sampleAid(rect: rect)
                }
                .coordinateSpace(.named("photoPane"))
                .frame(width: pane.width, height: pane.height)
                // A click anywhere on the pane that is not a marker (also beside the photo) lets go of the selection.
                .contentShape(Rectangle())
                .onTapGesture { model.selectedMarkerID = nil }
                .clipped()
                .overlay(alignment: .bottom) { captions }
                .overlay(alignment: .bottomTrailing) { zoomHUD }

                if stacked, let preview = model.previewImage {
                    previewPane(preview, rect: rect, imageSize: imageSize, fit: fit.size, pane: pane)
                }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .bottomLeading) { if previewActive { layoutSwitch } }
                .background(PaneEventCatcher(
                    // The lower photo shows the same view as the upper one: a pointer there counts as at the same place above.
                    onScroll: { scroll, location in
                        handleScroll(scroll, at: upperLocation(location, pane: pane, gap: gap, stacked: stacked), fit: fit.size, pane: pane)
                    },
                    onMagnify: { magnification, location in
                        handleMagnify(magnification, at: upperLocation(location, pane: pane, gap: gap, stacked: stacked), fit: fit.size, pane: pane)
                    },
                    onArrow: { dx, dy in
                        let moved = model.nudgeSelectedMarker(dx: dx, dy: dy)
                        if moved { revealSelectedMarker(fit: fit.size, pane: pane) }
                        return moved
                    }
                ))
                .onAppear { keepViewportValid(image: image, fit: fit.size, pane: pane) }
                .onChange(of: pane) { keepViewportValid(image: image, fit: fit.size, pane: pane) }
                .onChange(of: model.viewport) { keepViewportValid(image: image, fit: fit.size, pane: pane) }
                .onChange(of: model.previewSettings) { model.refreshPreview() }
                // Picking a marker in the list or on the wheel, or adding one, brings it into view when zoomed in.
                .onChange(of: model.selectedMarkerID) { revealSelectedMarker(fit: fit.size, pane: pane) }
            } else {
                emptyState.frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Photo layers

    private func photo(image: LoadedImage, size: CGSize, pixelScale: CGFloat, fit: CGSize, pane: CGSize) -> some View {
        // Beyond ~1.5 screen points per image pixel show the pixels themselves, like an editor at high zoom.
        let interpolation: Image.Interpolation = pixelScale > 1.5 ? .none : .high
        return ZStack {
            Image(decorative: image.display, scale: 1)
                .resizable()
                .interpolation(interpolation)
            if let after = model.afterImage, model.compareMode != .before {
                Image(decorative: after.display, scale: 1)
                    .resizable()
                    .interpolation(interpolation)
                    .clipShape(RightPart(fraction: model.compareMode == .split ? model.splitPosition : 0))
            } else if model.afterImage == nil, model.showPreview, model.previewLayout == .split, let preview = model.previewImage {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(interpolation)
                    .clipShape(RightPart(fraction: model.splitPosition))
            }
            if let saliency = model.saliencyOverlay {
                Image(decorative: saliency, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .allowsHitTesting(false)
            }
            if let overlay = model.regionOverlay {
                Image(decorative: overlay, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .onTapGesture(count: 2) { location in
            model.addMarker(at: CGPoint(x: location.x / size.width, y: location.y / size.height))
        }
        .onTapGesture { model.selectedMarkerID = nil }
        .gesture(panGesture(fit: fit, pane: pane))
    }

    /// "Before" / "After" labels in the corners of the visible part of the photo.
    @ViewBuilder
    private func comparisonTags(visible: CGRect, previewActive: Bool, stacked: Bool) -> some View {
        if (model.afterImage != nil || previewActive), !visible.isNull, visible.width > 0, visible.height > 0 {
            Color.clear
                .frame(width: visible.width, height: visible.height)
                .overlay(alignment: .topLeading) {
                    tag(previewActive ? "Original" : model.compareMode == .after ? "After" : "Before")
                }
                .overlay(alignment: .topTrailing) {
                    if previewActive { if !stacked { tag("Preview") } } else if model.compareMode == .split { tag("After") }
                }
                .position(x: visible.midX, y: visible.midY)
                .allowsHitTesting(false)
        }
    }

    /// Switch between the preview right of a divider and below the original: two icons in a small capsule in the lower left corner of the photo pane.
    private var layoutSwitch: some View {
        HStack(spacing: 2) {
            ForEach(AnalysisModel.PreviewLayout.allCases) { layout in
                let selected = model.previewLayout == layout
                Button {
                    model.previewLayout = layout
                } label: {
                    Image(systemName: layout == .split ? "rectangle.split.2x1" : "rectangle.split.1x2")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 22)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background(selected ? Color.accentColor : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(layout == .split ? "Preview right of a divider you can drag" : "Preview in a second photo below the original")
                .accessibilityLabel(layout == .split ? "Preview next to the original, with a divider" : "Preview below the original")
            }
        }
        .padding(3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        .padding(10)
    }

    /// The preview under the original: the same part of the photo at the same zoom, with its own label. Dragging it moves both.
    private func previewPane(_ preview: CGImage, rect: CGRect, imageSize: CGSize, fit: CGSize, pane: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(rect.width / imageSize.width > 1.5 ? .none : .high)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            if let visible = Optional(rect.intersection(CGRect(origin: .zero, size: pane))), !visible.isNull, visible.width > 0 {
                Color.clear
                    .frame(width: visible.width, height: visible.height)
                    .overlay(alignment: .topLeading) { tag("Preview") }
                    .position(x: visible.midX, y: visible.midY)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(.named("photoPane"))
        .frame(width: pane.width, height: pane.height)
        .contentShape(Rectangle())
        .gesture(panGesture(fit: fit, pane: pane))
        .clipped()
    }

    /// A pointer in the lower photo, as a place in the upper one.
    private func upperLocation(_ location: CGPoint, pane: CGSize, gap: CGFloat, stacked: Bool) -> CGPoint {
        guard stacked, location.y > pane.height + gap / 2 else { return location }
        return CGPoint(x: location.x, y: location.y - pane.height - gap)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .allowsHitTesting(false)
    }

    private func splitDivider(in rect: CGRect, visible: CGRect) -> some View {
        ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: visible.height)
                .shadow(color: .black.opacity(0.5), radius: 2)
            Circle()
                .fill(.white)
                .frame(width: 28, height: 28)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.7))
                }
                .shadow(color: .black.opacity(0.5), radius: 3)
        }
        .frame(width: 44, height: max(visible.height, 1))
        .contentShape(Rectangle())
        .position(x: rect.minX + model.splitPosition * rect.width, y: visible.midY)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("photoPane"))
                .onChanged { value in
                    model.splitPosition = min(0.98, max(0.02, (value.location.x - rect.minX) / rect.width))
                }
        )
        .help("Drag to compare before and after")
    }

    /// For the selected marker, when zoomed in: the area its color is averaged over, with ticks and a dot
    /// at the exact spot, so it can be placed precisely under a marker badge.
    @ViewBuilder
    private func sampleAid(rect: CGRect) -> some View {
        if let id = model.selectedMarkerID, let marker = model.markers.first(where: { $0.id == id }) {
            let r = marker.sampleRadius * min(rect.width, rect.height)
            if r >= 4 {
                ZStack {
                    Circle()
                        .strokeBorder(.black.opacity(0.55), lineWidth: 3.5)
                        .frame(width: 2 * r, height: 2 * r)
                    Circle()
                        .strokeBorder(.white, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .frame(width: 2 * r, height: 2 * r)
                    ForEach([0.0, 90, 180, 270], id: \.self) { angle in
                        Capsule()
                            .fill(.white)
                            .frame(width: 2, height: 9)
                            .shadow(color: .black.opacity(0.8), radius: 1)
                            .offset(y: -(r + 9))
                            .rotationEffect(.degrees(angle))
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1))
                }
                .frame(width: 2 * r + 40, height: 2 * r + 40)
                .position(x: rect.minX + marker.location.x * rect.width,
                          y: rect.minY + marker.location.y * rect.height)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var captions: some View {
        VStack(spacing: 6) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            if model.afterAspectMismatch {
                Label("The graded version has a different aspect ratio — markers may not line up.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            if model.showSaliency, model.saliencyOverlay != nil {
                Label("Subject map — the darker the area, the less it counts", systemImage: "viewfinder")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
            if let id = model.highlightedMarkerID, let coverage = model.regionCoverage {
                Text(String(format: "Region of color %d · %.1f%% of the photo", model.number(of: id), coverage * 100)
                     + (model.regionWeightedShare.map { String(format: " · %.1f%% weighted", $0 * 100) } ?? ""))
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(8)
        .allowsHitTesting(false)
    }

    /// Zoom level and a way back to the whole photo, shown while zoomed in.
    @ViewBuilder
    private var zoomHUD: some View {
        if model.viewport.isZoomed {
            HStack(spacing: 8) {
                Text(model.zoomLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                Button("Fit") { model.fitPhoto() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .help("Scroll or drag to move the photo · ⌘-scroll or pinch to zoom · ⌘0 shows the whole photo")
        }
    }

    // MARK: Interaction

    private func dragGesture(for marker: Marker, in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.dragStart == nil {
                    model.dragStart = marker.location
                    model.beginMarkerMove(marker.id)
                    model.selectedMarkerID = marker.id
                }
                guard let start = model.dragStart, value.translation != .zero else { return }
                model.moveMarker(marker.id, to: CGPoint(x: start.x + value.translation.width / rect.width,
                                                        y: start.y + value.translation.height / rect.height))
            }
            .onEnded { _ in
                model.dragStart = nil
                model.endMarkerMove()
            }
    }

    /// Dragging the photo itself moves it while zoomed in.
    private func panGesture(fit: CGSize, pane: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("photoPane"))
            .onChanged { value in
                guard model.viewport.isZoomed else { return }
                if model.panStart == nil { model.panStart = model.viewport.pan }
                guard let start = model.panStart else { return }
                model.viewport.pan = CGSize(width: start.width + value.translation.width,
                                            height: start.height + value.translation.height)
                model.viewport = model.viewport.clamped(photoFit: fit, pane: pane)
            }
            .onEnded { _ in model.panStart = nil }
    }

    /// ⌘- or ⌥-scroll zooms around the pointer; plain scrolling moves the photo while zoomed in.
    private func handleScroll(_ scroll: PaneEventCatcher.Scroll, at location: CGPoint, fit: CGSize, pane: CGSize) -> Bool {
        guard model.image != nil else { return false }
        if scroll.modifiers.contains(.command) || scroll.modifiers.contains(.option) {
            let factor = exp(scroll.delta.height * (scroll.precise ? 0.01 : 0.08))
            model.viewport.zoom(by: factor, anchor: anchorOffset(location, pane: pane))
        } else if model.viewport.isZoomed {
            let unit: CGFloat = scroll.precise ? 1 : 10
            model.viewport.pan.width += scroll.delta.width * unit
            model.viewport.pan.height += scroll.delta.height * unit
        } else {
            return false
        }
        model.viewport = model.viewport.clamped(photoFit: fit, pane: pane)
        return true
    }

    /// Pinch on the trackpad zooms around the pointer.
    private func handleMagnify(_ magnification: CGFloat, at location: CGPoint, fit: CGSize, pane: CGSize) -> Bool {
        guard model.image != nil else { return false }
        model.viewport.zoom(by: max(0.2, 1 + magnification), anchor: anchorOffset(location, pane: pane))
        model.viewport = model.viewport.clamped(photoFit: fit, pane: pane)
        return true
    }

    private func anchorOffset(_ location: CGPoint, pane: CGSize) -> CGPoint {
        CGPoint(x: location.x - pane.width / 2, y: location.y - pane.height / 2)
    }

    /// Moves the zoomed photo just far enough that the selected marker is inside the pane, with a margin.
    private func revealSelectedMarker(fit: CGSize, pane: CGSize) {
        guard model.viewport.isZoomed, let id = model.selectedMarkerID,
              let marker = model.markers.first(where: { $0.id == id }) else { return }
        var viewport = model.viewport.clamped(photoFit: fit, pane: pane)
        let rect = viewport.photoRect(photoFit: fit, pane: pane)
        let margin: CGFloat = 32
        let x = rect.minX + marker.location.x * rect.width
        let y = rect.minY + marker.location.y * rect.height
        var pan = viewport.pan
        if x < margin { pan.width += margin - x } else if x > pane.width - margin { pan.width -= x - (pane.width - margin) }
        if y < margin { pan.height += margin - y } else if y > pane.height - margin { pan.height -= y - (pane.height - margin) }
        guard pan != viewport.pan else { return }
        viewport.pan = pan
        model.viewport = viewport.clamped(photoFit: fit, pane: pane)
    }

    /// Keeps the stored viewport inside the pane after a resize or a zoom from outside (toolbar, menu).
    private func keepViewportValid(image: LoadedImage, fit: CGSize, pane: CGSize) {
        let valid = model.viewport.clamped(photoFit: fit, pane: pane)
        if valid != model.viewport { model.viewport = valid }
        model.actualPixelsZoom = PhotoViewport.actualPixelsZoom(imagePixels: CGFloat(image.display.width),
                                                                photoFitWidth: fit.width)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Drop a photo here or press ⌘O")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("Open Photo…") { model.presentOpenPanel() }
        }
    }

    private func fittedRect(_ imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Everything to the right of `fraction` (0...1) of the width.
private struct RightPart: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.width * fraction, y: 0, width: rect.width * (1 - fraction), height: rect.height))
    }
}
