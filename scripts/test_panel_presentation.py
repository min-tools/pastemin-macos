#!/usr/bin/env python3
"""Verify panel geometry, filters, shortcuts and modal tag editing in a GUI session."""
from pathlib import Path
import argparse
import subprocess
import tempfile

from build import ROOT, swift_compiler

fixture = r'''
import AppKit
import SwiftUI

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

@MainActor
final class OrderedWindowRecorder: NSObject {
    var windows: [NSWindow] = []

    @objc func sampleVisibleWindows() {
        windows.append(contentsOf: NSApp.windows.filter(\.isVisible))
    }
}

@MainActor
final class TagsEditorDriver: NSObject {
    var saved = false
    var cancel = false
    var useReturn = false
    var expectedTags = "work, documentation"
    var editedTags = "guides, WORK, guides"

    // saveTags(timer): Check and operate the fixture's modal tag editor. The
    // required timer argument is supplied by AppKit and is otherwise unused.
    @objc func saveTags(_ timer: Timer) {
        guard let window = NSApp.modalWindow else { fatalError("Tags editor did not open") }
        check((window.firstResponder as? NSTextView)?.isFieldEditor == true,
              "Tags editor did not focus its input")
        guard let content = window.contentView else { fatalError("Tags editor has no content") }
        content.layoutSubtreeIfNeeded()
        check(window.frame.width <= 280, "Tags editor widened the native dialog")
        // Locate the fixture field by identity, then replace only its text.
        let views = descendants(content)
        guard let field = views.compactMap({ $0 as? NSTextField }).first(where: {
            $0.identifier?.rawValue == "PasteminTagsField"
        }) else { fatalError("Tags editor did not load the saved tags") }
        check(field.stringValue == expectedTags, "Tags editor did not load the current tags")
        field.stringValue = cancel ? "discarded" : editedTags
        // Confirm the native action stays compact before completing the dialog.
        guard let button = views.compactMap({ $0 as? NSButton }).first(where: {
            $0.title == localized("save", "Save")
        }) else { fatalError("Tags editor has no Save action") }
        check(button.frame.width <= 120, "Save button stretched across the editor")
        saved = true
        if cancel || useReturn {
            // Exercise modal key equivalents independently of list shortcuts.
            let characters = cancel ? "\u{1b}" : "\r"
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: cancel ? 53 : 36)!
            // Fall back to field-editor dispatch only for an unhandled key
            // equivalent.
            if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        } else {
            // The default case verifies button activation of the same save
            // action.
            button.performClick(nil)
        }
    }

    // descendants(view): Inspect only controls belonging to the fixture's modal window.
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@main
enum PanelPresentationTest {
    /// main(): Use argv[1] as an isolated history root, then verify panel
    /// geometry, filters, keyboard actions and native modal tag editing.
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        let recorder = OrderedWindowRecorder()
        let samplingTimer = Timer.scheduledTimer(
            timeInterval: 0.001,
            target: recorder,
            selector: #selector(OrderedWindowRecorder.sampleVisibleWindows),
            userInfo: nil,
            repeats: true
        )

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = try ClipboardHistoryStore(rootURL: root, retention: .oneMonth)
        // Materialize stars and tags with fixture content, never the real clipboard.
        for index in 0..<6 {
            let item = NSPasteboardItem()
            check(item.setString("Saved fixture \(index)", forType: .string), "Set fixture text")
            check(store.capture([item], sourceAppName: nil) == 1, "Capture fixture text")
        }
        check(store.setStarred(store.items[0], starred: true), "Star fixture item")
        check(store.updateTags(store.items[0], input: "work, documentation"), "Tag fixture item")
        let model = ClipboardViewModel(store: store)
        let defaults = UserDefaults(suiteName: "tools.min.pastemin.panel-test")!
        defaults.removePersistentDomain(forName: "tools.min.pastemin.panel-test")
        let preferences = ClipboardPreferences(defaults: defaults)
        let optionsSelection = OptionsSelectionModel()
        let optionsHost = NSHostingView(rootView: ClipboardOptionsMenuView(
            model: model,
            preferences: preferences,
            store: store,
            selection: optionsSelection,
            recordingChanged: { _ in },
            showPurchases: {},
            showPrivacyPolicy: {},
            showAbout: {},
            revealStorage: {},
            clearCurrentClipboard: {},
            clearHistory: {},
            dismiss: {}
        ))
        let optionsSize = optionsHost.fittingSize
        check(optionsSize.width == 360, "Options menu width")
        check((300...560).contains(optionsSize.height), "Options menu height")
        let history = ClipboardHistoryView(
            model: model,
            store: store,
            preferences: preferences,
            proStore: .shared,
            accessBannerState: AccessLimitedBannerState(),
            recordingChanged: { _ in },
            showPurchases: {},
            restorePurchases: { nil },
            showPrivacyPolicy: {},
            showAbout: {},
            revealStorage: {},
            clearCurrentClipboard: {},
            clearHistory: {}
        )
        let panel = ClipboardPanel(rootView: history)
        panel.toggleStarSelection = history.toggleSelectedStar
        panel.editTagsSelection = history.editSelectedTags

        // sendShortcut(key, code, [repeated = false]): Send a Command shortcut
        // with the required characters and hardware key code to the fixture
        // panel.
        func sendShortcut(_ key: String, code: UInt16, repeated: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key,
                isARepeat: repeated, keyCode: code)!
            panel.sendEvent(event)
        }

        func findHostingView(in view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("NSHostingView") { return view }
            for subview in view.subviews {
                if let hosting = findHostingView(in: subview) { return hosting }
            }
            return nil
        }

        func checkFullSizeHierarchy() {
            guard let root = panel.contentView else { fatalError("Missing panel content") }
            root.layoutSubtreeIfNeeded()
            check(root.bounds.size == NSSize(width: 900, height: 590), "Panel content size")
            if #available(macOS 26.0, *) {
                check(root is NSGlassEffectView, "Liquid Glass is the panel content view")
            }
            let hosting = findHostingView(in: root)
            check(hosting != nil, "Missing SwiftUI content host")
            check(hosting?.frame == hosting?.superview?.bounds, "Content host fills the glass content view")
        }

        // Lay out at the final size without displaying the hidden glass
        // surface.
        panel.contentView?.layoutSubtreeIfNeeded()
        checkFullSizeHierarchy()
        check(panel.initialFirstResponder === panel.contentView, "Initial first responder defers editing")

        // Materialize the first window transaction outside every display and
        // verify that it never falls back to a smaller placeholder surface.
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        check(panel.isVisible, "Panel ordered on screen")
        check(
            !(panel.firstResponder is NSTextView),
            "Ordering the panel in started editing before it was visible"
        )

        // Focusing after presentation must use the custom input client
        // directly. Creating an NSTextField field editor first is too late to
        // stop TextInputUI's accessory host.
        panel.focusSearchField()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        check(panel.frame.size == NSSize(width: 900, height: 590), "First presentation size")
        checkFullSizeHierarchy()
        let editor = panel.firstResponder as? NSTextView
        check(editor != nil, "Search field was not focused after the panel became visible")
        check(
            editor.map { String(describing: type(of: $0)) } == "ClipboardSearchTextView",
            "Search field is not the active text-input client"
        )
        check(editor?.isFieldEditor == false, "Search unexpectedly created an NSTextField editor")
        check(
            editor?.preferredTextAccessoryPlacement() == .invisible,
            "Text cursor accessory HUD is not hidden for the search field"
        )
        let sameEditor = panel.firstResponder
        panel.focusSearchField()
        check(panel.firstResponder === sameEditor, "Refocusing restarted the editing session")
        check(
            recorder.windows.allSatisfy { $0 === panel },
            "First presentation ordered a transient SwiftUI host window"
        )
        check(
            NSApp.windows.allSatisfy { $0 === panel || !$0.isVisible },
            "A second window is visible after the first presentation"
        )
        check(panel.childWindows?.isEmpty ?? true, "The panel gained a child window during presentation")

        // The saved-items filter must update the real panel without taking search focus.
        model.toggleStarredFilter()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(model.filteredItems.count == 1 && model.selectedItem?.isStarred == true,
              "Starred filter keeps the saved item selected")
        check(model.selectedItem?.tagNames == ["work", "documentation"], "Preview retains tags")
        check(panel.firstResponder === sameEditor, "Filtering moved keyboard focus")
        checkFullSizeHierarchy()
        model.toggleStarredFilter()
        check(model.filteredItems.count == 6, "Clearing the filter restores history")

        // Starring from the search field preserves its text and ignores held-key repeats.
        sendShortcut("f", code: 3)
        check(model.selectedItem?.isStarred == false, "Command-F did not remove the star")
        sendShortcut("f", code: 3, repeated: true)
        check(model.selectedItem?.isStarred == false, "Held Command-F toggled repeatedly")
        sendShortcut("f", code: 3)
        check(model.selectedItem?.isStarred == true, "Command-F did not restore the star")
        check(panel.firstResponder === sameEditor && editor?.string == "", "Command-F changed search input")
        model.toggleTaggedFilter()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(model.filteredItems.count == 1, "Tagged filter did not narrow the real panel")
        checkFullSizeHierarchy()
        model.toggleTaggedFilter()
        check(model.filteredItems.count == 6, "Clearing the tagged filter restores history")

        // Saving tags uses the modal field rather than the clipboard panel's Return shortcut.
        let editorDriver = TagsEditorDriver()
        let editTimer = Timer(timeInterval: 0.1, target: editorDriver,
            selector: #selector(TagsEditorDriver.saveTags(_:)), userInfo: nil, repeats: false)
        RunLoop.current.add(editTimer, forMode: .modalPanel)
        sendShortcut("t", code: 17)
        editTimer.invalidate()
        check(editorDriver.saved, "Tags editor did not save")
        check(model.selectedItem?.tagNames == ["guides", "WORK"], "Tags editor did not normalize edits")

        // Escape discards edits; Return saves without invoking the panel's
        // paste action.
        var choseItem = false
        panel.choose = { choseItem = true }
        for cancel in [true, false] {
            let driver = TagsEditorDriver()
            driver.expectedTags = "guides, WORK"
            driver.cancel = cancel
            driver.useReturn = !cancel
            driver.editedTags = "keyboard, WORK, keyboard"
            let timer = Timer(timeInterval: 0.1, target: driver,
                selector: #selector(TagsEditorDriver.saveTags(_:)), userInfo: nil, repeats: false)
            RunLoop.current.add(timer, forMode: .modalPanel)
            sendShortcut("t", code: 17)
            timer.invalidate()
            check(driver.saved, "Modal keyboard test did not run")
            let expected = cancel ? ["guides", "WORK"] : ["keyboard", "WORK"]
            check(model.selectedItem?.tagNames == expected, "Modal editor saved incorrect tags")
            check(!choseItem, "Modal Return chose a clipboard item")
        }

        // The options dropdown opens as a right-aligned child window under its
        // button, registers its rows for keyboard control and leaves nothing
        // behind once dismissed.
        func findOptionsButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.toolTip == localized("pastemin_options", "Pastemin options") {
                return button
            }
            for subview in view.subviews {
                if let button = findOptionsButton(in: subview) { return button }
            }
            return nil
        }
        guard let optionsButton = findOptionsButton(in: panel.contentView!) else {
            fatalError("Options button missing")
        }
        let dropdownSelection = OptionsSelectionModel()
        let dropdown = ClipboardOptionsPanel(
            rootView: ClipboardOptionsMenuView(
                model: model,
                preferences: preferences,
                store: store,
                selection: dropdownSelection,
                recordingChanged: { _ in },
                showPurchases: {},
                showPrivacyPolicy: {},
                showAbout: {},
                revealStorage: {},
                clearCurrentClipboard: {},
                clearHistory: {},
                dismiss: {}
            ),
            selection: dropdownSelection
        )
        dropdown.present(below: optionsButton)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(dropdown.isVisible, "Options dropdown was not shown")
        check(dropdown.parent === panel, "Options dropdown is not a child of the panel")
        check(dropdown.frame.width == 360, "Options dropdown width")
        check(
            dropdown.frame.minX >= panel.frame.minX && dropdown.frame.maxX <= panel.frame.maxX + 0.5,
            "Options dropdown extends beyond the panel"
        )
        check(dropdown.frame.maxY < panel.frame.maxY, "Options dropdown does not hang below the header")
        check(dropdownSelection.rows.first == .starred, "Options rows were not registered")
        check(Array(dropdownSelection.rows.prefix(3)) == [.starred, .tagged, .clearCurrent],
              "Filter rows do not lead the dropdown")
        check(dropdownSelection.rows.last == .privacy, "Options rows end with the privacy footer")
        check(
            Array(dropdownSelection.rows.suffix(4)) == [.storage, .purchases, .about, .privacy],
            "Storage, Pro, About and Privacy rows are out of display order"
        )
        dropdownSelection.moveSelection(by: 1)
        check(dropdownSelection.selection == .starred, "Down arrow did not select the first row")
        dropdownSelection.moveSelection(by: -1)
        check(dropdownSelection.selection == .starred, "Up arrow left the first row")
        dropdownSelection.moveSelection(by: 1)
        check(dropdownSelection.selection == .tagged, "Down arrow did not advance")
        // Return on a filter row narrows the list behind the dropdown, like a click.
        dropdownSelection.activateSelection()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(model.showsTaggedOnly && model.filteredItems.count == 1,
              "Return on the tagged row did not filter the list")
        model.toggleTaggedFilter()
        dropdown.dismiss()
        check(!dropdown.isVisible, "Options dropdown stayed visible after dismiss")
        check(dropdownSelection.selection == nil, "Dismiss did not clear the selection")
        check(panel.childWindows?.isEmpty ?? true, "Options dropdown remained a child window")
        panel.orderOut(nil)
        samplingTimer.invalidate()
        print("Pastemin panel: first render used one correctly sized window")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='pastemin-panel-test-', dir='/private/tmp') as folder_name:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=1)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error('--runs must be at least 1')

    folder = Path(folder_name)
    main = folder / 'main.swift'
    main.write_text(fixture)
    output = folder / 'panel-test'
    command = swift_compiler() + [
        '-parse-as-library', '-swift-version', '5',
        '-module-cache-path', str(folder / 'modules'),
        '-target', 'arm64-apple-macos14.0',
        str(ROOT / 'Sources/PasteminApp/Localization.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardModels.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardHistoryStore.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardViewModel.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardPreferences.swift'),
        str(ROOT / 'Sources/PasteminApp/GlobalHotKey.swift'),
        str(ROOT / 'Sources/PasteminApp/PasteminEntitlementLogic.swift'),
        str(ROOT / 'Sources/PasteminApp/BuildEdition.swift'),
        str(ROOT / 'Sources/PasteminApp/PasteminStore.swift'),
        str(ROOT / 'Sources/PasteminApp/PrivacyPolicy.swift'),
        str(ROOT / 'Sources/PasteminApp/SettingsPopUpPicker.swift'),
        str(ROOT / 'Sources/PasteminApp/ShortcutRecorder.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardOptionsMenu.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardOptionsPanel.swift'),
        str(ROOT / 'Sources/PasteminApp/AccessBanner.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardHistoryView.swift'),
        str(ROOT / 'Sources/PasteminApp/ClipboardPanel.swift'),
        str(main),
        '-framework', 'AppKit', '-framework', 'SwiftUI', '-framework', 'Carbon',
        '-framework', 'CryptoKit', '-framework', 'ImageIO', '-framework', 'StoreKit',
        '-o', str(output),
    ]
    subprocess.run(command, check=True)
    for attempt in range(args.runs):
        fixture_command = [str(output), str(folder / f'History-{attempt}')]
        subprocess.run(fixture_command, check=True, timeout=30)
    if args.runs > 1:
        print(f'Pastemin panel: {args.runs} fresh-process presentations passed')
