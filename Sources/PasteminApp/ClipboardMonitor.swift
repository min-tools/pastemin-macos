import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let currentChangeCount: () -> Int
    private let captureChange: () -> Void
    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: ClipboardHistoryStore, pasteboard: NSPasteboard = .general) {
        currentChangeCount = { pasteboard.changeCount }
        captureChange = {
            // Attribute a copy to the frontmost external app, but never label our own restores.
            let source = NSWorkspace.shared.frontmostApplication
            let ownBundleID = Bundle.main.bundleIdentifier
            let isOwnApp = source?.bundleIdentifier == ownBundleID
            _ = store.capture(
                pasteboard,
                sourceAppName: isOwnApp ? nil : source?.localizedName,
                sourceBundleIdentifier: isOwnApp ? nil : source?.bundleIdentifier
            )
        }
        lastChangeCount = pasteboard.changeCount
    }

    init(changeCount: @escaping () -> Int, capture: @escaping () -> Void) {
        currentChangeCount = changeCount
        captureChange = capture
        lastChangeCount = changeCount()
    }

    func start() {
        guard timer == nil else { return }
        // Never archive clipboard changes made while monitoring was stopped.
        lastChangeCount = currentChangeCount()
        // changeCount makes idle polls constant-time and avoids reading pasteboard payloads.
        let timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func acknowledgeCurrentPasteboard() {
        lastChangeCount = currentChangeCount()
    }

    private func poll() {
        let changeCount = currentChangeCount()
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        captureChange()
    }
}
