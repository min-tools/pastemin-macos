#!/usr/bin/env python3
"""Verify the single sandboxed build contract."""
from pathlib import Path
import plistlib
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
    chunks = []
    offset = 8
    while offset < len(data):
        chunk_type = data[offset:offset + 4].decode('ascii')
        chunk_size = struct.unpack('>I', data[offset + 4:offset + 8])[0]
        payload = data[offset + 8:offset + chunk_size]
        assert payload.startswith(b'\x89PNG\r\n\x1a\n')
        chunks.append(chunk_type)
        offset += chunk_size
    assert chunks == ['ic11', 'ic12', 'ic07', 'ic13', 'ic08', 'ic14', 'ic09', 'ic10']

    iconset = folder / 'Decoded.iconset'
    subprocess.run(['iconutil', '-c', 'iconset', str(icon), '-o', str(iconset)], check=True)
    expected = {
        'icon_16x16@2x.png': 32,
        'icon_32x32@2x.png': 64,
        'icon_128x128.png': 128,
        'icon_128x128@2x.png': 256,
        'icon_256x256.png': 256,
        'icon_256x256@2x.png': 512,
        'icon_512x512.png': 512,
        'icon_512x512@2x.png': 1024,
    }
    for filename, size in expected.items():
        details = subprocess.check_output(
            ['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', str(iconset / filename)],
            text=True,
        )
        assert f'pixelWidth: {size}' in details
        assert f'pixelHeight: {size}' in details

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
    assert '_CGEventPost' in symbols
    binary = (app / 'Contents/MacOS/Pastemin').read_bytes()
    assert b'Paste automatically' in binary
    assert b'PasteminDidCompleteSetupWizard' in binary
    assert b'Source build' not in binary and b'If it earns its keep' not in binary
    assert b'Trial ended' in binary and b'5 most recent items' in binary
    assert b'Restore Purchases' in binary and b'Purchase' in binary
    assert b'tools.min.pastemin.pro.yearly' in binary
    assert b'tools.min.pastemin.pro.lifetime' in binary

    release_app = build_app(folder / 'PasteminRelease.app')
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
print('Pastemin build: unified sandboxed app passed')
