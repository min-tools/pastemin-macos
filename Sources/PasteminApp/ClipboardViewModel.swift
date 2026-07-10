import AppKit
import Foundation

@MainActor
final class ClipboardViewModel: ObservableObject {
    @Published var query = ""
    @Published var selectedID: UUID?
    @Published private(set) var visibleStartIndex: Int
    @Published private(set) var visibleEndIndex: Int
    @Published private(set) var scrollToTopRequest = 0
    @Published private(set) var keyboardSelectionRequest = 0
    @Published private(set) var filteredItems: [ClipboardRecord]
    @Published private(set) var isSearching = false

    let store: ClipboardHistoryStore
    var onChoose: (() -> Void)?
    private let pageSize = 50
    private var itemLimit: Int?
    private var searchTask: Task<Void, Never>?

    init(store: ClipboardHistoryStore, itemLimit: Int? = nil) {
        self.store = store
        self.itemLimit = itemLimit
        let initialItems = Self.accessibleItems(in: store, limit: itemLimit)
        filteredItems = initialItems
        visibleStartIndex = 0
        visibleEndIndex = min(50, initialItems.count)
        selectedID = initialItems.first?.id
    }

    var selectedItem: ClipboardRecord? {
        filteredItems.first { $0.id == selectedID }
    }

    var displayedItems: ArraySlice<ClipboardRecord> {
        filteredItems[visibleStartIndex..<visibleEndIndex]
    }

    func prepareForPresentation() {
        reconcileSelection()
        // Default every opening to one newest-first batch and a deterministic top anchor.
        resetVisibleWindow()
        selectedID = filteredItems.first?.id
        scrollToTopRequest &+= 1
    }

    func queryDidChange() {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            isSearching = false
            filteredItems = accessibleItems
            resetVisibleWindow()
            reconcileSelection()
            scrollToTopRequest &+= 1
            return
        }

        let requestedQuery = query
        isSearching = true
        filteredItems = []
        resetVisibleWindow()
        selectedID = nil
        searchTask = Task { [weak self] in
            // Debounce typing before reading any external text payloads.
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self, !Task.isCancelled, self.query == requestedQuery else { return }
            let matches = await self.store.search(matching: needle, among: self.accessibleItems)
            guard !Task.isCancelled, self.query == requestedQuery else { return }
            self.filteredItems = matches
            self.isSearching = false
            self.resetVisibleWindow()
            self.selectedID = matches.first?.id
            self.scrollToTopRequest &+= 1
        }
    }

    func resetSearch() {
        searchTask?.cancel()
        isSearching = false
        guard !query.isEmpty else { return }
        query = ""
        filteredItems = accessibleItems
        resetVisibleWindow()
        selectedID = filteredItems.first?.id
        scrollToTopRequest &+= 1
    }

    func storeDidChange() {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryDidChange()
            return
        }
        filteredItems = accessibleItems
        clampVisibleWindow()
        reconcileSelection()
    }

    func updateItemLimit(_ newValue: Int?) {
        itemLimit = newValue.map { max($0, 1) }
        searchTask?.cancel()
        isSearching = false
        query = ""
        filteredItems = accessibleItems
        resetVisibleWindow()
        selectedID = filteredItems.first?.id
        scrollToTopRequest &+= 1
    }

    func loadMoreIfNeeded(afterDisplaying id: UUID) {
        let visible = displayedItems
        guard visibleEndIndex < filteredItems.count else { return }
        // Prefetch the next batch when any of the final five visible records appears.
        let threshold = visible.suffix(min(5, visible.count))
        guard threshold.contains(where: { $0.id == id }) else { return }
        visibleEndIndex = min(visibleEndIndex + pageSize, filteredItems.count)
        visibleStartIndex = max(0, visibleEndIndex - maximumVisibleItemCount)
    }

    func loadPreviousIfNeeded(beforeDisplaying id: UUID) {
        let visible = displayedItems
        guard visibleStartIndex > 0 else { return }
        // Restore the preceding batch when the user returns to the first five visible records.
        let threshold = visible.prefix(min(5, visible.count))
        guard threshold.contains(where: { $0.id == id }) else { return }
        visibleStartIndex = max(0, visibleStartIndex - pageSize)
        visibleEndIndex = min(filteredItems.count, visibleStartIndex + maximumVisibleItemCount)
    }

    func reconcileSelection() {
        if let selectedID, filteredItems.contains(where: { $0.id == selectedID }) { return }
        selectedID = filteredItems.first?.id
    }

    func select(_ id: UUID) {
        guard filteredItems.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func moveSelection(by offset: Int) {
        let records = filteredItems
        guard !records.isEmpty else { selectedID = nil; return }
        let current = selectedID.flatMap { id in records.firstIndex { $0.id == id } } ?? 0
        let target = min(max(current + offset, 0), records.count - 1)
        // Keyboard navigation shifts the same bounded window used by scrolling.
        ensureVisible(target)
        selectedID = records[target].id
        keyboardSelectionRequest &+= 1
    }

    func chooseSelected() {
        guard let selectedItem, store.restore(selectedItem) else { return }
        onChoose?()
    }

    func deleteSelected() {
        guard let selectedItem else { return }
        let records = filteredItems
        let index = records.firstIndex(of: selectedItem) ?? 0
        store.delete(selectedItem)
        filteredItems.removeAll { $0.id == selectedItem.id }
        clampVisibleWindow()
        let remaining = filteredItems
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    func waitForSearchCompletion() async {
        await searchTask?.value
    }

    private var maximumVisibleItemCount: Int {
        pageSize * 3
    }

    private var accessibleItems: [ClipboardRecord] {
        Self.accessibleItems(in: store, limit: itemLimit)
    }

    private static func accessibleItems(
        in store: ClipboardHistoryStore,
        limit: Int?
    ) -> [ClipboardRecord] {
        guard let limit else { return store.items }
        return Array(store.items.prefix(limit))
    }

    private func resetVisibleWindow() {
        visibleStartIndex = 0
        visibleEndIndex = min(pageSize, filteredItems.count)
    }

    private func clampVisibleWindow() {
        guard !filteredItems.isEmpty else {
            visibleStartIndex = 0
            visibleEndIndex = 0
            return
        }
        if visibleStartIndex >= filteredItems.count {
            visibleStartIndex = max(0, filteredItems.count - min(pageSize, maximumVisibleItemCount))
        }
        visibleEndIndex = min(max(visibleEndIndex, visibleStartIndex), filteredItems.count)
        if visibleEndIndex == visibleStartIndex {
            visibleEndIndex = min(filteredItems.count, visibleStartIndex + pageSize)
        }
    }

    private func ensureVisible(_ index: Int) {
        if index < visibleStartIndex {
            visibleStartIndex = max(0, index - pageSize + 1)
            visibleEndIndex = min(filteredItems.count, visibleStartIndex + maximumVisibleItemCount)
        } else if index >= visibleEndIndex {
            visibleEndIndex = min(filteredItems.count, max(index + 1, visibleEndIndex + pageSize))
            visibleStartIndex = max(0, visibleEndIndex - maximumVisibleItemCount)
        }
    }

}
