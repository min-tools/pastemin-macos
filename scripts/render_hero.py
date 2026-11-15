#!/usr/bin/env python3
"""Render the README heroes, Mac App Store screenshots, and GitHub profile images from a fictional
clipboard history, without launching the app."""
from pathlib import Path
import argparse
import subprocess
import tempfile

from build import ROOT, swift_compiler

# PasteminMain.swift holds the app's own entry point; the renderer supplies its own.
SOURCES = [
    path for path in sorted((ROOT / 'Sources/PasteminApp').glob('*.swift'))
    if path.name != 'PasteminMain.swift'
]
SOURCES.append(ROOT / 'scripts/render_hero.swift')

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--readme', type=Path, default=ROOT / 'docs/images',
    help='directory for hero-light.png and hero-dark.png (default: docs/images)',
)
parser.add_argument(
    '--app-store', type=Path, default=ROOT / 'private/app-store/screenshots',
    help='directory for the 2880x1800 App Store set (default: private/app-store/screenshots)',
)
parser.add_argument('--no-app-store', action='store_true', help='skip the App Store set')
parser.add_argument(
    '--profile', type=Path,
    help='also write 900-pixel pastemin-hero-light.png and pastemin-hero-dark.png here, '
         'for the GitHub organization profile',
)
args = parser.parse_args()

# Build the renderer from the real app sources so the images show the actual views.
with tempfile.TemporaryDirectory(prefix='pastemin-hero-', dir='/private/tmp') as directory:
    folder = Path(directory)
    executable = folder / 'render-hero'
    command = swift_compiler() + [
        '-parse-as-library', '-swift-version', '5', '-module-name', 'PasteminHero',
        '-D', 'PASTEMIN_SCREENSHOTS',
        '-module-cache-path', str(folder / 'modules'), '-target', 'arm64-apple-macos14.0',
        *map(str, SOURCES), '-framework', 'AppKit', '-framework', 'Carbon',
        '-framework', 'Accelerate', '-framework', 'CryptoKit', '-framework', 'ImageIO',
        '-framework', 'StoreKit', '-o', str(executable),
    ]
    subprocess.run(command, check=True)
    # The renderer stages the fictional history in a throwaway store under this folder.
    arguments = [str(executable), str(folder), '--readme', str(args.readme.resolve())]
    if not args.no_app_store:
        arguments += ['--app-store', str(args.app_store.resolve())]
    if args.profile:
        arguments += ['--profile', str(args.profile.resolve())]
    subprocess.run(arguments, check=True, timeout=300)
