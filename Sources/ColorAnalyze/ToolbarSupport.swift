import SwiftUI

/// A visible gap between groups of toolbar items. On macOS 26 and later this is the system's fixed
/// spacer (the groups then show as separate pills); on older systems a small empty item.
struct ToolbarGap: ToolbarContent {
    var body: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarSpacer(.fixed)
            ToolbarSpacer(.fixed)
        } else {
            ToolbarItem {
                Color.clear.frame(width: 28, height: 1)
            }
        }
    }
}

/// "Colors: 6" with a stepper, the way both windows show a count setting.
struct CountStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var help: String

    var body: some View {
        HStack(spacing: 6) {
            Text("\(title): \(value)")
                .monospacedDigit()
            Stepper(title, value: $value, in: range)
                .labelsHidden()
        }
        .padding(.horizontal, 4)
        .help(help)
    }
}

/// A slider that jumps back to `resetValue` on a double-click. SwiftUI's own Slider swallows the mouse events,
/// so a double-click gesture on it never fires.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var resetValue: Double

    final class ResetSlider: NSSlider {
        var onReset: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset?() } else { super.mouseDown(with: event) }
        }
    }

    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ResetSlider {
        let slider = ResetSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: ResetSlider, context: Context) {
        context.coordinator.parent = self
        slider.onReset = { [binding = $value, resetValue] in binding.wrappedValue = resetValue }
        if slider.doubleValue != value { slider.doubleValue = value }
    }
}

/// A pop-up menu that applies the highlighted item at once, so arrowing through the items shows each one on the photo.
/// Choosing an item keeps it; closing the menu without a choice (Escape, a click outside) puts the original back.
struct LivePreviewPicker<Value: Hashable>: NSViewRepresentable {
    var selection: Value
    var items: [(value: Value, title: String)]
    /// Applies a value; `remember` is false for a mere preview.
    var apply: (Value, _ remember: Bool) -> Void
    /// A small image for the menu item of a value (and so for the closed button), if it has one.
    var icon: ((Value) -> NSImage?)?

    /// Does not ask for the width of its longest title, which would make the pane wider than the window shows.
    final class FlexiblePopUpButton: NSPopUpButton {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
    }

    final class Coordinator: NSObject, NSMenuDelegate {
        var parent: LivePreviewPicker
        var original: Value?
        var committed = false
        init(_ parent: LivePreviewPicker) { self.parent = parent }

        @objc func chosen(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.items.indices.contains(index) else { return }
            committed = true
            if let original { parent.apply(original, false) }   // so the choice counts as a change and is remembered
            parent.apply(parent.items[index].value, true)
        }

        func menuWillOpen(_ menu: NSMenu) {
            original = parent.selection
            committed = false
        }

        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard let item, menu.index(of: item) >= 0, parent.items.indices.contains(menu.index(of: item)) else { return }
            parent.apply(parent.items[menu.index(of: item)].value, false)
        }

        func menuDidClose(_ menu: NSMenu) {
            // The action of a chosen item is sent after this call.
            DispatchQueue.main.async { [self] in
                if !committed, let original { parent.apply(original, false) }
                original = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FlexiblePopUpButton(frame: .zero, pullsDown: false)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.menu?.delegate = context.coordinator
        button.target = context.coordinator
        button.action = #selector(Coordinator.chosen(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = items.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let icon {
            for (item, entry) in zip(button.itemArray, items) { item.image = icon(entry.value) }
        }
        if let index = items.firstIndex(where: { $0.value == selection }), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
    }
}
