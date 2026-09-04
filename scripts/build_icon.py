#!/usr/bin/env python3
"""Build the Pastemin ICNS file from its 1024-pixel master artwork."""
from pathlib import Path
import struct
import subprocess
import tempfile

from build import ROOT

SOURCE = ROOT / 'Resources/AppIcon-1024.png'
OUTPUT = ROOT / 'Resources/AppIcon.icns'

# Retina 16/32-point chunks also provide clean downsampling for 1x displays. Do not
# add manually packed icp4/icp5 PNG chunks: current ImageIO decodes them as legacy
# low-resolution payloads and renders color noise.
REPRESENTATIONS = (
    ('ic11', 32),
    ('ic12', 64),
    ('ic07', 128),
    ('ic13', 256),
    ('ic08', 256),
    ('ic14', 512),
    ('ic09', 512),
    ('ic10', 1024),
)


def build_icon(source=SOURCE, output=OUTPUT):
    source = Path(source)
    output = Path(output)
    if not source.is_file():
        raise FileNotFoundError(f'Icon master is missing: {source}')

    chunks = []
    with tempfile.TemporaryDirectory(prefix='clipboard-icon-', dir='/private/tmp') as folder:
        folder = Path(folder)
        for index, (chunk_type, size) in enumerate(REPRESENTATIONS):
            image = folder / f'{index}-{size}.png'
            subprocess.run([
                'sips', '-z', str(size), str(size), str(source), '--out', str(image)
            ], check=True, stdout=subprocess.DEVNULL)
            payload = image.read_bytes()
            chunks.append(chunk_type.encode('ascii') + struct.pack('>I', len(payload) + 8) + payload)

        candidate = folder / 'AppIcon.icns'
        body = b''.join(chunks)
        candidate.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
        output.parent.mkdir(parents=True, exist_ok=True)
        candidate.replace(output)
    print(f'Built {output}', flush=True)
    return output


if __name__ == '__main__':
    build_icon()
