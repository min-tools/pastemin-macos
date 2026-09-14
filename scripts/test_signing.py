#!/usr/bin/env python3
"""Verify Mac App Store profile validation and distribution entitlements."""
from datetime import datetime, timedelta, timezone

from build import BUNDLE_IDENTIFIER, app_store_entitlements_from_profile


def profile(**entitlement_overrides):
    team = 'ABCDE12345'
    entitlements = {
        'com.apple.application-identifier': f'{team}.{BUNDLE_IDENTIFIER}',
        'com.apple.developer.team-identifier': team,
        'com.apple.security.get-task-allow': False,
    }
    entitlements.update(entitlement_overrides)
    return {
        'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=30),
        'TeamIdentifier': [team],
        'Platform': ['OSX'],
        'DeveloperCertificates': [b'fixture-certificate'],
        'Entitlements': entitlements,
    }


def rejected(candidate, message):
    try:
        app_store_entitlements_from_profile(candidate)
    except ValueError:
        return
    raise AssertionError(message)


validated = app_store_entitlements_from_profile(profile())
assert validated['com.apple.security.app-sandbox'] is True
assert validated['com.apple.application-identifier'] == f'ABCDE12345.{BUNDLE_IDENTIFIER}'
assert validated['com.apple.developer.team-identifier'] == 'ABCDE12345'

expired = profile()
expired['ExpirationDate'] = datetime.now(timezone.utc) - timedelta(seconds=1)
rejected(expired, 'Expired profiles must be rejected')
rejected(
    profile(**{'com.apple.application-identifier': 'ABCDE12345.org.example.other'}),
    'Profiles for another app must be rejected',
)
rejected(
    profile(**{'com.apple.security.get-task-allow': True}),
    'Development profiles must be rejected',
)

conflicting_team = profile()
conflicting_team['TeamIdentifier'] = ['OTHER12345']
rejected(conflicting_team, 'Conflicting team identifiers must be rejected')

device_profile = profile()
device_profile['ProvisionedDevices'] = ['fixture-device']
rejected(device_profile, 'Device profiles must be rejected')

developer_id_profile = profile()
developer_id_profile['ProvisionsAllDevices'] = True
rejected(developer_id_profile, 'Developer ID profiles must be rejected')
print('Pastemin signing: App Store provisioning profile validation passed')
