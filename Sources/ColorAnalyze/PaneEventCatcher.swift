import AppKit
import SwiftUI

/// Reports scroll-wheel, trackpad-scroll and pinch events over its pane. SwiftUI does not expose them,
/// and the photo and markers on top would swallow them, so the events are watched with a local monitor
/// and filtered by the pane's frame. Place it as the `.background` of the pane.
struct PaneEventCatcher: NSViewRepresentable {
    struct Scroll {
        var delta: CGSize
        var precise: Bool
        var modifiers: NSEvent.ModifierFlags
    }

    /// `location` is in the pane's coordinates (top-left origin). Return true when the event was used.
    var onScroll: (Scroll, CGPoint) -> Bool
    var onMagnify: (CGFloat, CGPoint) -> Bool
    /// An arrow key (dx, dy in steps; 10 with ⇧, y grows downward) while no text is being edited.
    var onArrow: (Int, Int) -> Bool
    /// The left mouse button goes down (true) or up (false) over the pane. The event always continues to the views below.
    var onPress: ((Bool) -> Void)?

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onArrow = onArrow
        view.onPress = onPress
    }

    final class CatcherView: NSView {
        var onScroll: ((Scroll, CGPoint) -> Bool)?
        var onMagnify: ((CGFloat, CGPoint) -> Bool)?
        var onArrow: ((Int, Int) -> Bool)?
        var onPress: ((Bool) -> Void)?
        private var monitor: Any?
        private var pressMonitor: Any?
        private var pressing = false

        /// Never takes mouse events itself.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor() } else { installMonitor(); installPressMonitor() }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .keyDown]) { [weak self] event in
                // The monitor runs on the main thread; only a Bool crosses back out of the isolated block.
                let used = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return used ? nil : event
            }
        }

        private func installPressMonitor() {
            guard pressMonitor == nil else { return }
            pressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                MainActor.assumeIsolated { self?.handlePress(event) }
                return event
            }
        }

        private func handlePress(_ event: NSEvent) {
            if event.type == .leftMouseUp {
                if pressing { pressing = false; onPress?(false) }
                return
            }
            guard event.window != nil, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            pressing = true
            onPress?(true)
        }

        /// True when the event was over this view and one of the handlers used it.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window != nil, event.window === window else { return false }
            if event.type == .keyDown { return handleKey(event) }
            let p = convert(event.locationInWindow, from: nil)
            guard bounds.contains(p) else { return false }
            let location = CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
            if event.type == .magnify {
                return onMagnify?(event.magnification, location) ?? false
            }
            let scroll = Scroll(delta: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY),
                                precise: event.hasPreciseScrollingDeltas, modifiers: event.modifierFlags)
            return onScroll?(scroll, location) ?? false
        }

        /// Arrow keys nudge the selected marker, unless text or another control is using the keyboard.
        private func handleKey(_ event: NSEvent) -> Bool {
            let step = event.modifierFlags.contains(.shift) ? 10 : 1
            let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(blocked).isEmpty else { return false }
            let move: (Int, Int)
            switch event.keyCode {
            case 123: move = (-step, 0)
            case 124: move = (step, 0)
            case 125: move = (0, step)
            case 126: move = (0, -step)
            default: return false
            }
            let responder = window?.firstResponder
            if responder is NSText || responder is NSControl { return false }
            return onArrow?(move.0, move.1) ?? false
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
            pressMonitor = nil
            if pressing { pressing = false; onPress?(false) }
        }
    }
}
