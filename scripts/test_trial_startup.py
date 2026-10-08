#!/usr/bin/env python3
"""Exercise trial startup with delayed transactions and in-memory preferences."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

from build import ROOT, swift_compiler

# Compile the real store; substitute only signed-transaction input and preferences.
source = (ROOT / 'Sources/PasteminApp/PasteminStore.swift').read_text()
assert source.count('private let defaults = UserDefaults.standard') == 1
source = source.replace('private let defaults = UserDefaults.standard',
                        'private let defaults = TrialFixture.defaults')
source = source.replace('UserDefaults.standard', 'TrialFixture.defaults')
source = source.replace('AppTransaction.shared', 'TrialFixture.shared')
source = source.replace('private(set)', '').replace('private ', '')
fixture = (ROOT / 'scripts/test_trial_startup.swift').read_text()
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
    test = folder / 'Tests.swift'
    test.write_text(fixture)
    for flags, name in (([], 'source'), (['-D', 'PASTEMIN_APP_STORE'], 'app-store')):
        binary = folder / name
        subprocess.run(swift_compiler() + [
            '-swift-version', '5', '-warnings-as-errors',
            '-module-cache-path', str(folder / 'modules'), *flags,
            str(ROOT / 'Sources/PasteminApp/BuildEdition.swift'),
            str(ROOT / 'Sources/PasteminApp/PasteminEntitlementLogic.swift'),
            str(ROOT / 'Sources/PasteminApp/Localization.swift'),
            str(store), str(test), '-o', str(binary),
        ], check=True, env=environment)
        subprocess.run([str(binary)], check=True, timeout=30)
