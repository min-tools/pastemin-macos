import AppKit
import SwiftUI

private enum HistoryScrollAnchor: Hashable {
    case top
}

private enum HistoryScrollCoordinateSpace {
    static let name = "ClipboardHistoryScroll"
}

private struct HistoryTopPositionKey: PreferenceKey {
    static var defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
