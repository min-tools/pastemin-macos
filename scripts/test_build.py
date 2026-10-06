#!/usr/bin/env python3
"""Verify sandboxed builds and the local-only automatic-paste boundary."""
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile

from build import ROOT, build_app

EXPECTED_LANGUAGES = {
    'cs', 'da', 'de', 'el', 'en', 'es', 'fi', 'fr', 'hi', 'hr', 'hu', 'id',
    'it', 'ja', 'ko', 'nb', 'nl', 'pl', 'pt', 'ro', 'ru', 'sk', 'sr',
    'sr-Latn', 'sv', 'th', 'tr', 'uk', 'vi', 'zh-Hans', 'zh-Hant',
}


def verify_localizations(app):
    resources = app / 'Contents/Resources'
    languages = {folder.stem for folder in resources.glob('*.lproj') if folder.is_dir()}
    assert languages == EXPECTED_LANGUAGES
    for language in languages:
        strings = resources / f'{language}.lproj/Localizable.strings'
        assert strings.is_file() and strings.stat().st_size > 0


def verify_icon_representations(icon, folder):
    data = icon.read_bytes()
    assert data[:4] == b'icns'
    assert struct.unpack('>I', data[4:8])[0] == len(data)
    expected = {'icp4': 16, 'icp5': 32, 'icp6': 64, 'ic07': 128,
                'ic08': 256, 'ic09': 512, 'ic10': 1024}
    chunks = []
    offset = 8
    while offset < len(data):
        chunk_type = data[offset:offset + 4].decode('ascii')
        chunk_size = struct.unpack('>I', data[offset + 4:offset + 8])[0]
        assert chunk_size >= 8 and offset + chunk_size <= len(data)
        payload = data[offset + 8:offset + chunk_size]
        assert payload.startswith(b'\x89PNG\r\n\x1a\n')
        size = expected[chunk_type]
        assert struct.unpack('>II', payload[16:24]) == (size, size)
        chunks.append(chunk_type)
        offset += chunk_size
    assert chunks == list(expected)

    # Check unpacking separately: iconutil emits a legacy 48-pixel fallback for
    # Netmin's icp6 layout, while NSImage uses its original 64-pixel PNG.
    iconset = folder / 'Decoded.iconset'
    subprocess.run(['iconutil', '-c', 'iconset', str(icon), '-o', str(iconset)], check=True)
    assert (iconset / 'icon_16x16.png').is_file()
    assert (iconset / 'icon_512x512@2x.png').is_file()


def signed_entitlements(app):
    data = subprocess.check_output(
        ['codesign', '-d', '--xml', '--entitlements', '-', str(app)],
        stderr=subprocess.DEVNULL,
    )
    return plistlib.loads(data)


with tempfile.TemporaryDirectory(prefix='pastemin-app-test-', dir='/private/tmp') as folder_name:
    folder = Path(folder_name)
    app = build_app(folder / 'Pastemin.app', configuration='Debug')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == 'tools.min.pastemin'
    assert info['CFBundleExecutable'] == 'Pastemin'
    assert info['CFBundleDisplayName'] == 'Pastemin'
    assert info['CFBundleIconFile'] == 'AppIcon'
    assert info['CFBundleSupportedPlatforms'] == ['MacOSX']
    assert info['DTPlatformName'] == 'macosx'
    # Compare bundle metadata with the executable, not the metadata helper itself.
    load_commands = subprocess.check_output(
        ['xcrun', 'vtool', '-show-build', str(app / 'Contents/MacOS/Pastemin')], text=True
    )
    sdk_version = re.search(r'^\s+sdk\s+(\S+)', load_commands, re.MULTILINE).group(1)
    assert info['DTSDKName'] == f'macosx{sdk_version}'
    assert info['DTPlatformVersion'] == sdk_version
    assert info['DTSDKBuild'] == info['DTPlatformBuild'] and info['DTSDKBuild']
    assert info['LSUIElement'] is True
    assert (app / 'Contents/Resources/AppIcon.icns').is_file()
    assert (app / 'Contents/Resources/PrivacyInfo.xcprivacy').is_file()
    assert (app / 'Contents/Resources/PRIVACY.md').is_file()
    assert (
        app / 'Contents/Resources/PRIVACY.md'
    ).read_text() == (ROOT / 'PRIVACY.md').read_text()
    verify_localizations(app)
    verify_icon_representations(app / 'Contents/Resources/AppIcon.icns', folder)
    assert signed_entitlements(app)['com.apple.security.app-sandbox'] is True

    symbols = subprocess.check_output(
        ['nm', '-u', str(app / 'Contents/MacOS/Pastemin')], text=True
    )
    event_posting_symbols = (
        '_CGEventPostToPid', '_CGRequestPostEventAccess', '_CGPreflightPostEventAccess',
    )
    for symbol in event_posting_symbols:
        assert symbol in symbols, f'Local build lost {symbol}'
    binary = (app / 'Contents/MacOS/Pastemin').read_bytes()
    assert b'Paste automatically' in binary
    assert b'PasteminDidCompleteSetupWizard' in binary
    assert b'Source build' not in binary and b'If it earns its keep' not in binary
    assert b'Trial ended' in binary and b'5 most recent items' in binary
    assert b'Restore Purchases' in binary and b'Purchase' in binary
    assert b'tools.min.pastemin.pro.yearly' in binary
    assert b'tools.min.pastemin.pro.lifetime' in binary

    release_app = build_app(folder / 'PasteminRelease.app', app_store=True)
    # A saved local preference cannot enable code that is absent from the Store binary.
    store_symbols = subprocess.check_output(
        ['nm', '-u', str(release_app / 'Contents/MacOS/Pastemin')], text=True
    )
    for symbol in event_posting_symbols:
        assert symbol not in store_symbols, f'App Store build includes {symbol}'
    store_binary = (release_app / 'Contents/MacOS/Pastemin').read_bytes()
    for marker in (b'Paste automatically', b'PasteminPasteAutomatically', b'automatic_paste_access_needed'):
        assert marker not in store_binary, f'App Store build includes {marker!r}'
    assert signed_entitlements(release_app)['com.apple.security.app-sandbox'] is True
    release_symbols = folder / 'PasteminRelease.app.dSYM'
    assert release_symbols.is_dir()
    assert not (release_app / 'Contents/MacOS/Pastemin.dSYM').exists()
    app_uuid = subprocess.check_output([
        'dwarfdump', '--uuid', str(release_app / 'Contents/MacOS/Pastemin'),
    ], text=True).split()[1]
    symbols_uuid = subprocess.check_output([
        'dwarfdump', '--uuid', str(release_symbols),
    ], text=True).split()[1]
    assert app_uuid == symbols_uuid
print('Pastemin build: sandboxed local and App Store editions passed')
