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

/// Shared symbol weight, hit areas and alignment for panel icon buttons.
private enum PanelIcon {
    /// Side of the square hit area and its highlight.
    static let side: CGFloat = 28
    /// Gap between neighboring item actions.
    static let spacing: CGFloat = 6
    /// Aligns the trailing header and preview actions.
    static let trailingInset: CGFloat = 16
    static let cornerRadius: CGFloat = 8
    static let headerSymbolSize: CGFloat = 17
    static let actionSymbolSize: CGFloat = 15
    static let symbolWeight = Font.Weight.medium
    /// The same weight for the options button, which AppKit draws.
    static let appKitSymbolWeight = NSFont.Weight.medium

    // symbol(name, size, tint): Draw the required SF Symbol with the supplied
    // nominal point size and color, using the shared weight.
    static func symbol(_ name: String, size: CGFloat, tint: Color) -> some View {
        // Reduce the tag by a point to balance its visual size with other
        // icons.
        let opticalSize = name.hasPrefix("tag") ? size - 1 : size
        return Image(systemName: name)
            .font(.system(size: opticalSize, weight: symbolWeight))
            .foregroundStyle(tint)
            #if PASTEMIN_SCREENSHOTS
            // Lower tags by half an output pixel in the screenshot renderer.
            .offset(y: name.hasPrefix("tag") ? 0.5 / RenderHero.scale : 0)
            #endif
    }
}

/// Draws icon and filter-chip highlights using AppKit pointer tracking,
/// without adding hover state to the SwiftUI hierarchy.
private struct PanelIconBackdrop: NSViewRepresentable {
    var isActive = false
    var isPressed = false
    /// A chip passes half its height to get a capsule.
    var cornerRadius = PanelIcon.cornerRadius

    /// makeNSView(context:) creates the tracking view with the required context.
    func makeNSView(context: Context) -> PanelIconBackdropView { PanelIconBackdropView() }

    /// updateNSView(view, context): Sync the required native view with button
    /// state. The required SwiftUI context is unused.
    func updateNSView(_ view: PanelIconBackdropView, context: Context) {
        view.isActive = isActive
        view.isPressed = isPressed
        view.cornerRadius = cornerRadius
    }
}

/// Tracks one control's hover state and draws its current interaction fill.
private final class PanelIconBackdropView: NSView {
    // Redraw only when filter activation changes.
    var isActive = false { didSet { if isActive != oldValue { needsDisplay = true } } }
    // Redraw only when the button enters or leaves its pressed state.
    var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    // A changed radius switches between icon and capsule-shaped fills.
    var cornerRadius = PanelIcon.cornerRadius {
        didSet { if cornerRadius != oldValue { needsDisplay = true } }
    }
    // Ignore repeated hover assignments that would produce the same fill.
    private var isHovering = false { didSet { if isHovering != oldValue { needsDisplay = true } } }
    private var keyObserver: NSObjectProtocol?

    /// init(frame:) installs pointer tracking for the required frame.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Track visible controls even when this nonactivating panel is not key.
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    /// init(coder): Reject the required archive decoder; create this view in
    /// code.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// deinit: Release any observer owned by this tracking view.
    deinit {
        // A view removed before joining a window has no observer.
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
    }

    /// hitTest(point): Pass clicks at the required point through to the button.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// mouseEntered(with:) shows the hover fill for the required event.
    override func mouseEntered(with event: NSEvent) { isHovering = true }

    /// mouseExited(with:) removes the hover fill for the required event.
    override func mouseExited(with event: NSEvent) { isHovering = false }

    /// viewDidMoveToWindow() follows the new window's key status.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Stop observing the previous window before following the new one.
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        guard let window else { return }
        // Losing key status may not send a pointer exit. Clear stale hover
        // then.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isHovering = false }
        }
    }

    /// draw(dirtyRect): Redraw the control fill when AppKit invalidates the
    /// required region. The shape always uses the full view bounds.
    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if isActive {
            // Keep active filters visibly tinted even without hover or a press.
            fill = .controlAccentColor.withAlphaComponent(isPressed ? 0.30 : isHovering ? 0.24 : 0.18)
        } else if isPressed {
            // A stronger fill provides immediate feedback during a press.
            fill = .labelColor.withAlphaComponent(0.16)
        } else if isHovering {
            // A subtle fill identifies the control under the pointer.
            fill = .labelColor.withAlphaComponent(0.09)
        } else {
            // An idle icon has no fill.
            return
        }
        // Clamp the radius so short controls keep a valid rounded outline.
        fill.setFill()
        let radius = min(cornerRadius, bounds.height / 2)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// Gives icon buttons consistent hover feedback without dimming their labels.
private struct PanelIconButtonStyle: ButtonStyle {
    /// makeBody(configuration:) centers the required label in the shared hit area.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: PanelIcon.side, height: PanelIcon.side)
            .background(PanelIconBackdrop(isPressed: configuration.isPressed))
            .contentShape(Rectangle())
    }
}

/// Shows an active filter and lets the user remove it independently.
private struct FilterChip: View {
    static let height: CGFloat = 24

    let symbol: String
    let title: String
    /// The filter's full name, for VoiceOver.
    let name: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(FilterChipButtonStyle())
        // Keep chips compact and announce the full filter name and active
        // state.
        .fixedSize()
        .help(localized("remove_filter", "Remove filter"))
        .accessibilityLabel(name)
        .accessibilityValue(localized("on", "On"))
        .accessibilityHint(localized("remove_filter", "Remove filter"))
    }
}

/// Gives active filters an accent capsule with icon-style interaction feedback.
private struct FilterChipButtonStyle: ButtonStyle {
    /// makeBody(configuration:) pads the required label inside the capsule.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .frame(height: FilterChip.height)
            .background(PanelIconBackdrop(
                isActive: true,
                isPressed: configuration.isPressed,
                cornerRadius: FilterChip.height / 2
            ))
            .contentShape(Capsule())
    }
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
            // Keep storage failures visible alongside the current history.
            if let storageError = store.storageError {
                storageErrorBanner(storageError)
                Divider().opacity(0.65)
            }
            if store.items.isEmpty && !model.showsStarredOnly && !model.showsTaggedOnly {
                // With no filters or stored items, explain how history begins.
                emptyState
            } else if model.filteredItems.isEmpty {
                // No accessible items match the current query or filters.
                noMatches
            } else {
                // Show the stable current results while any new search runs.
                historyContent
            }
            // Show the limit only after both purchase and trial status resolve.
            if proStore.hasResolvedEntitlement && proStore.hasPreparedAppTrial && !proStore.hasFullAccess {
                AccessLimitedBanner(
                    state: accessBannerState,
                    showPurchases: showPurchases,
                    restorePurchases: restorePurchases
                )
            }
        }
        .background(Color.clear)
        .onAppear { model.reconcileSelection() }
        .onChange(of: store.items) { model.storeDidChange() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.primary)
                .frame(width: 36)

            ClipboardSearchField(
                text: model.query,
                textChanged: model.updateQuery
            )
            .frame(height: 32)

            // Each chip removes only its own filter, preserving the other
            // filter and the query.
            HStack(spacing: 8) {
                // Indicate saved-only results independently of tagged-only
                // results.
                if model.showsStarredOnly {
                    FilterChip(
                        symbol: "star.fill",
                        title: localized("starred", "Starred"),
                        name: localized("starred_items", "Starred Items"),
                        remove: model.toggleStarredFilter
                    )
                }
                // Both chips remain visible when the filters are combined.
                if model.showsTaggedOnly {
                    FilterChip(
                        symbol: "tag.fill",
                        title: localized("tagged", "Tagged"),
                        name: localized("tagged_items", "Tagged Items"),
                        remove: model.toggleTaggedFilter
                    )
                }

                ClipboardOptionsButton(
                    model: model,
                    preferences: preferences,
                    store: store,
                    recordingChanged: recordingChanged,
                    showPurchases: showPurchases,
                    showPrivacyPolicy: showPrivacyPolicy,
                    showAbout: showAbout,
                    revealStorage: revealStorage,
                    clearCurrentClipboard: clearCurrentClipboard,
                    clearHistory: clearHistory
                )
                .frame(width: PanelIcon.side, height: PanelIcon.side)
                .background(PanelIconBackdrop())
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, PanelIcon.trailingInset)
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
        Group {
            if model.query.isEmpty && model.showsStarredOnly && !model.showsTaggedOnly {
                // An empty saved collection is different from an unmatched query.
                emptyCollection(
                    symbol: "star",
                    title: localized("no_starred_items", "No Starred Items"),
                    detail: localized("starred_items_appear_here", "Items you star will appear here.")
                )
            } else if model.query.isEmpty && model.showsTaggedOnly && !model.showsStarredOnly {
                // No accessible item has tags; hidden history may still have
                // them.
                emptyCollection(
                    symbol: "tag",
                    title: localized("no_tagged_items", "No Tagged Items"),
                    detail: localized("tagged_items_appear_here", "Items you tag will appear here.")
                )
            } else {
                // A query, or both filters together, simply found nothing.
                ContentUnavailableView.search(text: model.query)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // emptyCollection(symbol, title, detail): Explain an empty filtered list
    // using the required SF Symbol name, heading and supporting text.
    private func emptyCollection(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.medium))
            Text(detail).foregroundStyle(.secondary)
        }
        .offset(y: -18)
    }

    private var historyContent: some View {
        HStack(spacing: 0) {
            historyList.frame(width: 350)
            Divider().opacity(0.65)
            ClipboardPreview(
                record: model.selectedItem,
                store: store,
                delete: model.deleteSelected,
                toggleStar: toggleSelectedStar,
                editTags: editSelectedTags
            )
        }
    }

    // toggleSelectedStar(): Toggle the selected star, offering full access
    // only when adding another star would exceed the Free allowance.
    func toggleSelectedStar() {
        guard model.selectedItem != nil else { return }
        guard model.canStarSelectedItem else {
            showPurchases()
            return
        }
        model.toggleSelectedStar()
    }

    // editSelectedTags(): Edit the selected item's tags in a native modal
    // window that handles Return and Escape independently of the history.
    func editSelectedTags() {
        // Capture identity before the modal loop allows new clipboard captures.
        guard let record = model.selectedItem else { return }
        let alert = NSAlert()
        alert.messageText = localized("tags", "Tags")
        alert.informativeText = localized("tags_help", "Separate tags with commas. Tags are searchable.")
        // Fit the native compact dialog instead of widening its content and buttons.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = record.tagNames.joined(separator: ", ")
        field.placeholderString = "work, documentation"
        field.identifier = NSUserInterfaceItemIdentifier("PasteminTagsField")
        field.setAccessibilityLabel(localized("tags", "Tags"))
        alert.accessoryView = field
        // Native button order gives Return to Save; focus the editable field.
        alert.addButton(withTitle: localized("save", "Save"))
        alert.addButton(withTitle: localized("cancel", "Cancel"))
        alert.window.initialFirstResponder = field
        // Save only on confirmation, still targeting the originally selected
        // item.
        if alert.runModal() == .alertFirstButtonReturn {
            model.updateTags(for: record.id, input: field.stringValue)
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
                                .onContinuousHover { phase in
                                    // Ignore initial hover until the pointer moves.
                                    if case .active = phase {
                                        model.selectFromPointer(record.id)
                                    }
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
    let text: String
    let textChanged: (String) -> Void

    /// makeCoordinator() forwards native text changes to the view model.
    func makeCoordinator() -> Coordinator { Coordinator(textChanged: textChanged) }

    /// makeNSView(context:) creates the search field with the required context.
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

    /// updateNSView(_:context:) syncs the required view and context.
    func updateNSView(_ scrollView: ClipboardSearchScrollView, context: Context) {
        context.coordinator.textChanged = textChanged
        let textView = scrollView.textView
        // Preserve native editing state unless the model changed the text.
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            textView.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var textChanged: (String) -> Void

        /// init(textChanged:) stores the required text callback.
        init(textChanged: @escaping (String) -> Void) {
            self.textChanged = textChanged
        }

        /// textDidChange(_:) forwards the required text-view notification.
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            textChanged(textView.string)
        }
    }
}

private final class ClipboardSearchScrollView: NSScrollView {
    let textView = ClipboardSearchTextView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        automaticallyAdjustsContentInsets = false

        let font = NSFont.systemFont(ofSize: 26, weight: .regular)
        textView.identifier = NSUserInterfaceItemIdentifier("PasteminSearchField")
        textView.font = font
        textView.textColor = .labelColor
        // Label color keeps the caret white on the dark glass and legible in light mode.
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.height]
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.maximumNumberOfLines = 1
        textView.textContainer?.lineBreakMode = .byClipping
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        let height = ceil(font.boundingRectForFont.height)
        textView.minSize = NSSize(width: 0, height: height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: height)
        textView.frame = NSRect(x: 0, y: 0, width: max(1, frameRect.width), height: height)
        documentView = textView
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: textView.minSize.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct ClipboardOptionsButton: NSViewRepresentable {
    let model: ClipboardViewModel
    @ObservedObject var preferences: ClipboardPreferences
    @ObservedObject var store: ClipboardHistoryStore
    let recordingChanged: (Bool) -> Void
    let showPurchases: () -> Void
    let showPrivacyPolicy: () -> Void
    let showAbout: () -> Void
    let revealStorage: () -> Void
    let clearCurrentClipboard: () -> Void
    let clearHistory: () -> Void

    // makeCoordinator(): Retain the model and actions for native button events.
    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            preferences: preferences,
            store: store,
            recordingChanged: recordingChanged,
            showPurchases: showPurchases,
            showPrivacyPolicy: showPrivacyPolicy,
            showAbout: showAbout,
            revealStorage: revealStorage,
            clearCurrentClipboard: clearCurrentClipboard,
            clearHistory: clearHistory
        )
    }

    // makeNSView(context): Build the options button using the required SwiftUI
    // context to route clicks and the keyboard shortcut to its coordinator.
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: localized("pastemin_options", "Pastemin options")
        )?.withSymbolConfiguration(.init(
            pointSize: PanelIcon.headerSymbolSize, weight: PanelIcon.appKitSymbolWeight
        ))
        // Share icon tint with the panel and route native events to the model.
        button.contentTintColor = .labelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.toolTip = localized("pastemin_options", "Pastemin options")
        button.setAccessibilityLabel(localized("pastemin_options", "Pastemin options"))
        context.coordinator.button = button
        context.coordinator.observeShortcut()
        return button
    }

    // updateNSView(button, context): Refresh coordinator inputs through the
    // required context. The required button itself needs no visual changes.
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.model = model
        context.coordinator.preferences = preferences
        context.coordinator.store = store
        context.coordinator.recordingChanged = recordingChanged
        context.coordinator.showPurchases = showPurchases
        context.coordinator.showPrivacyPolicy = showPrivacyPolicy
        context.coordinator.showAbout = showAbout
        context.coordinator.revealStorage = revealStorage
        context.coordinator.clearCurrentClipboard = clearCurrentClipboard
        context.coordinator.clearHistory = clearHistory
    }

    @MainActor
    final class Coordinator: NSObject {
        var model: ClipboardViewModel
        var preferences: ClipboardPreferences
        var store: ClipboardHistoryStore
        var recordingChanged: (Bool) -> Void
        var showPurchases: () -> Void
        var showPrivacyPolicy: () -> Void
        var showAbout: () -> Void
        var revealStorage: () -> Void
        var clearCurrentClipboard: () -> Void
        var clearHistory: () -> Void

        // init(model, preferences, store, recordingChanged, showPurchases,
        // showPrivacyPolicy, showAbout, revealStorage, clearCurrentClipboard,
        // clearHistory): Retain the required models and action callbacks
        // used to build and operate the options dropdown.
        init(
            model: ClipboardViewModel,
            preferences: ClipboardPreferences,
            store: ClipboardHistoryStore,
            recordingChanged: @escaping (Bool) -> Void,
            showPurchases: @escaping () -> Void,
            showPrivacyPolicy: @escaping () -> Void,
            showAbout: @escaping () -> Void,
            revealStorage: @escaping () -> Void,
            clearCurrentClipboard: @escaping () -> Void,
            clearHistory: @escaping () -> Void
        ) {
            self.model = model
            self.preferences = preferences
            self.store = store
            self.recordingChanged = recordingChanged
            self.showPurchases = showPurchases
            self.showPrivacyPolicy = showPrivacyPolicy
            self.showAbout = showAbout
            self.revealStorage = revealStorage
            self.clearCurrentClipboard = clearCurrentClipboard
            self.clearHistory = clearHistory
        }

        weak var button: NSButton?
        private var optionsPanel: ClipboardOptionsPanel?
        private var shortcutObserver: NSObjectProtocol?

        deinit {
            if let shortcutObserver { NotificationCenter.default.removeObserver(shortcutObserver) }
        }

        /// Command-comma in the clipboard panel toggles the same dropdown as the button.
        func observeShortcut() {
            guard shortcutObserver == nil else { return }
            shortcutObserver = NotificationCenter.default.addObserver(
                forName: .showClipboardOptions,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.toggleOptions() }
            }
        }

        // showMenu(button): Handle the required native button sender.
        @objc func showMenu(_ button: NSButton) {
            toggleOptions()
        }

        // toggleOptions(): Close an open dropdown, or build it with current
        // inputs.
        func toggleOptions() {
            guard let button, button.window?.isVisible == true else { return }
            // A second click or shortcut dismisses the already visible
            // dropdown.
            if let optionsPanel, optionsPanel.isVisible {
                optionsPanel.dismiss()
                return
            }
            // A child window supports native controls and shortcut recording
            // while retaining menu-style keyboard navigation.
            let selection = OptionsSelectionModel()
            let panel = ClipboardOptionsPanel(
                rootView: ClipboardOptionsMenuView(
                    model: model,
                    preferences: preferences,
                    store: store,
                    selection: selection,
                    recordingChanged: recordingChanged,
                    showPurchases: showPurchases,
                    showPrivacyPolicy: showPrivacyPolicy,
                    showAbout: showAbout,
                    revealStorage: revealStorage,
                    clearCurrentClipboard: clearCurrentClipboard,
                    clearHistory: clearHistory,
                    dismiss: { [weak self] in self?.optionsPanel?.dismiss() }
                ),
                selection: selection
            )
            optionsPanel = panel
            panel.present(below: button)
        }
    }
}

private struct ClipboardRow: View {
    let record: ClipboardRecord
    let itemImage: NSImage?
    let sourceAppIcon: NSImage?
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                // Prefer the source app icon to identify where the item came
                // from.
                if let sourceAppIcon {
                    Image(nsImage: sourceAppIcon)
                        .resizable()
                        .scaledToFit()
                        .padding(2)
                } else if let itemImage {
                    // Fall back to the captured image when the app icon is
                    // absent.
                    Image(nsImage: itemImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Use a content-type symbol when neither image is
                    // available.
                    Image(systemName: record.kind == .image ? "photo" : "doc.text")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.primary)
                }
            }
            .frame(width: 38, height: 38)
            .background(selected ? .white.opacity(0.12) : .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.title)
                    .font(.system(size: 18, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    // Identify saved items even outside the starred filter.
                    if record.isStarred {
                        Image(systemName: "star.fill")
                            .accessibilityLabel(localized("starred_items", "Starred Items"))
                    }
                    // Omit the separator as well when the source is unknown.
                    if let source = record.sourceAppName {
                        Text(source).lineLimit(1)
                        Text("·")
                    }
                    Text(record.displayTimestamp)
                }
                .font(.system(size: 13))
                .foregroundStyle(selected ? .white.opacity(0.78) : .secondary)
                // Untagged items need no extra metadata line.
                if !record.tagNames.isEmpty {
                    Text(record.tagNames.joined(separator: " · "))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(selected ? .white.opacity(0.78) : .secondary)
                }
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 11))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.accessibilityDescription)
        // Announce saved status and tags alongside the content description.
        .accessibilityValue(
            (record.isStarred ? localized("starred", "Starred") + ". " : "")
                + record.tagNames.joined(separator: ", ")
        )
    }
}

private struct ClipboardPreview: View {
    let record: ClipboardRecord?
    @ObservedObject var store: ClipboardHistoryStore
    let delete: () -> Void
    let toggleStar: () -> Void
    let editTags: () -> Void

    var body: some View {
        // Selection controls both the preview payload and its metadata actions.
        if let record {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Label(
                        record.kind == .image
                            ? localized("image", "Image")
                            : localized("text", "Text"),
                        systemImage: record.kind == .image ? "photo" : "doc.text"
                    )
                        .font(.system(size: 18, weight: .semibold))
                    // Explain the preview limit without implying a truncated
                    // paste.
                    if record.isTextPreviewTruncated {
                        Text(localized("one_kb_preview", "1 KB preview"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(nsColor: .systemOrange).opacity(0.16), in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(Color(nsColor: .systemOrange).opacity(0.3), lineWidth: 0.75)
                            }
                            .offset(y: 1)
                            .help(localized(
                                "one_kb_preview_help",
                                "Only the first 1 KB is shown here. Search and paste use all stored text."
                            ))
                            .accessibilityLabel(localized(
                                "one_kb_preview_accessibility",
                                "Preview limited to the first 1 KB"
                            ))
                    }
                    Spacer()
                    // Match action geometry to the header and tint saved
                    // metadata.
                    HStack(spacing: PanelIcon.spacing) {
                        // Filled accent stars show persistent cleanup
                        // protection.
                        Button(action: toggleStar) {
                            PanelIcon.symbol(
                                record.isStarred ? "star.fill" : "star",
                                size: PanelIcon.actionSymbolSize,
                                tint: record.isStarred ? .accentColor : .secondary
                            )
                        }
                        .buttonStyle(PanelIconButtonStyle())
                        .help((record.isStarred
                            ? localized("unstar_item", "Remove star")
                            : localized("star_item", "Star this item")) + " (⌘F)")
                        .accessibilityLabel(record.isStarred
                            ? localized("unstar_item", "Remove star")
                            : localized("star_item", "Star this item"))
                        // Fill and tint the tag only when metadata is present.
                        Button(action: editTags) {
                            PanelIcon.symbol(
                                record.tagNames.isEmpty ? "tag" : "tag.fill",
                                size: PanelIcon.actionSymbolSize,
                                tint: record.tagNames.isEmpty ? .secondary : .accentColor
                            )
                        }
                        .buttonStyle(PanelIconButtonStyle())
                        .help(localized("tag_item", "Tag this item") + " (⌘T)")
                        .accessibilityLabel(localized("tag_item", "Tag this item"))
                        // Explicit deletion remains available for starred items
                        // too.
                        Button(action: delete) {
                            PanelIcon.symbol("trash", size: PanelIcon.actionSymbolSize, tint: .secondary)
                        }
                        .buttonStyle(PanelIconButtonStyle())
                        .help(localized("delete_item_shortcut", "Delete this item (⌘⌫)"))
                    }
                }
                .padding(.leading, 22)
                .padding(.trailing, PanelIcon.trailingInset)
                .frame(height: 54)
                Divider().opacity(0.55)

                // Show the selected item's tags separately from clipboard
                // content.
                if !record.tagNames.isEmpty {
                    Text(record.tagNames.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.horizontal, 22)
                        .padding(.top, 10)
                }

                Group {
                    // Load image data only for the selected image record.
                    if record.kind == .image, let image = store.image(for: record) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(28)
                    } else {
                        // Bound text rendering to the stored preview, allowing
                        // selection.
                        ScrollView {
                            Text(record.previewText)
                                .font(.system(size: 18, design: .default))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(22)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().opacity(0.55)
                HStack {
                    Text(record.sourceAppName ?? localized("unknown_source", "Unknown source"))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(record.byteCount), countStyle: .file))
                    Text("·")
                    Text(record.detailedTimestamp)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .frame(height: 44)
            }
        } else {
            // Avoid showing actions or stale content without a selection.
            Text(localized("select_item_to_preview", "Select an item to preview it"))
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
