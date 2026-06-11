import AppKit
import CryptoKit
import Foundation
import ImageIO

private struct ClipboardSearchCandidate: Sendable {
    let record: ClipboardRecord
    let externalTextURL: URL?
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardRecord] = []
    @Published private(set) var storageError: String?
    @Published private(set) var storageByteCount: Int64?

    let rootURL: URL
    private let itemsURL: URL
    private let imagesURL: URL
    private let textItemsURL: URL
    private let fileManager: FileManager
    private var retention: RetentionPeriod
    private let maximumItemCount = 100_000
    private let maximumInlineTextBytes = 1_024
    private let maximumTextBytes = 2 * 1_024 * 1_024
    private let maximumImageBytes = 25 * 1_024 * 1_024
    private let maximumImagePixelCount = 40_000_000
    private var sourceIconCache: [String: NSImage] = [:]

    static func applicationSupportURL(fileManager: FileManager = .default) throws -> URL {
        let library = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = library.appendingPathComponent("Pastemin", isDirectory: true)
        let legacy = library.appendingPathComponent("Clipboard", isDirectory: true)
        // Preserve pre-rename direct-build history when the new location is still empty.
        if !fileManager.fileExists(atPath: destination.path),
           fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: destination)
        }
        return destination
    }

    init(
        rootURL: URL,
        retention: RetentionPeriod,
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL
        self.retention = retention
        self.fileManager = fileManager
        itemsURL = rootURL.appendingPathComponent("history.json")
        imagesURL = rootURL.appendingPathComponent("Images", isDirectory: true)
        textItemsURL = rootURL.appendingPathComponent("Text", isDirectory: true)
        // Clipboard contents are private even on Macs shared by multiple local accounts.
        try createPrivateDirectory(at: rootURL)
        try createPrivateDirectory(at: imagesURL)
        try createPrivateDirectory(at: textItemsURL)
        load()
        pruneExpiredItems()
    }

    func updateRetention(_ newValue: RetentionPeriod) {
        retention = newValue
        pruneExpiredItems()
    }

    func dismissStorageError() {
        storageError = nil
    }

    func refreshStorageByteCount() async {
        let bytes = await calculateStorageByteCount()
        if !Task.isCancelled { storageByteCount = bytes }
    }

    func calculateStorageByteCount() async -> Int64 {
        let rootURL = rootURL
        // Directory enumeration can touch thousands of image files, so keep it off the UI actor.
        return await Task.detached(priority: .utility) {
            Self.calculateStorageByteCountSynchronously(at: rootURL)
        }.value
    }

    nonisolated private static func calculateStorageByteCountSynchronously(at rootURL: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let bytes = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(bytes)
        }
        return total
    }

    @discardableResult
    func capture(
        _ pasteboard: NSPasteboard,
        sourceAppName: String?,
        sourceBundleIdentifier: String? = nil
    ) -> Int {
        capture(
            pasteboard.pasteboardItems ?? [],
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier
        )
    }

    @discardableResult
    func capture(
        _ sourceItems: [NSPasteboardItem],
        sourceAppName: String?,
        sourceBundleIdentifier: String? = nil
    ) -> Int {
        var captured = 0
        var payloadError: String?
        // Prefer an image representation when an item also exposes fallback text.
        for source in sourceItems where !shouldIgnore(source) {
            if let imageData = imageData(from: source) {
                if insertImage(
                    imageData,
                    sourceAppName: sourceAppName,
                    sourceBundleIdentifier: sourceBundleIdentifier
                ) {
                    captured += 1
                } else if payloadError == nil {
                    payloadError = storageError
                }
                continue
            }
            if let text = text(from: source), !text.isEmpty {
                if insertText(
                    text,
                    sourceAppName: sourceAppName,
                    sourceBundleIdentifier: sourceBundleIdentifier
                ) {
                    captured += 1
                } else if payloadError == nil {
                    payloadError = storageError
                }
            }
        }
        if captured > 0 {
            pruneExpiredItems(saveAfterPruning: false)
            save()
            // A successful index save must not hide a payload failure from the same capture.
            if storageError == nil, let payloadError { storageError = payloadError }
        }
        return captured
    }

    func restore(_ record: ClipboardRecord, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        let restored: Bool
        switch record.kind {
        case .text:
            guard let text = fullText(for: record) else { return false }
            restored = pasteboard.setString(text, forType: .string)
        case .image:
            guard let data = imageData(for: record) else { return false }
            // Publish PNG plus TIFF because receiving macOS apps commonly request either type.
            var imageRestored = pasteboard.setData(data, forType: .png)
            if let image = NSImage(data: data), let tiff = image.tiffRepresentation {
                imageRestored = pasteboard.setData(tiff, forType: .tiff) || imageRestored
            }
            restored = imageRestored
        }
        if restored { markUsed(record) }
        return restored
    }

    func image(for record: ClipboardRecord) -> NSImage? {
        imageData(for: record).flatMap(NSImage.init(data:))
    }

    func fullText(for record: ClipboardRecord) -> String? {
        guard record.kind == .text else { return nil }
        guard let filename = record.textFilename else { return record.text }
        guard let url = textURL(for: filename),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func record(_ record: ClipboardRecord, contains needle: String) -> Bool {
        record.title.localizedCaseInsensitiveContains(needle)
            || (record.sourceAppName?.localizedCaseInsensitiveContains(needle) ?? false)
            || (fullText(for: record)?.localizedCaseInsensitiveContains(needle) ?? false)
    }

    func search(
        matching needle: String,
        among records: [ClipboardRecord]? = nil
    ) async -> [ClipboardRecord] {
        let candidates = (records ?? items).map { record in
            ClipboardSearchCandidate(
                record: record,
                externalTextURL: record.textFilename.flatMap(textURL)
            )
        }
        let searchTask: Task<[ClipboardRecord], Never> = Task.detached(priority: .userInitiated) {
            var matches: [ClipboardRecord] = []
            matches.reserveCapacity(min(candidates.count, 256))
            for candidate in candidates {
                guard !Task.isCancelled else { return [ClipboardRecord]() }
                let record = candidate.record
                if record.title.localizedCaseInsensitiveContains(needle)
                    || (record.sourceAppName?.localizedCaseInsensitiveContains(needle) ?? false) {
                    matches.append(record)
                    continue
                }
                let text: String?
                if let url = candidate.externalTextURL,
                   let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    text = String(data: data, encoding: .utf8)
                } else {
                    text = record.text
                }
                if text?.localizedCaseInsensitiveContains(needle) == true {
                    matches.append(record)
                }
            }
            return matches
        }
        return await withTaskCancellationHandler {
            await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
    }

    func sourceAppIcon(for record: ClipboardRecord) -> NSImage? {
        // Cache icon resolution because row rendering may revisit the same source many times.
        let cacheKey: String
        if let bundleIdentifier = record.sourceBundleIdentifier {
            cacheKey = "bundle:\(bundleIdentifier)"
        } else if let name = record.sourceAppName {
            cacheKey = "name:\(name)"
        } else {
            return nil
        }
        if let cached = sourceIconCache[cacheKey] { return cached }

        // Running apps provide the freshest icon; installed apps are the fallback.
        let runningApplication: NSRunningApplication?
        if let bundleIdentifier = record.sourceBundleIdentifier {
            runningApplication = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier)
                .first
        } else {
            runningApplication = NSWorkspace.shared.runningApplications.first {
                $0.localizedName == record.sourceAppName
            }
        }

        let icon = runningApplication?.icon ?? record.sourceBundleIdentifier.flatMap { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
        if let icon { sourceIconCache[cacheKey] = icon }
        return icon
    }

    func delete(_ record: ClipboardRecord) {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return }
        let removed = items.remove(at: index)
        removePayload(for: removed)
        save()
    }

    func markUsed(_ record: ClipboardRecord) {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return }
        let current = items.remove(at: index)
        items.insert(current.withCreatedAt(Date()), at: 0)
        save()
    }

    func clearHistory() {
        items.removeAll()
        // Persist empty metadata even if removing an orphaned image later fails.
        save()
        do {
            // Recreate payload directories so the next capture never depends on lazy setup.
            for directory in [imagesURL, textItemsURL] {
                if fileManager.fileExists(atPath: directory.path) {
                    try fileManager.removeItem(at: directory)
                }
                try createPrivateDirectory(at: directory)
            }
        } catch {
            storageError = localizedFormat(
                "history_clear_failed",
                "Pastemin history could not be cleared: %@",
                error.localizedDescription
            )
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: itemsURL.path) else { return }
        do {
            let data = try Data(contentsOf: itemsURL)
            // Drop metadata whose external payload was removed outside the app.
            items = try JSONDecoder().decode([ClipboardRecord].self, from: data)
                .filter { record in
                    switch record.kind {
                    case .image: return imagePayloadExists(for: record)
                    case .text:
                        return record.textFilename == nil || textPayloadExists(for: record)
                    }
                }
            if externalizeLegacyTextItems() { save() }
        } catch {
            storageError = localizedFormat(
                "history_read_failed",
                "Pastemin history could not be read: %@",
                error.localizedDescription
            )
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            // Compact JSON reduces write amplification as histories grow into thousands.
            try encoder.encode(items).write(to: itemsURL, options: .atomic)
            try makePrivateFile(at: itemsURL)
            storageError = nil
        } catch {
            storageError = localizedFormat(
                "history_save_failed",
                "Pastemin history could not be saved: %@",
                error.localizedDescription
            )
        }
    }

    private func insertText(
        _ original: String,
        sourceAppName: String?,
        sourceBundleIdentifier: String?
    ) -> Bool {
        let data = Data(original.utf8)
        guard !data.isEmpty else { return false }
        // Bound a single record before hashing and persisting it.
        let text: String
        if data.count > maximumTextBytes {
            var length = maximumTextBytes
            while length > 0, String(data: data.prefix(length), encoding: .utf8) == nil {
                length -= 1
            }
            text = String(data: data.prefix(length), encoding: .utf8) ?? ""
        } else {
            text = original
        }
        let storedData = Data(text.utf8)
        let signature = digest(kind: .text, data: storedData)
        let id = UUID()
        let filename: String?
        let indexedText: String
        if storedData.count > maximumInlineTextBytes {
            filename = "\(id.uuidString).txt"
            indexedText = byteLimitedText(text, maximumBytes: maximumInlineTextBytes)
            do {
                guard let filename, let url = textURL(for: filename) else { return false }
                // Commit the payload before publishing its small index record.
                try storedData.write(to: url, options: .atomic)
                try makePrivateFile(at: url)
            } catch {
                storageError = localizedFormat(
                    "copied_text_save_failed",
                    "A copied text item could not be saved: %@",
                    error.localizedDescription
                )
                return false
            }
        } else {
            filename = nil
            indexedText = text
        }
        removeDuplicate(signature: signature)
        items.insert(ClipboardRecord(
            id: id,
            createdAt: Date(),
            kind: .text,
            text: indexedText,
            textFilename: filename,
            imageFilename: nil,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            byteCount: storedData.count,
            signature: signature
        ), at: 0)
        return true
    }

    private func insertImage(
        _ data: Data,
        sourceAppName: String?,
        sourceBundleIdentifier: String?
    ) -> Bool {
        let signature = digest(kind: .image, data: data)
        let id = UUID()
        let filename = "\(id.uuidString).png"
        do {
            // Commit the replacement before removing an older duplicate or publishing metadata.
            let imageURL = imagesURL.appendingPathComponent(filename)
            try data.write(to: imageURL, options: .atomic)
            try makePrivateFile(at: imageURL)
            removeDuplicate(signature: signature)
            items.insert(ClipboardRecord(
                id: id,
                createdAt: Date(),
                kind: .image,
                text: nil,
                textFilename: nil,
                imageFilename: filename,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                byteCount: data.count,
                signature: signature
            ), at: 0)
            return true
        } catch {
            storageError = localizedFormat(
                "copied_image_save_failed",
                "A copied image could not be saved: %@",
                error.localizedDescription
            )
            return false
        }
    }

    private func removeDuplicate(signature: String) {
        guard let index = items.firstIndex(where: { $0.signature == signature }) else { return }
        let duplicate = items.remove(at: index)
        removePayload(for: duplicate)
    }

    private func pruneExpiredItems(saveAfterPruning: Bool = true) {
        let cutoff = retention.lifetime.map { Date().addingTimeInterval(-$0) }
        var removed: [ClipboardRecord] = []
        // Collect removed records so their external payloads are pruned as well.
        items.removeAll { item in
            let isExpired = cutoff.map { item.createdAt < $0 } ?? false
            if isExpired { removed.append(item); return true }
            return false
        }
        if items.count > maximumItemCount {
            // Retain newest-first ordering while enforcing the emergency metadata ceiling.
            removed.append(contentsOf: items.dropFirst(maximumItemCount))
            items = Array(items.prefix(maximumItemCount))
        }
        removed.forEach(removePayload)
        if !removed.isEmpty, saveAfterPruning { save() }
    }

    private func shouldIgnore(_ item: NSPasteboardItem) -> Bool {
        // Respect standard opt-out markers used for secrets and short-lived pasteboard data.
        let ignored = [
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "org.nspasteboard.AutoGeneratedType"
        ]
        return item.types.contains { ignored.contains($0.rawValue) }
    }

    private func text(from item: NSPasteboardItem) -> String? {
        item.string(forType: .string) ?? item.string(forType: .fileURL)
    }

    private func imageData(from item: NSPasteboardItem) -> Data? {
        let source = item.data(forType: .png) ?? item.data(forType: .tiff)
        guard let source, source.count <= maximumImageBytes,
              let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumImagePixelCount / height,
              let image = NSImage(data: source), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        guard let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= maximumImageBytes else { return nil }
        return png
    }

    private func imageData(for record: ClipboardRecord) -> Data? {
        guard let filename = record.imageFilename, let url = imageURL(for: filename) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func removeImage(for record: ClipboardRecord) {
        guard let filename = record.imageFilename, let url = imageURL(for: filename) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func imagePayloadExists(for record: ClipboardRecord) -> Bool {
        // Like text payloads, images are validated without loading their contents at launch.
        guard let filename = record.imageFilename, let url = imageURL(for: filename) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func removeText(for record: ClipboardRecord) {
        guard let filename = record.textFilename, let url = textURL(for: filename) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func textPayloadExists(for record: ClipboardRecord) -> Bool {
        // Validate only the directory entry so launch never reads a large text payload.
        guard let filename = record.textFilename, let url = textURL(for: filename) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func removePayload(for record: ClipboardRecord) {
        removeImage(for: record)
        removeText(for: record)
    }

    private func imageURL(for filename: String) -> URL? {
        // History metadata must never escape the managed Images directory.
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              (filename as NSString).lastPathComponent == filename else { return nil }
        return imagesURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func textURL(for filename: String) -> URL? {
        // History metadata must never escape the managed Text directory.
        guard !filename.isEmpty,
              filename != ".",
              filename != "..",
              (filename as NSString).lastPathComponent == filename else { return nil }
        return textItemsURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func byteLimitedText(_ text: String, maximumBytes: Int) -> String {
        let data = Data(text.utf8)
        guard data.count > maximumBytes else { return text }
        var length = maximumBytes
        while length > 0, String(data: data.prefix(length), encoding: .utf8) == nil {
            length -= 1
        }
        return String(data: data.prefix(length), encoding: .utf8) ?? ""
    }

    private func externalizeLegacyTextItems() -> Bool {
        var changed = false
        for index in items.indices {
            let record = items[index]
            guard record.kind == .text,
                  record.textFilename == nil,
                  let text = record.text,
                  Data(text.utf8).count > maximumInlineTextBytes else { continue }
            let filename = "\(record.id.uuidString).txt"
            guard let url = textURL(for: filename) else { continue }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                try makePrivateFile(at: url)
                items[index] = ClipboardRecord(
                    id: record.id,
                    createdAt: record.createdAt,
                    kind: record.kind,
                    text: byteLimitedText(text, maximumBytes: maximumInlineTextBytes),
                    textFilename: filename,
                    imageFilename: record.imageFilename,
                    sourceAppName: record.sourceAppName,
                    sourceBundleIdentifier: record.sourceBundleIdentifier,
                    byteCount: record.byteCount,
                    signature: record.signature
                )
                changed = true
            } catch {
                // Keep legacy inline text intact when migration cannot safely write its payload.
                storageError = localizedFormat(
                    "stored_text_optimize_failed",
                    "A stored text item could not be optimized: %@",
                    error.localizedDescription
                )
            }
        }
        return changed
    }

    private func createPrivateDirectory(at url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path
        )
    }

    private func makePrivateFile(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func digest(kind: ClipboardItemKind, data: Data) -> String {
        let hash = SHA256.hash(data: Data(kind.rawValue.utf8) + data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
