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
