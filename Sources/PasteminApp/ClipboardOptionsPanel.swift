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

/// Shared highlight state for the dropdown: the mouse and the arrow keys move the same selection,
/// exactly like a menu, and Return or Space activates whatever is highlighted.
@MainActor
final class OptionsSelectionModel: ObservableObject {
    @Published var selection: OptionsRow?
    var rows: [OptionsRow] = []
    var activate: (OptionsRow) -> Void = { _ in }
    var adjust: (OptionsRow, Int) -> Void = { _, _ in }

    func hover(_ row: OptionsRow, _ hovering: Bool) {
        if hovering {
            selection = row
        } else if selection == row {
            selection = nil
        }
    }

    func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        guard let selection, let index = rows.firstIndex(of: selection) else {
            self.selection = offset > 0 ? rows.first : rows.last
            return
        }
        self.selection = rows[min(max(index + offset, 0), rows.count - 1)]
    }

    func activateSelection() {
        guard let selection else { return }
        activate(selection)
    }

    func adjustSelection(by delta: Int) {
        guard let selection else { return }
        adjust(selection, delta)
    }
}
