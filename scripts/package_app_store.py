#!/usr/bin/env python3
"""Build and package Pastemin for upload to App Store Connect."""
from pathlib import Path
import argparse
import subprocess
import tempfile

from build import ROOT, build_app


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--application-identity', required=True)
    parser.add_argument('--installer-identity', required=True)
    parser.add_argument('--provisioning-profile', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/app-store/Pastemin.pkg')
    args = parser.parse_args()

    package = args.output.expanduser().absolute()
    if package.suffix != '.pkg' or package.is_symlink():
        raise ValueError('The package output must be a regular .pkg file.')
    package.parent.mkdir(parents=True, exist_ok=True)
    if package.exists():
        if not package.is_file():
            raise ValueError('The package output must be a regular .pkg file.')

    # Keep any previous valid package until its replacement builds and verifies successfully.
    with tempfile.TemporaryDirectory(prefix='pastemin-store-package-', dir=package.parent) as folder:
        work = Path(folder)
        app = build_app(
            work / 'Pastemin.app',
            identity=args.application_identity,
            provisioning_profile=args.provisioning_profile,
            app_store=True,
        )
        candidate = work / 'Pastemin.pkg'
        subprocess.run([
            'productbuild', '--component', str(app), '/Applications',
            '--sign', args.installer_identity, str(candidate),
        ], check=True)
        subprocess.run(['pkgutil', '--check-signature', str(candidate)], check=True)
        candidate.replace(package)
    print(f'Packaged {package} for App Store Connect', flush=True)
