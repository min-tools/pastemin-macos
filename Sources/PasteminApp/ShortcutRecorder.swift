import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: GlobalShortcut
    let recordingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(shortcut: $shortcut, recordingChanged: recordingChanged)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: shortcut.displayName, target: context.coordinator, action: #selector(Coordinator.beginRecording))
        button.bezelStyle = .rounded
        button.controlSize = .large
        context.coordinator.button = button
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        if !context.coordinator.isRecording { button.title = shortcut.displayName }
    }

    final class Coordinator: NSObject {
        @Binding var shortcut: GlobalShortcut
        weak var button: NSButton?
        private let recordingChanged: (Bool) -> Void
        private var monitor: Any?
        fileprivate var isRecording = false

        init(shortcut: Binding<GlobalShortcut>, recordingChanged: @escaping (Bool) -> Void) {
            _shortcut = shortcut
            self.recordingChanged = recordingChanged
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(activateRecorder),
                name: .activateClipboardShortcutRecorder,
                object: nil
            )
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func activateRecorder() {
            button?.performClick(nil)
        }

        @objc func beginRecording() {
            guard !isRecording else { cancel() ; return }
            // A local monitor captures only the next key while the shortcut control is recording.
            isRecording = true
            button?.title = localized("type_shortcut", "Type shortcut…")
            button?.state = .on
            recordingChanged(true)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isRecording else { return event }
                if event.keyCode == 53 {
                    self.cancel()
                    return nil
                }
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let modifiers = GlobalShortcut.carbonModifiers(from: flags)
                // Require a modifier so normal typing cannot become a system-wide shortcut.
                guard modifiers != 0 else {
                    NSSound.beep()
                    return nil
                }
                self.shortcut = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
                self.finish()
                return nil
            }
        }

        private func cancel() {
            finish()
        }

        private func finish() {
            // Always release the event monitor before re-registering the global shortcut.
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            isRecording = false
            button?.state = .off
            button?.title = shortcut.displayName
            recordingChanged(false)
        }
    }
}
