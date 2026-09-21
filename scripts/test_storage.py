#!/usr/bin/env python3
"""Exercise text and image history using isolated pasteboards and storage."""
from pathlib import Path
import subprocess
import tempfile

from build import ROOT, swift_compiler

fixture = r'''
import AppKit
import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@main
enum StorageTest {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        let textItem = NSPasteboardItem()
        check(textItem.setString("A useful clipboard line\nwith a preview", forType: .string), "Set text")
        check(store.capture(
            [textItem],
            sourceAppName: "Fixture",
            sourceBundleIdentifier: "com.example.fixture"
        ) == 1, "Capture text")
        check(store.items.count == 1 && store.items[0].kind == .text, "Store text")

        let duplicate = NSPasteboardItem()
        check(duplicate.setString("A useful clipboard line\nwith a preview", forType: .string), "Repeat text")
        check(store.capture(
            [duplicate],
            sourceAppName: "Fixture",
            sourceBundleIdentifier: "com.example.fixture"
        ) == 1, "Capture duplicate")
        check(store.items.count == 1, "Duplicate content is moved, not duplicated")

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let png = bitmap.representation(using: .png, properties: [:])!
        let imageItem = NSPasteboardItem()
        check(imageItem.setData(png, forType: .png), "Set image")
        check(store.capture(
            [imageItem],
            sourceAppName: "Fixture",
            sourceBundleIdentifier: "com.example.fixture"
        ) == 1, "Capture image")
        check(store.items.first?.kind == .image, "Store image")
        // Repeated reads should reuse one decoded image object.
        let firstDecodedImage = store.image(for: store.items[0])!
        let cachedImage = store.image(for: store.items[0])!
        check(firstDecodedImage === cachedImage, "Reuse decoded images while rendering")

        let historyURL = root.appendingPathComponent("history.json")
        let imagesURL = root.appendingPathComponent("Images", isDirectory: true)
        let textItemsURL = root.appendingPathComponent("Text", isDirectory: true)
        let imageURL = imagesURL.appendingPathComponent(store.items[0].imageFilename!)
        let rootPermissions = try permissions(of: root)
        let imageDirectoryPermissions = try permissions(of: imagesURL)
        let textDirectoryPermissions = try permissions(of: textItemsURL)
        let historyPermissions = try permissions(of: historyURL)
        let imagePermissions = try permissions(of: imageURL)
        check(rootPermissions & 0o777 == 0o700, "Private storage directory")
        check(imageDirectoryPermissions & 0o777 == 0o700, "Private image directory")
        check(textDirectoryPermissions & 0o777 == 0o700, "Private text directory")
        check(historyPermissions & 0o777 == 0o600, "Private history file")
        check(imagePermissions & 0o777 == 0o600, "Private image file")

        // A failed duplicate replacement must keep the earlier durable image intact.
        let durableImageID = store.items[0].id
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o500)],
            ofItemAtPath: imagesURL.path
        )
        let partialText = NSPasteboardItem()
        check(partialText.setString("Partial capture survives", forType: .string), "Set partial text")
        check(
            store.capture([imageItem, partialText], sourceAppName: "Fixture") == 1,
            "Save valid items beside an image write failure"
        )
        check(store.items.contains(where: { $0.id == durableImageID }), "Keep existing duplicate")
        check(store.storageError != nil, "Expose image write failure")
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: imagesURL.path
        )
        if let partial = store.items.first(where: { $0.text == "Partial capture survives" }) {
            store.delete(partial)
        }
        store.dismissStorageError()

        // Reject oversized encoded input before attempting to decode it.
        let oversizedImage = NSPasteboardItem()
        check(
            oversizedImage.setData(Data(count: 25 * 1_024 * 1_024 + 1), forType: .png),
            "Set oversized image"
        )
        check(store.capture([oversizedImage], sourceAppName: "Fixture") == 0, "Bound image input")

        // Truncation must observe the byte limit without splitting a multi-byte scalar.
        let largeItem = NSPasteboardItem()
        let deepSearchNeedle = "only-after-the-preview-boundary"
        let largeText = String(repeating: "🙂", count: 600) + deepSearchNeedle
            + String(repeating: "🙂", count: 599_400)
        check(largeItem.setString(largeText, forType: .string), "Set large text")
        check(store.capture([largeItem], sourceAppName: "Fixture") == 1, "Capture large text")
        check(store.items[0].byteCount <= 2 * 1_024 * 1_024, "Bound text bytes")
        check(store.items[0].textFilename != nil, "Externalize large text")
        check(store.items[0].text?.last == "🙂", "Preserve valid UTF-8")
        check(store.items[0].previewText.utf8.count < 1_100, "Bound rendered text preview")
        check(store.items[0].isTextPreviewTruncated, "Mark a limited text preview")
        let fullLargeText = store.fullText(for: store.items[0])
        check(fullLargeText!.utf8.count > store.items[0].previewText.utf8.count, "Keep text beyond preview")
        let externalMatches = await store.search(matching: deepSearchNeedle)
        check(externalMatches.first?.id == store.items[0].id, "Search complete external text")
        let textURL = textItemsURL.appendingPathComponent(store.items[0].textFilename!)
        let textPermissions = try permissions(of: textURL)
        let historyData = try Data(contentsOf: historyURL)
        check(textPermissions & 0o777 == 0o600, "Private text payload")
        check(historyData.count < 10_000, "Keep history index small")

        let reloaded = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        check(reloaded.items.count == 3, "History persists on disk")
        check(reloaded.fullText(for: reloaded.items[0]) == fullLargeText, "External text persists")
        check(reloaded.items.dropFirst().allSatisfy {
            $0.sourceBundleIdentifier == "com.example.fixture"
        }, "Source bundle identifiers persist")

        // Marking an older item as used promotes it and persists the refreshed timestamp.
        let promotedRecord = reloaded.items.last!
        let previousTimestamp = promotedRecord.createdAt
        reloaded.markUsed(promotedRecord)
        check(reloaded.items.first?.id == promotedRecord.id, "Promote restored item to the top")
        check(reloaded.items.first!.createdAt > previousTimestamp, "Refresh restored item timestamp")
        let promotionReloaded = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        check(promotionReloaded.items.first?.id == promotedRecord.id, "Persist promoted ordering")
        check(
            promotionReloaded.items.first?.createdAt == reloaded.items.first?.createdAt,
            "Persist promoted timestamp"
        )

        // Existing large inline records migrate only after their external payload is durable.
        let legacyRoot = root.appendingPathComponent("Legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyText = String(repeating: "legacy ", count: 1_000)
        let legacyRecord = ClipboardRecord(
            id: UUID(), createdAt: Date(), kind: .text, text: legacyText,
            textFilename: nil, imageFilename: nil, sourceAppName: "Fixture",
            sourceBundleIdentifier: "com.example.fixture", byteCount: legacyText.utf8.count,
            signature: "legacy-inline"
        )
        try JSONEncoder().encode([legacyRecord]).write(
            to: legacyRoot.appendingPathComponent("history.json"), options: .atomic
        )
        let migratedStore = try ClipboardHistoryStore(rootURL: legacyRoot, retention: .oneMonth)
        check(migratedStore.items[0].textFilename != nil, "Migrate legacy inline text")
        check(migratedStore.fullText(for: migratedStore.items[0]) == legacyText, "Preserve migrated text")
        let storageByteCount = await reloaded.calculateStorageByteCount()
        check(storageByteCount > 0, "Calculate storage size")
        reloaded.clearHistory()
        check(reloaded.items.isEmpty, "History clears")

        // Never follow a crafted metadata path beyond the managed image directory.
        let outsideURL = root.deletingLastPathComponent().appendingPathComponent("outside.png")
        let outsideTextURL = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
        try png.write(to: outsideURL)
        try Data("outside".utf8).write(to: outsideTextURL)
        let escaped = ClipboardRecord(
            id: UUID(), createdAt: Date(), kind: .image, text: nil,
            textFilename: nil, imageFilename: "../outside.png", sourceAppName: "Fixture",
            sourceBundleIdentifier: "com.example.fixture", byteCount: png.count,
            signature: "crafted-path"
        )
        let escapedText = ClipboardRecord(
            id: UUID(), createdAt: Date(), kind: .text, text: "outside",
            textFilename: "../outside.txt", imageFilename: nil, sourceAppName: "Fixture",
            sourceBundleIdentifier: "com.example.fixture", byteCount: 7,
            signature: "crafted-text-path"
        )
        try JSONEncoder().encode([escaped, escapedText]).write(to: historyURL, options: .atomic)
        let hardened = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        check(hardened.items.isEmpty, "Reject payload paths outside storage")
        check(FileManager.default.fileExists(atPath: outsideURL.path), "Do not delete outside files")
        check(FileManager.default.fileExists(atPath: outsideTextURL.path), "Do not delete outside text")

        // Starting after an access pause must ignore content copied during the pause.
        var changeCount = 0
        var captureCount = 0
        let monitor = ClipboardMonitor(
            changeCount: { changeCount },
            capture: { captureCount += 1 }
        )
        changeCount += 1
        monitor.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        check(captureCount == 0, "Ignore clipboard changes made while stopped")
        changeCount += 1
        try await Task.sleep(nanoseconds: 500_000_000)
        monitor.stop()
        check(captureCount == 1, "Capture active clipboard changes")
        print("Pastemin storage: payloads, migration, privacy and search passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='pastemin-storage-test-', dir='/private/tmp') as folder_name:
    folder = Path(folder_name)
    main = folder / 'main.swift'
    main.write_text(fixture)
    command = swift_compiler() + [
        '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(folder / 'modules'),
        '-target', 'arm64-apple-macos14.0',
        str(ROOT / 'Sources/PasteminApp/Localization.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardModels.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardHistoryStore.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardMonitor.swift'), str(main),
        '-framework', 'AppKit', '-framework', 'Carbon', '-framework', 'CryptoKit',
        '-framework', 'ImageIO',
        '-o', str(folder / 'storage-test')
    ]
    subprocess.run(command, check=True)
    storage = folder / 'Application Support/Pastemin'
    subprocess.run([str(folder / 'storage-test'), str(storage)], check=True, timeout=30)
