import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the clipboard panel for Command-comma; the options button toggles its dropdown.
    static let showClipboardOptions = Notification.Name("tools.min.pastemin.showClipboardOptions")
}
