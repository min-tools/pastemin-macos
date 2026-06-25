import AppKit
import SwiftUI

extension Notification.Name {
    static let activateClipboardShortcutRecorder = Notification.Name(
        "tools.min.pastemin.activateShortcutRecorder"
    )
    static let activateClipboardRetentionPicker = Notification.Name(
        "tools.min.pastemin.activateRetentionPicker"
    )
}
