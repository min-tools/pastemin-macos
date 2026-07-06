import AppKit
import SwiftUI

@MainActor
final class ClipboardPanel: NSPanel {
    var moveUp: (() -> Void)?
    var moveDown: (() -> Void)?
    var choose: (() -> Void)?
    var deleteSelection: (() -> Void)?
    var didDismiss: (() -> Void)?

    private let searchFieldIdentifier = "PasteminSearchField"
    private var focusRequest = 0
    private var presentationRequest = 0
    private var activationObserver: NSObjectProtocol?

    init(rootView: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 590),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = true
        isMovableByWindowBackground = true
        // Utility-window zoom briefly renders a small square during the first presentation.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let contentFrame = NSRect(origin: .zero, size: contentRect(forFrameRect: frame).size)
        let surface = ClipboardPanelSurface.make(frame: contentFrame)
        surface.view.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        surface.contentContainer.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: surface.contentContainer.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: surface.contentContainer.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: surface.contentContainer.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: surface.contentContainer.bottomAnchor)
        ])
        contentView = surface.view
        // AppKit otherwise starts editing the search field while ordering the panel in, before it is
        // on screen. Pointing the initial first responder at the glass surface, which refuses focus,
        // defers editing until showCentered() focuses the field on the visible panel.
        initialFirstResponder = surface.view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func orderOut(_ sender: Any?) {
        let wasVisible = isVisible
        presentationRequest += 1
        clearActivationObserver()
        focusRequest += 1
        if isEditingSearch { makeFirstResponder(nil) }
        // The options dropdown is a child window; never leave it behind or let it reappear stale.
        for child in childWindows ?? [] {
            (child as? ClipboardOptionsPanel)?.dismiss()
        }
        super.orderOut(sender)
        if wasVisible { didDismiss?() }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let textView = firstResponder as? NSTextView
            let textModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let activeModifiers = event.modifierFlags.intersection(textModifiers)

            // Command-Delete removes history even while the search field owns the responder.
            if event.keyCode == 51, activeModifiers == .command {
                deleteSelection?()
                return
            }

            // Forward selection commands to the search editor.
            if isEditingSearch,
               activeModifiers == .command,
               event.charactersIgnoringModifiers?.lowercased() == "a" {
                textView?.selectAll(nil)
                return
            }

            // Handle list navigation globally while leaving ordinary text editing untouched.
            switch event.keyCode {
            case 126: moveUp?(); return
            case 125: moveDown?(); return
            case 36, 76: choose?(); return
            case 51, 117:
                if isEditingSearch { break }
                if activeModifiers.isEmpty { deleteSelection?(); return }
            case 53: orderOut(nil); return
            default:
                // Command-comma opens the options dropdown, the panel's stand-in for Settings.
                if activeModifiers == .command, event.charactersIgnoringModifiers == "," {
                    NotificationCenter.default.post(name: .showClipboardOptions, object: nil)
                    return
                }
            }
        }
        super.sendEvent(event)
    }

    func toggleCentered() {
        // A panel hidden during app deactivation can briefly retain stale ordered-in state. Only
        // treat the shortcut as a close when Pastemin is active and the panel is truly on screen.
        if NSApp.isActive, isVisible {
            orderOut(nil)
            return
        }
        showCentered()
    }

    func showCentered() {
        // Match Spotlight by opening on the display currently under the pointer.
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            setFrameOrigin(NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.midY - frame.height / 2 + 30
            ))
        }
        contentView?.layoutSubtreeIfNeeded()

        // A nonactivating panel with hidesOnDeactivate enabled can be removed again when ordered
        // before application activation finishes. Wait for AppKit's activation notification so
        // one shortcut always produces one visible panel.
        presentationRequest += 1
        let request = presentationRequest
        clearActivationObserver()
        guard !NSApp.isActive else {
            finishPresentation(request: request)
            return
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.finishPresentation(request: request)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishPresentation(request: Int) {
        guard presentationRequest == request, NSApp.isActive else { return }
        clearActivationObserver()
        makeKeyAndOrderFront(nil)
        // Give AppKit one display turn to commit the panel before starting text input. The search
        // view is the input client itself, so TextInputUI sees its hidden-accessory preference from
        // the beginning instead of first creating a field editor and a remote accessory window.
        focusRequest += 1
        let request = focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.focusRequest == request else { return }
            self.focusSearchField()
        }
    }

    private func clearActivationObserver() {
        guard let activationObserver else { return }
        NotificationCenter.default.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    func focusSearchField() {
        // Start exactly one editing session, and only once the panel is on screen.
        guard isVisible,
              let contentView,
              let field = searchField(in: contentView),
              firstResponder !== field else { return }
        makeFirstResponder(field)
    }

    private var isEditingSearch: Bool {
        (firstResponder as? NSTextView)?.identifier?.rawValue == searchFieldIdentifier
    }

    private func searchField(in view: NSView) -> NSTextView? {
        if let field = view as? NSTextView,
           field.identifier?.rawValue == searchFieldIdentifier {
            return field
        }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }
}

final class ClipboardSearchTextView: NSTextView {
    var placeholderAttributedString: NSAttributedString? {
        didSet { needsDisplay = true }
    }

    // This view is the NSTextInputClient. Returning invisible here prevents TextInputUI from
    // creating its remote input-source and Caps Lock HUD for Pastemin's search cursor.
    override func preferredTextAccessoryPlacement() -> NSTextCursorAccessoryPlacement { .invisible }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholderAttributedString else { return }
        let origin = textContainerOrigin
        placeholderAttributedString.draw(in: NSRect(
            x: origin.x,
            y: origin.y,
            width: max(0, bounds.width - origin.x),
            height: bounds.height - origin.y
        ))
    }
}
