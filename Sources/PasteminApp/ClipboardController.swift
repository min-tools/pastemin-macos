import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftUI


@MainActor
private final class MinToolsAboutPanelController: NSWindowController {
    static let shared = MinToolsAboutPanelController()

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let copyrightLabel = NSTextField(labelWithString: "")
    private let profileButton = NSButton()

    private init() {
        let size = NSSize(width: 280, height: 174)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        versionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        copyrightLabel.font = .systemFont(ofSize: 11, weight: .medium)
        for label in [nameLabel, versionLabel, copyrightLabel] {
            label.alignment = .center
            label.textColor = .labelColor
        }

        profileButton.isBordered = false
        profileButton.attributedTitle = NSAttributedString(
            string: "GitHub.com/iliaross",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ]
        )
        profileButton.target = self
        profileButton.action = #selector(openProfile(_:))

        let stack = NSStackView(views: [
            iconView,
            nameLabel,
            versionLabel,
            copyrightLabel,
            profileButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(8, after: iconView)
        stack.setCustomSpacing(7, after: nameLabel)
        stack.setCustomSpacing(8, after: versionLabel)
        stack.setCustomSpacing(0, after: copyrightLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(stack)
        panel.contentView = content
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // show(applicationName): Refresh bundle details and present the About panel.
    func show(applicationName: String) {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let copyright = bundle.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 2026 Ilia Ross"

        iconView.image = NSApp.applicationIconImage
        nameLabel.stringValue = applicationName
        versionLabel.stringValue = "Version \(version) (\(build))"
        copyrightLabel.stringValue = copyright

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // openProfile(sender): Open the author's public GitHub profile.
    @objc private func openProfile(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/iliaross") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class ClipboardController: NSObject {
    let preferences: ClipboardPreferences
    let store: ClipboardHistoryStore

    private let hotKey = GlobalHotKeyManager()
    private let monitor: ClipboardMonitor
    private let viewModel: ClipboardViewModel
    private let proStore = PasteminStore.shared
    private let accessBannerState = AccessLimitedBannerState()
    private var panel: ClipboardPanel!
    private var setupWizard: SetupWizardController!
    private var paywallWindow: PasteminPaywallController!
    private var statusItem: NSStatusItem?
    private var previousApplication: NSRunningApplication?
    private var lastExternalApplication: NSRunningApplication?
    private var automaticPasteRequest: UInt = 0
    private var workspaceActivationObserver: NSObjectProtocol?
    private var entitlementObserver: NSObjectProtocol?

    override init() {
        preferences = ClipboardPreferences()
        do {
            // FileManager resolves this to the app container only for the sandboxed build.
            let root = try ClipboardHistoryStore.applicationSupportURL()
            store = try ClipboardHistoryStore(rootURL: root, retention: preferences.retention)
        } catch {
            fatalError(localizedFormat(
                "storage_initialize_failed",
                "Pastemin storage could not be initialized: %@",
                error.localizedDescription
            ))
        }
        monitor = ClipboardMonitor(store: store)
        viewModel = ClipboardViewModel(store: store, itemLimit: 5)
        super.init()
        configureApplicationTracking()
        setupWizard = SetupWizardController(preferences: preferences)
        configureWindows()
        configureHotKey()
        configureStatusItem()
        configureMainMenu()
        configurePurchases()
        DispatchQueue.main.async { [weak self] in self?.presentSetupWizardIfNeeded() }
    }

    func showClipboard() {
        requestClipboardPresentation(toggle: true)
    }

    func presentClipboard() {
        requestClipboardPresentation(toggle: false)
    }

    func clearCurrentClipboard() {
        NSPasteboard.general.clearContents()
        monitor.acknowledgeCurrentPasteboard()
    }

    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = localized("clear_history_question", "Clear Clipboard History?")
        alert.informativeText = localized(
            "clear_history_warning",
            "Every stored text and image item will be permanently removed from this Mac."
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("clear_history", "Clear History"))
        alert.addButton(withTitle: localized("cancel", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { store.clearHistory() }
    }

    private func prepareClipboardPresentationIfNeeded() {
        // AppKit can briefly report a deactivated, hidden panel as visible.
        guard !NSApp.isActive || !panel.isVisible else { return }
        // Opening the panel cancels a delayed paste from an earlier selection.
        automaticPasteRequest &+= 1
        rememberFrontmostApplication()
        viewModel.prepareForPresentation()
    }

    private func configureApplicationTracking() {
        // Preserve the latest external app even when a launcher activates Pastemin first.
        rememberFrontmostApplication()
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(application)
            }
        }
    }

    private func rememberExternalApplication(_ application: NSRunningApplication) {
        guard application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApplication = application
    }

    private func rememberFrontmostApplication() {
        // Prefer the current caller, then fall back to the last app seen before a launcher opened us.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
            lastExternalApplication = frontmost
        } else if let lastExternalApplication, !lastExternalApplication.isTerminated {
            previousApplication = lastExternalApplication
        }
    }

    private func configureWindows() {
        let history = ClipboardHistoryView(
            model: viewModel,
            store: store,
            preferences: preferences,
            proStore: proStore,
            accessBannerState: accessBannerState,
            recordingChanged: { [weak self] recording in self?.shortcutRecordingChanged(recording) },
            showPurchases: { [weak self] in self?.showPurchases() },
            restorePurchases: { [weak self] in
                await self?.restorePurchases() ?? localized(
                    "purchases_unavailable",
                    "Pastemin purchases are unavailable right now. Please try again later."
                )
            },
            showPrivacyPolicy: { [weak self] in self?.showPrivacyPolicy() },
            showAbout: { [weak self] in self?.showAbout() },
            revealStorage: { [weak self] in self?.revealStorage() },
            clearCurrentClipboard: { [weak self] in self?.clearCurrentClipboard() },
            clearHistory: { [weak self] in self?.confirmClearHistory() }
        )
        panel = ClipboardPanel(rootView: history)
        panel.moveUp = { [weak viewModel] in viewModel?.moveSelection(by: -1) }
        panel.moveDown = { [weak viewModel] in viewModel?.moveSelection(by: 1) }
        panel.choose = { [weak viewModel] in viewModel?.chooseSelected() }
        panel.deleteSelection = { [weak viewModel] in viewModel?.deleteSelected() }
        panel.pointerDidMove = { [weak viewModel] in viewModel?.enablePointerSelection() }
        panel.didDismiss = { [weak viewModel] in
            // Clear hidden search state after the panel has left the screen.
            DispatchQueue.main.async { viewModel?.resetSearch() }
        }
        viewModel.onChoose = { [weak self] in
            guard let self else { return }
            // The view model has restored the pasteboard; return focus before optional paste.
            monitor.acknowledgeCurrentPasteboard()
            panel.orderOut(nil)
            let shouldPaste = preferences.pasteAutomatically
                && (CGPreflightPostEventAccess() || requestAutomaticPasteAccess())
            restorePreviousApplication(andPaste: shouldPaste)
        }

        paywallWindow = PasteminPaywallController(store: proStore)
    }

    private func configurePurchases() {
        entitlementObserver = NotificationCenter.default.addObserver(
            forName: PasteminStore.entitlementDidChange,
            object: proStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateEntitlementAccess() }
        }
        proStore.start()
        updateEntitlementAccess()
        // Monitoring continues after the trial; only the visible history is limited.
        monitor.start()
    }

    private func updateEntitlementAccess() {
        viewModel.updateItemLimit(proStore.hasFullAccess ? nil : 5)
    }

    private func requestClipboardPresentation(toggle: Bool) {
        displayClipboard(toggle: toggle)
    }

    private func displayClipboard(toggle: Bool) {
        prepareClipboardPresentationIfNeeded()
        if toggle {
            panel.toggleCentered()
        } else {
            panel.showCentered()
        }
    }

    private func showPurchases() {
        previousApplication = nil
        panel.orderOut(nil)
        paywallWindow.show()
    }

    private func restorePurchases() async -> String? {
        do {
            if try await proStore.restore() { return nil }
            return localized(
                "no_active_purchase",
                "No active Pastemin purchase was found."
            )
        } catch {
            return error.localizedDescription
        }
    }

    private func presentSetupWizardIfNeeded() {
        // Expired-trial previews open directly to the limited clipboard.
        guard !PasteminEdition.isExpiredTrialPreview else { return }
        guard !setupWizard.isCompleted else { return }
        setupWizard.present()
    }

    private func showPrivacyPolicy() {
        previousApplication = nil
        panel.orderOut(nil)
        PrivacyPolicyController.shared.show()
    }

    // showAbout(): Present bundle details and the author's profile.
    private func showAbout() {
        previousApplication = nil
        panel.orderOut(nil)
        MinToolsAboutPanelController.shared.show(applicationName: "Pastemin")
    }

    private func revealStorage() {
        NSWorkspace.shared.activateFileViewerSelecting([store.rootURL])
    }

    private func restorePreviousApplication(andPaste shouldPaste: Bool) {
        guard let application = previousApplication else { return }
        previousApplication = nil
        automaticPasteRequest &+= 1
        let pasteRequest = automaticPasteRequest
        // Yield before the next-turn request so macOS restores the caller's key window and focus.
        NSApp.yieldActivation(to: application)
        DispatchQueue.main.async { [weak self] in
            guard let self, !application.isTerminated else { return }
            _ = application.activate(from: .current, options: [])
            guard shouldPaste else { return }
            // Activation is asynchronous, so wait for the intended app instead of dropping the
            // paste when a single fixed delay is too short.
            pasteWhenApplicationIsFrontmost(application, request: pasteRequest)
        }
    }

    private func pasteWhenApplicationIsFrontmost(
        _ application: NSRunningApplication,
        request: UInt,
        attemptsRemaining: Int = 40
    ) {
        guard request == automaticPasteRequest, !application.isTerminated else { return }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
            Self.postPasteShortcut(to: application.processIdentifier)
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pasteWhenApplicationIsFrontmost(
                application,
                request: request,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func requestAutomaticPasteAccess() -> Bool {
        if CGPreflightPostEventAccess() {
            preferences.refreshAutomaticPasteAuthorization()
            return true
        }
        // The first automatic-paste attempt hides the panel before asking, keeping the system
        // prompt in front while preserving the app that should regain focus afterward.
        panel.orderOut(nil)
        let granted = CGRequestPostEventAccess()
        preferences.refreshAutomaticPasteAuthorization()
        return granted
    }

    private static func postPasteShortcut(to processIdentifier: pid_t) {
        // Send one balanced key-down/key-up pair only to the app the user chose as the target.
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              ) else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func configureHotKey() {
        // Keep live services in sync with settings without recreating the controller.
        hotKey.onPressed = { [weak self] in self?.showClipboard() }
        preferences.onShortcutChange = { [weak self] shortcut in self?.register(shortcut) }
        preferences.onRetentionChange = { [weak store] retention in store?.updateRetention(retention) }
        register(preferences.shortcut)
    }

    private func register(_ shortcut: GlobalShortcut) {
        preferences.hotKeyError = hotKey.register(shortcut)
            ? nil
            : localizedFormat(
                "shortcut_unavailable",
                "%@ is unavailable. Choose another shortcut.",
                shortcut.displayName
            )
        rebuildStatusMenu()
    }

    private func shortcutRecordingChanged(_ recording: Bool) {
        if recording {
            hotKey.unregister()
        } else {
            register(preferences.shortcut)
        }
    }

    private func configureStatusItem() {
        preferences.onMenuBarVisibilityChange = { [weak self] visible in
            self?.setStatusItemVisible(visible)
        }
        setStatusItemVisible(preferences.showInMenuBar)
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Pastemin")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        add(
            applicationMenu,
            title: String(format: localized("about_app", "About %@"), "Pastemin"),
            action: #selector(showAboutFromMenu)
        )
        add(
            applicationMenu,
            title: "Pastemin Pro…",
            action: #selector(showPurchasesFromMenu)
        )
        applicationMenu.addItem(.separator())

        let servicesItem = NSMenuItem(
            title: localized("services", "Services"),
            action: nil,
            keyEquivalent: ""
        )
        let servicesMenu = NSMenu(title: localized("services", "Services"))
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu

        applicationMenu.addItem(.separator())
        addApplicationItem(
            applicationMenu,
            title: localized("hide_pastemin", "Hide Pastemin"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        add(
            applicationMenu,
            title: localized("quit_pastemin", "Quit Pastemin"),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: localized("edit", "Edit"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        addResponderItem(editMenu, title: localized("undo", "Undo"), action: #selector(UndoManager.undo), keyEquivalent: "z")
        addResponderItem(editMenu, title: localized("redo", "Redo"), action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        addResponderItem(editMenu, title: localized("cut", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        addResponderItem(editMenu, title: localized("copy", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        addResponderItem(editMenu, title: localized("paste", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        addResponderItem(editMenu, title: localized("select_all", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: localized("window", "Window"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        addResponderItem(windowMenu, title: localized("close", "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        addResponderItem(windowMenu, title: localized("minimize", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu
    }

    private func setStatusItemVisible(_ visible: Bool) {
        guard visible else {
            // Removing the status item releases it; retaining a hidden item leaves dead UI state.
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }

        guard statusItem == nil else {
            rebuildStatusMenu()
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Pastemin")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Pastemin"
        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let show = NSMenuItem(
            title: localized("show_pastemin", "Show Pastemin"),
            action: #selector(showFromMenu),
            keyEquivalent: ""
        )
        show.target = self
        show.keyEquivalent = preferences.shortcut.menuKeyEquivalent
        show.keyEquivalentModifierMask = preferences.shortcut.menuModifierFlags
        menu.addItem(show)
        menu.addItem(.separator())
        add(menu, title: "Pastemin Pro…", action: #selector(showPurchasesFromMenu))
        menu.addItem(.separator())
        add(menu, title: localized("clear_current_clipboard", "Clear Current Clipboard"), action: #selector(clearCurrentFromMenu))
        add(menu, title: localized("clear_history_ellipsis", "Clear History…"), action: #selector(clearHistoryFromMenu))
        menu.addItem(.separator())
        add(
            menu,
            title: String(format: localized("about_app", "About %@"), "Pastemin"),
            action: #selector(showAboutFromMenu)
        )
        menu.addItem(.separator())
        add(menu, title: localized("quit_pastemin", "Quit Pastemin"), action: #selector(quitFromMenu), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func add(_ menu: NSMenu, title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func addApplicationItem(_ menu: NSMenu, title: String, action: Selector, keyEquivalent: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = NSApp
        menu.addItem(item)
    }

    private func addResponderItem(_ menu: NSMenu, title: String, action: Selector, keyEquivalent: String) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        menu.addItem(item)
    }

    // showAboutFromMenu(): Open the same About panel used by the options menu.
    @objc private func showAboutFromMenu() {
        showAbout()
    }

    @objc private func showPurchasesFromMenu() { showPurchases() }
    @objc private func showFromMenu() { showClipboard() }
    @objc private func clearCurrentFromMenu() { clearCurrentClipboard() }
    @objc private func clearHistoryFromMenu() { confirmClearHistory() }
    @objc private func quitFromMenu() { NSApp.terminate(nil) }
}
