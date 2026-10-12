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
