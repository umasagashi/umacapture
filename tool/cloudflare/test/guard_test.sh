#!/usr/bin/env bash
# ============================================================================
# Stub test for tool/cloudflare/guard.sh. Touches nothing outside a temporary
# directory: each scenario runs a copy of the script and of server/guard/ in a
# throwaway tree whose server/node_modules/wrangler/bin/wrangler.js is a fake.
# The fake records every command line in $STUB_LOG, answers each SELECT from a
# fixed state (production open at gen 4, staging closed at gen 2, nothing
# measured, no reconciled day, a ledger that is not stalled) and answers every
# write with meta.changes $STUB_CHANGES (default 1). Nothing is sent anywhere.
#
# What the commands do to D1 (CAS, refusals, repeats) is tested on a real D1 in
# server/test/guard/operator.test.mjs; this file tests the shell: the grammar,
# the confirmation, and the wrangler command lines.
#
# Run from Git Bash:  bash tool/cloudflare/test/guard_test.sh
# Needs node.
# ============================================================================
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT

PASSED=0
FAILED=0
pass() { echo "  ok: $*"; PASSED=$((PASSED + 1)); }
flunk() { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else flunk "$name"; fi; }

TREE="$ROOT/tree"
mkdir -p "$TREE/tool/cloudflare" "$TREE/server/node_modules/wrangler/bin"
cp "$SRC_ROOT/tool/cloudflare/guard.sh" "$TREE/tool/cloudflare/guard.sh"
cp -r "$SRC_ROOT/server/guard" "$TREE/server/guard"
printf '{}\n' > "$TREE/server/wrangler.guard.jsonc"
printf 'CLOUDFLARE_API_TOKEN=stub-token\nCLOUDFLARE_ACCOUNT_ID=stub-account\n' > "$TREE/tool/cloudflare/.env"
cat > "$TREE/server/node_modules/wrangler/bin/wrangler.js" <<'JS'
const fs = require("node:fs");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.STUB_LOG, JSON.stringify(args) + "\n");
const sql = args[args.indexOf("--command") + 1];
const now = Math.floor(Date.now() / 1000);
const env = [
  { env: "production", gen: 4, mode: "open", stage_a: 0, base_limit_micros: 10000000, limit_micros: 10000000, pending_allowance_micros: null, warn_permille: 800, open_until_s: 0 },
  { env: "staging", gen: 2, mode: "closed", stage_a: 0, base_limit_micros: 0, limit_micros: null, pending_allowance_micros: null, warn_permille: 800, open_until_s: null },
];
const rows = (s) => {
  if (/^\s*(UPDATE|INSERT)/.test(s)) return null;
  if (s.includes("h.arm_requested_s")) return [{ arm_requested_s: null, last_measurable_s: null, open_until_s: 0, bill_to_s: null, accepted_to_s: null }];
  if (s.includes("FROM guard_env WHERE env =")) return env.filter((r) => s.includes(`'${r.env}'`));
  if (s.includes("FROM guard_env")) return env;
  if (s.includes("COUNT(*)")) return [{ n: 0 }];
  if (s.includes("FROM guard_ledger")) return ["workers", "d1"].map((d) => ({ dataset: d, from_s: now - 7200, to_s: now - 600 }));
  if (s.includes("FROM guard_bill ")) return [{ from_s: null, to_s: null, last_try_s: null, last_verdict: null, last_day: null }];
  return [];
};
const out = sql.split(";\n").map((s) => {
  const r = rows(s);
  return r === null
    ? { success: true, results: [], meta: { changes: Number(process.env.STUB_CHANGES ?? 1) } }
    : { success: true, results: r, meta: { changes: 0 } };
});
console.log(JSON.stringify(out));
JS

# The log as node reads it: on Windows a Git Bash path such as /tmp/... means nothing to node.
NODE_LOG="$ROOT/log"
if command -v cygpath >/dev/null; then NODE_LOG="$(cygpath -m "$NODE_LOG")"; fi

# Runs guard.sh in the tree with stdin from $1 and the rest as arguments; sets RC and OUT.
run() {
  local input="$1"; shift
  : > "$ROOT/log"
  set +e
  OUT="$(cd "$TREE" && printf '%s\n' "$input" | STUB_LOG="$NODE_LOG" bash tool/cloudflare/guard.sh "$@" 2>&1)"
  RC=$?
  set -e
}
log_has() { grep -qF -- "$1" "$ROOT/log"; }
no_write() { ! grep -qE '"(UPDATE|INSERT)' "$ROOT/log"; }
no_call() { [[ ! -s "$ROOT/log" ]]; }
rc_is() { [[ "$RC" == "$1" ]]; }
out_has() { grep -qF -- "$1" <<<"$OUT"; }

echo "(1) the grammar is checked before D1 is read"
for bad in "" "open" "open production" "open production --allowance 1 --for 1h" "open staging --allowance 1" \
  "open staging --allowance 1 --for 9d" "open staging --allowance -1 --for 1h" "close" "close dev" \
  "limit staging --base 1" "limit production --base 1.0000001" "recon-accept production --through 2026-1-1" \
  "recon-accept staging --through 2026-10-01" "status now" "renew production --for 1h"; do
  # shellcheck disable=SC2086
  run "" $bad
  check "'$bad' is refused without a wrangler call" eval 'rc_is 1 && no_call'
done

echo "(2) status reads through the pinned wrangler and asks nothing"
run "" status
check "status exits 0" rc_is 0
check "status runs d1 execute umacapture-guard --remote on the guard's config" \
  log_has '["d1","execute","umacapture-guard","--remote","-c","server/wrangler.guard.jsonc","--json","--command"'
check "status writes nothing" no_write
check "status does not ask" eval '! out_has "Type '"'"'yes'"'"'"'

echo "(3) a write not answered 'yes' sends no write"
run "no" open staging --allowance 1 --for 2h
check "the answer 'no' aborts" eval 'rc_is 1 && out_has aborted'
check "the current state was shown" out_has '"mode": "closed"'
check "no write reached wrangler" no_write

echo "(4) open staging --yes"
run "" open staging --allowance 1.5 --for 2h --yes
check "exits 0" rc_is 0
check "the UPDATE moves gen on and is guarded by the gen read" log_has "gen = gen + 1 WHERE env = 'staging' AND gen = 2"
check "it writes the allowance in micro-USD" log_has "pending_allowance_micros = 1500000"

echo "(5) a write that lost its compare-and-set exits 3"
STUB_CHANGES=0 run "" close production --yes
check "exits 3 and says so" eval 'rc_is 3 && out_has "another writer"'
check "the UPDATE was guarded by production's gen" log_has "WHERE env = 'production' AND gen = 4"

echo "(6) close of a closed environment writes nothing"
run "" close staging --yes
check "exits 0 with nothing to do" eval 'rc_is 0 && out_has "nothing to do"'
check "no write" no_write

echo "(7) limit production --base"
run "" limit production --base 20 --yes
check "exits 0" rc_is 0
check "writes base_limit_micros under gen 4" log_has "base_limit_micros = 20000000"

echo "(8) recon-accept sends its three statements in one command"
run "" recon-accept production --through 2026-10-01 --yes
check "exits 0" rc_is 0
check "one command carries the accept, the reach and open_until_s" \
  eval 'grep -F "INSERT INTO guard_bill_accepts" "$ROOT/log" | grep -F "UPDATE guard_bill SET" | grep -qF "UPDATE guard_env SET open_until_s"'

echo "(9) arm refused on the state read sends no write"
run "" arm --yes
check "exits 1 with the refusal" eval 'rc_is 1 && out_has "refused: the guard has not been measurable"'
check "no write" no_write

echo "(10) ledger-bridge on a ledger that is not stalled writes nothing"
run "" ledger-bridge --yes
check "exits 0 with nothing to do" eval 'rc_is 0 && out_has "nothing to do"'
check "no write" no_write

echo "(11) no credentials, no call"
mv "$TREE/tool/cloudflare/.env" "$ROOT/env.bak"
run "" status
check "status without .env fails before wrangler" eval 'rc_is 1 && no_call'
mv "$ROOT/env.bak" "$TREE/tool/cloudflare/.env"

echo
echo "passed $PASSED, failed $FAILED"
[[ "$FAILED" == 0 ]]
