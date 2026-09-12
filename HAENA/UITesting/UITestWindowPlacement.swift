#if DEBUG
import AppKit
import SwiftUI

/// Geometry only, inside the existing in-memory UI-test assembly. No storage override.
struct UITestWindowPlacement: NSViewRepresentable {
    var resizeMainWindow = false

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        view.resizeMainWindow = resizeMainWindow
        return view
    }
    func updateNSView(_ nsView: Anchor, context: Context) {}

    final class Anchor: NSView {
        var resizeMainWindow = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard ProcessInfo.processInfo.environment["HAENA_UI_TESTING"] == "1",
                  let window, let screen = NSScreen.screens.first else { return }
            let resize = resizeMainWindow
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                if resize {
                    window.setContentSize(NSSize(width: min(1000, screen.visibleFrame.width - 160),
                                                 height: min(800, screen.visibleFrame.height - 160)))
                }
                window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 80,
                                                   y: screen.visibleFrame.maxY - 80))
            }
        }
    }
}
#endif
