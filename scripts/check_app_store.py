#!/usr/bin/env python3
"""Report local release failures and optionally verify public submission URLs."""
from pathlib import Path
import plistlib
import re
import socket
import struct
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from check_localizations import localization_issues

ROOT = Path(__file__).resolve().parent.parent
PUBLIC_URLS = (
    'https://min.tools/pastemin/',
    'https://min.tools/pastemin/privacy/',
    'https://min.tools/pastemin/support/',
)


def png_dimensions(path):
    data = path.read_bytes()[:24]
    if len(data) != 24 or not data.startswith(b'\x89PNG\r\n\x1a\n'):
        return None
    return struct.unpack('>II', data[16:24])


def icns_chunks(path):
    data = path.read_bytes()
    if len(data) < 8 or data[:4] != b'icns' or struct.unpack('>I', data[4:8])[0] != len(data):
        return None
    chunks = []
    offset = 8
    while offset < len(data):
        if offset + 8 > len(data):
            return None
        chunk_type = data[offset:offset + 4].decode('ascii', errors='replace')
        chunk_size = struct.unpack('>I', data[offset + 4:offset + 8])[0]
        if chunk_size < 8 or offset + chunk_size > len(data):
            return None
        chunks.append(chunk_type)
        offset += chunk_size
    return chunks


def blockers(check_online=False):
    issues = []
    _, localization_errors = localization_issues()
    issues.extend(f'Localization: {error}' for error in localization_errors)
    info = plistlib.loads((ROOT / 'PasteminInfo.plist').read_bytes())
    app_entitlements = plistlib.loads(
        (ROOT / 'Configuration/Pastemin.entitlements').read_bytes()
    )
    manifest = plistlib.loads((ROOT / 'PrivacyInfo.xcprivacy').read_bytes())
    build = (ROOT / 'scripts/build.py').read_text()
    package = (ROOT / 'scripts/package_app_store.py').read_text()
    products = (ROOT / 'Sources/PasteminApp/PasteminEntitlementLogic.swift').read_text()
    store = (ROOT / 'Sources/PasteminApp/PasteminStore.swift').read_text()
    monitor = (ROOT / 'Sources/PasteminApp/ClipboardMonitor.swift').read_text()
    banner = (ROOT / 'Sources/PasteminApp/AccessBanner.swift').read_text()
    readme = (ROOT / 'README.md').read_text()
    license_text = (ROOT / 'LICENSE').read_text()
    privacy = (ROOT / 'PRIVACY.md').read_text()
    bundled_privacy = (ROOT / 'Sources/PasteminApp/Resources/PRIVACY.md').read_text()
    distribution = (ROOT / 'docs/distribution.md').read_text()

    expected_info = {
        'CFBundleIdentifier': 'tools.min.pastemin',
        'CFBundleExecutable': 'Pastemin',
        'CFBundleDisplayName': 'Pastemin',
        'CFBundleShortVersionString': '2026.09.23',
        'CFBundleVersion': '2026092300',
        'NSHumanReadableCopyright': '© 2026 Ilia Ross',
        'LSMinimumSystemVersion': '14.0',
        'LSApplicationCategoryType': 'public.app-category.productivity',
        'LSUIElement': True,
        'ITSAppUsesNonExemptEncryption': False,
    }
    for key, value in expected_info.items():
        if info.get(key) != value:
            issues.append(f'Info.plist has an unexpected {key}.')
    version = info.get('CFBundleShortVersionString', '')
    build_number = info.get('CFBundleVersion', '')
    if re.fullmatch(r'\d{4}\.\d{2}\.\d{2}', version) is None or not build_number.startswith(version.replace('.', '')):
        issues.append('The version does not use the YYYY.MM.DD and YYYYMMDDNN release model.')
    if not app_entitlements.get('com.apple.security.app-sandbox'):
        issues.append('The Pastemin app is not sandboxed.')
    if "'-target', 'arm64-apple-macos14.0'" not in build:
        issues.append('The release target is not arm64 macOS 14.')
    if "'-whole-module-optimization', '-g'" not in build:
        issues.append('The release build must include dSYM crash information.')
    if 'PASTEMIN_APP_STORE' in build or 'DISTRIBUTIONS' in build:
        issues.append('The build script still contains separate edition logic.')
    signing_markers = (
        'com.apple.application-identifier',
        'com.apple.developer.team-identifier',
        'DeveloperCertificates',
        '--extract-certificates',
    )
    if not all(marker in build for marker in signing_markers):
        issues.append('Distribution signing does not validate profile identifiers and certificate.')
    if 'productbuild' not in package or "'pkgutil', '--check-signature'" not in package:
        issues.append('The App Store package is not built and signature-checked.')
    if 'tools.min.pastemin.pro.yearly' not in products:
        issues.append('The yearly StoreKit product identifier is missing.')
    if 'tools.min.pastemin.pro.lifetime' not in products:
        issues.append('The lifetime StoreKit product identifier is missing.')
    if 'Transaction.currentEntitlements' not in store or 'case .verified(let transaction)' not in store:
        issues.append('StoreKit access is not based on verified current entitlements.')
    if 'AppStore.sync()' not in store:
        issues.append('Restore Purchases does not synchronize with the App Store.')
    if 'AccessLimitedBanner' not in banner or 'restorePurchases' not in banner:
        issues.append('The limited-history banner does not offer purchase and restore actions.')
    if 'lastChangeCount = currentChangeCount()' not in monitor:
        issues.append('Clipboard monitoring can capture changes made while access was disabled.')

    if manifest.get('NSPrivacyTracking') is not False:
        issues.append('The privacy manifest tracking declaration is missing.')
    if manifest.get('NSPrivacyCollectedDataTypes') != []:
        issues.append('The privacy manifest unexpectedly declares collected data.')
    accessed = manifest.get('NSPrivacyAccessedAPITypes', [])
    if not any(
        item.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryUserDefaults'
        and 'CA92.1' in item.get('NSPrivacyAccessedAPITypeReasons', [])
        for item in accessed
    ):
        issues.append('The UserDefaults required-reason declaration is missing.')

    if png_dimensions(ROOT / 'Resources/AppIcon-1024.png') != (1024, 1024):
        issues.append('The App Store icon master is not a 1024-pixel square PNG.')
    expected_chunks = ['ic11', 'ic12', 'ic07', 'ic13', 'ic08', 'ic14', 'ic09', 'ic10']
    if icns_chunks(ROOT / 'Resources/AppIcon.icns') != expected_chunks:
        issues.append('The ICNS file has missing, corrupt, or unsafe representations.')

    if 'Copyright © 2026 Ilia Ross.' not in license_text:
        issues.append('The source-available license notice is missing.')
    if ('PolyForm Strict License 1.0.0' not in license_text
            or 'Additional Permission for Personal Modification' not in license_text
            or 'Additional Permission for Contributions' not in license_text):
        issues.append('The source-available license is incomplete.')
    if 'source-available' not in readme or '## Build' not in readme:
        issues.append('The source release is not clearly documented.')
    if 'Clipboard content never leaves the Mac.' not in readme:
        issues.append('The README privacy summary changed unexpectedly.')
    required_privacy_sections = (
        'Data on your Mac', 'Clipboard access and automatic paste',
        'Retention and deletion', 'Your choices', 'Changes and contact',
    )
    if privacy != bundled_privacy:
        issues.append('The repository and bundled privacy policies differ.')
    if any(section not in privacy for section in required_privacy_sections):
        issues.append('The privacy policy is missing a required section.')
    if 'never uploaded by Pastemin' not in privacy:
        issues.append('The privacy policy does not state the clipboard upload boundary.')
    public_text = '\n'.join((readme, privacy, distribution, store, banner))
    for url in PUBLIC_URLS:
        if url.rstrip('/') not in public_text:
            issues.append(f'The public product links are missing {url}.')

    if check_online:
        for url in PUBLIC_URLS:
            try:
                host = re.match(r'https://([^/]+)', url).group(1)
                socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM)
                request = Request(url, headers={'User-Agent': 'Pastemin release checker/1.0'})
                with urlopen(request, timeout=10) as response:
                    if response.status >= 400:
                        issues.append(f'Public submission URL returned HTTP {response.status}: {url}')
            except HTTPError as error:
                issues.append(f'Public submission URL returned HTTP {error.code}: {url}')
            except (OSError, URLError, AttributeError) as error:
                issues.append(f'Public submission URL is unavailable: {url} ({error})')
    return issues


if __name__ == '__main__':
    unknown = [argument for argument in sys.argv[1:] if argument != '--online']
    if unknown:
        print(f'Usage: {Path(sys.argv[0]).name} [--online]', file=sys.stderr)
        sys.exit(2)
    found = blockers(check_online='--online' in sys.argv[1:])
    if found:
        print('App Store release is blocked:')
        for issue in found:
            print(f'- {issue}')
        sys.exit(1)
    print('App Store release metadata checks passed')
