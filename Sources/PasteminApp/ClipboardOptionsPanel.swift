import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the clipboard panel for Command-comma; the options button toggles its dropdown.
    static let showClipboardOptions = Notification.Name("tools.min.pastemin.showClipboardOptions")
}

/// Every row the options dropdown can highlight, in display order.
enum OptionsRow: Hashable {
    case clearCurrent
    case clearHistory
    case retention
    case menuBar
    case automaticPaste
    case shortcut
    case storage
    case about
    case privacy
}
