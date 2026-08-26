# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Provision the third-party JavaScript/Wasm assets the Flutter web bundle ships.

``web/wasm/`` is gitignored and was historically populated by hand: the
onnxruntime-web runtime and the locally built recognition core. This script
restores the fetchable part of that tree from pinned upstream artifacts,
verifying every byte against ``tool/web_deps.json``.

It is the web-side counterpart of ``tool/fetch_deps.py``, and deliberately a
*separate* script: ``fetch_deps.py``'s CLI is pinned by CI
(``.github/workflows/ci.yml``), so its ``--only`` choices must not grow.

Unlike ``fetch_deps.py``, the pins do not live in constants here -- they live in
``tool/web_deps.json``, which is also the source of truth for the license
disclosure. This file only knows how to *act* on that manifest:

* ``origin: upstream`` entries are downloaded (an npm tarball is fetched once and
  every member it supplies is extracted from it), hash-verified, and written into
  ``web/``. The archive itself is verified against ``source_form.sha256`` before a
  single byte is unpacked, exactly like ``fetch_deps.py`` does for its zips.
* ``origin: in-tree`` entries cannot be downloaded (the recognition core is built
  by ``native/wasm/build.sh``). They are verified when present and reported when
  missing or drifted -- never fetched.

Run it via ``uv run`` (this repo invokes Python through ``uv``, never bare
``python``); it uses only the standard library::

    uv run tool/fetch_web_deps.py                       # everything missing or drifted
    uv run tool/fetch_web_deps.py --only onnxruntime-web  # a single package
    uv run tool/fetch_web_deps.py --force               # re-download even if present and valid
    uv run tool/fetch_web_deps.py --strict              # + fail on any warning (for CI)

A full run also walks ``web/`` and warns about any file that is neither pinned
here nor listed as first-party in the manifest's ``first_party`` allowlist --
``flutter build web`` copies ``web/`` verbatim into ``build/web/``, so an
unreviewed file dropped anywhere in that tree gets published.

Exit status is non-zero if any file ends up not matching its pin. Drift in an
``in-tree`` entry, and an unlisted file, are reported but not fatal by default,
because rebuilding the core legitimately changes its hash (refresh the manifest
when it does). ``--strict`` turns every warning into a failure.

To bump a pin, edit ``tool/web_deps.json`` -- its ``_comment`` block spells out
the procedure -- and re-run with ``--force --only <package>``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_ROOT / "tool" / "web_deps.json"
WEB_DIR = REPO_ROOT / "web"

# Per-read socket timeout (seconds). Bounds a stalled connection so a hung
# download fails fast instead of blocking until the caller gives up.
DOWNLOAD_TIMEOUT = 60

# Manifest key holding the in-repo, locally produced artifacts. Used as the
# ``--only`` name for them, since they have no upstream package name.
IN_TREE_GROUP = "in-tree"


def log(message: str) -> None:
    """Print a progress line."""
    print(f"[fetch_web_deps] {message}", flush=True)


def download(url: str, dest: Path) -> None:
    """Stream ``url`` to ``dest``."""
    log(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=DOWNLOAD_TIMEOUT) as response, dest.open("wb") as out:
        shutil.copyfileobj(response, out)


def verify_sha256(path: Path, expected: str) -> None:
    """Raise ``SystemExit`` if ``path`` does not hash to ``expected``."""
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != expected:
        raise SystemExit(f"SHA-256 mismatch for {path.name}\n  expected {expected}\n  actual   {digest}")
    log(f"verified {path.name} (sha256 ok)")


def download_verified(url: str, dest: Path, expected: str) -> None:
    """Download ``url`` to ``dest`` and check it against ``expected``."""
    download(url, dest)
    verify_sha256(dest, expected)


def matches(path: Path, entry: dict) -> bool:
    """Return ``True`` if ``path`` already holds exactly the bytes ``entry`` pins."""
    if not path.is_file():
        return False
    data = path.read_bytes()
    return len(data) == entry["bytes"] and hashlib.sha256(data).hexdigest() == entry["sha256"]


def write_member(relative: str, entry: dict, data: bytes) -> None:
    """Verify ``data`` against ``entry`` and write it to ``web/<relative>``."""
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != entry["bytes"] or digest != entry["sha256"]:
        raise SystemExit(
            f"SHA-256/size mismatch for {relative}\n"
            f"  expected {entry['sha256']} ({entry['bytes']} bytes)\n"
            f"  actual   {digest} ({len(data)} bytes)"
        )
    # The manifest key is a path we join onto web/; refuse anything that escapes it,
    # so a bad (or malicious) key cannot make this script write outside the web bundle.
    target = (WEB_DIR / relative).resolve()
    if not target.is_relative_to(WEB_DIR.resolve()):
        raise SystemExit(f"manifest key {relative!r} escapes {WEB_DIR}; refusing to write")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    log(f"placed web/{relative} ({len(data)} bytes, sha256 ok)")


def group_of(entry: dict) -> str:
    """Return the ``--only`` name an entry belongs to."""
    if entry["origin"] != "upstream":
        return IN_TREE_GROUP
    return entry["upstream"]["package"]


def fetch_direct(relative: str, entry: dict) -> None:
    """Provision a single entry whose ``upstream.url`` is the file itself."""
    with tempfile.TemporaryDirectory() as tmp:
        downloaded = Path(tmp) / Path(relative).name
        download_verified(entry["upstream"]["url"], downloaded, entry["sha256"])
        write_member(relative, entry, downloaded.read_bytes())


def fetch_from_archive(url: str, wanted: list[tuple[str, dict]]) -> None:
    """Download the npm tarball at ``url`` once and unpack every ``(path, entry)`` in ``wanted``.

    The archive is hash-verified against ``source_form.sha256`` *before* anything is
    unpacked, so a tampered or truncated tarball never reaches the extractor. Members
    are read straight out of the archive rather than extracted to disk, which also
    sidesteps any path traversal in the tarball's member names.
    """
    archive_hashes = {entry["source_form"]["sha256"] for _, entry in wanted}
    if len(archive_hashes) != 1:
        raise SystemExit(f"conflicting source_form.sha256 pins for {url}: {sorted(archive_hashes)}")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "package.tgz"
        download_verified(url, archive, archive_hashes.pop())
        with tarfile.open(archive, "r:gz") as tar:
            for relative, entry in wanted:
                member = entry["upstream"]["member"]
                extracted = tar.extractfile(member)
                if extracted is None:
                    raise SystemExit(f"{member} is missing from {url}")
                with extracted:
                    write_member(relative, entry, extracted.read())


def check_in_tree(relative: str, entry: dict) -> str | None:
    """Verify a locally produced artifact. Return a warning line, or ``None`` when fine."""
    target = WEB_DIR / relative
    if matches(target, entry):
        log(f"web/{relative}: in-tree artifact matches the manifest")
        return None
    hint = entry.get("build", {}).get("script") or "the process recorded in tool/web_deps.json"
    if not target.is_file():
        return f"web/{relative} is missing; it is produced locally (see {hint}) and cannot be downloaded"
    return f"web/{relative} does not match its pin; rebuild it (see {hint}) or refresh tool/web_deps.json"


def is_first_party(relative: str, allowlist: dict) -> bool:
    """Return ``True`` if ``relative`` is one of this repo's own hand-written web files.

    Matching is exact. The allowlist has no directory-prefix form on purpose: a prefix
    would allow an unbounded number of unreviewed files underneath it.
    """
    return relative in allowlist["files"]


def unlisted_files(listed: set[str], allowlist: dict) -> list[str]:
    """Return paths anywhere under ``web/`` that are neither pinned nor first-party.

    Scoping this to ``web/wasm/`` would miss the more dangerous case: a stray
    third-party file dropped at the root of ``web/`` is copied into ``build/web/``
    and published just the same.

    Symbolic links are always reported, however they are named: the name says nothing
    about the bytes they resolve to, so no allowlist entry can vouch for them.
    """
    if not WEB_DIR.is_dir():
        return []
    problems = []
    for path in WEB_DIR.rglob("*"):
        relative = path.relative_to(WEB_DIR).as_posix()
        if path.is_symlink():
            problems.append(relative)
        elif path.is_file() and relative not in listed and not is_first_party(relative, allowlist):
            problems.append(relative)
    return sorted(problems)


def load_manifest() -> dict:
    """Return the parsed manifest."""
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


def main() -> None:
    manifest = load_manifest()
    files = manifest["files"]
    allowlist = manifest["first_party"]
    groups = sorted({group_of(entry) for entry in files.values()})

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--only",
        choices=[*groups, "all"],
        default="all",
        help="provision a single package instead of all (default: all)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-download even if the file is already present and matches its pin",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero on any warning (unlisted or drifted file); for CI gating",
    )
    args = parser.parse_args()

    selected = {
        relative: entry for relative, entry in files.items() if args.only in ("all", group_of(entry))
    }

    warnings: list[str] = []
    # An npm tarball supplies several files; collect them so it is downloaded once.
    archives: dict[str, list[tuple[str, dict]]] = {}

    for relative, entry in selected.items():
        if entry["origin"] == "in-tree":
            warning = check_in_tree(relative, entry)
            if warning:
                warnings.append(warning)
            continue
        if not args.force and matches(WEB_DIR / relative, entry):
            log(f"web/{relative} already present and verified; skipping (use --force to re-fetch)")
            continue
        upstream = entry["upstream"]
        if "member" in upstream:
            archives.setdefault(upstream["url"], []).append((relative, entry))
        else:
            fetch_direct(relative, entry)

    for url, wanted in archives.items():
        fetch_from_archive(url, wanted)

    # Final pass: nothing is "provisioned" until it hashes to the pin on disk.
    for relative, entry in selected.items():
        if entry["origin"] == "upstream" and not matches(WEB_DIR / relative, entry):
            raise SystemExit(f"web/{relative} does not match its pin after provisioning")

    if args.only == "all":
        for extra in unlisted_files(set(files), allowlist):
            warnings.append(
                f"web/{extra} is neither pinned in tool/web_deps.json nor listed as first-party; "
                "'flutter build web' would publish it unreviewed"
            )

    for warning in warnings:
        log(f"WARNING: {warning}")
    log(f"done ({len(selected)} manifest entr{'y' if len(selected) == 1 else 'ies'} checked)")
    if warnings and args.strict:
        raise SystemExit(f"--strict: {len(warnings)} warning(s); see above")


if __name__ == "__main__":
    main()
