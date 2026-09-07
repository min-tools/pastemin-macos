#!/usr/bin/env python3
"""Run Pastemin checks without touching the user's real clipboard history."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
tests = sorted(path for path in (ROOT / 'scripts').glob('test_*.py') if path.name != 'test_all.py')
for test in tests:
    subprocess.run([sys.executable, str(test)], cwd=ROOT, check=True)
    print(f'PASS {test.stem}', flush=True)
print(f'{len(tests)}/{len(tests)} suites passed', flush=True)
