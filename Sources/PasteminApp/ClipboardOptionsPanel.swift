import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted by the clipboard panel for Command-comma; the options button toggles its dropdown.
    static let showClipboardOptions = Notification.Name("tools.min.pastemin.showClipboardOptions")
}

/// Every row the options dropdown can highlight, in display order.
enum OptionsRow: Hashable {
    case clearCurrent
    case clearHistory
    case retention
    case menuBar
    case automaticPaste
    case shortcut
    case storage
    case about
    case privacy
}

/// Shared highlight state for the dropdown: the mouse and the arrow keys move the same selection,
/// exactly like a menu, and Return or Space activates whatever is highlighted.
@MainActor
final class OptionsSelectionModel: ObservableObject {
    @Published var selection: OptionsRow?
    var rows: [OptionsRow] = []
    var activate: (OptionsRow) -> Void = { _ in }
    var adjust: (OptionsRow, Int) -> Void = { _, _ in }

    func hover(_ row: OptionsRow, _ hovering: Bool) {
        if hovering {
            selection = row
        } else if selection == row {
            selection = nil
        }
    }

    func moveSelection(by offset: Int) {
        guard !rows.isEmpty else { return }
        guard let selection, let index = rows.firstIndex(of: selection) else {
            self.selection = offset > 0 ? rows.first : rows.last
            return
        }
        self.selection = rows[min(max(index + offset, 0), rows.count - 1)]
    }

    func activateSelection() {
        guard let selection else { return }
        activate(selection)
    }

    func adjustSelection(by delta: Int) {
        guard let selection else { return }
        adjust(selection, delta)
    }
}

/// A menu-style dropdown under the options button: a borderless glass child window of the
/// clipboard panel, with no popover arrow, that closes on Escape, Command-comma, any click
/// outside it or loss of key status.
@MainActor
final class ClipboardOptionsPanel: NSPanel {
    private static let width: CGFloat = 360
    private static let cornerRadius: CGFloat = 14
    private static let anchorGap: CGFloat = 6

    private let selection: OptionsSelectionModel
    private let hosting: OptionsHostingView
    private weak var anchor: NSView?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(rootView: some View, selection: OptionsSelectionModel) {
        self.selection = selection
        hosting = OptionsHostingView(rootView: AnyView(rootView))
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let size = NSSize(width: Self.width, height: hosting.fittingSize.height)
        setContentSize(size)
        let surface = ClipboardPanelSurface.make(
            frame: NSRect(origin: .zero, size: size),
            cornerRadius: Self.cornerRadius
        )
        hosting.frame = surface.contentContainer.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.sizeDidChange = { [weak self] in self?.fitContent() }
        surface.contentContainer.addSubview(hosting)
        contentView = surface.view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func present(below anchor: NSView) {
        guard let parent = anchor.window else { return }
        self.anchor = anchor
        place(below: anchor, in: parent)
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        selection.selection = nil
        installMonitors()
    }

    func dismiss() {
        removeMonitors()
        let parent = parent
        parent?.removeChildWindow(self)
        orderOut(nil)
        selection.selection = nil
        // Hand key status straight back so the search field keeps its caret.
        if let parent, parent.isVisible { parent.makeKey() }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            switch event.keyCode {
            case 126: selection.moveSelection(by: -1); return
            case 125: selection.moveSelection(by: 1); return
            case 123: selection.adjustSelection(by: -1); return
            case 124: selection.adjustSelection(by: 1); return
            case 48: selection.moveSelection(by: modifiers.contains(.shift) ? -1 : 1); return
            case 36, 76, 49: selection.activateSelection(); return
            case 53: dismiss(); return
            default:
                if modifiers == .command, event.charactersIgnoringModifiers == "," {
                    dismiss()
                    return
                }
            }
        }
        super.sendEvent(event)
    }

    /// Right-align the dropdown under its button and keep it inside the clipboard panel.
    private func place(below anchor: NSView, in parent: NSWindow) {
        let anchorRect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let x = max(anchorRect.maxX - frame.width, parent.frame.minX + Self.anchorGap)
        setFrameOrigin(NSPoint(x: x, y: anchorRect.minY - Self.anchorGap - frame.height))
    }

    /// Grow or shrink with the content, such as the shortcut error line, keeping the top edge fixed.
    private func fitContent() {
        let height = hosting.fittingSize.height
        guard abs(height - frame.height) > 0.5 else { return }
        let top = frame.maxY
        setContentSize(NSSize(width: Self.width, height: height))
        setFrameOrigin(NSPoint(x: frame.minX, y: top - height))
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks anywhere else close the dropdown but still reach their target. A click on the
        // options button is left to the button, which toggles the dropdown itself.
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self, event.window !== self else { return event }
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                return event
            }
            dismiss()
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: self, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.dismiss() }
            }
        ]
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

/// Reports SwiftUI size changes so the dropdown can follow its content height.
private final class OptionsHostingView: NSHostingView<AnyView> {
    var sizeDidChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        sizeDidChange?()
    }
}
