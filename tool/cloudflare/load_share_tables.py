# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Append the name tables of a module archive to one deploy target's D1, or read them back.

    uv run tool/cloudflare/load_share_tables.py --target production|staging --archive <modules.zip>
        [--baseline <tables.json>] [--dry-run]
    uv run tool/cloudflare/load_share_tables.py --target production|staging --read-to <tables.json>

The share Worker resolves sids through the tables in its own D1 (share_table_name, share_table_gid,
share_table_load). A shared record stores sids, so a list may only ever grow at the end. This script
reads the target's rows back, builds the tables of the archive with build_share_tables.build_tables,
and requires every list to agree with the rows over the range both hold
(build_share_tables.append_only_violations with allow_shorter). It then inserts only the entries
the rows lack, in pos order, so an older archive passes with nothing to add and the rows it lacks
stay. With nothing to add it writes nothing. Otherwise it reads the rows back, requires them to be
exactly the planned result, and only then records the load as one share_table_load row, last.
A run that stops part way leaves every list a prefix of the archive's, and running it again
completes it. Rows beyond what the load records account for (the sum of rows_added) were written by
a load that stopped before its record: the next run records them with its own rows, even when it adds
none, and is refused when its archive does not hold every row D1 has, since it cannot tell which
archive they came from.

D1 is reached through the wrangler pinned in server/ (`d1 execute DB --remote --command ... --json`
against server/wrangler.jsonc, with `--env staging` for staging), never with --file: a remote --file
is an import, during which the database answers no queries. Writes go in statements small enough
for one command line. Credentials come from the environment (CLOUDFLARE_API_TOKEN,
CLOUDFLARE_ACCOUNT_ID), as tool/cloudflare/publish_modules.sh exports them.

--baseline <file> also requires the tables a Worker of the target bundled before Workers read them from
D1 (tool/cloudflare/.deploy-backup/tables.<target>.json, written by the last such deploy) to be a prefix
of the result, for the first load into a D1 that is still empty. It is refused when the file does not
exist.

--read-to <file> writes the tables the target's D1 holds as {version, generation, names, gids} and
writes nothing to D1 (tool/cloudflare/deploy_web.sh checks with it that the target has tables, and cuts
the page fonts from them). It is refused when D1 records no load: the Worker then has no tables and
answers every name lookup with a 500.

--dry-run prints how many entries would be added and writes nothing.
Exit status: 0 loaded or nothing to add, 1 refused or failed (the message says whether anything was
written).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_share_tables import BuildError, append_only_violations, build_tables  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
WRANGLER_JS = REPO / "server" / "node_modules" / "wrangler" / "bin" / "wrangler.js"
WRANGLER_CONFIG = REPO / "server" / "wrangler.jsonc"
# The D1 binding of server/wrangler.jsonc; wrangler resolves it in the environment the target names.
BINDING = "DB"
TARGET_ENV_ARGS = {"production": [], "staging": ["--env", "staging"]}
TABLES = {"names": ("share_table_name", "name"), "gids": ("share_table_gid", "gid")}
# Characters of SQL per write command. A Windows command line holds 32767 UTF-16 units and D1 takes
# statements under 100 KB, so a write stays far below both.
CHUNK_CHARS = 8000

Wrangler = Callable[[list[str]], str]


def node_wrangler(args: list[str]) -> str:
    """Runs the pinned wrangler with node and returns its stdout. No shell: names reach it verbatim."""
    result = subprocess.run(
        ["node", str(WRANGLER_JS), *args], capture_output=True, text=True, encoding="utf-8", cwd=REPO
    )
    if result.returncode != 0:
        tail = (result.stderr or result.stdout).strip().splitlines()[-5:]
        raise BuildError(f"wrangler exited {result.returncode}: " + " / ".join(tail))
    return result.stdout


def sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class Target:
    def __init__(self, name: str, wrangler: Wrangler) -> None:
        self.name = name
        self.wrangler = wrangler

    def execute(self, sql: str) -> list[dict]:
        """The rows of the last statement of `sql`."""
        args = ["d1", "execute", BINDING, "--remote", "-c", str(WRANGLER_CONFIG), *TARGET_ENV_ARGS[self.name]]
        out = self.wrangler([*args, "--json", "--command", sql])
        try:
            results = json.loads(out[out.index("[") :])
        except ValueError:
            raise BuildError(f"{self.name}: wrangler printed no JSON result") from None
        if not results or not all(isinstance(r, dict) and r.get("success") for r in results):
            raise BuildError(f"{self.name}: D1 did not report success: {out.strip()[:300]}")
        return results[-1].get("results") or []

    def recorded_rows(self) -> int:
        """The rows the load records account for. Rows beyond them were written by a load that stopped
        before its record."""
        return self.execute("SELECT COALESCE(SUM(rows_added), 0) AS n FROM share_table_load")[0]["n"]

    def read_tables(self) -> dict:
        tables: dict = {}
        for section, (table, column) in TABLES.items():
            lists: dict[str, list] = {}
            for row in self.execute(f"SELECT key, pos, {column} AS value FROM {table} ORDER BY key, pos"):
                values = lists.setdefault(row["key"], [])
                if row["pos"] != len(values):
                    raise BuildError(f"{self.name}: {table} rows of {row['key']} are not numbered 0, 1, 2, ...")
                values.append(row["value"])
            tables[section] = lists
        return tables


def read_back(target: Target, out: Path) -> int:
    """Writes the tables D1 holds to `out`. The generation is read before the rows, as the Worker reads
    them, so a load in progress can only make the rows longer than the generation records."""
    last = target.execute(
        "SELECT generation, recognizer_version FROM share_table_load ORDER BY generation DESC LIMIT 1"
    )
    if not last:
        raise BuildError(f"{target.name}: D1 records no load of the name tables. Publish a module set first")
    tables = {"version": last[0]["recognizer_version"], "generation": last[0]["generation"], **target.read_tables()}
    out.write_text(json.dumps(tables, ensure_ascii=False, separators=(",", ":")), encoding="utf-8", newline="\n")
    print(f"{target.name}: read {count_rows(tables)} entries of generation {tables['generation']} into {out}")
    return 0


def count_rows(tables: dict) -> int:
    return sum(len(values) for section in TABLES for values in tables[section].values())


def covers(archive_tables: dict, loaded: dict) -> bool:
    """Every list of `loaded` is no longer than the same list of the archive."""
    return all(
        len(values) <= len(archive_tables[section].get(key, ()))
        for section, lists in loaded.items()
        for key, values in lists.items()
    )


def plan(loaded: dict, archive_tables: dict) -> tuple[list[tuple[str, str, int, object]], dict]:
    """The rows to insert, in pos order per list, and the tables D1 holds once they are in."""
    rows, merged = [], {}
    for section in TABLES:
        merged[section] = {key: list(values) for key, values in loaded[section].items()}
        for key, values in archive_tables[section].items():
            have = merged[section].setdefault(key, [])
            for pos in range(len(have), len(values)):
                rows.append((section, key, pos, values[pos]))
                have.append(values[pos])
    return rows, merged


def insert_commands(rows: list[tuple[str, str, int, object]]) -> list[str]:
    """INSERT statements of consecutive rows of one table, each under CHUNK_CHARS."""
    commands: list[str] = []
    current_section, values = None, []

    def flush() -> None:
        if values:
            table, column = TABLES[current_section]
            commands.append(f"INSERT INTO {table} (key, pos, {column}) VALUES " + ",".join(values))

    for section, key, pos, value in rows:
        literal = sql_text(value) if section == "names" else str(int(value))
        tuple_sql = f"({sql_text(key)},{pos},{literal})"
        head = len("INSERT INTO share_table_name (key, pos, name) VALUES ")
        if section != current_section or head + sum(len(v) + 1 for v in values) + len(tuple_sql) > CHUNK_CHARS:
            flush()
            current_section, values = section, []
        values.append(tuple_sql)
    flush()
    return commands


def load(target: Target, archive_bytes: bytes, baseline: dict | None, dry_run: bool) -> int:
    sha = hashlib.sha256(archive_bytes).hexdigest()
    try:
        archive_tables = build_tables(archive_bytes)
        loaded = target.read_tables()
        violations = append_only_violations(loaded, archive_tables, allow_shorter=True)
        if violations:
            raise BuildError("the archive contradicts the rows in D1:\n  " + "\n  ".join(violations))
        unrecorded = count_rows(loaded) - target.recorded_rows()
        if unrecorded > 0 and not covers(archive_tables, loaded):
            raise BuildError(
                f"{unrecorded} rows in D1 have no load record and this archive does not hold them all: an earlier "
                "load stopped part way. Run this again with the archive of that load"
            )
        rows, merged = plan(loaded, archive_tables)
        if baseline is not None:
            violations = append_only_violations(baseline, merged)
            if violations:
                raise BuildError("the result would drop names the Worker bundles:\n  " + "\n  ".join(violations))
    except BuildError as e:
        raise BuildError(f"{target.name}: {e}\nNothing was written") from None
    expected = {section: {key: v for key, v in lists.items() if v} for section, lists in merged.items()}
    print(
        f"{target.name}: archive {sha} (version {archive_tables['version']}): {len(rows)} entries to add, "
        f"{max(unrecorded, 0)} in D1 without a load record"
    )
    added = len(rows) + max(unrecorded, 0)
    if not added or dry_run:
        if dry_run:
            print(f"{target.name}: dry run, nothing was written")
        return 0
    try:
        for command in insert_commands(rows):  # nothing when only the record is missing
            target.execute(command)
        if target.read_tables() != expected:
            raise BuildError("the rows read back are not the planned result")
        target.execute(
            "INSERT INTO share_table_load (generation, archive_sha256, recognizer_version, rows_added, loaded_at) "
            f"SELECT COALESCE(MAX(generation), 0) + 1, {sql_text(sha)}, {sql_text(archive_tables['version'])}, "
            f"{added}, {int(time.time())} FROM share_table_load"
        )
        last = target.execute(
            "SELECT archive_sha256, rows_added FROM share_table_load ORDER BY generation DESC LIMIT 1"
        )
        if last != [{"archive_sha256": sha, "rows_added": added}]:
            raise BuildError("the load record read back is not the one written")
    except BuildError as e:
        raise BuildError(
            f"{target.name}: {e}. Rows may have been partly written; every list is still a prefix of the "
            "archive's, and running this again completes the load"
        ) from None
    print(f"{target.name}: added {len(rows)} entries and recorded the load of {added}")
    return 0


def main(argv: list[str] | None = None, wrangler: Wrangler = node_wrangler) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", choices=sorted(TARGET_ENV_ARGS), required=True)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--archive", type=Path, help="the module archive being published")
    source.add_argument("--read-to", type=Path, help="write the tables D1 holds here; write nothing to D1")
    parser.add_argument("--baseline", type=Path, help="tables the target's Worker bundles; must be a prefix")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if args.read_to is not None and (args.baseline is not None or args.dry_run):
        parser.error("--read-to takes neither --baseline nor --dry-run")
    try:
        if args.read_to is not None:
            return read_back(Target(args.target, wrangler), args.read_to)
        baseline = None
        if args.baseline is not None:
            if not args.baseline.is_file():
                raise BuildError(f"no baseline at {args.baseline}")
            baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        return load(Target(args.target, wrangler), args.archive.read_bytes(), baseline, args.dry_run)
    except (BuildError, OSError) as e:
        print(f"load_share_tables: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
