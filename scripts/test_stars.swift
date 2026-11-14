import AppKit
import Foundation

@main enum StarredItemsTests {
    // record(index, [starred = false], [tags = nil]): Create a text fixture
    // whose required index offsets its copy and optional star dates by seconds.
    static func record(_ index: Int, starred: Bool = false, tags: [String]? = nil) -> ClipboardRecord {
        ClipboardRecord(
            id: UUID(), createdAt: Date().addingTimeInterval(-Double(index)),
            kind: .text, text: "Item \(index)", textFilename: nil, imageFilename: nil,
            sourceAppName: nil, sourceBundleIdentifier: nil, byteCount: 8,
            signature: "fixture-\(index)",
            starredAt: starred ? Date().addingTimeInterval(-Double(index)) : nil, tags: tags
        )
    }

    // history(root, records, [retention = .forever]): Write the required
    // fixture records under root and load them through the real index format.
    @MainActor static func history(
        _ root: URL, records: [ClipboardRecord], retention: RetentionPeriod = .forever
    ) throws -> ClipboardHistoryStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("history.json"))
        return try ClipboardHistoryStore(rootURL: root, retention: retention)
    }

    // main(): Verify saved-item behavior using the fixture root from argv[1].
    // Pasteboard items are isolated objects, never the system clipboard.
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

        // Old indexes without either new key must decode with no stars or tags.
        let old = record(0)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        legacy.removeValue(forKey: "starredAt")
        legacy.removeValue(forKey: "tags")
        let decoded = try JSONDecoder().decode(ClipboardRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(!decoded.isStarred && decoded.tagNames.isEmpty)
        precondition(ClipboardRecord.normalizedTags(" work, WORK, , documentation , work ") == ["work", "documentation"])

        // Free reserves at most three stars and fills five slots when enough
        // ordinary items exist.
        for count in 0...5 {
            let stars = (10..<(10 + count)).map { record($0, starred: true, tags: ["saved"]) }
            let recent = (0..<8).map { record($0) }
            let store = try history(root.appendingPathComponent("free-\(count)"), records: recent + stars)
            let model = ClipboardViewModel(store: store, itemLimit: 5)
            let accessibleStars = min(count, 3)
            precondition(model.filteredItems.count == 5)
            precondition(model.filteredItems.filter(\.isStarred).count == accessibleStars)
            precondition(model.filteredItems.filter { !$0.isStarred }.map(\.id) == Array(recent.prefix(5 - accessibleStars)).map(\.id))
            precondition(model.filteredItems.filter(\.isStarred).map(\.id) == Array(stars.prefix(3)).map(\.id))
            // Neither content searches nor tag searches can bypass the
            // allowance.
            model.updateQuery("Item 7")
            await model.waitForSearchCompletion()
            precondition(model.filteredItems.isEmpty, "Search cannot bypass the total allowance")
            model.updateQuery("saved")
            await model.waitForSearchCompletion()
            precondition(model.filteredItems.count == accessibleStars)
            // Filtering keeps the cap; Pro restores every retained star.
            model.resetSearch()
            model.toggleStarredFilter()
            precondition(model.filteredItems.count == accessibleStars, "Filtering cannot expose hidden stars")
            model.updateItemLimit(nil)
            precondition(model.filteredItems.count == count, "Pro restores every retained star")
            model.toggleStarredFilter()
            precondition(model.filteredItems.count == recent.count + stars.count)
            // Expiry must cancel an in-flight unrestricted search.
            model.updateQuery("saved")
            model.updateItemLimit(5)
            await model.waitForSearchCompletion()
            precondition(model.filteredItems.count == 5 && store.items.count == recent.count + stars.count,
                         "Expiry cancels a full-history search without deleting saved items")
        }

        // A fourth Free star must fail without disturbing the existing three.
        let capped = try history(root.appendingPathComponent("cap"), records: (0..<8).map { record($0) })
        let free = ClipboardViewModel(store: capped, itemLimit: 5)
        for item in capped.items.prefix(3) {
            free.select(item.id)
            precondition(free.canStarSelectedItem)
            free.toggleSelectedStar()
        }
        // The view-model check and the store both enforce the filled allowance.
        free.select(capped.items[3].id)
        precondition(!free.canStarSelectedItem)
        free.toggleSelectedStar()
        precondition(capped.items.filter(\.isStarred).count == 3)
        precondition(free.filteredItems.count == 5)

        // Tags outrank text, and stars boost matches only within the same tag rank.
        let textMatch = record(0, tags: ["other"])
        let starredText = record(1, starred: true)
        let partialTag = record(2, tags: ["Item guides"])
        let exactTag = record(3, tags: ["ITEM"])
        let searchStore = try history(root.appendingPathComponent("ranking"), records: [textMatch, starredText, partialTag, exactTag])
        let matches = await searchStore.search(matching: "item")
        precondition(matches.map(\.id) == [exactTag.id, partialTag.id, starredText.id, textMatch.id])
        precondition(searchStore.record(exactTag, contains: "ITEM"))

        // Tagged-only results include any tag and combine with stars and
        // search.
        let workStar = record(0, starred: true, tags: ["Work"])
        let workRecent = record(1, tags: ["WORK"])
        let workshop = record(2, tags: ["workshop"])
        let untagged = (3..<8).map { record($0) }
        let archive = record(9, tags: ["archive"])
        let tagStore = try history(root.appendingPathComponent("tag-filter"), records:
            [workStar, workRecent, workshop] + untagged + [archive])
        // Each filter narrows the same candidates before text search runs.
        let tagModel = ClipboardViewModel(store: tagStore)
        tagModel.toggleTaggedFilter()
        precondition(tagModel.filteredItems.map(\.id) == [workStar.id, workRecent.id, workshop.id, archive.id])
        tagModel.toggleStarredFilter()
        precondition(tagModel.filteredItems.map(\.id) == [workStar.id])
        tagModel.updateQuery("Item 1")
        await tagModel.waitForSearchCompletion()
        precondition(tagModel.filteredItems.isEmpty, "Search must respect both filters")
        tagModel.toggleStarredFilter()
        await tagModel.waitForSearchCompletion()
        precondition(tagModel.filteredItems.map(\.id) == [workRecent.id])
        // Changing a filter while a search waits must invalidate its
        // candidates.
        tagModel.resetSearch()
        tagModel.updateQuery("Item 5")
        tagModel.toggleTaggedFilter()
        await tagModel.waitForSearchCompletion()
        precondition(tagModel.filteredItems.map(\.id) == [untagged[2].id], "Pending searches must follow the latest filter")
        // The allowance applies before tags, excluding older matching history.
        tagModel.resetSearch()
        tagModel.toggleTaggedFilter()
        tagModel.updateItemLimit(5)
        precondition(tagModel.filteredItems.map(\.id) == [workStar.id, workRecent.id, workshop.id],
                     "The tagged filter cannot expose history outside Free access")
        tagModel.toggleTaggedFilter()
        precondition(tagModel.filteredItems.count == 5)
        tagModel.toggleTaggedFilter()
        // Removing the final accessible tags clears both results and selection.
        for tagged in [workStar, workRecent, workshop] {
            precondition(tagStore.updateTags(tagged, input: ""))
        }
        tagModel.storeDidChange()
        precondition(tagModel.filteredItems.isEmpty && tagModel.selectedItem == nil,
                     "Removing the last accessible tag empties the tagged filter")
        tagModel.toggleTaggedFilter()
        precondition(tagModel.filteredItems.count == 5, "Turning off an empty tagged filter restores history")

        // Duplicate text retains saved metadata and identity with external
        // payloads.
        let savedRoot = root.appendingPathComponent("saved")
        let saved = try history(savedRoot, records: [])
        let text = NSPasteboardItem()
        precondition(text.setString(String(repeating: "https://example.test/guide ", count: 100), forType: .string))
        precondition(saved.capture([text], sourceAppName: "Fixture") == 1)
        let original = saved.items[0]
        precondition(saved.setStarred(original, starred: true, limit: 3))
        precondition(saved.updateTags(original, input: " docs, DOCS, work "))
        // Recapture and reuse update recency without replacing the star date.
        let starDate = saved.items[0].starredAt
        precondition(saved.capture([text], sourceAppName: "Fixture") == 1)
        precondition(saved.items.count == 1 && saved.items[0].id == original.id)
        precondition(saved.items[0].starredAt == starDate && saved.items[0].tagNames == ["docs", "work"])
        saved.markUsed(saved.items[0])
        precondition(saved.items[0].starredAt == starDate && saved.items[0].tagNames == ["docs", "work"])
        // Reload from disk to distinguish durable metadata from in-memory
        // state.
        let reloaded = try ClipboardHistoryStore(rootURL: savedRoot, retention: .forever)
        precondition(reloaded.items[0].isStarred && reloaded.items[0].tagNames == ["docs", "work"])
        precondition(reloaded.fullText(for: reloaded.items[0]) == text.string(forType: .string))

        // A failed save must not advertise unsaved protection or tags.
        let savedRecord = reloaded.items[0]
        let selected = ClipboardViewModel(store: reloaded)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: savedRoot.path)
        precondition(!reloaded.setStarred(savedRecord, starred: false))
        precondition(reloaded.items[0].isStarred)
        precondition(!reloaded.updateTags(savedRecord, input: "unsaved"))
        precondition(reloaded.items[0].tagNames == ["docs", "work"])
        // Failed duplicate saves must also leave the old payload recoverable.
        precondition(reloaded.capture([text], sourceAppName: "Fixture") == 1)
        precondition(reloaded.storageError != nil, "The read-only index must reject a duplicate save")
        precondition(selected.selectedItem?.textFilename == reloaded.items[0].textFilename,
                     "Selection must use the current payload even before results refresh")
        // Restore write access and verify the previous durable index still
        // works.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: savedRoot.path)
        let recovered = try ClipboardHistoryStore(rootURL: savedRoot, retention: .forever)
        precondition(recovered.items.count == 1 && recovered.items[0].isStarred,
                     "A failed duplicate save must preserve the durable starred record")
        precondition(recovered.fullText(for: recovered.items[0]) == text.string(forType: .string))

        // Images must preserve the same saved metadata and payload guarantees.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let image = NSPasteboardItem()
        precondition(image.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png))
        precondition(reloaded.capture([image], sourceAppName: "Fixture") == 1)
        // Image recapture must retain identity and keep a readable payload.
        let imageID = reloaded.items[0].id
        precondition(reloaded.setStarred(reloaded.items[0], starred: true))
        precondition(reloaded.updateTags(reloaded.items[0], input: "diagram"))
        precondition(reloaded.capture([image], sourceAppName: "Fixture") == 1)
        precondition(reloaded.items[0].id == imageID && reloaded.items[0].tagNames == ["diagram"])
        precondition(reloaded.items[0].isStarred && reloaded.image(for: reloaded.items[0]) != nil)
        // Ordinary clearing retains both saved payload types; explicit
        // inclusion removes them.
        reloaded.clearHistory()
        precondition(reloaded.items.count == 2)
        precondition(reloaded.fullText(for: reloaded.items.first { $0.id == savedRecord.id }!) != nil)
        precondition(reloaded.image(for: reloaded.items[0]) != nil)
        reloaded.clearHistory(includeStarred: true)
        precondition(reloaded.items.isEmpty)

        // Starred text survives retention and legacy payload migration.
        var ancient = record(0, starred: true, tags: ["archive"])
        ancient = ancient.withCreatedAt(Date(timeIntervalSince1970: 0))
        let expired = record(1).withCreatedAt(Date(timeIntervalSince1970: 0))
        let retained = try history(root.appendingPathComponent("retention"), records: [ancient, expired], retention: .oneHour)
        precondition(retained.items.map(\.id) == [ancient.id])
        // Large legacy inline text keeps metadata while moving to an external
        // file.
        let upgraded = ClipboardRecord(id: UUID(), createdAt: Date(timeIntervalSince1970: 0), kind: .text,
            text: String(repeating: "legacy ", count: 1_000), textFilename: nil, imageFilename: nil,
            sourceAppName: nil, sourceBundleIdentifier: nil, byteCount: 7_000,
            signature: "legacy", starredAt: Date(), tags: ["archive"])
        let migrated = try history(root.appendingPathComponent("migration"), records: [upgraded], retention: .oneHour)
        precondition(migrated.items[0].textFilename != nil && migrated.items[0].isStarred)
        precondition(migrated.items[0].tagNames == ["archive"])

        // The ordinary-history ceiling must never evict a saved item.
        let large = try history(root.appendingPathComponent("ceiling"), records:
            (0..<100_001).map { record($0) } + [record(100_001, starred: true)])
        precondition(large.items.count == 100_000 && large.items.last!.isStarred)
        print("Pastemin stars: persistence, retention, tags, ranking, Free limits, and clearing passed")
    }
}
