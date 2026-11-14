#!/usr/bin/env python3
"""Exercise saved items, tags, retention, and the five-item Free allowance."""
from pathlib import Path
import subprocess
import tempfile

from build import ROOT, swift_compiler

# Keep compiled code, module caches and fixture history in one disposable
# folder.
with tempfile.TemporaryDirectory(prefix='pastemin-stars-', dir='/private/tmp') as directory:
    folder = Path(directory)
    binary = folder / 'stars-test'
    sources = ROOT / 'Sources/PasteminApp'
    subprocess.run(swift_compiler() + [
        '-parse-as-library', '-swift-version', '5', '-warnings-as-errors',
        '-module-cache-path', str(folder / 'modules'), '-target', 'arm64-apple-macos14.0',
        str(sources / 'Localization.swift'), str(sources / 'ClipboardModels.swift'),
        str(sources / 'ClipboardHistoryStore.swift'), str(sources / 'ClipboardViewModel.swift'),
        str(ROOT / 'scripts/test_stars.swift'), '-o', str(binary),
    ], check=True)
    # The Swift fixture uses standalone pasteboard items, not the system
    # clipboard.
    subprocess.run([str(binary), str(folder / 'history')], check=True, timeout=60)
