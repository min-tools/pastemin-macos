#!/usr/bin/env python3
"""Exercise rendering, search, and selection with a 10,000-item history."""
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

@main
enum PaginationTest {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let records = (0..<10_000).map { index in
            ClipboardRecord(
                id: UUID(),
                createdAt: Date(),
                kind: .text,
                text: "Item \(index)",
                textFilename: nil,
                imageFilename: nil,
                sourceAppName: "Fixture",
                sourceBundleIdentifier: "com.example.fixture",
                byteCount: 12,
                signature: "fixture-\(index)"
            )
        }
        try JSONEncoder().encode(records).write(
            to: root.appendingPathComponent("history.json"),
            options: .atomic
        )

        let store = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        check(store.items.count == 10_000, "Store keeps large histories")

        // A normal copy must remain responsive even when the retained index is large.
        let nextItem = NSPasteboardItem()
        check(nextItem.setString("Newest item", forType: .string), "Set newest item")
        let saveStarted = Date()
        check(store.capture([nextItem], sourceAppName: "Fixture") == 1, "Capture into large history")
        check(Date().timeIntervalSince(saveStarted) < 1.0, "Persist large history without a long pause")
        check(store.items.count == 10_001, "Append to large history")

        let model = ClipboardViewModel(store: store)
        check(model.displayedItems.count == 50, "Initial batch contains 50 items")
        let thresholdID = model.displayedItems.dropFirst(45).first!.id
        model.loadMoreIfNeeded(afterDisplaying: thresholdID)
        check(model.displayedItems.count == 100, "Near-bottom appearance loads another batch")

        model.moveSelection(by: 100)
        check(model.displayedItems.count == 150, "Keyboard navigation loads fixed 50-item batches")
        let pointerTarget = model.filteredItems[5]
        let keyboardRequest = model.keyboardSelectionRequest
        model.select(pointerTarget.id)
        check(model.selectedID == pointerTarget.id, "Pointer selection updates the shared selection")
        check(
            model.keyboardSelectionRequest == keyboardRequest,
            "Pointer selection does not force a keyboard scroll"
        )
        model.moveSelection(by: 1)
        check(
            model.selectedID == model.filteredItems[6].id,
            "Keyboard navigation continues from the pointer selection"
        )
        check(
            model.keyboardSelectionRequest == keyboardRequest + 1,
            "Keyboard navigation requests selection scrolling"
        )

        let slidingModel = ClipboardViewModel(store: store)
        for _ in 0..<8 {
            slidingModel.loadMoreIfNeeded(afterDisplaying: slidingModel.displayedItems.last!.id)
        }
        check(slidingModel.displayedItems.count <= 150, "Rendered history stays within three batches")
        check(slidingModel.visibleStartIndex > 0, "Older rendering drops rows from the opposite edge")
        let previousStart = slidingModel.visibleStartIndex
        slidingModel.loadPreviousIfNeeded(beforeDisplaying: slidingModel.displayedItems.first!.id)
        check(slidingModel.visibleStartIndex < previousStart, "Scrolling back restores the preceding batch")

        let scrollRequest = model.scrollToTopRequest
        model.prepareForPresentation()
        check(model.displayedItems.count == 50, "Every presentation resets to one fixed batch")
        check(model.selectedID == model.filteredItems.first?.id, "Default presentation selects newest item")
        check(model.scrollToTopRequest == scrollRequest + 1, "Default presentation requests top position")
        let stationaryPointerTarget = model.filteredItems[8]
        model.selectFromPointer(stationaryPointerTarget.id)
        check(
            model.selectedID == model.filteredItems.first?.id,
            "A stationary pointer cannot replace the default selection"
        )
        model.enablePointerSelection()
        model.selectFromPointer(stationaryPointerTarget.id)
        check(
            model.selectedID == stationaryPointerTarget.id,
            "Pointer movement enables hover selection"
        )

        // Search must never bypass the expired-access limit.
        let limitedModel = ClipboardViewModel(store: store, itemLimit: 5)
        check(limitedModel.filteredItems.count == 5, "Expired access exposes only five newest items")
        limitedModel.updateQuery("Item 9999")
        check(limitedModel.filteredItems.count == 5, "Typing keeps the current list stable")
        check(limitedModel.selectedID != nil, "Typing keeps the current selection stable")
        await limitedModel.waitForSearchCompletion()
        check(limitedModel.filteredItems.isEmpty, "Search cannot reveal history outside the limit")
        limitedModel.updateItemLimit(nil)
        check(limitedModel.filteredItems.count == store.items.count, "Purchase restores full history")

        // Simulate rapid typing while keeping the last completed results
        // visible.
        for query in ["I", "It", "Ite", "Item", "Item ", "Item 9", "Item 99", "Item 999", "Item 9999"] {
            model.updateQuery(query)
            check(!model.displayedItems.isEmpty, "Rapid typing keeps the current list visible")
        }
        await model.waitForSearchCompletion()
        check(model.query == "Item 9999", "Rapid typing keeps only the latest query")
        check(model.filteredItems.count == 1, "Search filters the large history once")

        // Pending results must not make an old selection actionable.
        let countBeforePendingDelete = store.items.count
        model.updateQuery("Item 99999")
        check(model.filteredItems.count == 1, "An extended query keeps completed results visible")
        model.deleteSelected()
        check(store.items.count == countBeforePendingDelete, "Pending search cannot delete a stale result")
        await model.waitForSearchCompletion()
        check(model.filteredItems.isEmpty, "An extended query narrows completed results")

        // Search results use the same bounded rendering window as full history.
        model.updateQuery("Item")
        await model.waitForSearchCompletion()
        for _ in 0..<8 {
            model.loadMoreIfNeeded(afterDisplaying: model.displayedItems.last!.id)
        }
        check(model.displayedItems.count <= 150, "Search results use the same sliding window")
        model.resetSearch()
        check(model.query.isEmpty && model.displayedItems.count == 50, "Dismissal resets search state")

        // Clearing history must invalidate both active and completed results.
        let clearingModel = ClipboardViewModel(store: store)
        var choseClearedItem = false
        clearingModel.onChoose = { choseClearedItem = true }
        clearingModel.updateQuery("Item")
        store.clearHistory()
        clearingModel.chooseSelected()
        check(!choseClearedItem, "Clearing immediately blocks the old selection")
        await clearingModel.waitForSearchCompletion()
        check(clearingModel.filteredItems.isEmpty, "Clearing invalidates an in-flight search")
        check(clearingModel.selectedID == nil, "Clearing cannot restore a stale selection")

        check(GlobalShortcut.defaultShortcut.menuKeyEquivalent == "c", "Menu displays shortcut key")
        check(
            GlobalShortcut.defaultShortcut.menuModifierFlags == [.control, .option],
            "Menu displays shortcut modifiers"
        )
        print("Pastemin pagination: 10,000-item incremental rendering passed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='pastemin-pagination-test-', dir='/private/tmp') as folder_name:
    folder = Path(folder_name)
    main = folder / 'main.swift'
    main.write_text(fixture)
    command = swift_compiler() + [
        '-parse-as-library', '-swift-version', '5', '-module-cache-path', str(folder / 'modules'),
        '-target', 'arm64-apple-macos14.0',
        str(ROOT / 'Sources/PasteminApp/Localization.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardModels.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardHistoryStore.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardViewModel.swift'), str(main),
        '-framework', 'AppKit', '-framework', 'Carbon', '-framework', 'CryptoKit',
        '-framework', 'ImageIO',
        '-o', str(folder / 'pagination-test')
    ]
    subprocess.run(command, check=True)
    storage = folder / 'Application Support/Pastemin'
    subprocess.run([str(folder / 'pagination-test'), str(storage)], check=True, timeout=30)
