import AppKit
import ColorCore
import SwiftUI

/// Chooses the color wheel from a pop-up menu with a small disc of each wheel in front of its name. Highlighting an
/// item shows that wheel at once (see `LivePreviewPicker`); choosing keeps it, Escape puts the original back.
struct WheelSwatchPicker: View {
    var selection: HueSpace
    var apply: (HueSpace, _ remember: Bool) -> Void

    @MainActor private static var icons: [HueSpace: NSImage] = [:]

    @MainActor private static func icon(_ space: HueSpace) -> NSImage {
        if let cached = icons[space] { return cached }
        let image = NSImage(cgImage: WheelGeometry.wheelImage(for: space), size: NSSize(width: 16, height: 16))
        icons[space] = image
        return image
    }

    var body: some View {
        LivePreviewPicker(selection: selection,
                          items: HueSpace.allCases.map { ($0, $0.displayName) },
                          apply: apply,
                          icon: { Self.icon($0) })
    }
}
