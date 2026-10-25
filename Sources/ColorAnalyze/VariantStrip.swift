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
            Text("Variants").font(.caption.weight(.medium))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.variants.enumerated()), id: \.element.id) { index, variant in
                        chip(variant, number: index + 1, isActive: variant.id == active)
                    }
                    if model.variants.isEmpty {
                        Text("Pin the current style, amount and aim to see it next to others.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            Toggle(isOn: $model.showVariantGrid) {
                Label("Compare", systemImage: "square.grid.2x2")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(model.variants.isEmpty)
            .help("Show the variants side by side with the original (Compare ▸ Compare All Variants)")
            Button {
                model.pinCurrentVariant()
            } label: {
                Label("Pin Current", systemImage: "pin")
            }
            .controlSize(.small)
            .disabled(model.colorGrading == nil)
            .help("Keep the current style, amount, aim and harmony as a variant (Compare ▸ Pin Current as Variant)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.bar)
        .task(id: model.variantPreviewKey) { await model.refreshVariantPreviews() }
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
        .help("Amount \(amountText(variant)) · aimed at \(variant.target.rawValue)"
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
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                if let original = model.image?.display {
                    cell(original, title: "Original", detail: nil, isActive: false, action: nil)
                }
                ForEach(Array(model.variants.enumerated()), id: \.element.id) { index, variant in
                    let preview = model.variantPreviews[variant.id]
                    cell(preview?.image, title: "\(index + 1) · \(variant.title)",
                         detail: fit(preview), isActive: variant.id == active) { model.applyVariant(variant.id) }
                }
            }
            .padding(10)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func fit(_ preview: VariantPreview?) -> String? {
        guard let before = preview?.fitBefore, let after = preview?.fitAfter else { return nil }
        return "\(Int(before.rounded()))° → \(Int(after.rounded()))°"
    }

    private func cell(_ image: CGImage?, title: String, detail: String?, isActive: Bool, action: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15)).aspectRatio(1.5, contentMode: .fit)
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
