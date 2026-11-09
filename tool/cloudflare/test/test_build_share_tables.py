# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The name tables of a module archive, and load_share_tables.py, which keeps them in each target's D1.

    uv run tool/cloudflare/test/test_build_share_tables.py

Each case builds a synthetic module archive (no game text) in a temporary directory. The loader runs
against a fake D1 (SQLite with the Worker's migrations), so nothing outside the temporary directory is
read or written and no request is made.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL_DIR))
import build_share_tables  # noqa: E402
import load_share_tables  # noqa: E402

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


def tags_of(sid: int) -> list[str]:
    return [f"tag {sid}"] if sid % 2 else [f"tag {sid}", "second"]


def write_archive(path: Path, names: dict) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("modules/version_info.json", json.dumps({"recognizer_version": "2026-01-01T00:00:00Z"}))
        archive.writestr("modules/labels.json", json.dumps(names))
        for key, source in GID_KEYS.items():
            # Listed in reverse sid order, so the columns have to be read by sid, not by position.
            info = [{"sid": sid, "gid": 1000 + sid, "tags": tags_of(sid)} for sid in reversed(range(len(names[key])))]
            archive.writestr(f"modules/{source}", json.dumps(info))


class AppendOnlyTest(unittest.TestCase):
    """The strict check (load_share_tables.py --baseline) between the tables of two archives."""

    def setUp(self) -> None:
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.previous = self.tables(labels())

    def tables(self, names: dict) -> dict:
        write_archive(self.dir / "modules.zip", names)
        return build_share_tables.build_tables((self.dir / "modules.zip").read_bytes())

    def test_appended_names_pass(self) -> None:
        """Control: a newer set that only appends passes."""
        tables = self.tables(labels(extra=1))
        self.assertEqual(build_share_tables.append_only_violations(self.previous, tables), [])
        self.assertEqual(len(tables["names"]["skill.name"]), 3)
        self.assertNotIn("campaign_field.name", tables["names"])
        self.assertEqual(tables["tags"], {"factor.name": [tags_of(sid) for sid in range(3)]})

    def test_reordered_names_stop(self) -> None:
        """A previous list that is not a prefix of the new one is a violation."""
        names = labels(extra=1)
        names["skill.name"].insert(0, names["skill.name"].pop())
        self.assertIn(
            "names[skill.name] no longer starts with the 2 entries deployed before",
            build_share_tables.append_only_violations(self.previous, self.tables(names)),
        )

    def test_removed_key_stops(self) -> None:
        """A key the previous tables name that the new set dropped is a violation."""
        names = labels()
        del names["aptitude.name"]
        self.assertIn(
            "names[aptitude.name] is gone", build_share_tables.append_only_violations(self.previous, self.tables(names))
        )


# The schema the share Worker's D1 is migrated to, triggers included, applied to SQLite (which D1 runs).
MIGRATIONS = sorted((TOOL_DIR.parents[1] / "server" / "migrations").glob("*.sql"))


class FakeD1:
    """`wrangler d1 execute --command ... --json` over an in-memory SQLite. Records every argv."""

    def __init__(self) -> None:
        import sqlite3

        self.db = sqlite3.connect(":memory:", isolation_level=None)
        self.db.row_factory = sqlite3.Row
        for migration in MIGRATIONS:
            self.db.executescript(migration.read_text(encoding="utf-8"))
        self.calls: list[list[str]] = []
        self.fail_on_write: int | None = None
        self.fail_on_load = False

    def __call__(self, args: list[str]) -> str:
        self.calls.append(args)
        sql = args[args.index("--command") + 1]
        if not sql.startswith("SELECT"):
            writes = sum(1 for call in self.calls if not call[call.index("--command") + 1].startswith("SELECT"))
            if writes == self.fail_on_write or (self.fail_on_load and sql.startswith("INSERT INTO share_table_load")):
                raise load_share_tables.BuildError("wrangler exited 1: stub failure")
        rows = [dict(row) for row in self.db.execute(sql)]
        return json.dumps([{"results": rows, "success": True, "meta": {}}])

    def writes(self) -> list[str]:
        return [sql for call in self.calls if not (sql := call[call.index("--command") + 1]).startswith("SELECT")]

    def count(self, table: str) -> int:
        return self.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]


class LoadTest(unittest.TestCase):
    """load_share_tables.py against a fake D1 that enforces the contract's triggers."""

    def setUp(self) -> None:
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.d1 = FakeD1()

    def load(self, names: dict, *extra: str) -> int:
        write_archive(self.dir / "modules.zip", names)
        argv = ["--target", "staging", "--archive", str(self.dir / "modules.zip"), *extra]
        return load_share_tables.main(argv, wrangler=self.d1)

    def test_short_d1_gets_only_the_tail(self) -> None:
        """(a) D1 holding an older set gets only the entries it lacks, then one load record."""
        self.assertEqual(self.load(labels()), 0)
        first = self.d1.count("share_table_name")
        self.d1.calls.clear()
        self.assertEqual(self.load(labels(extra=1)), 0)
        self.assertEqual(self.d1.count("share_table_name"), first + len(GID_KEYS))
        self.assertEqual(self.d1.count("share_table_gid"), 4 * 3)
        self.assertEqual(self.d1.count("share_table_load"), 2)
        self.assertTrue(self.d1.writes()[-1].startswith("INSERT INTO share_table_load"))
        rows = self.d1.db.execute("SELECT name FROM share_table_name WHERE key = 'skill.name' ORDER BY pos")
        self.assertEqual([r[0] for r in rows], ["skill.name 0", "skill.name 1", "skill.name 2"])
        for call in self.d1.calls:
            self.assertNotIn("--file", call)
            self.assertEqual(call[:4], ["d1", "execute", "DB", "--remote"])
            self.assertIn("--json", call)
            self.assertEqual(call[call.index("--env") + 1], "staging")

    def test_older_archive_adds_nothing(self) -> None:
        """(b) An archive shorter than D1 passes with nothing written, and D1 keeps its rows."""
        self.assertEqual(self.load(labels(extra=1)), 0)
        self.d1.calls.clear()
        self.assertEqual(self.load(labels()), 0)
        self.assertEqual(self.d1.writes(), [])
        self.assertEqual(self.d1.count("share_table_gid"), 4 * 3)
        self.assertEqual(self.d1.count("share_table_load"), 1)

    def test_contradicting_archive_is_refused(self) -> None:
        """(c) A list that differs within the range both hold is refused before any write."""
        self.assertEqual(self.load(labels()), 0)
        self.d1.calls.clear()
        names = labels(extra=1)
        names["skill.name"][1] = "renamed"
        self.assertEqual(self.load(names), 1)
        self.assertEqual(self.d1.writes(), [])

    def test_dry_run_writes_nothing(self) -> None:
        self.assertEqual(self.load(labels(), "--dry-run"), 0)
        self.assertEqual(self.d1.writes(), [])

    def test_writes_are_chunked_and_resumable(self) -> None:
        """(d) Many rows go in several statements under the bound, and a run stopped between them is
        completed by the next run without a duplicate."""
        names = labels(extra=600)
        self.d1.fail_on_write = 3
        self.assertEqual(self.load(names), 1)
        self.assertEqual(self.d1.count("share_table_load"), 0)
        partial = self.d1.count("share_table_name")
        self.assertGreater(partial, 0)
        self.d1.fail_on_write = None
        self.assertEqual(self.load(names), 0)
        writes = self.d1.writes()
        self.assertGreater(len(writes), 3)
        self.assertTrue(all(len(sql) <= load_share_tables.CHUNK_CHARS for sql in writes))
        self.assertEqual(self.d1.count("share_table_name"), sum(len(v) for v in names.values()) - 2)
        self.assertEqual(self.d1.count("share_table_load"), 1)

    def stop_before_record(self, names: dict) -> int:
        """Loads `names` with the load record failing; returns how many rows were written."""
        self.d1.fail_on_load = True
        self.assertEqual(self.load(names), 1)
        self.d1.fail_on_load = False
        self.assertEqual(self.d1.count("share_table_load"), 0)
        return sum(self.d1.count(table) for table, _ in load_share_tables.TABLES.values())

    def test_rerun_records_a_load_stopped_before_its_record(self) -> None:
        """(h) Rows written without their record are recorded by the next run, which adds none."""
        written = self.stop_before_record(labels())
        self.d1.calls.clear()
        self.assertEqual(self.load(labels()), 0)
        self.assertEqual([sql.split(" (")[0] for sql in self.d1.writes()], ["INSERT INTO share_table_load"])
        record = self.d1.db.execute("SELECT rows_added FROM share_table_load").fetchall()
        self.assertEqual([r[0] for r in record], [written])
        self.d1.calls.clear()
        self.assertEqual(self.load(labels()), 0)
        self.assertEqual(self.d1.writes(), [])

    def test_rerun_with_an_archive_not_covering_unrecorded_rows_is_refused(self) -> None:
        """(i) After a stopped load, an archive shorter than D1 cannot account for its rows: refused."""
        self.stop_before_record(labels(extra=1))
        self.d1.calls.clear()
        write_archive(self.dir / "modules.zip", labels())
        argv = ["--target", "staging", "--archive", str(self.dir / "modules.zip")]
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(load_share_tables.main(argv, wrangler=self.d1), 1)
        self.assertIn("an earlier load stopped part way", err.getvalue())
        self.assertEqual(self.d1.writes(), [])

    def test_names_reach_d1_verbatim(self) -> None:
        names = labels()
        names["skill.name"][1] = "it's \"quoted\"; DROP TABLE x --"
        self.assertEqual(self.load(names), 0)
        got = self.d1.db.execute("SELECT name FROM share_table_name WHERE key = 'skill.name' AND pos = 1")
        self.assertEqual(got.fetchone()[0], names["skill.name"][1])

    def test_baseline_longer_than_result_is_refused(self) -> None:
        """A baseline (tables the Worker bundles) the result would not extend stops before any write."""
        baseline = self.dir / "baseline.json"
        write_archive(self.dir / "modules.zip", labels(extra=1))
        baseline.write_text(json.dumps(load_share_tables.build_tables((self.dir / "modules.zip").read_bytes())))
        self.assertEqual(self.load(labels(), "--baseline", str(baseline)), 1)
        self.assertEqual(self.d1.writes(), [])
        self.assertEqual(self.load(labels(extra=1), "--baseline", str(baseline)), 0)
        self.assertEqual(self.load(labels(), "--baseline", str(self.dir / "missing.json")), 1)

    def test_read_to_writes_the_tables_d1_holds(self) -> None:
        """--read-to writes D1's tables, version and generation, and writes nothing to D1."""
        self.assertEqual(self.load(labels(extra=1)), 0)
        writes = len(self.d1.writes())
        out = self.dir / "read.json"
        self.assertEqual(load_share_tables.main(["--target", "staging", "--read-to", str(out)], wrangler=self.d1), 0)
        self.assertEqual(len(self.d1.writes()), writes)
        tables = json.loads(out.read_text(encoding="utf-8"))
        write_archive(self.dir / "modules.zip", labels(extra=1))
        expected = build_share_tables.build_tables((self.dir / "modules.zip").read_bytes())
        self.assertEqual(tables, {**expected, "generation": 1})

    def load_without_tags(self, names: dict) -> None:
        """Loads `names` the way a checkout from before 0007_share_table_tags.sql did: names and gids only."""
        tag_sources = build_share_tables.TAG_SOURCES.copy()
        build_share_tables.TAG_SOURCES.clear()
        try:
            self.assertEqual(self.load(names), 0)
        finally:
            build_share_tables.TAG_SOURCES.update(tag_sources)
        self.assertEqual(self.d1.count("share_table_tags"), 0)

    def test_untagged_d1_gets_only_the_tags(self) -> None:
        """A D1 loaded before tags were read gets only the tags from the same archive, under one new load."""
        self.load_without_tags(labels())
        names, gids = self.d1.count("share_table_name"), self.d1.count("share_table_gid")
        self.d1.calls.clear()
        self.assertEqual(self.load(labels()), 0)
        self.assertEqual((self.d1.count("share_table_name"), self.d1.count("share_table_gid")), (names, gids))
        rows = self.d1.db.execute("SELECT pos, tags FROM share_table_tags WHERE key = 'factor.name' ORDER BY pos")
        self.assertEqual([(r[0], json.loads(r[1])) for r in rows], [(0, tags_of(0)), (1, tags_of(1))])
        self.assertEqual(self.d1.count("share_table_tags"), 2)
        record = self.d1.db.execute("SELECT generation, rows_added FROM share_table_load ORDER BY generation")
        self.assertEqual([tuple(r) for r in record][1:], [(2, 2)])

    def test_read_to_refuses_a_d1_without_tags(self) -> None:
        """A D1 whose factor names have no tags is refused, and no file is written."""
        self.load_without_tags(labels())
        out = self.dir / "read.json"
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(load_share_tables.main(["--target", "staging", "--read-to", str(out)], wrangler=self.d1), 1)
        self.assertIn("fewer tags than names for factor.name", err.getvalue())
        self.assertFalse(out.exists())

    def test_read_to_refuses_a_d1_without_a_load(self) -> None:
        """A D1 that records no load is refused, and no file is written."""
        out = self.dir / "read.json"
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(load_share_tables.main(["--target", "staging", "--read-to", str(out)], wrangler=self.d1), 1)
        self.assertIn("records no load", err.getvalue())
        self.assertFalse(out.exists())


if __name__ == "__main__":
    unittest.main()
