#!/usr/bin/env python3
"""Build the sandboxed Pastemin app used locally and for the Mac App Store."""
from pathlib import Path
import argparse
from datetime import datetime, timezone
import hashlib
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
APP_ENTITLEMENTS = ROOT / 'Configuration/Pastemin.entitlements'
BUNDLE_IDENTIFIER = 'tools.min.pastemin'


def app_store_entitlements_from_profile(profile_data):
    """Return the distribution entitlements authorized by a decoded Mac profile."""
    profile_entitlements = profile_data.get('Entitlements')
    if not isinstance(profile_entitlements, dict):
        raise ValueError('The provisioning profile has no entitlements dictionary.')

    expiration = profile_data.get('ExpirationDate')
    if not isinstance(expiration, datetime):
        raise ValueError('The provisioning profile has no expiration date.')
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        raise ValueError('The provisioning profile has expired.')
    if profile_entitlements.get('com.apple.security.get-task-allow') is True:
        raise ValueError('A development provisioning profile cannot package an App Store build.')
    if profile_data.get('ProvisionedDevices'):
        raise ValueError('A device provisioning profile cannot package an App Store build.')
    if profile_data.get('ProvisionsAllDevices') is True:
        raise ValueError('A Developer ID provisioning profile cannot package an App Store build.')
    platforms = profile_data.get('Platform')
    if not isinstance(platforms, list) or 'OSX' not in platforms:
        raise ValueError('The provisioning profile is not for macOS.')
    certificates = profile_data.get('DeveloperCertificates')
    if not isinstance(certificates, list) or not certificates or not all(
        isinstance(certificate, bytes) for certificate in certificates
    ):
        raise ValueError('The provisioning profile contains no distribution certificate.')

    application_identifier = (
        profile_entitlements.get('com.apple.application-identifier')
        or profile_entitlements.get('application-identifier')
    )
    expected_suffix = f'.{BUNDLE_IDENTIFIER}'
    if not isinstance(application_identifier, str) or not application_identifier.endswith(expected_suffix):
        raise ValueError(
            f'The provisioning profile does not match bundle identifier {BUNDLE_IDENTIFIER}.'
        )
    app_identifier_prefix = application_identifier[:-len(expected_suffix)]
    if not app_identifier_prefix or '.' in app_identifier_prefix:
        raise ValueError('The provisioning profile contains an invalid application identifier.')

    team_identifier = profile_entitlements.get('com.apple.developer.team-identifier')
    profile_teams = profile_data.get('TeamIdentifier')
    if not team_identifier and isinstance(profile_teams, list) and profile_teams:
        team_identifier = profile_teams[0]
    if not isinstance(team_identifier, str) or not team_identifier:
        raise ValueError('The provisioning profile contains no team identifier.')
    if isinstance(profile_teams, list) and profile_teams and team_identifier not in profile_teams:
        raise ValueError('The provisioning profile contains conflicting team identifiers.')

    entitlements = plistlib.loads(APP_ENTITLEMENTS.read_bytes())
    entitlements['com.apple.application-identifier'] = application_identifier
    entitlements['com.apple.developer.team-identifier'] = team_identifier
    return entitlements


def decode_provisioning_profile(profile):
    """Decode and validate the supplied Mac App Store provisioning profile."""
    profile = Path(profile).expanduser().resolve()
    if not profile.is_file():
        raise ValueError(f'Provisioning profile does not exist: {profile}')
    try:
        decoded = subprocess.check_output(
            ['security', 'cms', '-D', '-i', str(profile)],
            stderr=subprocess.STDOUT,
        )
        profile_data = plistlib.loads(decoded)
    except (subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise ValueError('The provisioning profile could not be decoded.') from error
    entitlements = app_store_entitlements_from_profile(profile_data)
    certificate_hashes = {
        hashlib.sha256(certificate).digest()
        for certificate in profile_data['DeveloperCertificates']
    }
    return profile, entitlements, certificate_hashes


def signed_entitlements(app):
    data = subprocess.check_output(
        ['codesign', '-d', '--xml', '--entitlements', '-', str(app)],
        stderr=subprocess.DEVNULL,
    )
    return plistlib.loads(data)


def verify_distribution_signature(app, expected_entitlements, authorized_certificate_hashes):
    """Verify that codesign kept the profile identifiers in the final signature."""
    actual = signed_entitlements(app)
    for key, value in expected_entitlements.items():
        if actual.get(key) != value:
            raise ValueError(f'The signed app has an unexpected {key} entitlement.')

    details = subprocess.check_output(
        ['codesign', '-d', '--verbose=4', str(app)],
        stderr=subprocess.STDOUT,
        text=True,
    )
    match = re.search(r'^TeamIdentifier=(.+)$', details, re.MULTILINE)
    expected_team = expected_entitlements['com.apple.developer.team-identifier']
    if match is None or match.group(1).strip() != expected_team:
        raise ValueError('The signing certificate does not match the provisioning profile team.')

    with tempfile.TemporaryDirectory(prefix='pastemin-signature-certificates-') as folder:
        prefix = Path(folder) / 'certificate'
        subprocess.run([
            'codesign', '-d', '--extract-certificates', str(prefix), str(app)
        ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        leaf = Path(f'{prefix}0')
        if not leaf.is_file() or hashlib.sha256(leaf.read_bytes()).digest() not in authorized_certificate_hashes:
            raise ValueError('The signing certificate is not authorized by the provisioning profile.')


def sdk_path():
    return subprocess.check_output(
        ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True
    ).strip()


def swift_compiler():
    return ['xcrun', 'swiftc', '-sdk', sdk_path()]


def build_app(
    output,
    *,
    configuration='Release',
    sign=True,
    identity='-',
    provisioning_profile=None,
):
    output = Path(output).expanduser().absolute()
    if output.suffix != '.app' or output.is_symlink():
        raise ValueError('The output must be an .app directory, not a symbolic link.')
    if not sign and identity != '-':
        raise ValueError('A signing identity cannot be used with --unsigned.')
    if sign and identity != '-' and not provisioning_profile:
        raise ValueError('A distribution build requires an App Store provisioning profile.')
    if provisioning_profile and (not sign or identity == '-'):
        raise ValueError('A provisioning profile requires a distribution signing identity.')

    profile = None
    distribution_entitlements = None
    authorized_certificate_hashes = None
    if provisioning_profile:
        profile, distribution_entitlements, authorized_certificate_hashes = (
            decode_provisioning_profile(provisioning_profile)
        )
    sources = sorted((ROOT / 'Sources/PasteminApp').glob('*.swift'))
    if not sources:
        raise ValueError('Pastemin source files are missing.')
    output.parent.mkdir(parents=True, exist_ok=True)

    # Assemble and verify away from the destination so failed builds keep the last app intact.
    with tempfile.TemporaryDirectory(prefix='pastemin-build-', dir=output.parent) as folder:
        work = Path(folder)
        bundle = work / output.name
        executable = bundle / 'Contents/MacOS/Pastemin'
        resources = bundle / 'Contents/Resources'
        executable.parent.mkdir(parents=True)
        resources.mkdir(parents=True)
        command = swift_compiler() + [
            '-parse-as-library', '-swift-version', '5', '-module-name', 'PasteminApp',
            '-module-cache-path', str(work / 'modules'), '-target', 'arm64-apple-macos14.0'
        ]
        if configuration == 'Release':
            # Ask Swift to emit crash symbols for the optimized release executable.
            command += ['-O', '-whole-module-optimization', '-g']
        else:
            command += ['-Onone', '-D', 'DEBUG']
        command += [*map(str, sources), '-framework', 'AppKit', '-framework', 'Carbon',
                    '-framework', 'CryptoKit', '-framework', 'ImageIO',
                    '-framework', 'StoreKit', '-o', str(executable)]
        subprocess.run(command, check=True, cwd=work)
        symbols = None
        if configuration == 'Release':
            # Swift places the completed dSYM beside the executable; move it outside the app.
            generated_symbols = executable.with_suffix('.dSYM')
            symbols = work / f'{output.name}.dSYM'
            if not (generated_symbols / 'Contents/Resources/DWARF/Pastemin').is_file():
                raise ValueError('The release build did not produce Pastemin crash symbols.')
            generated_symbols.replace(symbols)
        shutil.copy2(ROOT / 'PasteminInfo.plist', bundle / 'Contents/Info.plist')
        shutil.copy2(ROOT / 'Resources/AppIcon.icns', resources / 'AppIcon.icns')
        shutil.copy2(ROOT / 'PrivacyInfo.xcprivacy', resources / 'PrivacyInfo.xcprivacy')
        shutil.copy2(
            ROOT / 'Sources/PasteminApp/Resources/PRIVACY.md',
            resources / 'PRIVACY.md',
        )
        localizations = sorted((ROOT / 'Resources').glob('*.lproj'))
        if not localizations:
            raise ValueError('Pastemin localization resources are missing.')
        for localization in localizations:
            strings = localization / 'Localizable.strings'
            if not strings.is_file():
                raise ValueError(f'Localization is missing Localizable.strings: {localization.name}')
            shutil.copytree(localization, resources / localization.name)
        if profile:
            shutil.copy2(profile, bundle / 'Contents/embedded.provisionprofile')
        plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())

        if sign:
            # App Store distribution identities require a trusted timestamp.
            sign_command = ['codesign', '--force', '--sign', identity]
            if identity != '-':
                sign_command += ['--timestamp']
            entitlements_path = APP_ENTITLEMENTS
            if distribution_entitlements is not None:
                entitlements_path = work / 'AppStoreDistribution.entitlements'
                with entitlements_path.open('wb') as file:
                    plistlib.dump(distribution_entitlements, file, sort_keys=True)
            sign_command += [
                '--entitlements', str(entitlements_path), str(bundle)
            ]
            subprocess.run(sign_command, check=True)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)], check=True)
            if distribution_entitlements is not None:
                verify_distribution_signature(
                    bundle,
                    distribution_entitlements,
                    authorized_certificate_hashes,
                )
        previous = work / f'previous-{output.name}'
        symbols_output = output.with_name(f'{output.name}.dSYM')
        previous_symbols = work / f'previous-{symbols_output.name}'
        # Validate existing artifacts before moving either one out of the way.
        if output.exists() and not (output / 'Contents/Info.plist').is_file():
            raise ValueError('Refusing to replace a directory that is not an app bundle.')
        if (symbols is not None and symbols_output.exists()
                and not (symbols_output / 'Contents/Info.plist').is_file()):
            raise ValueError('Refusing to replace a directory that is not a dSYM bundle.')
        if output.exists():
            output.replace(previous)
        if symbols is not None and symbols_output.exists():
            symbols_output.replace(previous_symbols)
        try:
            # All paths share a parent filesystem, so each final artifact swap is atomic.
            bundle.replace(output)
            if symbols is not None:
                symbols.replace(symbols_output)
        except Exception:
            if output.exists():
                output.replace(work / f'failed-{output.name}')
            if previous.exists():
                previous.replace(output)
            if symbols is not None and symbols_output.exists():
                symbols_output.replace(work / f'failed-{symbols_output.name}')
            if previous_symbols.exists():
                previous_symbols.replace(symbols_output)
            raise
    print(f'Built {output} (sandboxed, arm64)', flush=True)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--identity', default='-', help='codesign identity; default is ad-hoc signing')
    parser.add_argument('--provisioning-profile', type=Path)
    parser.add_argument('--unsigned', action='store_true')
    args = parser.parse_args()
    build_app(
        args.output or ROOT / 'build/Pastemin.app',
        configuration=args.configuration,
        sign=not args.unsigned,
        identity=args.identity,
        provisioning_profile=args.provisioning_profile,
    )
