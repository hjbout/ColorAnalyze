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
