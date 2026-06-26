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

/// One metric system for every row so titles, dividers and controls share the same edges.
private enum OptionsMetrics {
    /// Distance from the highlight edge to titles, dividers and the trailing control edge.
    static let inset: CGFloat = 10
    /// Even gap between the dropdown's edge and the row highlights on every side.
    static let edgePadding: CGFloat = 6
    static let width: CGFloat = 360
    static let actionRowHeight: CGFloat = 28
    static let controlRowHeight: CGFloat = 38
    static let detailRowHeight: CGFloat = 48
    static let controlWidth: CGFloat = 118
    static let controlHeight: CGFloat = 28
    static let highlightRadius: CGFloat = 6
}
