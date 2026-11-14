import AppKit
import CryptoKit
import Foundation
import ImageIO

private struct ClipboardSearchCandidate: Sendable {
    let record: ClipboardRecord
    let externalTextURL: URL?
}

/// Keeps complete external text off the main actor and bounds its memory use.
private actor ClipboardSearchEngine {
    private struct CachedText {
        let value: String
        let byteCount: Int
    }

    private let maximumCacheBytes = 32 * 1_024 * 1_024
    private var cachedText: [URL: CachedText] = [:]
    private var insertionOrder: [URL] = []
    private var evictionIndex = 0
    private var cachedByteCount = 0

    /// matches(candidates, needle): Search the required snapshot and query,
    /// returning matches ranked by tags, stars, then recency.
    func matches(
        _ candidates: [ClipboardSearchCandidate],
        needle: String
    ) -> [ClipboardRecord] {
        var matches: [ClipboardRecord] = []
        matches.reserveCapacity(min(candidates.count, 256))

        for candidate in candidates {
            guard !Task.isCancelled else { return [] }
            let record = candidate.record
            // Metadata matches avoid loading an external text payload.
            if record.tagMatchRank(needle) > 0
                || record.title.localizedCaseInsensitiveContains(needle)
                || (record.sourceAppName?.localizedCaseInsensitiveContains(needle) ?? false) {
                matches.append(record)
                continue
            }

            let text = candidate.externalTextURL.flatMap(cachedText(at:)) ?? record.text
            // Full-text matching covers records that metadata cannot identify.
            if text?.localizedCaseInsensitiveContains(needle) == true {
                matches.append(record)
            }
        }
        // Rank tags first, then stars, with recent items breaking equal matches.
        return matches.sorted { first, second in
            let firstRank = first.tagMatchRank(needle)
            let secondRank = second.tagMatchRank(needle)
            // Exact tags outrank partial tags, which outrank content matches.
            if firstRank != secondRank { return firstRank > secondRank }
            // Stars break ties only within the same tag rank.
            if first.isStarred != second.isStarred { return first.isStarred }
            return first.createdAt > second.createdAt
        }
    }

    /// cachedText(at:) reads the required managed file and caches valid UTF-8.
    private func cachedText(at url: URL) -> String? {
        // Reuse complete text without touching the file system again.
        if let cached = cachedText[url] { return cached.value }
        guard !Task.isCancelled,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              !Task.isCancelled,
              let text = String(data: data, encoding: .utf8) else { return nil }

        cachedText[url] = CachedText(value: text, byteCount: data.count)
        insertionOrder.append(url)
        cachedByteCount += data.count
        evictIfNeeded()
        return text
    }

    /// evictIfNeeded() removes the oldest text until the cache meets its limit.
    private func evictIfNeeded() {
        while cachedByteCount > maximumCacheBytes, evictionIndex < insertionOrder.count {
            let url = insertionOrder[evictionIndex]
            evictionIndex += 1
            // A key may already be absent if it appeared earlier in the queue.
            if let removed = cachedText.removeValue(forKey: url) {
                cachedByteCount -= removed.byteCount
            }
        }

        // Periodically discard consumed keys without shifting the queue on
        // every eviction.
        if evictionIndex > 1_024, evictionIndex * 2 > insertionOrder.count {
            insertionOrder.removeFirst(evictionIndex)
            evictionIndex = 0
        }
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    @Published private(set) var items: [ClipboardRecord] = [] {
        didSet { itemsGeneration &+= 1 }
    }
    @Published private(set) var storageError: String?
    @Published private(set) var storageByteCount: Int64?

    // A synchronous generation lets searches reject obsolete item snapshots.
    private(set) var itemsGeneration = 0

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
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private var searchEngine = ClipboardSearchEngine()
    // Keep replaced files until the index safely points to their replacements.
    private var replacedPayloads: [ClipboardRecord] = []

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

    /// image(for:) returns a decoded image for the required record.
    func image(for record: ClipboardRecord) -> NSImage? {
        guard let filename = record.imageFilename else { return nil }
        let cacheKey = filename as NSString
        // Reuse decoded image data as rows enter and leave the visible window.
        if let cached = imageCache.object(forKey: cacheKey) { return cached }
        guard let data = imageData(for: record), let image = NSImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: cacheKey, cost: imageCacheCost(for: data))
        return image
    }

    func fullText(for record: ClipboardRecord) -> String? {
        guard record.kind == .text else { return nil }
        guard let filename = record.textFilename else { return record.text }
        guard let url = textURL(for: filename),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // record(record, needle): Match the required item against tags, title,
    // source app, or complete text, ignoring case.
    func record(_ record: ClipboardRecord, contains needle: String) -> Bool {
        record.tagMatchRank(needle) > 0
            || record.title.localizedCaseInsensitiveContains(needle)
            || (record.sourceAppName?.localizedCaseInsensitiveContains(needle) ?? false)
            || (fullText(for: record)?.localizedCaseInsensitiveContains(needle) ?? false)
    }

    /// search(matching:,[among:]) finds the required needle in optional
    /// records; omitting records searches all items.
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
        // Capture this engine so deletion can safely replace the store's cache.
        let engine = searchEngine
        return await engine.matches(candidates, needle: needle)
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

    /// registerSourceIcon(_:forBundleIdentifier:) seeds the icon cache for the required
    /// bundle identifier. Offscreen renders in a sandbox cannot reach the icon service and
    /// use it to show real app icons.
    func registerSourceIcon(_ icon: NSImage, forBundleIdentifier bundleIdentifier: String) {
        sourceIconCache["bundle:\(bundleIdentifier)"] = icon
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

    // setStarred(record, starred, [limit = nil]): Set the required item's
    // protection state. A nil limit allows any number of stars.
    @discardableResult
    func setStarred(_ record: ClipboardRecord, starred: Bool, limit: Int? = nil) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return false }
        let previous = items[index]
        guard previous.isStarred != starred else { return true }
        // Enforce the supplied cap only when adding a star.
        if starred, let limit, items.filter(\.isStarred).count >= limit { return false }
        items[index].starredAt = starred ? Date() : nil
        guard save() else {
            // Restore the previous in-memory state when saving fails.
            items[index] = previous
            return false
        }
        return true
    }

    // updateTags(record, input): Normalize the required comma-separated input
    // and save it on the item without changing its clipboard content.
    @discardableResult
    func updateTags(_ record: ClipboardRecord, input: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == record.id }) else { return false }
        let previous = items[index]
        let tags = ClipboardRecord.normalizedTags(input)
        guard tags != previous.tagNames else { return true }
        // Omit empty metadata from the index and restore it if saving fails.
        items[index].tags = tags.isEmpty ? nil : tags
        guard save() else {
            // Keep the last saved tags when the index cannot be written.
            items[index] = previous
            return false
        }
        return true
    }

    // clearHistory([includeStarred = false]): Remove ordinary history,
    // preserving stars unless the caller explicitly includes them.
    func clearHistory(includeStarred: Bool = false) {
        // Save the reduced index before deleting any of its former payloads.
        let previous = items
        let removed = items.filter { includeStarred || !$0.isStarred }
        items.removeAll { includeStarred || !$0.isStarred }
        guard save() else {
            // Never delete payloads while the durable index still references them.
            items = previous
            return
        }
        removed.forEach(removePayload)
        imageCache.removeAllObjects()
        // Discard cached text when clearing the source history.
        searchEngine = ClipboardSearchEngine()
        // Saved items still own payloads in these directories.
        guard items.isEmpty else { return }
        do {
            // Recreate payload directories so the next capture never depends on lazy setup.
            for directory in [imagesURL, textItemsURL] {
                // Replace old directories to remove orphans and restore
                // private permissions.
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

    // save(): Atomically replace the index and apply private permissions.
    // Retire duplicate payloads only after both steps succeed.
    @discardableResult
    private func save() -> Bool {
        do {
            let encoder = JSONEncoder()
            // Compact JSON reduces write amplification as histories grow into thousands.
            try encoder.encode(items).write(to: itemsURL, options: .atomic)
            try makePrivateFile(at: itemsURL)
            storageError = nil
            // The committed index no longer needs these replacement backups.
            let obsolete = replacedPayloads
            replacedPayloads.removeAll()
            obsolete.forEach(removePayload)
            return true
        } catch {
            storageError = localizedFormat(
                "history_save_failed",
                "Pastemin history could not be saved: %@",
                error.localizedDescription
            )
            return false
        }
    }

    // insertText(original, sourceAppName, sourceBundleIdentifier): Stage a
    // text capture for the next index save. All arguments are required;
    // source names and identifiers may be nil.
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
            // Text within the payload limit needs no truncation.
            text = original
        }
        let storedData = Data(text.utf8)
        let signature = digest(kind: .text, data: storedData)
        let id = UUID()
        let filename: String?
        let indexedText: String
        // Store large text separately so the index contains only a preview.
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
            // Small text stays entirely in the index.
            filename = nil
            indexedText = text
        }
        // Recapture updates recency and source, retaining identity, star and
        // tags.
        let previous = removeDuplicate(signature: signature)
        items.insert(ClipboardRecord(
            id: previous?.id ?? id,
            createdAt: Date(),
            kind: .text,
            text: indexedText,
            textFilename: filename,
            imageFilename: nil,
            sourceAppName: sourceAppName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            byteCount: storedData.count,
            signature: signature,
            starredAt: previous?.starredAt,
            tags: previous?.tags
        ), at: 0)
        return true
    }

    // insertImage(data, sourceAppName, sourceBundleIdentifier): Stage a PNG
    // capture for the next index save. All arguments are required; source
    // names and identifiers may be nil.
    private func insertImage(
        _ data: Data,
        sourceAppName: String?,
        sourceBundleIdentifier: String?
    ) -> Bool {
        let signature = digest(kind: .image, data: data)
        let id = UUID()
        let filename = "\(id.uuidString).png"
        do {
            // Use a fresh filename so a failed index save leaves the old
            // payload available to the previously saved record.
            let imageURL = imagesURL.appendingPathComponent(filename)
            try data.write(to: imageURL, options: .atomic)
            try makePrivateFile(at: imageURL)
            // Preserve saved metadata while replacing the image capture.
            let previous = removeDuplicate(signature: signature)
            items.insert(ClipboardRecord(
                id: previous?.id ?? id,
                createdAt: Date(),
                kind: .image,
                text: nil,
                textFilename: nil,
                imageFilename: filename,
                sourceAppName: sourceAppName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                byteCount: data.count,
                signature: signature,
                starredAt: previous?.starredAt,
                tags: previous?.tags
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

    // removeDuplicate(signature): Remove and return the matching index item.
    // Defer deleting its payload until its replacement is saved.
    private func removeDuplicate(signature: String) -> ClipboardRecord? {
        guard let index = items.firstIndex(where: { $0.signature == signature }) else { return nil }
        let duplicate = items.remove(at: index)
        // A failed index write must leave the previously saved copy recoverable.
        replacedPayloads.append(duplicate)
        return duplicate
    }

    // pruneExpiredItems([saveAfterPruning = true]): Remove expired or excess
    // unstarred items. Callers batching changes can defer the index save.
    private func pruneExpiredItems(saveAfterPruning: Bool = true) {
        let cutoff = retention.lifetime.map { Date().addingTimeInterval(-$0) }
        var removed: [ClipboardRecord] = []
        // Collect removed records so their external payloads are pruned as well.
        items.removeAll { item in
            // Stars survive both time-based retention and the history size limit.
            guard !item.isStarred else { return false }
            let isExpired = cutoff.map { item.createdAt < $0 } ?? false
            // Collect expired payloads for deletion with their records.
            if isExpired { removed.append(item); return true }
            return false
        }
        // Stars can exceed the total ceiling; only ordinary history is trimmed.
        if items.count > maximumItemCount {
            // Reserve room for all stars before keeping recent ordinary items.
            var remaining = max(0, maximumItemCount - items.filter(\.isStarred).count)
            items.removeAll { item in
                guard !item.isStarred else { return false }
                // Newest-first traversal keeps the most recent unstarred items.
                if remaining > 0 { remaining -= 1; return false }
                removed.append(item)
                return true
            }
        }
        removed.forEach(removePayload)
        // Avoid a redundant write when pruning is part of a larger save.
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

    /// imageCacheCost(for:) estimates the decoded size of the required data.
    private func imageCacheCost(for data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= Int.max / height / 4 else { return data.count }
        return max(data.count, width * height * 4)
    }

    /// removeImage(for:) evicts and deletes the required record's image.
    private func removeImage(for record: ClipboardRecord) {
        guard let filename = record.imageFilename, let url = imageURL(for: filename) else { return }
        imageCache.removeObject(forKey: filename as NSString)
        try? fileManager.removeItem(at: url)
    }

    private func imagePayloadExists(for record: ClipboardRecord) -> Bool {
        // Like text payloads, images are validated without loading their contents at launch.
        guard let filename = record.imageFilename, let url = imageURL(for: filename) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// removeText(for:) drops cached text before deleting the required payload.
    private func removeText(for record: ClipboardRecord) {
        guard let filename = record.textFilename, let url = textURL(for: filename) else { return }
        // Prevent later searches from reusing this payload from the cache.
        searchEngine = ClipboardSearchEngine()
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

    // externalizeLegacyTextItems(): Move oversized inline text to payload
    // files, preserving all metadata. Return whether the index needs saving.
    private func externalizeLegacyTextItems() -> Bool {
        var changed = false
        for index in items.indices {
            // Skip records already externalized or small enough to stay inline.
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
                // Replace only text storage fields; stars and tags survive
                // migration.
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
                    signature: record.signature,
                    starredAt: record.starredAt,
                    tags: record.tags
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
