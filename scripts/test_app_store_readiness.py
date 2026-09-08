#!/usr/bin/env python3
"""Ensure the offline App Store release audit is clear."""
from check_app_store import blockers


found = blockers()
assert found == [], '\n'.join(found)
print('Pastemin App Store: offline release audit passed')
