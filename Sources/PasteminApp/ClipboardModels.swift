import AppKit
import Carbon
import Foundation

private let clipboardTextPreviewByteLimit = 1_024

enum ClipboardItemKind: String, Codable, Hashable, Sendable {
    case text
    case image
}

struct ClipboardRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let kind: ClipboardItemKind
    let text: String?
    let textFilename: String?
    let imageFilename: String?
    let sourceAppName: String?
    let sourceBundleIdentifier: String?
    let byteCount: Int
    let signature: String

    func withCreatedAt(_ date: Date) -> ClipboardRecord {
        ClipboardRecord(
            id: id,
            createdAt: date,
            kind: kind,
            text: text,
            textFilename: textFilename,
            imageFilename: imageFilename,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            byteCount: byteCount,
            signature: signature
        )
    }

    var title: String {
        if kind == .image {
            return localized("image", "Image")
        }
        let line = limitedTextPreview.value
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line?.isEmpty == false ? line! : localized("text", "Text")
    }

    var previewText: String {
        limitedTextPreview.value
    }

    var isTextPreviewTruncated: Bool {
        textFilename != nil || limitedTextPreview.truncated
    }

    var accessibilityDescription: String {
        switch kind {
        case .text:
            let description = previewText.isEmpty
                ? localized("text_clipboard_item", "Text clipboard item")
                : previewText
            return isTextPreviewTruncated
                ? localizedFormat(
                    "text_clipboard_item_truncated",
                    "%@. Showing the first 1 KB.",
                    description
                )
                : description
        case .image:
            return localized("image_clipboard_item", "Image clipboard item")
        }
    }

    private var limitedTextPreview: (value: String, truncated: Bool) {
        guard let text else { return ("", false) }
        let bytes = text.utf8
        guard var end = bytes.index(
            bytes.startIndex,
            offsetBy: clipboardTextPreviewByteLimit,
            limitedBy: bytes.endIndex
        ), end != bytes.endIndex else {
            return (text, false)
        }
        while String.Index(end, within: text) == nil {
            end = bytes.index(before: end)
        }
        let textEnd = String.Index(end, within: text) ?? text.startIndex
        return (String(text[..<textEnd]), true)
    }

    // Keep history rows visually static while the panel is idle. SwiftUI's
    // relative date text schedules continuous updates and relayouts on macOS.
    var displayTimestamp: String {
        if Calendar.current.isDateInToday(createdAt) {
            return createdAt.formatted(date: .omitted, time: .shortened)
        }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var detailedTimestamp: String {
        createdAt.formatted(
            .dateTime
                .month(.abbreviated)
                .day()
                .year()
                .hour()
                .minute()
                .second()
        )
    }
}

enum RetentionPeriod: String, CaseIterable, Codable, Identifiable {
    case oneHour
    case oneDay
    case oneWeek
    case oneMonth
    case threeMonths
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneHour: localized("retention_one_hour", "1 hour")
        case .oneDay: localized("retention_one_day", "1 day")
        case .oneWeek: localized("retention_one_week", "1 week")
        case .oneMonth: localized("retention_one_month", "1 month")
        case .threeMonths: localized("retention_three_months", "3 months")
        case .forever: localized("retention_forever", "Forever")
        }
    }

    var lifetime: TimeInterval? {
        switch self {
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .oneWeek: 7 * 24 * 60 * 60
        case .oneMonth: 30 * 24 * 60 * 60
        case .threeMonths: 90 * 24 * 60 * 60
        case .forever: nil
        }
    }
}

struct GlobalShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(controlKey | optionKey)
    )

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyNames[
            keyCode,
            default: localizedFormat("key_number", "Key %lld", Int64(keyCode))
        ]
    }

    var menuKeyEquivalent: String {
        Self.menuKeyEquivalents[keyCode] ?? ""
    }

    var menuModifierFlags: NSEvent.ModifierFlags {
        // Carbon owns global registration while AppKit needs equivalent flags for menu display.
        var result: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        return result
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "−", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 49: localized("space_key", "Space"), 50: "`"
    ]

    private static let menuKeyEquivalents: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x",
        8: "c", 9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r",
        16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l",
        38: "j", 39: "'", 40: "k", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "n", 46: "m", 47: ".", 49: " ", 50: "`"
    ]
}
