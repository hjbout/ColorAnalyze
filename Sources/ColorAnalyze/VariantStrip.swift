import ColorCore
import SwiftUI

/// The pinned grading variants under the photo: a thumbnail of each as the calibrated model predicts it. One click puts
/// a variant's style, amount, aim and harmony back; *Compare* shows them all side by side.
struct VariantStrip: View {
    @Environment(AnalysisModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let active = model.activeVariantID
        HStack(spacing: 10) {
            previewSwitches
            Divider().frame(height: 36)
            Text("Variants").font(.caption.weight(.medium))
            Button {
                model.stepVariant(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(model.variants.count < 2)
            .help("Previous variant (⌥⌘[)")
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.variants.enumerated()), id: \.element.id) { index, variant in
                            chip(variant, number: index + 1, isActive: variant.id == active)
                                .id(variant.id)
                        }
                        if model.variants.isEmpty {
                            Text("Pin the current style, amount and aim to see it next to others.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    // Same height as with a chip (thumbnail 44 + 2×4 padding + 2×3), so the bar doesn't shrink when empty.
                    .frame(minHeight: 58)
                }
                // Scrolls sideways with the trackpad, or shift + wheel; the arrows beside it step through the variants.
                .onChange(of: active) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Button {
                model.stepVariant(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(model.variants.count < 2)
            .help("Next variant (⌥⌘])")
            VStack(spacing: 4) {
                Button {
                    model.pinCurrentVariant()
                } label: {
                    Label("Pin Current", systemImage: "pin")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
                .disabled(model.colorGrading == nil)
                .help("Keep the current style, amount, aim and harmony as a variant (Compare ▸ Pin Current as Variant)")
                Toggle(isOn: $model.showVariantGrid) {
                    Label("Compare", systemImage: "square.grid.2x2")
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(model.variants.isEmpty)
                .help("Show the variants side by side with the original (Compare ▸ Compare All Variants)")
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .task(id: model.variantPreviewKey) { await model.refreshVariantPreviews() }
    }

    /// The preview on the photo and its exaggeration, always at hand under the photo.
    @ViewBuilder
    private var previewSwitches: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Toggle("Preview", isOn: $model.showPreview)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(model.afterImage != nil || model.colorGrading == nil)
                    .help((model.afterImage != nil ? "Close the comparison with the graded version first: it has the divider.\n\n" : "")
                          + (model.showPreview && model.previewSettings?.isIdentity == true ? "The suggestion changes nothing to show.\n\n" : "")
                          + "Show the photo with the suggested Color Grading and HSL values applied, right of a divider you can drag, below the original or alone in the whole pane, where D held down shows the original (P). An approximation of the tints and hue turns, not PhotoLab's own rendering.")
                if let caveats = model.previewSettings?.modelCaveats, !caveats.isEmpty {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help("The preview is less exact here than on the measured chart:\n" + caveats.map { "• " + $0 }.joined(separator: "\n"))
                }
            }
            Picker("Preview amount", selection: $model.previewAmount) {
                Text("×1").tag(1.0)
                Text("×2").tag(2.0)
                Text("×4").tag(4.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 110)
            .disabled(!model.showPreview)
            .help("Preview amount: ×1 is as suggested; ×2 and ×4 exaggerate the tints (not the hue turns), to see the direction of a small suggestion")
        }
        .fixedSize()
    }

    private func chip(_ variant: GradeVariant, number: Int, isActive: Bool) -> some View {
        let preview = model.variantPreviews[variant.id]
        return Button {
            model.applyVariant(variant.id)
        } label: {
            HStack(spacing: 6) {
                thumbnail(preview?.image)
                    .frame(width: 66, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(number) · \(variant.title)")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(detail(variant, preview))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let preview, !preview.caveats.isEmpty {
                        Text("outside measured range")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: 130, alignment: .leading)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isActive ? 2 : 0.5))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Update with Current Settings") { model.updateVariant(variant.id) }
                .disabled(isActive || model.colorGrading == nil)
            Button("Remove Variant") { model.removeVariant(variant.id) }
        }
        .help("Amount \(amountText(variant)) · aimed at \(variant.target.rawValue) · \(variant.hueSpace.displayName) wheel"
              + (preview?.caveats.isEmpty == false ? "\n" + (preview?.caveats.joined(separator: "\n") ?? "") : ""))
    }

    @ViewBuilder
    private func thumbnail(_ image: CGImage?) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.secondary.opacity(0.15))
        }
    }

    private func amountText(_ variant: GradeVariant) -> String {
        variant.amount.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func detail(_ variant: GradeVariant, _ preview: VariantPreview?) -> String {
        var text = "×" + amountText(variant)
        if variant.hueSpace != .rgb { text += " · " + variant.hueSpace.displayName }
        if let before = preview?.fitBefore ?? variant.fitBefore, let after = preview?.fitAfter ?? variant.fitAfter {
            text += " · \(Int(before.rounded()))° → \(Int(after.rounded()))°"
        }
        return text
    }
}

/// The original and every variant side by side, with the same crop, for choosing between them.
struct VariantGrid: View {
    @Environment(AnalysisModel.self) private var model

    var body: some View {
        let active = model.activeVariantID
        GeometryReader { geo in
        // In preview focus the grid is a fixed layout: 3 × 2 for a landscape photo, 4 × 1 for a portrait one.
        let landscape = aspect >= 1
        let focus = model.previewFocus
        let columns = focus ? (landscape ? 3 : 4) : 0
        let rows = focus ? (landscape ? 2 : 1) : 0
        // Room for the caption line and the spacing between the rows.
        let cellHeight: CGFloat? = focus ? max(60, (geo.size.height - 20 - CGFloat(rows - 1) * 10) / CGFloat(rows) - 24) : nil
        ScrollView {
            LazyVGrid(columns: focus ? Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
                                     : [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                if let original = model.image?.display {
                    cell(original, title: "Original", detail: nil, isActive: false, maxHeight: cellHeight, action: nil)
                }
                ForEach(Array(model.variants.enumerated()), id: \.element.id) { index, variant in
                    let preview = model.variantPreviews[variant.id]
                    cell(preview?.image, title: "\(index + 1) · \(variant.title)",
                         detail: [fit(preview), variant.hueSpace.displayName].compactMap { $0 }.joined(separator: " · "),
                         isActive: variant.id == active, maxHeight: cellHeight) { model.applyVariant(variant.id) }
                        .contextMenu {
                            Button("Use This Variant") { model.applyVariant(variant.id) }
                                .disabled(variant.id == active)
                            Button("Update with Current Settings") { model.updateVariant(variant.id) }
                                .disabled(variant.id == active || model.colorGrading == nil)
                            Button("Remove Variant") { model.removeVariant(variant.id) }
                        }
                        .help(preview?.caveats.isEmpty == false ? preview?.caveats.joined(separator: "\n") ?? "" : "")
                }
            }
            .padding(10)
        }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Width over height of the photo, shared by all cells so they line up.
    private var aspect: CGFloat {
        guard let image = model.image?.display, image.height > 0 else { return 1.5 }
        return CGFloat(image.width) / CGFloat(image.height)
    }

    /// Dragging moves every cell's photo while zoomed in.
    private func panGesture(pane: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard model.viewport.isZoomed else { return }
                if model.panStart == nil { model.panStart = model.viewport.pan }
                guard let start = model.panStart else { return }
                model.viewport.pan = CGSize(width: start.width + value.translation.width,
                                            height: start.height + value.translation.height)
                model.viewport = model.viewport.clamped(photoFit: pane, pane: pane)
            }
            .onEnded { _ in model.panStart = nil }
    }

    /// ⌘- or ⌥-scroll zooms around the pointer; plain scrolling moves the photos while zoomed in, else it scrolls the grid.
    private func handleScroll(_ scroll: PaneEventCatcher.Scroll, at location: CGPoint, pane: CGSize) -> Bool {
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
        model.viewport = model.viewport.clamped(photoFit: pane, pane: pane)
        return true
    }

    private func handleMagnify(_ magnification: CGFloat, at location: CGPoint, pane: CGSize) -> Bool {
        model.viewport.zoom(by: max(0.2, 1 + magnification), anchor: anchorOffset(location, pane: pane))
        model.viewport = model.viewport.clamped(photoFit: pane, pane: pane)
        return true
    }

    private func anchorOffset(_ location: CGPoint, pane: CGSize) -> CGPoint {
        CGPoint(x: location.x - pane.width / 2, y: location.y - pane.height / 2)
    }

    private func fit(_ preview: VariantPreview?) -> String? {
        guard let before = preview?.fitBefore, let after = preview?.fitAfter else { return nil }
        return "\(Int(before.rounded()))° → \(Int(after.rounded()))°"
    }

    private func cell(_ image: CGImage?, title: String, detail: String?, isActive: Bool, maxHeight: CGFloat?, action: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.secondary.opacity(image == nil ? 0.15 : 0)
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxHeight: maxHeight)
                .overlay {
                    GeometryReader { geo in
                        // Every cell shows the same crop: they share the window's zoom and pan.
                        let pane = geo.size
                        let viewport = model.viewport.clamped(photoFit: pane, pane: pane)
                        if let image {
                            Image(decorative: image, scale: 1).resizable()
                                .frame(width: pane.width * viewport.zoom, height: pane.height * viewport.zoom)
                                .offset(viewport.pan)
                                .frame(width: pane.width, height: pane.height)
                        }
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(panGesture(pane: pane))
                            .background(PaneEventCatcher(
                                onScroll: { scroll, location in handleScroll(scroll, at: location, pane: pane) },
                                onMagnify: { magnification, location in handleMagnify(magnification, at: location, pane: pane) },
                                onArrow: { _, _ in false }
                            ))
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isActive ? Color.accentColor : .clear, lineWidth: 3))
            HStack {
                Text(title).font(.caption.weight(.medium))
                Spacer()
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}
