"""Read the name tables the share Worker resolves sids through out of a module archive.

A library of tool/cloudflare/load_share_tables.py, which appends these tables to each deploy target's
D1 when tool/cloudflare/publish_modules.sh publishes a module set; the Worker reads them from there.
The tables are read out of the archive's modules/labels.json and modules/*_info.json, in the shape
{version, names, gids, tags} that server/src/tables.mjs reads from D1. tags holds, per key of
TAG_SOURCES, the info table's tags of each sid as the module states them (a list of strings).

A shared record stores sids, so the tables may only ever grow at the end;
append_only_violations states what a set of tables may not do to another.
"""

from __future__ import annotations

import io
import json
import zipfile

# labels.json keys the public form never names (campaign_field.name: no record field reads it).
EXCLUDED_KEYS = frozenset({"campaign_field.name"})
# labels.json key -> the info table that carries its gid column.
GID_SOURCES = {
    "character.card": "character_card_info.json",
    "skill.name": "skill_info.json",
    "factor.name": "factor_info.json",
    "race_title.name": "race_title_info.json",
}
# labels.json key -> the info table that carries its tags column (a list of strings per sid).
TAG_SOURCES = {
    "factor.name": "factor_info.json",
}
# The per-sid lists of a set of tables, each one append-only.
SECTIONS = ("names", "gids", "tags")


class BuildError(Exception):
    """A refusal: the caller exits 1 with this message."""


def read_json(archive: zipfile.ZipFile, name: str):
    try:
        return json.loads(archive.read(f"modules/{name}").decode("utf-8"))
    except KeyError:
        raise BuildError(f"the archive has no modules/{name}") from None


def info_column(info: list, field: str, key: str, count: int) -> list:
    """`field` of every sid, in sid order. The info table has to hold sids 0..count-1 exactly once."""
    by_sid = {entry["sid"]: entry[field] for entry in info}
    if len(info) != count or sorted(by_sid) != list(range(count)):
        raise BuildError(f"the info table for {key} does not hold sids 0..{count - 1} exactly once")
    return [by_sid[sid] for sid in range(count)]


def tag_list(value, key: str) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(tag, str) for tag in value):
        raise BuildError(f"the info table for {key} has tags that are not a list of strings")
    return value


def build_tables(archive_bytes: bytes) -> dict:
    with zipfile.ZipFile(io.BytesIO(archive_bytes)) as archive:
        version = read_json(archive, "version_info.json")["recognizer_version"]
        labels = read_json(archive, "labels.json")
        names = {key: value for key, value in labels.items() if key not in EXCLUDED_KEYS}
        missing = [key for key in {**GID_SOURCES, **TAG_SOURCES} if key not in names]
        if missing:
            raise BuildError(f"labels.json has no {', '.join(missing)}")
        gids = {
            key: info_column(read_json(archive, source), "gid", key, len(names[key]))
            for key, source in GID_SOURCES.items()
        }
        tags = {
            key: [tag_list(v, key) for v in info_column(read_json(archive, source), "tags", key, len(names[key]))]
            for key, source in TAG_SOURCES.items()
        }
    return {"version": version, "names": names, "gids": gids, "tags": tags}


def append_only_violations(previous: dict, current: dict, *, allow_shorter: bool = False) -> list[str]:
    """Every list of `previous` that `current` contradicts.

    The entries both lists hold have to be the same. By default `current` also has to hold every entry of
    `previous` (each list of `previous` is a prefix of the one in `current`): load_share_tables.py
    --baseline, where a record shared under the tables a Worker once bundled must stay readable through
    D1's. With allow_shorter, `current` may stop early or lack a key: the
    caller keeps what `previous` holds beyond it (load_share_tables.py, where D1 keeps its rows)."""
    violations = []
    for section in SECTIONS:
        for key, old in previous.get(section, {}).items():
            new = current.get(section, {}).get(key)
            if new is None:
                if not allow_shorter:
                    violations.append(f"{section}[{key}] is gone")
                continue
            common = min(len(old), len(new))
            if allow_shorter and new[:common] != old[:common]:
                violations.append(f"{section}[{key}] differs from the {common} entries both hold")
            elif not allow_shorter and new[: len(old)] != old:
                violations.append(f"{section}[{key}] no longer starts with the {len(old)} entries deployed before")
    return violations
