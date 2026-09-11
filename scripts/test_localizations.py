#!/usr/bin/env python3
"""Test localization coverage and printf argument validation."""
import subprocess
import sys
import plistlib
import shutil
import tempfile
from pathlib import Path

from check_localizations import ROOT, format_arguments, strings_values

assert format_arguments('%@, %@') == {1: '@', 2: '@'}
assert format_arguments('%lld items') == {1: 'lld'}
assert format_arguments('%1$@ · %2$lld') == {1: '@', 2: 'lld'}
assert format_arguments('100%%') == {}
try:
    format_arguments('%1$@ %d')
except ValueError:
    pass
else:
    raise AssertionError('Mixed numbered and unnumbered arguments must fail')

subprocess.run([sys.executable, str(ROOT / 'scripts/check_localizations.py')], check=True)

# Exercise Bundle.main language selection in an actual app bundle, not just plist parsing.
with tempfile.TemporaryDirectory(prefix='pastemin-localization-', dir='/private/tmp') as directory:
    root = ROOT / 'Resources'
    app = Path(directory) / 'LocalizationTest.app'
    executable = app / 'Contents/MacOS/LocalizationTest'
    resources = app / 'Contents/Resources'
    executable.parent.mkdir(parents=True)
    resources.mkdir(parents=True)
    for localization in root.glob('*.lproj'):
        shutil.copytree(localization, resources / localization.name)
    info = {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': 'LocalizationTest',
        'CFBundleIdentifier': 'tools.min.pastemin.localization-test',
        'CFBundleName': 'LocalizationTest',
        'CFBundlePackageType': 'APPL',
    }
    with (app / 'Contents/Info.plist').open('wb') as file:
        plistlib.dump(info, file)
    main = Path(directory) / 'main.swift'
    main.write_text('''
import Foundation
print(Bundle.main.preferredLocalizations.first ?? "")
print(localized("clear_history", "Clear History"))
''')
    subprocess.run([
        'swiftc', '-swift-version', '5', '-module-cache-path', str(Path(directory) / 'modules'),
        str(ROOT / 'Sources/PasteminApp/Localization.swift'),
        str(main), '-o', str(executable),
    ], check=True)
    for language in ('de', 'sr-Latn', 'zh-Hant'):
        output = subprocess.check_output([
            str(executable), '-AppleLanguages', f'({language})'
        ], text=True).splitlines()
        expected = strings_values(root / f'{language}.lproj/Localizable.strings')['clear_history']
        assert output == [language, expected], (language, output, expected)

print('Pastemin localization validation passed')
