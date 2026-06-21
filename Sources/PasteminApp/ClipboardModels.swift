import AppKit
import Carbon
import Foundation

private let clipboardTextPreviewByteLimit = 1_024

enum ClipboardItemKind: String, Codable, Hashable, Sendable {
    case text
    case image
}
