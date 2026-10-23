import ColorCore
import SwiftUI

/// The reference photo with its palette: hover a color (or the photo) to see where in the reference it comes from,
/// click to match the selected color of the current photo with it.
struct ReferencePanelView: View {
    @Environment(AnalysisModel.self) private var model

    var body: some View {
        if let reference = model.referencePhoto {
            let lit = model.highlightedReferenceIndex
            let selected = model.selectedMarkerID.flatMap { id in model.markers.first { $0.id == id } }
            let matched = selected.flatMap { model.seriesMatch(for: $0)?.index }
            VStack(alignment: .leading, spacing: 8) {
                referencePhoto(reference, lit: lit)
                swatches(reference, lit: lit, matched: matched, selected: selected)
                Text(caption(reference, lit: lit, selected: selected, matched: matched))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func referencePhoto(_ reference: AnalysisModel.ReferencePhoto, lit: Int?) -> some View {
        let size = CGSize(width: reference.image.display.width, height: reference.image.display.height)
        return ZStack {
            Image(decorative: reference.image.display, scale: 1).resizable().interpolation(.high)
            if let lit, reference.regionOverlays.indices.contains(lit), let overlay = reference.regionOverlays[lit] {
                Image(decorative: overlay, scale: 1).resizable().interpolation(.high).allowsHitTesting(false)
            }
        }
        .aspectRatio(size, contentMode: .fit)
        .frame(maxHeight: 190)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.2)))
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): model.hoveredReferenceIndex = model.referenceIndex(atPixel: normalized(point, in: geo.size))
                        case .ended: model.hoveredReferenceIndex = nil
                        }
                    }
                    .onTapGesture { point in
                        if let index = model.referenceIndex(atPixel: normalized(point, in: geo.size)) { choose(index) }
                    }
            }
        }
        .help("Hover to see which palette color a spot belongs to; click to match the selected color with it")
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }

    private func swatches(_ reference: AnalysisModel.ReferencePhoto, lit: Int?, matched: Int?, selected: Marker?) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(reference.palette.enumerated()), id: \.offset) { index, shared in
                let color = shared.color
                let isChosen = selected?.referenceIndex == index
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.swiftUIColor)
                    .overlay {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(color.contrastingText)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.25)))
                    .overlay {
                        if matched == index {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: isChosen ? [] : [4, 2]))
                                .padding(-3)
                        }
                    }
                    .frame(height: 26)
                    .scaleEffect(lit == index ? 1.1 : 1)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { model.hoveredReferenceIndex = index } else if model.hoveredReferenceIndex == index { model.hoveredReferenceIndex = nil }
                    }
                    .onTapGesture { choose(index) }
                    .help(String(format: "Reference color %d · %@ · %.0f%% of the photo", index + 1, color.hex,
                                 (reference.regionCoverage.indices.contains(index) ? reference.regionCoverage[index] : 0) * 100))
            }
        }
        .padding(.horizontal, 3)
    }

    /// Matches the selected color with palette color `index`; a second click on the chosen one goes back to automatic.
    private func choose(_ index: Int) {
        guard let id = model.selectedMarkerID, let marker = model.markers.first(where: { $0.id == id }) else {
            model.showNotice("Select a color in the list or on the photo first")
            return
        }
        model.setReferenceIndex(marker.referenceIndex == index ? nil : index, for: id)
    }

    private func caption(_ reference: AnalysisModel.ReferencePhoto, lit: Int?, selected: Marker?, matched: Int?) -> String {
        var parts: [String] = []
        if let lit, reference.regionCoverage.indices.contains(lit) {
            parts.append(String(format: "Reference color %d covers %.0f%% of the reference photo.", lit + 1, reference.regionCoverage[lit] * 100))
        }
        if let selected, let number = model.markers.firstIndex(where: { $0.id == selected.id }).map({ $0 + 1 }) {
            if let matched {
                let how = selected.referenceIndex == matched ? "chosen by you; click it again for automatic" : "automatic, the nearest"
                parts.append("Color \(number) → reference color \(matched + 1) (\(how)). Click another color to change it.")
            } else {
                parts.append("Color \(number) has no close reference color. Click one to match it anyway.")
            }
        } else {
            parts.append("Select a color of this photo, then click a reference color (or a spot in the reference photo) to match them.")
        }
        return parts.joined(separator: " ")
    }
}

/// Context menu entry: match a color with a chosen color of the reference photo.
struct ReferenceMatchMenu: View {
    @Environment(AnalysisModel.self) private var model
    let markerID: Marker.ID

    var body: some View {
        if let reference = model.referencePhoto, let marker = model.markers.first(where: { $0.id == markerID }) {
            Menu("Match Reference Color") {
                Button("Automatic (nearest)") { model.setReferenceIndex(nil, for: markerID) }
                    .disabled(marker.referenceIndex == nil)
                Divider()
                ForEach(Array(reference.palette.enumerated()), id: \.offset) { index, shared in
                    Button("\(marker.referenceIndex == index ? "✓ " : "")Reference color \(index + 1) (\(shared.color.hex))") {
                        model.setReferenceIndex(index, for: markerID)
                    }
                }
            }
        }
    }
}
