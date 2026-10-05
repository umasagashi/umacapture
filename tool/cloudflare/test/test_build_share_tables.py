# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The append-only refusal of build_share_tables.py, run as the deploy runs it.

    uv run tool/cloudflare/test/test_build_share_tables.py

Each case builds a synthetic module archive (no game text) in a temporary directory and runs the
script as a subprocess with --archive, --previous and --out pointing there, so nothing outside the
temporary directory is read or written and no request is made.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build_share_tables.py"
GID_KEYS = {
    "character.card": "character_card_info.json",
    "skill.name": "skill_info.json",
    "factor.name": "factor_info.json",
    "race_title.name": "race_title_info.json",
}


def labels(extra: int = 0) -> dict:
    """labels.json with two names per key, plus `extra` names appended to every gid key."""
    out = {key: [f"{key} 0", f"{key} 1"] for key in ("aptitude.name", "campaign_field.name", "record_type.name")}
    for key in GID_KEYS:
        out[key] = [f"{key} {sid}" for sid in range(2 + extra)]
    return out


def write_archive(path: Path, names: dict) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("modules/version_info.json", json.dumps({"recognizer_version": "2026-01-01T00:00:00Z"}))
        archive.writestr("modules/labels.json", json.dumps(names))
        for key, source in GID_KEYS.items():
            info = [{"sid": sid, "gid": 1000 + sid} for sid in range(len(names[key]))]
            archive.writestr(f"modules/{source}", json.dumps(info))


class AppendOnlyTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.out = self.dir / "tables.generated.json"
        self.previous = self.dir / "previous.json"

    def run_script(self, names: dict) -> subprocess.CompletedProcess:
        write_archive(self.dir / "modules.zip", names)
        argv = ["--archive", self.dir / "modules.zip", "--previous", self.previous, "--out", self.out]
        return subprocess.run([sys.executable, SCRIPT, *map(str, argv)], capture_output=True, text=True)

    def deploy_baseline(self, names: dict) -> None:
        self.assertEqual(self.run_script(names).returncode, 0)
        self.out.replace(self.previous)

    def test_appended_names_pass(self) -> None:
        """Control: a newer set that only appends is accepted and written."""
        self.deploy_baseline(labels())
        result = self.run_script(labels(extra=1))
        self.assertEqual(result.returncode, 0, result.stderr)
        tables = json.loads(self.out.read_text(encoding="utf-8"))
        self.assertEqual(len(tables["names"]["skill.name"]), 3)
        self.assertNotIn("campaign_field.name", tables["names"])

    def test_reordered_names_stop(self) -> None:
        """A baseline that is not a prefix of the new names stops the script and writes nothing."""
        self.deploy_baseline(labels())
        names = labels(extra=1)
        names["skill.name"].insert(0, names["skill.name"].pop())
        result = self.run_script(names)
        self.assertEqual(result.returncode, 1)
        self.assertIn("names[skill.name] no longer starts with the 2 entries deployed before", result.stderr)
        self.assertFalse(self.out.exists())

    def test_removed_key_stops(self) -> None:
        """A key the baseline names that the new set dropped stops the script."""
        self.deploy_baseline(labels())
        names = labels()
        del names["aptitude.name"]
        result = self.run_script(names)
        self.assertEqual(result.returncode, 1)
        self.assertIn("names[aptitude.name] is gone", result.stderr)


if __name__ == "__main__":
    unittest.main()
