#!/usr/bin/env python3
"""Exercise setup opt-in behavior and translated AppKit layout in isolation."""
from pathlib import Path
import os
import subprocess
import tempfile

from build import ROOT

# Verify the copy and system integrations promised by the setup wizard.
wizard_path = ROOT / 'Sources/PasteminApp/SetupWizard.swift'
wizard = wizard_path.read_text()
assert '30 days of full access' in wizard
assert 'No subscription starts, and you will not be charged.' in wizard
assert 'shows and searches only the 5 newest items' in wizard
assert 'Open at login' in wizard
assert 'try service.register()' in wizard
assert 'try service.unregister()' in wizard
assert 'SMAppService.openSystemSettingsLoginItems()' in wizard
assert 'presentLoginItemError(error)' in wizard
assert 'case 0: step = readyStep()' in wizard
assert 'if stepIndex == 0 {' in wizard
assert 'PasteminStore.shared.beginAppTrial()' in wizard
assert 'func windowWillClose(_ notification: Notification) {' in wizard


def method(name):
    """Extract one production method by balancing its Swift braces."""
    signature = f'    private func {name}'
    start = wizard.index(signature)
    brace = wizard.index('{', start)
    depth = 0
    end = brace
    in_string = False
    escaped = False
    for index in range(brace, len(wizard)):
        character = wizard[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == '\\':
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == '{':
            depth += 1
        elif character == '}':
            depth -= 1
            if depth == 0:
                end = index + 1
                break
    block = wizard[start:end]
    return block.replace('    private func', '    func', 1) + '\n'


# Keep the build-boundary and permission contract visible beside the behavioral fixture.
controller = (ROOT / 'Sources/PasteminApp/ClipboardController.swift').read_text()
preferences = (ROOT / 'Sources/PasteminApp/ClipboardPreferences.swift').read_text()
options = (ROOT / 'Sources/PasteminApp/ClipboardOptionsMenu.swift').read_text()
assert '#if !PASTEMIN_APP_STORE' not in controller
assert '#if !PASTEMIN_APP_STORE' not in preferences
assert '#if !PASTEMIN_APP_STORE' not in options
assert 'preferences.pasteAutomatically\n                && (CGPreflightPostEventAccess() || requestAutomaticPasteAccess())' in controller
assert 'CGRequestPostEventAccess()' in controller
assert 'pasteWhenApplicationIsFrontmost(application, request: pasteRequest)' in controller
assert 'Self.postPasteShortcut(to: application.processIdentifier)' in controller
assert 'keyDown.postToPid(processIdentifier)' in controller
assert 'keyUp.postToPid(processIdentifier)' in controller
assert 'requestAutomaticPasteAccess' not in wizard
assert 'CGPreflightPostEventAccess() || requestAutomaticPasteAccess()' in controller
assert 'panel.orderOut(nil)\n            let shouldPaste = preferences.pasteAutomatically' in controller

yield_call = 'NSApp.yieldActivation(to: application)'
activate_call = 'application.activate(from: .current, options: [])'
assert yield_call in controller
assert activate_call in controller
assert controller.index(yield_call) < controller.index(activate_call)
assert 'application.activate(options: [])' not in controller

fixture = r'''
import Cocoa

var strings: [String: String] = [:]
func localized(_ key: String, _ fallback: String) -> String { strings[key] ?? fallback }
func localizedFormat(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key, fallback), locale: Locale(identifier: "en_US"), arguments: arguments)
}

enum RetentionPeriod: String, CaseIterable {
    case oneHour, oneDay, oneWeek, oneMonth, threeMonths, forever
    var title: String {
        switch self {
        case .oneHour: localized("retention_one_hour", "1 hour")
        case .oneDay: localized("retention_one_day", "1 day")
        case .oneWeek: localized("retention_one_week", "1 week")
        case .oneMonth: localized("retention_one_month", "1 month")
        case .threeMonths: localized("retention_three_months", "3 months")
        case .forever: localized("retention_forever", "Forever")
        }
    }
}

struct Shortcut { var displayName = "⌃⌥C" }
final class Preferences {
    var retention = RetentionPeriod.oneMonth
    var showInMenuBar = true
    var shortcut = Shortcut()
    var pasteAutomatically = false
    var automaticPasteAuthorized = false
    func refreshAutomaticPasteAuthorization() {}
}

final class LayoutFixture: NSObject, NSWindowDelegate {
    let preferences = Preferences()
    var window: NSWindow?
    var stepIndex = 0
    let stepCount = 4
    var stepViews: [Int: NSView] = [:]
    var contentContainer: NSView!
    var progressLabel: NSTextField!
    var backButton: NSButton!
    var continueButton: NSButton!
    var laterButton: NSButton!
    var retentionPopup: NSPopUpButton?
    var menuBarCheckbox: NSButton?
    var loginItemCheckbox: NSButton?
    var autoPasteCheckbox: NSButton?
    var loginItemIsSelected: () -> Bool = { false }
    @objc func setUpLater(_ sender: Any?) {}
    @objc func goBack(_ sender: Any?) {}
    @objc func goForward(_ sender: Any?) {}
'''
fixture += ''.join(method(name) for name in [
    'buildWindow()', 'showStep()', 'fitWindow(to step: NSView)',
    'stepStack(title: String, body: String, extra: [NSView] = [])',
    'welcomeStep()', 'essentialsStep()', 'automaticPasteStep()', 'readyStep()',
    'trialRow(symbol: String, title: String, detail: String)',
    'labeledRow(_ title: String, control: NSView)',
])
fixture += r'''
}

final class Defaults {
    var values: [String: Bool] = [:]
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}
final class Window {
    var orderedOut = false
    var closed = false
    func orderOut(_ sender: Any?) { orderedOut = true }
    func close() { closed = true }
}
final class FinishFixture {
    static let completedKey = "PasteminDidCompleteSetupWizard"
    let preferences = Preferences()
    let defaults = Defaults()
    var window: Window? = Window()
    var retentionPopup: NSPopUpButton?
    var menuBarCheckbox: NSButton?
    var loginItemCheckbox: NSButton?
    var autoPasteCheckbox: NSButton?
    var setLoginItemSelected: (Bool) throws -> Void = { _ in }
    var presentLoginItemError: (Error) -> Void = { _ in }
'''
fixture += method('finish()').replace('    func finish()', '    func finish()')
fixture += r'''
}

let _ = NSApplication.shared
var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
    checks += 1
}

let resources = URL(fileURLWithPath: CommandLine.arguments[1])
let locales = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "lproj" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
for locale in locales {
    let data = try Data(contentsOf: locale.appendingPathComponent("Localizable.strings"))
    strings = (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]) ?? [:]
    let layout = LayoutFixture()
    layout.buildWindow()
    let window = layout.window!
    let top = window.frame.maxY
    for index in 0..<layout.stepCount {
        layout.stepIndex = index
        layout.showStep()
        window.contentView!.layoutSubtreeIfNeeded()
        let view = layout.stepViews[index]!
        let available = window.contentView!.bounds.height - 24 - 20 - layout.continueButton.fittingSize.height - 20
        check(view.fittingSize.height <= available + 0.5, "\(locale.lastPathComponent): step \(index + 1) fits above footer")
        check(window.contentView!.bounds.width >= 560, "\(locale.lastPathComponent): setup keeps its content width")
        check(window.contentView!.bounds.height >= 440, "\(locale.lastPathComponent): setup keeps its minimum height")
        check(window.contentView!.bounds.height < 800, "\(locale.lastPathComponent): setup remains compact")
        check(abs(window.frame.maxY - top) < 0.5, "\(locale.lastPathComponent): resizing keeps the top edge fixed")
    }
    check(layout.loginItemCheckbox?.state == .off, "\(locale.lastPathComponent): login item reflects disabled state")
    check(layout.autoPasteCheckbox?.state == .off, "\(locale.lastPathComponent): automatic paste starts unchecked")
    window.close()
}

// controls(_:automaticPaste:openAtLogin:) installs the required fixture
// controls.
// All parameters are required; the booleans set the two opt-in states.
func controls(_ fixture: FinishFixture, automaticPaste: Bool, openAtLogin: Bool) {
    let retention = NSPopUpButton(frame: .zero, pullsDown: false)
    retention.addItem(withTitle: "Forever")
    retention.lastItem?.representedObject = RetentionPeriod.forever.rawValue
    fixture.retentionPopup = retention
    fixture.menuBarCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    fixture.menuBarCheckbox?.state = .off
    fixture.loginItemCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    fixture.loginItemCheckbox?.state = openAtLogin ? .on : .off
    fixture.autoPasteCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    fixture.autoPasteCheckbox?.state = automaticPaste ? .on : .off
}

// Verify login launch can be enabled while automatic paste remains disabled.
let copyOnly = FinishFixture()
var copyOnlyLoginChoice: Bool?
copyOnly.setLoginItemSelected = { copyOnlyLoginChoice = $0 }
controls(copyOnly, automaticPaste: false, openAtLogin: true)
copyOnly.finish()
check(!copyOnly.preferences.pasteAutomatically, "copy-only setup stays disabled")
check(copyOnly.preferences.retention == .forever, "setup saves retention")
check(!copyOnly.preferences.showInMenuBar, "setup saves menu-bar visibility")
check(copyOnlyLoginChoice == true, "setup enables the selected login item")
check(copyOnly.defaults.values[FinishFixture.completedKey] == true, "setup records completion")
check(copyOnly.window?.closed == true, "setup closes after saving")

// Verify automatic paste can be enabled while login launch remains disabled.
let optedIn = FinishFixture()
var optedInLoginChoice: Bool?
optedIn.setLoginItemSelected = { optedInLoginChoice = $0 }
controls(optedIn, automaticPaste: true, openAtLogin: false)
optedIn.finish()
check(optedIn.preferences.pasteAutomatically, "explicit opt-in enables automatic paste")
check(optedIn.preferences.retention == .forever, "opt-in setup saves retention")
check(!optedIn.preferences.showInMenuBar, "opt-in setup saves menu-bar visibility")
check(optedInLoginChoice == false, "setup disables the unselected login item")
check(optedIn.defaults.values[FinishFixture.completedKey] == true, "opt-in setup records completion")

// Verify a system registration failure is reported without completing setup.
enum LoginItemFailure: Error { case registrationDenied }
let failedLoginItem = FinishFixture()
var presentedLoginItemError: Error?
failedLoginItem.setLoginItemSelected = { _ in throw LoginItemFailure.registrationDenied }
failedLoginItem.presentLoginItemError = { presentedLoginItemError = $0 }
controls(failedLoginItem, automaticPaste: false, openAtLogin: true)
failedLoginItem.finish()
check(presentedLoginItemError != nil, "setup reports a login-item registration failure")
check(failedLoginItem.defaults.values[FinishFixture.completedKey] != true, "failed login-item setup remains incomplete")
check(failedLoginItem.window?.closed == false, "failed login-item setup stays open")

print("\(checks) setup behavior and layout checks passed across \(locales.count) languages")
'''

with tempfile.TemporaryDirectory(prefix='pastemin-setup-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    source = folder / 'main.swift'
    source.write_text(fixture)
    cache = os.environ.get('PASTEMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    subprocess.run([
        'swiftc', '-swift-version', '5', '-module-cache-path', cache,
        str(source), '-o', str(folder / 'tests'),
    ], check=True)
    subprocess.run([str(folder / 'tests'), str(ROOT / 'Resources')], check=True, timeout=30)
