# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Fetch and inspect umacapture Sentry issues via the REST API.

Stdlib-only (urllib) so it runs under `uv run --no-project` with no install
step. The auth token is read from a file outside the repo so it never lands in
the command line, shell history, or the repository.

Subcommands:
  list    List issues for a project (filtered by a Sentry search query).
  event   Dump the latest event of an issue: meta, tags, contexts, stack.

Run `python sentry_issues.py <subcommand> -h` for per-command options.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# umacapture Sentry coordinates (US region, sentry.io). The numeric IDs work
# directly in the API path, so no org/project *slug* lookup is needed.
ORG_ID = "1367286"
PROJECTS = {
    "release": "6670477",  # production build (kReleaseMode)
    "debug": "6668087",  # legacy: debug builds no longer init Sentry; historical events only
}
DEFAULT_TOKEN_PATH = "~/.sentry_token"
BASE = "https://sentry.io/api/0"

# The issues endpoint only accepts these statsPeriod values; anything else is a
# 400. Use "" (empty) to search across all time, which is what you want when
# filtering by release: a fresh release has little history inside a 14d window.
VALID_PERIODS = {"", "24h", "14d"}


def read_token(path: str) -> str:
    token_file = Path(os.path.expanduser(path))
    if not token_file.exists():
        sys.exit(f"Token file not found: {token_file}\nCreate it and paste a Sentry auth token inside.")
    token = token_file.read_text(encoding="utf-8").strip()
    if not token:
        sys.exit(f"Token file is empty: {token_file}")
    return token


def api_get(url: str, token: str) -> object:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        sys.exit(f"HTTP {exc.code} from {url}\n{body}")
    except urllib.error.URLError as exc:
        sys.exit(f"Network error for {url}: {exc.reason}")


def latest_release(project: str, token: str) -> str | None:
    """Return the newest release version for a project, or None if it has none.

    Sentry's releases endpoint is ordered newest-first by creation date, so the
    first entry is the latest build that has reported events.
    """
    url = f"{BASE}/projects/{ORG_ID}/{project}/releases/?per_page=1"
    releases = api_get(url, token)
    if isinstance(releases, list) and releases:
        return releases[0].get("version")
    return None


def cmd_list(args: argparse.Namespace, token: str) -> None:
    project = PROJECTS[args.project]

    # By default we scope to the latest release build only: old versions
    # accumulate stale issues that users on the current build can't hit, so an
    # unscoped list is mostly noise. The user can widen this with --all-releases
    # or pin a version with --release. An explicit release: token in --query also
    # counts as "the user chose", so we don't override it.
    query = args.query
    release = None
    if not args.all_releases and "release:" not in query:
        release = args.release or latest_release(project, token)
        if release:
            query = f"{query} release:{release}".strip()

    # A release filter needs an all-time window ("") — a fresh build has little
    # history inside 14d. Only force this when the user didn't pick a period.
    period = args.stats_period
    if period is None:
        period = "" if (release or "release:" in query) else "14d"
    if period not in VALID_PERIODS:
        sys.exit(f"--stats-period must be one of {sorted(VALID_PERIODS)!r} (Sentry constraint).")

    url = (
        f"{BASE}/projects/{ORG_ID}/{project}/issues/"
        f"?query={urllib.parse.quote(query, safe='')}"
        f"&statsPeriod={urllib.parse.quote(period, safe='')}&sort={args.sort}&limit={args.limit}"
    )
    issues = api_get(url, token)
    if isinstance(issues, dict):
        sys.exit(f"Unexpected response: {json.dumps(issues)[:300]}")
    if args.json:
        print(json.dumps(issues, ensure_ascii=False, indent=2))
        return
    scope = f"release {release}" if release else ("all releases" if args.all_releases else "query as given")
    print(f"{len(issues)} issue(s) for project={args.project} [{scope}] query={query!r}\n")
    for i in issues:
        print(
            f'{i["shortId"]:22} | {i["level"]:6} | n={i["count"]:>5} '
            f'| first={i["firstSeen"][:10]} last={i["lastSeen"][:10]} '
            f'| {i["title"][:70]}'
        )
    if issues and args.links:
        print("\nLinks:")
        for i in issues:
            print(f'  {i["shortId"]:22} {i["permalink"]}  (id={i["id"]})')


def _frames_table(frames: list, top: int) -> None:
    # Sentry orders frames oldest-first, so the crash site is last. Show the
    # innermost `top` frames; mark in-app frames with `*`.
    for f in frames[-top:]:
        pkg = (f.get("package") or "").replace("\\", "/").rsplit("/", 1)[-1]
        name = f.get("function") or f.get("symbol") or "?"
        line = f.get("lineNo")
        mark = "*" if f.get("inApp") else " "
        addr = f.get("instructionAddr") or ""
        print(f'  {mark} {pkg:26} {name}  {("L" + str(line)) if line else ""} {addr}')


def cmd_event(args: argparse.Namespace, token: str) -> None:
    ref = args.event_id or "latest"
    url = f"{BASE}/issues/{args.issue_id}/events/{ref}/"
    d = api_get(url, token)
    if args.json:
        print(json.dumps(d, ensure_ascii=False, indent=2))
        return

    print("=== meta ===")
    for k in ("eventID", "dateCreated", "platform"):
        print(f"{k}: {d.get(k)}")
    rel = d.get("release")
    print("release:", rel.get("version") if isinstance(rel, dict) else rel)
    print("title:", d.get("title"))

    print("\n=== tags ===")
    for t in d.get("tags", []) or []:
        print(f'{t.get("key")} = {t.get("value")}')

    print("\n=== contexts ===")
    for k, v in (d.get("contexts", {}) or {}).items():
        print(f"{k}: {json.dumps(v, ensure_ascii=False)[:400]}")

    print("\n=== stack (innermost last) ===")
    for entry in d.get("entries", []) or []:
        if entry.get("type") == "exception":
            for v in entry["data"]["values"]:
                st = v.get("stacktrace") or {}
                frames = st.get("frames") or []
                print(f'\n# EXC {v.get("type")} | {v.get("value")} | frames={len(frames)}')
                _frames_table(frames, args.top)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--token-path", default=DEFAULT_TOKEN_PATH, help=f"auth token file (default: {DEFAULT_TOKEN_PATH})")
    sub = p.add_subparsers(dest="command", required=True)

    pl = sub.add_parser("list", help="list issues for a project")
    pl.add_argument("--project", choices=PROJECTS, default="release")
    pl.add_argument("--query", default="is:unresolved", help='Sentry search, e.g. "is:unresolved release:0.1.0"')
    pl.add_argument("--release", help="pin a specific release version (default: auto-detect the latest)")
    pl.add_argument("--all-releases", action="store_true", help="do not scope to a release; list every version")
    pl.add_argument("--stats-period", default=None, help='"", "24h", or "14d" (default: 14d, or "" when release-scoped)')
    pl.add_argument("--sort", default="freq", choices=["date", "new", "freq", "user"])
    pl.add_argument("--limit", type=int, default=25)
    pl.add_argument("--links", action="store_true", help="also print permalinks and numeric ids")
    pl.add_argument("--json", action="store_true", help="raw JSON instead of a table")
    pl.set_defaults(func=cmd_list)

    pe = sub.add_parser("event", help="dump an issue's latest (or specific) event")
    pe.add_argument("issue_id", help="numeric issue id (from `list --links`)")
    pe.add_argument("--event-id", help="specific event id (default: latest)")
    pe.add_argument("--top", type=int, default=25, help="number of innermost stack frames to show")
    pe.add_argument("--json", action="store_true", help="raw JSON instead of a summary")
    pe.set_defaults(func=cmd_event)
    return p


def main() -> None:
    args = build_parser().parse_args()
    token = read_token(args.token_path)
    args.func(args, token)


if __name__ == "__main__":
    main()
