#!/usr/bin/env python3
"""Ensure the offline App Store release audit is clear."""
from check_app_store import blockers, valid_release_version


# Monthly releases and patches remain valid even when built in a later month.
for version, build in [('26.9', '2026092600'), ('26.9.1', '2026100100'), ('26.10', '2026100101'), ('27.1', '2027010100')]:
    assert valid_release_version(version, build), (version, build)

# Reject the retired date format, padded/invalid months, and malformed builds.
for version in ['2026.09.26', '26.09', '26.0', '26.13', '26.9.0', '26.9.01', '26.9.1.1', '', None]:
    assert not valid_release_version(version, '2026092600'), version
for build in ['20260926', '20260926000', '2026130100', '2026023000', '20260926ab', '', None]:
    assert not valid_release_version('26.9', build), build

found = blockers()
assert found == [], '\n'.join(found)
print('Pastemin App Store: offline release audit passed')
