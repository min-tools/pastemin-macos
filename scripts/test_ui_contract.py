#!/usr/bin/env python3
"""Guard Pastemin's panel, options, access, privacy, and search contracts."""
from build import ROOT

sources = ROOT / 'Sources/PasteminApp'
panel = (sources / 'ClipboardPanel.swift').read_text()
main = (sources / 'PasteminMain.swift').read_text()
view = (sources / 'ClipboardHistoryView.swift').read_text()
view_model = (sources / 'ClipboardViewModel.swift').read_text()
options = (sources / 'ClipboardOptionsMenu.swift').read_text()
controller = (sources / 'ClipboardController.swift').read_text()
preferences = (sources / 'ClipboardPreferences.swift').read_text()
store = (sources / 'ClipboardHistoryStore.swift').read_text()
models = (sources / 'ClipboardModels.swift').read_text()
privacy = (sources / 'PrivacyPolicy.swift').read_text()
wizard = (sources / 'SetupWizard.swift').read_text()
banner = (sources / 'AccessBanner.swift').read_text()
build = (ROOT / 'scripts/build.py').read_text()

# The cold-launch panel remains a single, fully sized glass window.
assert 'private final class ClipboardGlassView: NSGlassEffectView' in panel
assert 'animationBehavior = .none' in panel and '.utilityWindow' not in panel
assert 'initialFirstResponder = surface.view' in panel
assert 'final class ClipboardSearchTextView: NSTextView' in panel
assert 'NSTextCursorAccessoryPlacement { .invisible }' in panel
assert 'NSApplication.didBecomeActiveNotification' in panel
assert 'if NSApp.isActive, isVisible {' in panel
assert 'openSettings' not in panel
assert 'NotificationCenter.default.post(name: .showClipboardOptions, object: nil)' in panel
assert '(child as? ClipboardOptionsPanel)?.dismiss()' in panel
assert 'applicationShouldHandleReopen' in main and 'controller?.presentClipboard()' in main

# Settings live only in the hamburger menu; the removed controls cannot persist stale behavior.
assert not (sources / 'SettingsWindow.swift').exists()
assert 'struct ClipboardOptionsMenuView: View' in options
for label in (
    'Clear Current Clipboard', 'Clear History…', 'Keep copied items',
    'Show in menu bar', 'Paste automatically', 'Show Pastemin',
    'Local storage', 'Show in Finder', 'Privacy Policy',
):
    assert label in options
assert 'Items per batch' not in options and 'Remember list position' not in options
assert 'historyPageSize' not in preferences and 'preserveScrollPosition' not in preferences
assert 'settingsWindow' not in controller and 'showSettings' not in controller
assert 'settingsFromMenu' not in controller and 'settings_ellipsis' not in controller
assert 'String(format: localized("about_app", "About %@"), "Pastemin")' in controller
assert 'string: "GitHub.com/iliaross"' in controller
assert 'URL(string: "https://github.com/iliaross")' in controller
assert 'iconView,\n            nameLabel,\n            versionLabel,\n            copyrightLabel,\n            profileButton' in controller
assert 'MinToolsAboutPanelController.shared.show(applicationName: "Pastemin")' in controller
assert 'let size = NSSize(width: 280, height: 174)' in controller
assert 'stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10)' in controller
assert 'row: .about' in options
assert 'title: localized("about", "About")' in options
assert 'rows += [.storage, .about, .privacy]' in options
assert 'ClipboardOptionsButton' in view and 'ClipboardOptionsMenuView(' in view
assert 'ClipboardOptionsPanel(' in view and 'panel.present(below: button)' in view
assert 'NSPopover' not in view and 'let menu = NSMenu()' not in view
options_panel = (sources / 'ClipboardOptionsPanel.swift').read_text()
assert 'final class ClipboardOptionsPanel: NSPanel' in options_panel
assert 'case 126: selection.moveSelection(by: -1); return' in options_panel
assert 'case 36, 76, 49: selection.activateSelection(); return' in options_panel
assert 'case 53: dismiss(); return' in options_panel
assert 'addLocalMonitorForEvents' in options_panel
assert 'selection.rows = rows' in options and 'selection.activate = { row in' in options
assert '.onHover { hovering in selection.hover(row, hovering) }' in options

# Histories render in fixed 50-item batches and expired access is a reversible view limit.
assert 'private let pageSize = 50' in view_model
assert 'private let searchDebounceNanoseconds: UInt64 = 35_000_000' in view_model
assert 'private var itemLimit: Int?' in view_model
assert 'func updateItemLimit(_ newValue: Int?)' in view_model
assert 'search(matching: needle, among: candidates)' in view_model
assert 'private(set) var query = ""' in view_model
assert 'func updateQuery(_ newValue: String)' in view_model
assert '.onChange(of: model.query)' not in view
assert 'filteredItems = []' not in view_model
assert 'else if model.isSearching' not in view
assert 'private actor ClipboardSearchEngine' in store
assert 'maximumCacheBytes = 32 * 1_024 * 1_024' in store
assert store.count('searchEngine = ClipboardSearchEngine()') >= 3
assert 'private(set) var itemsGeneration = 0' in store
assert 'imageCache.object(forKey: cacheKey)' in store
assert 'imageCache.setObject(image, forKey: cacheKey, cost: imageCacheCost(for: data))' in store
assert 'private var searchResultsAreCurrent: Bool' in view_model
assert view_model.count('guard searchResultsAreCurrent') == 2
assert view_model.count('store.items.contains(where:') == 2
assert 'self.store.itemsGeneration == storeGeneration' in view_model
assert 'viewModel.updateItemLimit(proStore.hasFullAccess ? nil : 5)' in controller
assert 'monitor.start()' in controller and 'monitor.stop()' not in controller
assert 'requestClipboardPresentation(toggle: Bool)' in controller
# The event-posting prompt must appear only on the first selected item after opt-in.
assert 'CGPreflightPostEventAccess() || requestAutomaticPasteAccess()' in controller
assert 'CGRequestPostEventAccess()' in controller
assert 'requestAutomaticPasteAccess' not in wizard and 'requestAutomaticPasteAccess' not in options
assert 'refreshEntitlement()' not in controller
assert 'showPurchases(preservePreviousApplication:' not in controller
assert 'AccessLimitedBanner(' in view
assert 'proStore.hasResolvedEntitlement && !proStore.hasFullAccess' in view
assert 'Pastemin now shows your 5 most recent items.' in banner
assert 'Restore Purchases' in banner and 'localized("purchase_or_subscribe", "Purchase")' in banner
assert 'restoreMessage = await restorePurchases()' in banner
assert 'Color(nsColor: .systemOrange).opacity(0.16)' in banner
assert 'Pastemin Pro' not in options and 'case purchases' not in options_panel

# Choosing an item makes it newest without replacing its identity or payload.
assert 'if restored { markUsed(record) }' in store
assert 'items.insert(current.withCreatedAt(Date()), at: 0)' in store
assert 'func withCreatedAt(_ date: Date)' in models

# Privacy is bundled and shown in the same native reader design as Langmin.
assert 'final class PrivacyPolicyController' in privacy
assert 'Bundle.module.url(forResource: "PRIVACY", withExtension: "md")' in privacy
assert 'Bundle.main.url(forResource: "PRIVACY", withExtension: "md")' in privacy
assert 'NSScrollView()' in privacy and 'NSButton(' in privacy
assert (sources / 'Resources/PRIVACY.md').is_file()
assert "resources / 'PRIVACY.md'" in build

# Existing clipboard ergonomics remain intact.
assert 'ClipboardPreview' in view and 'Image(nsImage: image)' in view
assert 'Text(record.previewText)' in view and 'Text(record.displayTimestamp)' in view
assert 'ForEach(model.displayedItems)' in view
assert '.onContinuousHover { phase in' in view and 'model.selectFromPointer(record.id)' in view
assert 'onChange(of: model.keyboardSelectionRequest)' in view
assert 'pointerLocationAtPresentation = point' in panel
assert 'enablePointerSelectionIfMoved(event)' in panel
assert 'panel.pointerDidMove' in controller and 'viewModel?.enablePointerSelection()' in controller
assert 'guard !NSApp.isActive || !panel.isVisible else { return }' in controller
assert 'panel.didDismiss' in controller and 'viewModel?.resetSearch()' in controller
assert 'NSWorkspace.didActivateApplicationNotification' in controller
assert 'lastExternalApplication = application' in controller
assert 'previousApplication = frontmost' in controller
assert 'previousApplication = lastExternalApplication' in controller
assert 'NSApp.yieldActivation(to: application)' in controller
assert 'application.activate(from: .current, options: [])' in controller
assert 'pasteWhenApplicationIsFrontmost(application, request: pasteRequest)' in controller
assert 'Self.postPasteShortcut(to: application.processIdentifier)' in controller
assert 'keyDown.postToPid(processIdentifier)' in controller
assert 'keyUp.postToPid(processIdentifier)' in controller
edition = (sources / 'BuildEdition.swift').read_text()
assert 'PASTEMIN_LOCAL_BUILD' in edition and 'PASTEMIN_APP_STORE' in edition
assert 'PASTEMIN_LOCAL_BUILD' not in ''.join(
    source.read_text() for source in sources.glob('*.swift') if source.name != 'BuildEdition.swift'
)
# Setup remains one-time and exposes the public login-item registration path.
assert 'PasteminDidCompleteSetupWizard' in wizard
assert 'case 0: step = readyStep()' in wizard
assert 'PasteminStore.shared.beginAppTrial()' in wizard
assert 'Open at login' in wizard
assert 'try service.register()' in wizard
assert 'try service.unregister()' in wizard
assert 'Setup Assistant…' not in options and 'case setupAssistant' not in options_panel
assert 'run Setup Assistant again' not in wizard
assert 'Pastemin always' not in wizard and 'Pastemin remains' not in wizard

print('Pastemin UI: unified options, privacy, access limit and promotion passed')
