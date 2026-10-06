# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build the name tables the share Worker resolves sids through (server/src/tables.generated.json).

    uv run tool/cloudflare/build_share_tables.py --previous <baseline>

The tables come from the module set served to users, not from a local one: the live pointer
(https://data.umacapture.com/umacapture/version_info.json) names an archive by sha256 and size, the
archive is fetched anonymously and checked against both, and the tables are read out of its
modules/labels.json and modules/*_info.json. The output shape is the contract stated at the top of
server/src/tables.mjs: {version, names, gids}.

A published record stores sids, and its names are looked up in whichever tables are deployed when
it is read, so the tables may only ever grow at the end. The tables last deployed are kept as the
baseline, given with --previous. It is required and has no default, because each deploy target has
its own D1 and so its own baseline (tool/cloudflare/deploy_web.sh passes
tool/cloudflare/.deploy-backup/tables.<target>.json). Every list of the baseline has to be a prefix
of the same list in the new tables, or the script stops with exit 1 and writes nothing. When the
baseline file does not exist the check is skipped, and the script says so. This script
only reads the baseline; promoting the output to the baseline is the deploy's job, once the tables
have actually been deployed.

--archive <zip> builds from a local archive instead of the live one (no network, no sha256 check).

--source-out <file> also writes the sha256 of the archive the tables were read from, as one line of
64 hex digits, for the deploy to record. It is written only when the tables are.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import re
import sys
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DATA_ROOT = "https://data.umacapture.com/umacapture"
DEFAULT_OUT = REPO / "server" / "src" / "tables.generated.json"

# labels.json keys the public form never names (campaign_field.name: no record field reads it).
EXCLUDED_KEYS = frozenset({"campaign_field.name"})
# labels.json key -> the info table that carries its gid column.
GID_SOURCES = {
    "character.card": "character_card_info.json",
    "skill.name": "skill_info.json",
    "factor.name": "factor_info.json",
    "race_title.name": "race_title_info.json",
}
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


class BuildError(Exception):
    """A refusal: the script exits 1 with this message and writes nothing."""


def fetch(url: str) -> bytes:
    # Cloudflare answers 403 to urllib's default User-Agent, so the request names itself.
    request = urllib.request.Request(url, headers={"User-Agent": "umacapture-build-share-tables"})
    try:
        with urllib.request.urlopen(request, timeout=60) as res:
            return res.read()
    except OSError as e:
        raise BuildError(f"could not fetch {url}: {e}") from None


def fetch_live_archive() -> tuple[bytes, str]:
    """The archive the live pointer names, checked against its sha256 and size."""
    pointer = json.loads(fetch(f"{DATA_ROOT}/version_info.json"))
    archive = pointer.get("module_archive") or {}
    sha, size, path = archive.get("sha256"), archive.get("size"), archive.get("path")
    if not (isinstance(sha, str) and SHA_RE.match(sha) and isinstance(size, int) and path == f"modules/{sha}.zip"):
        raise BuildError("the live pointer does not name an archive as modules/<sha256>.zip with a size")
    body = fetch(f"{DATA_ROOT}/{path}")
    got = hashlib.sha256(body).hexdigest()
    if got != sha or len(body) != size:
        raise BuildError(f"the archive does not match the pointer: sha256 {got}, size {len(body)}")
    return body, sha


def read_json(archive: zipfile.ZipFile, name: str):
    try:
        return json.loads(archive.read(f"modules/{name}").decode("utf-8"))
    except KeyError:
        raise BuildError(f"the archive has no modules/{name}") from None


def gid_column(info: list, key: str, count: int) -> list[int]:
    """The gid of every sid, in sid order. The info table has to hold sids 0..count-1 exactly once."""
    by_sid = {entry["sid"]: entry["gid"] for entry in info}
    if len(info) != count or sorted(by_sid) != list(range(count)):
        raise BuildError(f"the info table for {key} does not hold sids 0..{count - 1} exactly once")
    return [by_sid[sid] for sid in range(count)]


def build_tables(archive_bytes: bytes) -> dict:
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        version = read_json(archive, "version_info.json")["recognizer_version"]
        labels = read_json(archive, "labels.json")
        names = {key: value for key, value in labels.items() if key not in EXCLUDED_KEYS}
        missing = [key for key in GID_SOURCES if key not in names]
        if missing:
            raise BuildError(f"labels.json has no {', '.join(missing)}")
        gids = {
            key: gid_column(read_json(archive, source), key, len(names[key])) for key, source in GID_SOURCES.items()
        }
    return {"version": version, "names": names, "gids": gids}


def append_only_violations(previous: dict, current: dict) -> list[str]:
    """Every list of `previous` that is not a prefix of the same list of `current`."""
    violations = []
    for section in ("names", "gids"):
        for key, old in previous.get(section, {}).items():
            new = current[section].get(key)
            if new is None:
                violations.append(f"{section}[{key}] is gone")
            elif new[: len(old)] != old:
                violations.append(f"{section}[{key}] no longer starts with the {len(old)} entries deployed before")
    return violations


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--archive", type=Path, help="build from this local module archive instead of the live one")
    parser.add_argument("--previous", type=Path, required=True, help="tables last deployed to the target (baseline)")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--source-out", type=Path, help="write the sha256 of the source archive here")
    args = parser.parse_args(argv)
    try:
        if args.archive:
            archive_bytes, source = args.archive.read_bytes(), str(args.archive)
            sha = hashlib.sha256(archive_bytes).hexdigest()
        else:
            archive_bytes, sha = fetch_live_archive()
            source = f"modules/{sha}.zip"
        tables = build_tables(archive_bytes)
        if args.previous.is_file():
            violations = append_only_violations(json.loads(args.previous.read_text(encoding="utf-8")), tables)
            if violations:
                raise BuildError("the tables are not append-only against the baseline:\n  " + "\n  ".join(violations))
        else:
            print(f"no baseline at {args.previous}: the append-only check was skipped")
    except BuildError as e:
        print(f"build_share_tables: {e}. Nothing was written.", file=sys.stderr)
        return 1
    body = json.dumps(tables, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(body)
    if args.source_out:
        args.source_out.write_text(f"{sha}\n", encoding="ascii", newline="\n")
    name_count = sum(len(v) for v in tables["names"].values())
    gid_count = sum(len(v) for v in tables["gids"].values())
    print(
        f"wrote {args.out} from {source} (version {tables['version']}): {len(tables['names'])} keys, "
        f"{name_count} names, {gid_count} gids, {len(body)} bytes, {len(gzip.compress(body, 9))} gzipped"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
