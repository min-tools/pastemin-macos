#!/usr/bin/env python3
"""Exercise edition-specific selection and preferences without posting events."""
from pathlib import Path
import os
import subprocess
import tempfile

from build import ROOT

controller = (ROOT / 'Sources/PasteminApp/ClipboardController.swift').read_text()


def block_after(marker):
    """Extract the balanced Swift block after a required source marker."""
    start = controller.index('{', controller.index(marker))
    depth = 1
    end = start + 1
    while depth:
        depth += (controller[end] == '{') - (controller[end] == '}')
        end += 1
    return controller[start + 1:end - 1]


selection = block_after('viewModel.onChoose =').removeprefix(' [weak self] in')
restore = block_after('private func restorePreviousApplication(')
fixture = r'''
import Foundation
import Combine

// In-memory defaults and permission stubs keep the workstation unchanged.
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = ["PasteminPasteAutomatically": true]
    var reads: [String] = []
    var writes: [String] = []
    func object(forKey key: String) -> Any? { reads.append(key); return values[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func set(_ value: Any?, forKey key: String) { writes.append(key); values[key] = value }
}
enum RetentionPeriod: String { case oneMonth }
struct GlobalShortcut: Codable { static let defaultShortcut = GlobalShortcut() }
var permissionChecks = 0
var permissionAllowed = false
func CGPreflightPostEventAccess() -> Bool { permissionChecks += 1; return permissionAllowed }

final class NSRunningApplication {
    static let current = NSRunningApplication()
    var isTerminated = false
    var activations = 0
    func activate(from: NSRunningApplication, options: [Int]) -> Bool {
        activations += 1
        return true
    }
}
final class Application {
    var yieldedTo: NSRunningApplication?
    func yieldActivation(to application: NSRunningApplication) { yieldedTo = application }
}
let NSApp = Application()
final class DispatchQueue {
    static let main = DispatchQueue()
    func async(execute: () -> Void) { execute() }
}
final class Monitor {
    var acknowledged = false
    func acknowledgeCurrentPasteboard() { acknowledged = true }
}
final class Panel {
    var hidden = false
    func orderOut(_ sender: Any?) { hidden = true }
}
@MainActor final class Controller {
    let preferences = ClipboardPreferences()
    let monitor = Monitor()
    let panel = Panel()
    var previousApplication: NSRunningApplication?
    var automaticPasteRequest: UInt = 0
    var requestedPermission = false
    var pasteAttempts = 0
    func requestAutomaticPasteAccess() -> Bool { requestedPermission = true; return false }
    func pasteWhenApplicationIsFrontmost(_ app: NSRunningApplication, request: UInt) {
        pasteAttempts += 1
    }
    func choose() {
        let onChoose = { [weak self] in
SELECTION_BODY
        }
        onChoose()
    }
    func restorePreviousApplication(andPaste shouldPaste: Bool) {
RESTORE_BODY
    }
}

@MainActor func runChecks() {
// Existing local opt-in is retained without reading it or checking permission in Store builds.
let defaults = UserDefaults()
let preferences = ClipboardPreferences(defaults: defaults)
#if PASTEMIN_APP_STORE
precondition(permissionChecks == 0)
precondition(!defaults.reads.contains("PasteminPasteAutomatically"))
#else
precondition(preferences.pasteAutomatically)
precondition(permissionChecks == 1)
preferences.refreshAutomaticPasteAuthorization()
precondition(permissionChecks == 2)
preferences.pasteAutomatically = false
precondition(defaults.values["PasteminPasteAutomatically"] as? Bool == false)
#endif
preferences.showInMenuBar = false
precondition(defaults.writes.contains("PasteminShowInMenuBar"))
#if PASTEMIN_APP_STORE
precondition(!defaults.writes.contains("PasteminPasteAutomatically"))
precondition(defaults.values["PasteminPasteAutomatically"] as? Bool == true)
#endif

// Real selection and focus-restoration code runs against inert app and permission doubles.
for enabled in [false, true] {
    for allowed in [false, true] {
        permissionAllowed = allowed
        let controller = Controller()
        #if !PASTEMIN_APP_STORE
        controller.preferences.pasteAutomatically = enabled
        #endif
        permissionChecks = 0
        let target = NSRunningApplication()
        controller.previousApplication = target
        controller.choose()
        precondition(controller.monitor.acknowledged && controller.panel.hidden)
        precondition(NSApp.yieldedTo === target && target.activations == 1)
        precondition(controller.previousApplication == nil)
        #if PASTEMIN_APP_STORE
        precondition(permissionChecks == 0 && !controller.requestedPermission)
        precondition(controller.pasteAttempts == 0)
        #else
        precondition(permissionChecks == (enabled ? 1 : 0))
        precondition(controller.requestedPermission == (enabled && !allowed))
        precondition(controller.pasteAttempts == (enabled && allowed ? 1 : 0))
        #endif
    }
}

// Store focus restoration ignores even a direct request to paste.
let direct = Controller()
let target = NSRunningApplication()
direct.previousApplication = target
direct.restorePreviousApplication(andPaste: true)
precondition(target.activations == 1)
#if PASTEMIN_APP_STORE
precondition(direct.pasteAttempts == 0)
#else
precondition(direct.pasteAttempts == 1)
#endif
let terminated = NSRunningApplication()
terminated.isTerminated = true
direct.previousApplication = terminated
direct.restorePreviousApplication(andPaste: false)
precondition(terminated.activations == 0)
direct.restorePreviousApplication(andPaste: false)
print("Automatic-paste edition, preference, and focus checks passed")
}
MainActor.assumeIsolated { runChecks() }
'''.replace('SELECTION_BODY', selection).replace('RESTORE_BODY', restore)

with tempfile.TemporaryDirectory(prefix='pastemin-paste-tests-', dir='/private/tmp') as directory:
    folder = Path(directory)
    source = folder / 'main.swift'
    source.write_text(fixture)
    cache = os.environ.get('PASTEMIN_TEST_MODULE_CACHE', str(folder / 'modules'))
    for edition, flags in [('local', []), ('app-store', ['-D', 'PASTEMIN_APP_STORE'])]:
        executable = folder / edition
        subprocess.run([
            'swiftc', '-swift-version', '5', '-module-cache-path', cache, *flags,
            str(ROOT / 'Sources/PasteminApp/ClipboardPreferences.swift'),
            str(source), '-o', str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True, timeout=30)
