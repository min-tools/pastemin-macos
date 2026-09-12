#!/usr/bin/env python3
"""Materialize the clipboard panel off-screen and verify its first rendered geometry."""
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

@main
enum PanelPresentationTest {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
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
        let model = ClipboardViewModel(store: store)
        let defaults = UserDefaults(suiteName: "tools.min.pastemin.panel-test")!
        defaults.removePersistentDomain(forName: "tools.min.pastemin.panel-test")
        let preferences = ClipboardPreferences(defaults: defaults)
        let optionsSelection = OptionsSelectionModel()
        let optionsHost = NSHostingView(rootView: ClipboardOptionsMenuView(
            preferences: preferences,
            store: store,
            selection: optionsSelection,
            recordingChanged: { _ in },
            showPrivacyPolicy: {},
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
            revealStorage: {},
            clearCurrentClipboard: {},
            clearHistory: {}
        )
        let panel = ClipboardPanel(rootView: history)

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

        // Lay out at the final size without displaying the hidden glass surface.
        panel.contentView?.layoutSubtreeIfNeeded()
        checkFullSizeHierarchy()
        check(panel.initialFirstResponder === panel.contentView, "Initial first responder defers editing")

        // Materialize the first window transaction outside every display and verify that it never
        // falls back to a smaller placeholder surface.
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.makeKeyAndOrderFront(nil)
        check(panel.isVisible, "Panel ordered on screen")
        check(
            !(panel.firstResponder is NSTextView),
            "Ordering the panel in started editing before it was visible"
        )

        // Focusing after presentation must use the custom input client directly. Creating an
        // NSTextField field editor first is too late to stop TextInputUI's accessory host.
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

        // The options dropdown opens as a right-aligned child window under its button, registers
        // its rows for keyboard control and leaves nothing behind once dismissed.
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
                preferences: preferences,
                store: store,
                selection: dropdownSelection,
                recordingChanged: { _ in },
                showPrivacyPolicy: {},
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
        check(dropdownSelection.rows.first == .clearCurrent, "Options rows were not registered")
        check(dropdownSelection.rows.last == .privacy, "Options rows end with the privacy footer")
        dropdownSelection.moveSelection(by: 1)
        check(dropdownSelection.selection == .clearCurrent, "Down arrow did not select the first row")
        dropdownSelection.moveSelection(by: -1)
        check(dropdownSelection.selection == .clearCurrent, "Up arrow left the first row")
        dropdownSelection.moveSelection(by: 1)
        check(dropdownSelection.selection == .clearHistory, "Down arrow did not advance")
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
