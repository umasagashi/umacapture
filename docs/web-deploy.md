# Deploying the web app

The web app is served from `https://umacapture.com` by **Cloudflare Workers Static Assets**. This
first deployment is **assets only**: `server/wrangler.assets-only.jsonc` has no `main`, so no Worker
script runs, every request is a static-asset request, and the Worker request quota is not used.

Deployment runs from the one PC that can build the wasm recognition core (CI cannot; see
`docs/wasm-toolchain/`). `tool/cloudflare/deploy_web.sh` does the whole run.

## What is served, and how

| Piece | Where it comes from |
|---|---|
| Files | `build/web/`, built in the same run by `tool/build_web.sh` from a clean `HEAD` |
| Excluded files | `web/.assetsignore` (copied into `build/web/`): `*.map` (uploaded to Sentry, not public) and `.last_build_id` |
| Response headers | `web/_headers` (copied into `build/web/`): `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`, `X-Content-Type-Options: nosniff` on every file |
| Caching | The platform default, `Cache-Control: public, max-age=0, must-revalidate` with an `ETag`. Not overridden: `main.dart.js`, `worker.js`, `*.mjs` and `wasm/*` have fixed names, so every visit revalidates and an old script never runs against a new wasm module. Revalidations of static assets are free |
| CanvasKit | Served from the bundle's own `canvaskit/`. `tool/build_web.sh` always passes `--no-web-resources-cdn`, so nothing is loaded from `www.gstatic.com` |
| Fonts | Still fetched at runtime from `fonts.gstatic.com` (not bundled) |
| Unknown paths | Static 404 (`not_found_handling: "none"`). The app uses hash routing and needs no server-side path but `/` |
| Build marker | `build/web/deploy.json`: `git_sha`, `built_at`, `wasm_sha256` of what was deployed |

With the real COOP/COEP headers the page is cross-origin isolated on the first load, and
`web/coi-serviceworker.js` returns before registering a service worker. The shim stays in
`web/index.html` for `flutter run`, whose dev server cannot send headers.

`_headers` only applies to static responses. A response built by a Worker script (the record
pages `/r/*` and the API `/api/*` that a later stage adds) does not get COOP/COEP.

## One-time preparation (the owner does this)

These are outward-facing or account-level operations. Nothing in the repository performs them.

1. **API token.** Add to the account API token in `tool/cloudflare/.env` (see
   `tool/cloudflare/.env.example`):
   - Account › Workers Scripts › Edit
   - Zone › Workers Routes › Edit (zone `umacapture.com`)

   Alternatively run `wrangler login` once (it opens a browser sign-in) and leave the token out.
2. **Sentry.** `deploy_web.sh` uploads the source maps with `tool/upload_web_sourcemaps.sh`, an
   authenticated transmission to Sentry. Put a Sentry auth token with release / artifact upload
   rights in `~/.sentry_token` and export it before deploying (below).
3. **Pre-deployment checks.** Confirm and write down the result before the first deployment.
   They are the grounds for the claim that this deployment cannot be billed:
   - The account is on **Workers Free** (Dashboard › Workers & Pages › Plans). On Free, exceeding
     a limit stops requests instead of billing.
   - `server/wrangler.assets-only.jsonc` declares **no billable binding** (no R2, no Workers Paid
     product, no D1 yet). It has none today; read it again before deploying.
   - The **list of existing Workers** in the account (Workers & Pages › Overview). They share the
     daily request quota with this one; write the names down.
   - The **entrance list** below matches the actual settings.
4. **Custom domain.** The config routes `umacapture.com` as a custom domain
   (`"custom_domain": true`). The first `wrangler deploy` creates the DNS record and certificate.
   If `umacapture.com` already has a DNS record pointing elsewhere, the deploy fails and the record
   has to be removed in the dashboard first. Check this before the first deployment.

### Entrance list

| Entrance | What it serves | Zone WAF | Expected setting |
|---|---|---|---|
| `umacapture.com` (custom domain) | The web app | Applies | The only production entrance |
| `umacapture-web.<account>.workers.dev` | Would serve the same Worker | Does not apply | Closed: `workers_dev: false` |
| Per-version preview URLs | Would serve each version | Does not apply | Closed: `preview_urls: false` |
| `data.umacapture.com` (R2) | Recognizer modules, announcements | — | Unrelated to this deployment |

After the first deployment, confirm in the dashboard (Worker › Settings › Domains & Routes) that
`workers.dev` and preview URLs are shown as disabled and that `umacapture.com` is the only domain.

## Deploying

From Git Bash at the repository root, on a clean, committed tree:

```bash
export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
bash tool/cloudflare/deploy_web.sh --dry-run   # builds, uploads maps to Sentry, validates; no Cloudflare upload
bash tool/cloudflare/deploy_web.sh             # the same, then asks 'yes' and deploys
```

The script stops on a dirty tree, rebuilds `build/web/` from scratch (never reusing an earlier
build), uploads source maps (which rewrites the JS files with debug ids, so this runs before the
upload), writes `deploy.json`, runs `wrangler deploy --dry-run`, asks for confirmation, deploys,
then verifies through the public URL that:

- `https://umacapture.com/deploy.json` is byte-identical to the local one;
- `/` carries `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`;
- `/main.dart.js.map` and `/r/0000000000` answer 404.

A redeploy is needed whenever the app, `web/`, or the wasm core changes. A new recognizer module
does not need one: the app downloads modules from `data.umacapture.com` at runtime.

## After the first deployment — checks only a real browser can make

In a desktop Chromium-based browser and in Firefox, and in Android Chrome for video import:

1. `crossOriginIsolated` is `true` in the console on the **first** load.
2. `await navigator.serviceWorker.getRegistrations()` is an empty array.
3. The network log shows CanvasKit (`canvaskit.js`, `canvaskit.wasm`) from `umacapture.com` and no
   request to `www.gstatic.com`.
4. Capture (screen share) and video import both work.
5. The dashboard's "このサイトについて" card links to `/notice/`.

## The pinned wrangler

wrangler is pinned to one exact version in `server/package.json`, with `server/package-lock.json`
fixing everything it pulls in. `deploy_web.sh` runs `npm ci` in `server/` and calls
`server/node_modules/.bin/wrangler`; a wrangler installed globally or on `PATH` is never used.
Run wrangler by hand the same way:

```bash
(cd server && npm ci --no-audit --no-fund)
export WRANGLER_SEND_METRICS=false
server/node_modules/.bin/wrangler --version
```

Usage metrics are off twice over: every wrangler config sets `"send_metrics": false`, and
`WRANGLER_SEND_METRICS=false` (which `deploy_web.sh` exports) overrides the config key and the
consent stored in wrangler's user config. With `WRANGLER_LOG=debug` wrangler prints
`Metrics dispatcher: Dispatching disabled` for each event it would have sent.

To move to a newer wrangler, change the version in `server/package.json`, run `npm install` in
`server/`, and commit both files; re-check the `compatibility_date` comments in the configs, which
name the newest date the pinned version accepts.

## Local check without Cloudflare

`wrangler dev` serves the same config from the local machine, applying `_headers`,
`.assetsignore` and the 404 handling the way the platform does. Nothing is uploaded.

```bash
WRANGLER_SEND_METRICS=false server/node_modules/.bin/wrangler dev -c server/wrangler.assets-only.jsonc --port 8787
curl -sI http://localhost:8787/
```

The custom-domain route is ignored locally. This shows the headers the config produces; it does
not show that Cloudflare's edge applies them, which only the post-deployment checks above do.

## Rolling back and switching off

| Goal | How |
|---|---|
| Return to the previous version | `server/node_modules/.bin/wrangler rollback -c server/wrangler.assets-only.jsonc` |
| Take the site off the domain | Remove the `umacapture.com` custom domain in the dashboard |
