import AppKit

/// ⌘Q, the Dock's Quit, and the AppleScript `quit` command are meant to converge on
/// `NSApp.terminate(_:)`, but AppKit's own handling of that call silently declines — without ever
/// reaching `applicationShouldTerminate` — whenever a SwiftUI `.sheet` is attached to a window
/// (SwiftUI owns the sheet's presentation state, so ending the sheet from the AppKit side doesn't
/// clear the attachment either). For the AppleScript path this also surfaces as "user cancelled"
/// (-128); for ⌘Q it just does nothing and leaves the process running. All state here is already
/// persisted synchronously by each action, not on quit, so a direct process exit is exactly as
/// safe as the `pkill` this bug otherwise forces. We bypass the broken path for both entry points:
/// a raw Apple Event handler for `quit` (AppleScript, Dock menu) and a local ⌘Q key monitor
/// (keyboard shortcut), each triggering the same unconditional exit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuit(_:replyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )

        // Match by physical key code (kVK_ANSI_Q), not the translated character: under a
        // non-Roman input source (e.g. Korean 2-set), `charactersIgnoringModifiers` for this key
        // is "ㅂ", not "q", even with ⌘ held.
        let qKeyCode: UInt16 = 12
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command), event.keyCode == qKeyCode {
                exit(0)
            }
            return event
        }
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        exit(0)
    }
}
