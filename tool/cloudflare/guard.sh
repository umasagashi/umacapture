#!/usr/bin/env bash
# ============================================================================
# The operator's commands on the billing guard's state (the remote D1
# umacapture-guard). Every command but `status` writes; each write is an
# assignment guarded by the values it was planned on (compare-and-set), so a
# command another writer beat writes nothing, and a command repeated after it
# took effect writes nothing more.
#
#   status                                   print the state; writes nothing
#   arm                                      request the creation of the guard's
#                                            WAF rule. Refused unless the guard
#                                            was measurable in the last 10
#                                            minutes, production's open_until_s
#                                            is at least RENEW_WARN_S away, and
#                                            billing reconciliation passed a day
#                                            of its own past the last recon-accept
#   open production --allowance <USD>        open production with an allowance
#                                            (no --for: the guard extends it)
#   open staging --allowance <USD> --for <n>s|<n>m|<n>h
#                                            open a staging test window (at most
#                                            8 hours)
#   close production|staging                 close the environment
#   limit production --base <USD>            production's limit from the next
#                                            billing period
#   ledger-bridge                            accept the hole of every dataset
#                                            whose ledger cannot move on
#   recon-accept production --through <YYYY-MM-DD>
#                                            accept every UTC day up to that one
#                                            without billing reconciliation. Only
#                                            at rollout or after investigating a
#                                            reconciliation that stopped; never
#                                            on a schedule
#
# `open` is refused while the environment is open: the guard consumes an
# allowance, so granting one twice would add a second on top of the first.
# Close first to grant a new one.
#
# Every write shows the current state and asks for 'yes' (--yes answers it).
# The commands themselves are guard/src/operator.mjs, shared with the guard's
# tests; server/guard/tool/guard_cli.mjs runs them through the wrangler pinned
# in server/ (`wrangler d1 execute umacapture-guard --remote`).
# Exit status: 0 written or nothing to do, 1 refused or failed, 3 another writer
# changed the state first (nothing written: read the status and repeat).
#
# Run from Git Bash at the repository root:
#   bash tool/cloudflare/guard.sh <command> [...] [--yes]
# Cloudflare credentials come from tool/cloudflare/.env (see .env.example).
# GUARD_BY, when set, is recorded as the operator (default "operator").
#
# NOTE: `set -x` is deliberately never enabled, so no token is ever printed.
# ============================================================================
set -euo pipefail

export WRANGLER_SEND_METRICS=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

fail() { echo "error: $*" >&2; exit 1; }

usage="usage: $0 status | arm | ledger-bridge | open production --allowance <USD> | open staging --allowance <USD> --for <n>s|<n>m|<n>h | close production|staging | limit production --base <USD> | recon-accept production --through <YYYY-MM-DD>  [--yes]"

ASSUME_YES=0
ARGS=()
for a in "$@"; do
  if [[ "$a" == "--yes" ]]; then ASSUME_YES=1; else ARGS+=("$a"); fi
done
[[ ${#ARGS[@]} -ge 1 ]] || fail "$usage"

USD_RE='^[0-9]{1,9}(\.[0-9]{1,6})?$'
FOR_RE='^[0-9]{1,6}[smh]$'
DAY_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

# The grammar of every command, checked before anything is read. guard_cli.mjs checks the values again.
set -- "${ARGS[@]}"
case "$1" in
  status|arm|ledger-bridge)
    [[ $# -eq 1 ]] || fail "$usage" ;;
  open)
    if [[ $# -eq 4 && "$2" == production && "$3" == --allowance && "$4" =~ $USD_RE ]]; then :
    elif [[ $# -eq 6 && "$2" == staging && "$3" == --allowance && "$4" =~ $USD_RE && "$5" == --for && "$6" =~ $FOR_RE ]]; then :
    else fail "$usage"; fi ;;
  close)
    [[ $# -eq 2 && ( "$2" == production || "$2" == staging ) ]] || fail "$usage" ;;
  limit)
    [[ $# -eq 4 && "$2" == production && "$3" == --base && "$4" =~ $USD_RE ]] || fail "$usage" ;;
  recon-accept)
    [[ $# -eq 4 && "$2" == production && "$3" == --through && "$4" =~ $DAY_RE ]] || fail "$usage" ;;
  *) fail "$usage" ;;
esac

command -v node >/dev/null || fail "node not found on PATH"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE missing (copy .env.example)"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || fail "CLOUDFLARE_API_TOKEN is empty in $ENV_FILE"
[[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]] || fail "CLOUDFLARE_ACCOUNT_ID is empty in $ENV_FILE"

# Paths relative to the repository root, so the Windows node reads the same paths.
cd "$REPO_ROOT"
export GUARD_WRANGLER_JS="server/node_modules/wrangler/bin/wrangler.js"
export GUARD_WRANGLER_CONFIG="server/wrangler.guard.jsonc"
export GUARD_BY="${GUARD_BY:-operator}"
[[ -f "$GUARD_WRANGLER_JS" ]] || fail "$GUARD_WRANGLER_JS missing (run npm ci in server/)"
CLI="server/guard/tool/guard_cli.mjs"

if [[ "$1" != status ]]; then
  echo "==> current state of umacapture-guard"
  node "$CLI" status
  echo
  echo "==> about to run on the remote D1 umacapture-guard: $*"
  if [[ "$ASSUME_YES" != 1 ]]; then
    read -r -p "    Type 'yes' to write: " answer
    [[ "$answer" == "yes" ]] || fail "aborted"
  fi
fi

node "$CLI" "$@"
