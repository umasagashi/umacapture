# /// script
# requires-python = ">=3.11"
# ///
"""Compare every pinned file in tool/web_deps.json ("files", keyed by the path relative to web/)
with the same relative path under build/web and under web/, byte-for-byte (sha256). Read-only. Exit 1 on any mismatch.

    uv run tool/web_e2e/check_build_pins.py [REPO]

It does not cover main.dart.js, which nothing pins."""
import hashlib, json, sys
from pathlib import Path
repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]; deps = json.loads((repo / "tool/web_deps.json").read_text(encoding="utf-8"))
bad = n = 0
for k, v in deps["files"].items():
    for base in ("build/web", "web"):
        p = repo / base / k
        h = hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else None
        ok = h == v["sha256"]; n += 1; bad += not ok
        if not ok or "umacapture_core" in k:
            print("OK " if ok else "BAD", base, k, (h or "missing")[:16], v["sha256"][:16])
print(f"checked {n} mismatches {bad}")
sys.exit(1 if bad else 0)
