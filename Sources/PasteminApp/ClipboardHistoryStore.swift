import AppKit
import CryptoKit
import Foundation
import ImageIO

private struct ClipboardSearchCandidate: Sendable {
    let record: ClipboardRecord
    let externalTextURL: URL?
}
