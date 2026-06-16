import AppKit
import SwiftUI

private enum HistoryScrollAnchor: Hashable {
    case top
}

private enum HistoryScrollCoordinateSpace {
    static let name = "ClipboardHistoryScroll"
}

private struct HistoryTopPositionKey: PreferenceKey {
    static var defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct HistoryBottomPositionKey: PreferenceKey {
    static var defaultValue = CGFloat.infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardViewModel
    @ObservedObject var store: ClipboardHistoryStore
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var proStore: PasteminStore
    @ObservedObject var accessBannerState: AccessLimitedBannerState
    let recordingChanged: (Bool) -> Void
    let showPurchases: () -> Void
    let restorePurchases: () async -> String?
    let showPrivacyPolicy: () -> Void
    let showAbout: () -> Void
    let revealStorage: () -> Void
    let clearCurrentClipboard: () -> Void
    let clearHistory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.65)
            if let storageError = store.storageError {
                storageErrorBanner(storageError)
                Divider().opacity(0.65)
            }
            if store.items.isEmpty {
                emptyState
            } else if model.isSearching {
                searchingState
            } else if model.filteredItems.isEmpty {
                noMatches
            } else {
                historyContent
            }
            if proStore.hasResolvedEntitlement && !proStore.hasFullAccess {
                AccessLimitedBanner(
                    state: accessBannerState,
                    showPurchases: showPurchases,
                    restorePurchases: restorePurchases
                )
            }
        }
        .background(Color.clear)
        .onAppear { model.reconcileSelection() }
        .onChange(of: model.query) { model.queryDidChange() }
        .onChange(of: store.items) { model.storeDidChange() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.primary)
                .frame(width: 36)

            ClipboardSearchField(text: $model.query)
                .frame(height: 32)

            ClipboardOptionsButton(
                preferences: preferences,
                store: store,
                recordingChanged: recordingChanged,
                showPrivacyPolicy: showPrivacyPolicy,
                showAbout: showAbout,
                revealStorage: revealStorage,
                clearCurrentClipboard: clearCurrentClipboard,
                clearHistory: clearHistory
            )
            .frame(width: 38, height: 34)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    private func storageErrorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("pastemin_storage_error", "Pastemin Storage Error"))
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(action: store.dismissStorageError) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(localized("ok", "OK"))
            .accessibilityLabel(localized("ok", "OK"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color(nsColor: .systemOrange).opacity(0.10))
        .accessibilityElement(children: .contain)
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "clipboard")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(localized("no_items", "No Items")).font(.title2.weight(.medium))
            Text(localized("copied_items_appear_here", "Items you copy will appear here."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -18)
    }

    private var noMatches: some View {
        ContentUnavailableView.search(text: model.query)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchingState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(localized("searching_pastemin", "Searching Pastemin…"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyContent: some View {
        HStack(spacing: 0) {
            historyList.frame(width: 350)
            Divider().opacity(0.65)
            ClipboardPreview(
                record: model.selectedItem,
                store: store,
                delete: model.deleteSelected
            )
        }
    }

    private var historyList: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Scroll to the content origin, not the first row, to preserve its inset.
                        Color.clear
                            .frame(height: 0)
                            .id(HistoryScrollAnchor.top)

                        if model.visibleStartIndex > 0 {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: HistoryTopPositionKey.self,
                                    value: geometry.frame(in: .named(HistoryScrollCoordinateSpace.name)).minY
                                )
                            }
                            .frame(height: 1)
                        }

                        LazyVStack(spacing: 5) {
                            ForEach(model.displayedItems) { record in
                                ClipboardRow(
                                    record: record,
                                    itemImage: record.kind == .image ? store.image(for: record) : nil,
                                    sourceAppIcon: store.sourceAppIcon(for: record),
                                    selected: model.selectedID == record.id
                                )
                                .id(record.id)
                                .onHover { isInside in
                                    if isInside { model.select(record.id) }
                                }
                                .onTapGesture { model.select(record.id) }
                                .onTapGesture(count: 2) {
                                    model.select(record.id)
                                    model.chooseSelected()
                                }
                            }
                        }
                        .padding(12)

                        if model.visibleEndIndex < model.filteredItems.count {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: HistoryBottomPositionKey.self,
                                    value: geometry.frame(in: .named(HistoryScrollCoordinateSpace.name)).minY
                                )
                            }
                            .frame(height: 1)
                        }
                    }
                }
                .coordinateSpace(name: HistoryScrollCoordinateSpace.name)
                .onPreferenceChange(HistoryBottomPositionKey.self) { position in
                    guard position.isFinite,
                          position <= viewport.size.height + 220,
                          let last = model.displayedItems.last else { return }
                    // Defer mutation until SwiftUI finishes the current geometry pass.
                    DispatchQueue.main.async {
                        model.loadMoreIfNeeded(afterDisplaying: last.id)
                    }
                }
                .onPreferenceChange(HistoryTopPositionKey.self) { position in
                    guard position.isFinite,
                          position >= -220,
                          let first = model.displayedItems.first else { return }
                    DispatchQueue.main.async {
                        model.loadPreviousIfNeeded(beforeDisplaying: first.id)
                    }
                }
                .onChange(of: model.keyboardSelectionRequest) {
                    guard let selectedID = model.selectedID else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
                .onChange(of: model.scrollToTopRequest) {
                    DispatchQueue.main.async {
                        proxy.scrollTo(HistoryScrollAnchor.top, anchor: .top)
                    }
                }
            }
        }
    }
}

private struct ClipboardSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> ClipboardSearchScrollView {
        let scrollView = ClipboardSearchScrollView()
        let textView = scrollView.textView
        textView.delegate = context.coordinator
        textView.placeholderAttributedString = NSAttributedString(
            string: localized("clipboard", "Clipboard"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 26, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ]
        )
        textView.setAccessibilityLabel(localized("search_clipboard", "Search Clipboard"))
        return scrollView
    }

    func updateNSView(_ scrollView: ClipboardSearchScrollView, context: Context) {
        context.coordinator.text = $text
        let textView = scrollView.textView
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
