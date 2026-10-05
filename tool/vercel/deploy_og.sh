#!/usr/bin/env bash
# ============================================================================
# Deploy the OGP image function (og/) to Vercel, as one of two targets:
#
#   preview (default)  a fresh *.vercel.app deployment. PUBLIC_ORIGIN is set
#                      for the Preview environment only and points at the
#                      staging Worker, so a preview draws staging records.
#   production         the project's production deployment
#                      (og.umacapture.com once the domain is attached).
#
# Invariant: what is uploaded is og/ at the committed HEAD. A dirty working
# tree stops the script, and the CLI that uploads it is the one pinned in
# og/package-lock.json, never whatever vercel is on PATH. Vercel builds the
# function remotely from og/package-lock.json.
#
# Stages:
#   0 preflight (tools, token, project link, for a preview that the project
#     already has a production deployment, clean tree), then `npm ci` in og/
#   1 npm test in og/
#   2 confirmation gate ('yes')       <- --dry-run stops here;
#                                        --yes answers it without a prompt
#   3 vercel deploy
#   4 verify through the deployment URL: a well-formed id that does not exist
#     answers 404 from the function (not from the platform), and a query
#     string answers 404 without the function fetching anything
#
# Credentials come from tool/vercel/.env (gitignored):
#   VERCEL_TOKEN                     required; the CLI reads it from the
#                                    environment, so it never appears in argv
#   VERCEL_AUTOMATION_BYPASS_SECRET  optional; sent as a header by stage 4
#                                    only, because preview deployments sit
#                                    behind Vercel Authentication
# `vercel login` is never used: it would change the machine-wide account.
#
# The project link (og/.vercel/project.json, gitignored) is made once, by hand,
# as docs/web-deploy.md describes. This script refuses to create it, because
# `vercel link` also connects the Git repository and creates files.
#
# Run from Git Bash at the repository root:
#   bash tool/vercel/deploy_og.sh [--target preview|production] [--dry-run] [--yes]
#
# NOTE: `set -x` is deliberately never enabled, so no secret is ever printed.
# ============================================================================
set -euo pipefail

# The Vercel CLI reports usage to telemetry.vercel.com unless this is set.
# The environment variable is used instead of `vercel telemetry disable`,
# which would write the user's global config.
export VERCEL_TELEMETRY_DISABLED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OG_DIR="og"
ENV_FILE="$SCRIPT_DIR/.env"
VERCEL="$REPO_ROOT/$OG_DIR/node_modules/.bin/vercel"
# The CLI's own config (it writes one even with a token) stays inside the
# gitignored og/.vercel/ rather than in the user's profile.
GLOBAL_CONFIG="$REPO_ROOT/$OG_DIR/.vercel/global"
# Crockford base32, 10 characters: the shape of a public id, never issued.
ABSENT_ID="zzzzzzzzzz"

step() { echo; echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

usage="usage: $0 [--target preview|production] [--dry-run] [--yes]"
TARGET=preview
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) [[ $# -ge 2 ]] || fail "$usage"; TARGET="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) fail "$usage" ;;
  esac
  shift
done

case "$TARGET" in
  # The pinned CLI drops `--target preview` before it calls the API, so this
  # deploys exactly like a bare `vercel deploy`. That lands on production while
  # the project has no production deployment; stage 0 refuses that case.
  preview) DEPLOY_ARGS=(--target preview) ;;
  production) DEPLOY_ARGS=(--prod) ;;
  *) fail "$usage" ;;
esac

cd "$REPO_ROOT"

# ---- 0 preflight -------------------------------------------------------------
step "0 preflight ($TARGET)"
for tool in git curl npm node; do
  command -v "$tool" >/dev/null || fail "$tool not found on PATH"
done
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE missing"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
[[ -n "${VERCEL_TOKEN:-}" ]] || fail "VERCEL_TOKEN is empty in $ENV_FILE"
[[ -f "$OG_DIR/.vercel/project.json" ]] \
  || fail "$OG_DIR/.vercel/project.json missing; link the project first (docs/web-deploy.md)"
# Vercel makes a project's first deployment a production one whatever target
# was asked for, and the pinned CLI cannot ask for preview anyway (see
# DEPLOY_ARGS). So a preview is refused, before anything is created, unless the
# project already has a production deployment. A read-only GET; the token goes
# through node's environment, never argv. Any doubt refuses.
if [[ "$TARGET" == preview ]]; then
  node -e '
    const { projectId, orgId } = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    fetch(`https://api.vercel.com/v9/projects/${projectId}?teamId=${orgId}`,
          { headers: { authorization: `Bearer ${process.env.VERCEL_TOKEN}` } })
      .then(async (r) => {
        if (!r.ok) throw new Error(`project lookup: HTTP ${r.status}`);
        const p = await r.json();
        if (p.hasDeployments !== true || !p.targets?.production) {
          console.error("error: the project has no production deployment, so Vercel would make this");
          console.error("       deployment production. Nothing was deployed. Deploy with");
          console.error("       --target production first (docs/web-deploy.md).");
          process.exitCode = 1;
        }
      })
      // exitCode, not exit(): exiting under a live fetch aborts node on Windows.
      .catch((e) => { console.error(`error: ${e.message}`); process.exitCode = 1; });
  ' "$OG_DIR/.vercel/project.json" || exit 1
  echo "    the project has a production deployment; a preview stays a preview"
fi
[[ -z "$(git status --porcelain)" ]] || fail "working tree is not clean; commit or remove changes first"
GIT_SHA="$(git rev-parse HEAD)"
(cd "$OG_DIR" && npm ci --no-audit --no-fund)
[[ -x "$VERCEL" ]] || fail "$VERCEL missing after npm ci"
echo "    HEAD $GIT_SHA, vercel $("$VERCEL" --version 2>/dev/null | tail -1)"

# ---- 1 test ------------------------------------------------------------------
step "1 npm test"
(cd "$OG_DIR" && npm test)

# ---- 2 confirmation gate -----------------------------------------------------
step "2 confirm"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "    --dry-run: stopping before any upload to Vercel."
  exit 0
fi
if [[ "$ASSUME_YES" != 1 ]]; then
  read -r -p "    Deploy $GIT_SHA as a $TARGET deployment? Type 'yes': " answer
  [[ "$answer" == "yes" ]] || fail "aborted"
fi

# ---- 3 deploy ----------------------------------------------------------------
step "3 vercel deploy"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# stdout is a JSON summary; progress goes to stderr.
(cd "$OG_DIR" && "$VERCEL" deploy --yes --json --global-config "$GLOBAL_CONFIG" \
  "${DEPLOY_ARGS[@]}" --meta "git_sha=$GIT_SHA") > "$work/deploy.json"
# Refuses a deployment that landed on another target than the one asked for.
URL="$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).deployment;
  // The API reports a preview deployment with a null target.
  if ((d.target ?? "preview") !== process.argv[2]) { console.error("deployed as " + d.target); process.exit(1); }
  console.log(d.url);' "$work/deploy.json" "$TARGET" | tr -d '\r\n')"
[[ -n "$URL" ]] || fail "the deployment is not a $TARGET deployment"
[[ "$URL" =~ ^https://[a-z0-9.-]+\.vercel\.app$ ]] || fail "unexpected deployment URL: $URL"
echo "    deployed: $URL"

# ---- 4 verify ----------------------------------------------------------------
step "4 verify via $URL"
curl_args=(-sS -o /dev/null -D "$work/headers" -w '%{http_code}')
if [[ -n "${VERCEL_AUTOMATION_BYPASS_SECRET:-}" ]]; then
  curl_args+=(-H "x-vercel-protection-bypass: $VERCEL_AUTOMATION_BYPASS_SECRET")
fi
probe() { curl "${curl_args[@]}" "$URL$1" || echo "000"; }
header() { tr -d '\r' < "$work/headers" | awk -F': ' -v h="$1" 'tolower($1)==h{print $2}'; }

# The function's own 404 carries its cache header; the platform's does not.
code="$(probe "/r/$ABSENT_ID.png")"
[[ "$code" == "404" ]] || fail "/r/$ABSENT_ID.png: HTTP $code, expected 404"
[[ "$(header x-vercel-cache)" != "" ]] || fail "/r/$ABSENT_ID.png was not answered by the deployment"
[[ "$(header content-type)" != text/html* ]] || fail "/r/$ABSENT_ID.png: the platform's 404 page, not the function's"
code="$(probe "/r/$ABSENT_ID.png?a=1")"
[[ "$code" == "404" ]] || fail "query string: HTTP $code, expected 404"
echo "    an absent id and a query string both answer 404 from the function"

step "done: $GIT_SHA is at $URL ($TARGET)"
