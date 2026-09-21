import AppKit
import Foundation

@MainActor
final class ClipboardViewModel: ObservableObject {
    private(set) var query = ""
    @Published var selectedID: UUID?
    @Published private(set) var visibleStartIndex: Int
    @Published private(set) var visibleEndIndex: Int
    @Published private(set) var scrollToTopRequest = 0
    @Published private(set) var keyboardSelectionRequest = 0
    @Published private(set) var filteredItems: [ClipboardRecord]

    let store: ClipboardHistoryStore
    var onChoose: (() -> Void)?
    private let pageSize = 50
    private let searchDebounceNanoseconds: UInt64 = 35_000_000
    private var itemLimit: Int?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var completedSearchNeedle: String?
    private var completedSearchItems: [ClipboardRecord]?

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

    /// updateQuery(_:) stores the required text and schedules its search.
    func updateQuery(_ newValue: String) {
        guard query != newValue else { return }
        query = newValue
        queryDidChange()
    }

    /// queryDidChange() keeps current results visible during the latest search.
    private func queryDidChange() {
        searchTask?.cancel()
        searchGeneration &+= 1
        let requestedSearchGeneration = searchGeneration
        let needle = normalizedQuery
        guard !needle.isEmpty else {
            clearCompletedSearch()
            filteredItems = accessibleItems
            resetVisibleWindow()
            reconcileSelection()
            scrollToTopRequest &+= 1
            return
        }

        let candidates = searchCandidates(for: needle)
        let storeGeneration = store.itemsGeneration
        let debounceNanoseconds = searchDebounceNanoseconds
        searchTask = Task { [weak self] in
            // Coalesce rapid keystrokes while keeping the current list stable.
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard let self,
                  !Task.isCancelled,
                  self.searchGeneration == requestedSearchGeneration,
                  self.normalizedQuery == needle else { return }
            let matches = await self.store.search(matching: needle, among: candidates)
            guard !Task.isCancelled,
                  self.searchGeneration == requestedSearchGeneration,
                  self.normalizedQuery == needle else { return }
            // Restart if history changed while the actor searched its snapshot.
            guard self.store.itemsGeneration == storeGeneration else {
                self.queryDidChange()
                return
            }
            self.completedSearchNeedle = needle
            self.completedSearchItems = matches
            self.filteredItems = matches
            self.resetVisibleWindow()
            self.selectedID = matches.first?.id
            self.scrollToTopRequest &+= 1
        }
    }

    /// resetSearch() cancels searching and restores the accessible history.
    func resetSearch() {
        searchTask?.cancel()
        searchGeneration &+= 1
        clearCompletedSearch()
        guard !query.isEmpty else { return }
        query = ""
        filteredItems = accessibleItems
        resetVisibleWindow()
        selectedID = filteredItems.first?.id
        scrollToTopRequest &+= 1
    }

    /// storeDidChange() refreshes results after the history changes.
    func storeDidChange() {
        clearCompletedSearch()
        // Repeat an active search against the new history snapshot.
        if !normalizedQuery.isEmpty {
            queryDidChange()
            return
        }
        filteredItems = accessibleItems
        clampVisibleWindow()
        reconcileSelection()
    }

    /// updateItemLimit(_:) applies the required value; nil restores all items.
    func updateItemLimit(_ newValue: Int?) {
        itemLimit = newValue.map { max($0, 1) }
        searchTask?.cancel()
        searchGeneration &+= 1
        clearCompletedSearch()
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

    /// chooseSelected() restores the current valid selection to the pasteboard.
    func chooseSelected() {
        // Never paste a selection from an old query or history snapshot.
        guard searchResultsAreCurrent,
              let selectedItem,
              store.items.contains(where: { $0.id == selectedItem.id }),
              store.restore(selectedItem) else { return }
        onChoose?()
    }

    /// deleteSelected() removes the current valid selection from history.
    func deleteSelected() {
        // Never delete a selection from an old query or history snapshot.
        guard searchResultsAreCurrent,
              let selectedItem,
              store.items.contains(where: { $0.id == selectedItem.id }) else { return }
        let records = filteredItems
        let index = records.firstIndex(of: selectedItem) ?? 0
        store.delete(selectedItem)
        filteredItems.removeAll { $0.id == selectedItem.id }
        completedSearchItems?.removeAll { $0.id == selectedItem.id }
        clampVisibleWindow()
        let remaining = filteredItems
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    /// waitForSearchCompletion() awaits the latest search and any restart.
    func waitForSearchCompletion() async {
        while true {
            let awaitedGeneration = searchGeneration
            await searchTask?.value
            // Follow a search restarted after its source history changed.
            if awaitedGeneration == searchGeneration { return }
        }
    }

    private var maximumVisibleItemCount: Int {
        pageSize * 3
    }

    private var accessibleItems: [ClipboardRecord] {
        Self.accessibleItems(in: store, limit: itemLimit)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when visible results match the current normalized query.
    private var searchResultsAreCurrent: Bool {
        normalizedQuery.isEmpty || completedSearchNeedle == normalizedQuery
    }

    /// searchCandidates(for:) narrows a required query from compatible results.
    private func searchCandidates(for needle: String) -> [ClipboardRecord] {
        guard let completedSearchNeedle,
              needle.hasPrefix(completedSearchNeedle),
              let completedSearchItems else { return accessibleItems }
        // Extending a completed query can only narrow its matches.
        return completedSearchItems
    }

    /// clearCompletedSearch() invalidates the completed query and its results.
    private func clearCompletedSearch() {
        completedSearchNeedle = nil
        completedSearchItems = nil
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
