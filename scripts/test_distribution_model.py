#!/usr/bin/env python3
"""Verify that public builds cannot receive the ignored local access override."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
EDITION = ROOT / "Sources/PasteminApp/BuildEdition.swift"
STORE = (ROOT / "Sources/PasteminApp/PasteminStore.swift").read_text()
assert "PasteminEdition.localAccess" in STORE
assert "var hasFullAccess: Bool" in STORE
assert "guard developerOverride == nil" in STORE
assert "func beginAppTrial(now: Date = Date())" in STORE
assert "startIfNeeded: Bool = false" in STORE

with tempfile.TemporaryDirectory(prefix="pastemin-distribution-", dir="/private/tmp") as folder:
    folder = Path(folder)
    main = folder / "main.swift"
    main.write_text('''precondition(PasteminEdition.bundleIdentifier == "tools.min.pastemin")
precondition(PasteminEdition.localAccess == nil)
print("Public Pastemin requires verified access")
''')
    public = folder / "public"
    subprocess.run(["swiftc", "-module-cache-path", str(folder / "modules"), str(EDITION), str(main), "-o", str(public)], check=True)
    subprocess.run([str(public)], check=True)
    missing = subprocess.run(["swiftc", "-typecheck", "-module-cache-path", str(folder / "modules"), "-D", "PASTEMIN_LOCAL_BUILD", str(EDITION)], capture_output=True, text=True)
    assert missing.returncode != 0 and "PasteminLocalAccess" in missing.stderr
    conflict = subprocess.run(["swiftc", "-typecheck", "-module-cache-path", str(folder / "modules"), "-D", "PASTEMIN_LOCAL_BUILD", "-D", "PASTEMIN_APP_STORE", str(EDITION)], capture_output=True, text=True)
    assert conflict.returncode != 0 and "Local access must not be included" in conflict.stderr
