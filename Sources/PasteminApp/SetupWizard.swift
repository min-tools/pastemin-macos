import AppKit

/// Guides first-run choices while deferring optional system access until automatic paste is used.
@MainActor
final class SetupWizardController: NSObject, NSWindowDelegate {
    static let completedKey = "PasteminDidCompleteSetupWizard"

    private let preferences: ClipboardPreferences
    private let defaults: UserDefaults

    private var window: NSWindow?
    private var stepIndex = 0
    private let stepCount = 4
    private var stepViews: [Int: NSView] = [:]

    private var contentContainer: NSView!
    private var progressLabel: NSTextField!
    private var backButton: NSButton!
    private var continueButton: NSButton!
    private var laterButton: NSButton!

    private var retentionPopup: NSPopUpButton?
    private var menuBarCheckbox: NSButton?
    private var autoPasteCheckbox: NSButton?

    init(
        preferences: ClipboardPreferences,
        defaults: UserDefaults = .standard
    ) {
        self.preferences = preferences
        self.defaults = defaults
        super.init()
    }

    var isCompleted: Bool {
        defaults.bool(forKey: Self.completedKey)
    }

    /// Starts a fresh setup session using the preferences currently shown in the settings menu.
    func present() {
        stepIndex = 0
        if window == nil {
            buildWindow()
        } else if window?.isVisible == false {
            // Rebuild controls so reopening Setup reflects changes made in the options menu.
            stepViews.removeAll()
            retentionPopup = nil
            menuBarCheckbox = nil
            autoPasteCheckbox = nil
        }
        showStep()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Closing or skipping setup suppresses the automatic first-launch presentation.
    func windowWillClose(_ notification: Notification) {
        defaults.set(true, forKey: Self.completedKey)
    }

    // MARK: - Window

    private func buildWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("wizard_window", "Pastemin Setup")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.animationBehavior = .none

        guard let contentView = window.contentView else { return }
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)

        progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = NSFont.systemFont(ofSize: 11)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressLabel)

        laterButton = NSButton(
            title: localized("wizard_later", "Set Up Later"),
            target: self,
            action: #selector(setUpLater(_:))
        )
        laterButton.bezelStyle = .rounded
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(laterButton)

        backButton = NSButton(
            title: localized("wizard_back", "Back"),
            target: self,
            action: #selector(goBack(_:))
        )
        backButton.bezelStyle = .rounded
        backButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backButton)

        continueButton = NSButton(
            title: localized("wizard_continue", "Continue"),
            target: self,
            action: #selector(goForward(_:))
        )
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"
        continueButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(continueButton)

        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            contentContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            contentContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            contentContainer.bottomAnchor.constraint(equalTo: continueButton.topAnchor, constant: -20),

            progressLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            progressLabel.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),
            laterButton.leadingAnchor.constraint(equalTo: progressLabel.trailingAnchor, constant: 16),
            laterButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor),

            continueButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            continueButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            backButton.trailingAnchor.constraint(equalTo: continueButton.leadingAnchor, constant: -10),
            backButton.centerYAnchor.constraint(equalTo: continueButton.centerYAnchor)
        ])
        self.window = window
    }

    // MARK: - Steps

    private func showStep() {
        contentContainer.subviews.forEach { $0.removeFromSuperview() }
        progressLabel.stringValue = localizedFormat(
            "wizard_step_n_of_m",
            "Step %d of %d",
            Int32(stepIndex + 1),
            Int32(stepCount)
        )
        backButton.isHidden = stepIndex == 0
        laterButton.isHidden = stepIndex != 0
        continueButton.title = stepIndex == stepCount - 1
            ? localized("wizard_finish", "Finish")
            : localized("wizard_continue", "Continue")

        let step: NSView
        if let cached = stepViews[stepIndex] {
            step = cached
        } else {
            // Build each page once per session so Back preserves unfinished selections.
            switch stepIndex {
            case 0: step = welcomeStep()
            case 1: step = essentialsStep()
            case 2: step = automaticPasteStep()
            default: step = readyStep()
            }
            stepViews[stepIndex] = step
        }
        step.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(step)
        NSLayoutConstraint.activate([
            step.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            step.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            step.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            step.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor)
        ])
        fitWindow(to: step)
    }

    /// Gives translated instructions room while retaining a compact minimum window size.
    private func fitWindow(to step: NSView) {
        guard let window else { return }
        step.layoutSubtreeIfNeeded()
        let footerHeight = 20 + continueButton.fittingSize.height + 20
        let height = max(440, ceil(step.fittingSize.height) + 24 + footerHeight)
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 560, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    /// Creates the shared title, explanation, and control layout for each page.
    private func stepStack(title: String, body: String, extra: [NSView] = []) -> NSStackView {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = NSFont.systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleLabel, bodyLabel] + extra)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(10, after: titleLabel)
        for view in [titleLabel, bodyLabel] + extra {
            stack.widthAnchor.constraint(greaterThanOrEqualTo: view.widthAnchor).isActive = true
        }
        return stack
    }

    private func welcomeStep() -> NSView {
        let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 76).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 76).isActive = true
        return stepStack(
            title: localized("wizard_welcome_title", "Welcome"),
            body: localized(
                "wizard_welcome_body",
                "Keep everything you copy close, searchable, and private on your Mac. Choose a few essentials now. You can change them anytime from the settings menu."
            ),
            extra: [icon]
        )
    }

    /// Lets the user choose persistence and availability while showing the active shortcut.
    private func essentialsStep() -> NSView {
        let retention = NSPopUpButton(frame: .zero, pullsDown: false)
        for period in RetentionPeriod.allCases {
            retention.addItem(withTitle: period.title)
            retention.lastItem?.representedObject = period.rawValue
        }
        if let index = RetentionPeriod.allCases.firstIndex(of: preferences.retention) {
            retention.selectItem(at: index)
        }
        retention.translatesAutoresizingMaskIntoConstraints = false
        retention.widthAnchor.constraint(equalToConstant: 160).isActive = true
        retentionPopup = retention

        let retentionRow = labeledRow(
            localized("keep_copied_items", "Keep copied items"),
            control: retention
        )

        let menuBar = NSButton(
            checkboxWithTitle: localized("show_in_menu_bar", "Show in menu bar"),
            target: nil,
            action: nil
        )
        menuBar.state = preferences.showInMenuBar ? .on : .off
        menuBarCheckbox = menuBar

        let shortcut = NSTextField(labelWithString: preferences.shortcut.displayName)
        shortcut.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        shortcut.alignment = .right
        let shortcutRow = labeledRow(
            localized("wizard_shortcut_label", "Open Clipboard with"),
            control: shortcut
        )

        let note = NSTextField(wrappingLabelWithString: localized(
            "wizard_shortcut_note",
            "You can record a different shortcut later from the settings menu."
        ))
        note.font = NSFont.systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        return stepStack(
            title: localized("wizard_essentials_title", "Your clipboard"),
            body: localized(
                "wizard_essentials_body",
                "Choose how long copied items stay on this Mac and whether Clipboard appears in the menu bar."
            ),
            extra: [retentionRow, menuBar, shortcutRow, note]
        )
    }

    /// Explains the exact event used by automatic paste and when macOS requests permission.
    private func automaticPasteStep() -> NSView {
        preferences.refreshAutomaticPasteAuthorization()
        let checkbox = NSButton(
            checkboxWithTitle: localized(
                "wizard_auto_paste_option",
                "Paste automatically after choosing an item"
            ),
            target: nil,
            action: nil
        )
        checkbox.state = preferences.pasteAutomatically ? .on : .off
        autoPasteCheckbox = checkbox

        let permission = NSTextField(wrappingLabelWithString: preferences.automaticPasteAuthorized
            ? localized(
                "wizard_auto_paste_authorized",
                "Permission to post the paste shortcut is already allowed."
            )
            : localized(
                "wizard_auto_paste_permission",
                "If enabled, macOS will ask for Accessibility permission the first time automatic paste is used. If you decline, selected items are still copied."
            ))
        permission.font = NSFont.systemFont(ofSize: 11)
        permission.textColor = .tertiaryLabelColor

        return stepStack(
            title: localized("wizard_auto_paste_title", "Paste after selection"),
            body: localized(
                "wizard_auto_paste_body",
                "The selected item is always copied, and focus returns to the app you were using. Automatic paste then sends one ⌘V. Your keystrokes are never read."
            ),
            extra: [checkbox, permission]
        )
    }

    /// Explains the automatic trial, limited history view, and optional plans before setup ends.
    private func readyStep() -> NSView {
        let during = trialRow(
            symbol: "clock",
            title: localized("wizard_trial_during_title", "Your first 30 days"),
            detail: localized(
                "wizard_trial_during_pastemin",
                "Keep and search your complete clipboard history."
            )
        )
        let after = trialRow(
            symbol: "list.number",
            title: localized("wizard_trial_after_title", "After the trial"),
            detail: localized(
                "wizard_trial_after_pastemin",
                "Pastemin keeps storing your history, but shows and searches only the 5 newest items."
            )
        )
        let plans = trialRow(
            symbol: "creditcard",
            title: localized("wizard_trial_plans_title", "Keep full access"),
            detail: localized(
                "wizard_trial_plans_body",
                "Choose a yearly plan or lifetime access at any time."
            )
        )
        return stepStack(
            title: localized("wizard_ready_title", "30 days of full access"),
            body: localized(
                "wizard_ready_body",
                "Pastemin starts a free 30-day trial when you first open it. No subscription starts, and you will not be charged."
            ),
            extra: [during, after, plans]
        )
    }

    /// Presents one trial fact with a clear icon and supporting text.
    private func trialRow(symbol: String, title: String, detail: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    /// Aligns a label and its trailing setup control without fixing translated label widths.
    private func labeledRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13)
        let row = NSStackView(views: [label, NSView(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 450).isActive = true
        return row
    }

    // MARK: - Actions

    @objc private func goBack(_ sender: Any?) {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        showStep()
    }

    @objc private func goForward(_ sender: Any?) {
        if stepIndex == stepCount - 1 {
            finish()
            return
        }
        stepIndex += 1
        showStep()
    }

    @objc private func setUpLater(_ sender: Any?) {
        defaults.set(true, forKey: Self.completedKey)
        window?.close()
    }

    /// Applies completed choices without requesting optional system access from setup.
    private func finish() {
        if let rawValue = retentionPopup?.selectedItem?.representedObject as? String,
           let retention = RetentionPeriod(rawValue: rawValue) {
            preferences.retention = retention
        }
        if let menuBarCheckbox {
            preferences.showInMenuBar = menuBarCheckbox.state == .on
        }

        let automaticPasteEnabled = autoPasteCheckbox?.state == .on
        preferences.pasteAutomatically = automaticPasteEnabled
        defaults.set(true, forKey: Self.completedKey)
        window?.close()
    }
}
