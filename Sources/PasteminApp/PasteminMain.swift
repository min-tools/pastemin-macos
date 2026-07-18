import AppKit
import Foundation

@MainActor
final class PasteminAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ClipboardController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = ClipboardController()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.presentClipboard()
        return true
    }
}
