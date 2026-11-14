#!/usr/bin/env python3
"""Exercise trial startup and live expiry with fixture time and preferences."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

from build import ROOT, swift_compiler

# Compile the real store with fixture transactions, preferences, and time.
source = (ROOT / 'Sources/PasteminApp/PasteminStore.swift').read_text()
assert source.count('private let defaults = UserDefaults.standard') == 1
source = source.replace('private let defaults = UserDefaults.standard',
                        'private let defaults = TrialFixture.defaults')
source = source.replace('UserDefaults.standard', 'TrialFixture.defaults')
source = source.replace('AppTransaction.shared', 'TrialFixture.shared')
source = source.replace('Date()', 'TrialClock.now')
source = source.replace('private(set)', '').replace('private ', '')
fixture = (ROOT / 'scripts/test_trial_startup.swift').read_text()
fixture += (ROOT / 'scripts/test_trial_expiry.swift').read_text()
logic = (ROOT / 'Sources/PasteminApp/PasteminEntitlementLogic.swift').read_text()
logic = logic.replace('Date()', 'TrialClock.now')
# Use the exact visibility condition from the production view.
banner = (ROOT / 'Sources/PasteminApp/ClipboardHistoryView.swift').read_text()
condition = re.search(r'if ((?:proStore|store)\.hasResolvedEntitlement[^\n]+) \{', banner).group(1)
condition = condition.replace('proStore.', 'store.')
fixture += '\n@MainActor func bannerIsVisible(_ store: PasteminStore) -> Bool { ' + condition + ' }\n'
environment = os.environ.copy()
environment.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')

# No app is launched, no Apple Account is used, and preferences stay in memory.
with tempfile.TemporaryDirectory(prefix='pastemin-trial-startup-', dir='/private/tmp') as directory:
    folder = Path(directory)
    store = folder / 'PasteminStore.swift'
    store.write_text(source)
    policy = folder / 'PasteminEntitlementLogic.swift'
    policy.write_text(logic)
    test = folder / 'Tests.swift'
    test.write_text(fixture)
    for flags, name in (([], 'source'), (['-D', 'PASTEMIN_APP_STORE'], 'app-store')):
        binary = folder / name
        subprocess.run(swift_compiler() + [
            '-swift-version', '5', '-warnings-as-errors',
            '-module-cache-path', str(folder / 'modules'), *flags,
            str(ROOT / 'Sources/PasteminApp/BuildEdition.swift'),
            str(policy),
            str(ROOT / 'Sources/PasteminApp/Localization.swift'),
            str(ROOT / 'Sources/PasteminApp/ClipboardModels.swift'),
            str(ROOT / 'Sources/PasteminApp/ClipboardHistoryStore.swift'),
            str(ROOT / 'Sources/PasteminApp/ClipboardViewModel.swift'),
            str(store), str(test), '-o', str(binary),
        ], check=True, env=environment)
        subprocess.run([str(binary), str(folder / f'{name}-history')], check=True, timeout=30)
