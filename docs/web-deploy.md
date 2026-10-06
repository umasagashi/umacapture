# Deploying the web app

The web app is served from `https://umacapture.com` by **Cloudflare Workers Static Assets**,
together with the **record-sharing Worker** (`server/src/`, configured by `server/wrangler.jsonc`)
and its D1 database. The Worker answers the record pages `/r/<id>`, their JSON `/r/<id>.json` and
the API under `/api/`, and answers 404 to any other path that matches no file. A request for a file
in `build/web/` is a static-asset request: no Worker script runs and the Worker request quota is
not used.

Record sharing can be switched off without touching the app: `server/wrangler.assets-only.jsonc`
deploys the same assets with no Worker script at all, so every path that matches no file gets the
static 404 (see "Rolling back and switching off").

Deployment runs from the one PC that can build the wasm recognition core (CI cannot; see
`docs/wasm-toolchain/`). `tool/cloudflare/deploy_web.sh` does the whole run.

## What is served, and how

| Piece | Where it comes from |
|---|---|
| Files | `build/web/`, built in the same run by `tool/build_web.sh` from a clean `HEAD` |
| Excluded files | `web/.assetsignore` (copied into `build/web/`): `*.map` (uploaded to Sentry, not public) and `.last_build_id` |
| Response headers | `web/_headers` (copied into `build/web/`): `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`, `X-Content-Type-Options: nosniff` on every file |
| Caching | The platform default, `Cache-Control: public, max-age=0, must-revalidate` with an `ETag`, except `/og/fonts/*` (one day, see the Vercel section). Not overridden: `main.dart.js`, `worker.js`, `*.mjs` and `wasm/*` have fixed names, so every visit revalidates and an old script never runs against a new wasm module. Revalidations of static assets are free |
| CanvasKit | Served from the bundle's own `canvaskit/`. `tool/build_web.sh` always passes `--no-web-resources-cdn`, so nothing is loaded from `www.gstatic.com` |
| Fonts | Still fetched at runtime from `fonts.gstatic.com` (not bundled) |
| Record pages and API | `/r/*` and `/api/*` run the Worker first (`assets.run_worker_first`), so a static file can never shadow an endpoint |
| Unknown paths | `not_found_handling: "none"`: no SPA fallback. With sharing on, the Worker's 404, which carries `X-Robots-Tag: noindex`; with sharing off, the static 404. The app uses hash routing and needs no server-side path but `/` |
| Build marker | `build/web/deploy.json`: `git_sha`, `built_at`, `wasm_sha256` of what was deployed, and with sharing on `tables_module_sha256`, the module archive the Worker's name tables were built from |

With the real COOP/COEP headers the page is cross-origin isolated on the first load, and
`web/coi-serviceworker.js` returns before registering a service worker. The shim stays in
`web/index.html` for `flutter run`, whose dev server cannot send headers.

`_headers` only applies to static responses. A response the Worker builds (the record pages and
JSON, the API, and its 404) does not get COOP/COEP or anything else `_headers` lists.

## One-time preparation (the owner does this)

These are outward-facing or account-level operations. Nothing in the repository performs them.

1. **API token.** Add to the account API token in `tool/cloudflare/.env` (see
   `tool/cloudflare/.env.example`):
   - Account › Workers Scripts › Edit
   - Zone › Workers Routes › Edit (zone `umacapture.com`)
   - Account › D1 › Edit (create the databases, apply migrations)
   - For the release checks, read only: Account › Turnstile › Read, Zone › Zone WAF › Read,
     Account › Billing › Read

   Alternatively run `wrangler login` once (it opens a browser sign-in) and leave the token out.
2. **Sentry.** `deploy_web.sh` uploads the source maps with `tool/upload_web_sourcemaps.sh`, an
   authenticated transmission to Sentry. Put a Sentry auth token with release / artifact upload
   rights in `~/.sentry_token` and export it before deploying (below).
3. **Pre-deployment checks.** Confirm and write down the result before the first deployment.
   They are the grounds for the claim that this deployment cannot be billed:
   - The account is on **Workers Free** (Dashboard › Workers & Pages › Plans). On Free, exceeding
     a limit stops requests instead of billing, and D1 past its daily limits refuses queries with
     an error until 00:00 UTC.
   - `server/wrangler.jsonc` declares **no billable binding**: its one binding is the D1 database
     `DB`; no R2 and no Workers Paid product. `server/wrangler.assets-only.jsonc` declares none at
     all. Read both again before deploying.
   - The **list of existing Workers** in the account (Workers & Pages › Overview). They share the
     daily request quota with this one; write the names down.
   - The **entrance list** below matches the actual settings.
4. **Custom domain.** The config routes `umacapture.com` as a custom domain
   (`"custom_domain": true`). The first `wrangler deploy` creates the DNS record and certificate.
   If `umacapture.com` already has a DNS record pointing elsewhere, the deploy fails and the record
   has to be removed in the dashboard first. Check this before the first deployment.
5. **Production database.** Create it once and apply the schema in `server/migrations/`:

   ```bash
   server/node_modules/.bin/wrangler d1 create umacapture-share
   # write the printed id into the top-level d1_databases of server/wrangler.jsonc, commit, then:
   server/node_modules/.bin/wrangler d1 migrations apply umacapture-share --remote -c server/wrangler.jsonc
   ```

   The top-level `d1_databases` entry is the staging one with the production name and id: binding
   `DB`, `database_name` `umacapture-share`, `migrations_dir` `migrations`.
6. **Turnstile.** Create the widget in the dashboard for the hostname `umacapture.com`, in Managed
   mode. Its sitekey goes into the config (below). Its secret key is a Worker secret, never a var
   and never in a file in the repository; put it before the first deployment with the Worker:

   ```bash
   server/node_modules/.bin/wrangler secret put TURNSTILE_SECRET -c server/wrangler.jsonc
   ```

   In a terminal `secret put` asks for the value; otherwise it reads it from standard input.
   It creates a new version of the Worker and deploys it at once; it uploads no local code. A
   Worker running without the secret
   refuses every ticket (`403 verification_failed`). A deployment never deletes a secret.
7. **Production config.** The top level of `server/wrangler.jsonc` carries what `env.staging`
   does, with production values: `"main": "src/index.mjs"`, `assets.run_worker_first`
   `["/r/*", "/api/*"]`, `"observability": { "enabled": false }`, the D1 entry above, and these
   `vars`, which are every variable the Worker
   reads:

   | Var | Production value |
   |---|---|
   | `PUBLIC_ORIGIN` | `https://umacapture.com` |
   | `OG_IMAGE_MODE` | `"static"` until `og.umacapture.com` answers, then `"vercel"` (see the Vercel section) |
   | `OG_IMAGE_ORIGIN` | `https://og.umacapture.com` |
   | `PUBLISH_ENABLED` | `"true"`; `"false"` stops new tickets and publishes (`503 publishing_paused`) while reads and withdrawals go on |
   | `TURNSTILE_SITEKEY` | The widget's sitekey |
   | `TURNSTILE_TESTING_KEY` | `"false"`: answers issued for Turnstile's testing secrets are refused |
   | `TURNSTILE_HOSTNAME` | `umacapture.com` |
   | `TURNSTILE_ACTION` | `publish` |

   `wrangler deploy` replaces the Worker's vars with the ones in the config, so a var set in the
   dashboard does not survive the next deployment.
8. **Zone rate limiting.** One WAF rate limiting rule on the `umacapture.com` zone: requests whose URI path starts with `/r/` or `/api/` and that do not come
   from a verified bot, counted per IP, 10 requests in 10 seconds, blocked for 10 seconds. The Free
   plan allows exactly one such rule, with those fields, that counting key, that period and that
   timeout; if the zone already has one, decide which to keep rather than overwriting it.

### Entrance list

| Entrance | What it serves | Zone WAF | Expected setting |
|---|---|---|---|
| `umacapture.com` (custom domain) | The web app and the record-sharing Worker (`umacapture-web`) | Applies: the rate limiting rule on `/r/` and `/api/` | Production entrance |
| `data.umacapture.com` (custom domain) | Recognizer modules and announcements (`umacapture-data`, static assets only, no R2) | Applies, unused | Production entrance |
| `og.umacapture.com` (Vercel project domain, CNAME, DNS only) | The OGP image function (`umacapture-og` on Vercel) | Does not apply: the zone does not proxy it. The Vercel Firewall rule applies (see the Vercel section) | Production entrance |
| `umacapture-og.vercel.app` | The project's own production domain on Vercel | Does not apply | Kept. It answers without the bypass header: `/` gets the platform's 404 and `/r/<id>.png` reaches the function, because production domains are outside deployment protection. Whether the Vercel Firewall rule also applies here is not measured: the burst test ran against `og.umacapture.com` only |
| `umacapture-web-staging.umasagashi.workers.dev` | Staging (`umacapture-web-staging`), assets only once sharing is off there | Does not apply | Open, linked from nowhere (see "Staging") |
| `umacapture-web.<account>.workers.dev`, `umacapture-data.<account>.workers.dev` | Would serve the same Workers | Does not apply | Closed: `workers_dev: false` |
| Per-version preview URLs (both Workers) | Would serve each version | Does not apply | Closed: `preview_urls: false` |
| R2 bucket `umasagashi-data` | Nothing public | — | No custom domain, `r2.dev` disabled |

After the first deployment, confirm in the dashboard (Worker › Settings › Domains & Routes) that
`workers.dev` and preview URLs are shown as disabled and that each Worker has exactly one domain:
`umacapture.com` for `umacapture-web`, `data.umacapture.com` for `umacapture-data`. No zone route
points at either of them.

## Deploying

From Git Bash at the repository root, on a clean, committed tree:

```bash
export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
bash tool/cloudflare/deploy_web.sh --dry-run   # builds, uploads maps to Sentry, validates; no Cloudflare upload
bash tool/cloudflare/deploy_web.sh             # the same, then asks 'yes' and deploys
```

Two independent options pick what is deployed: `--target production|staging` (default
`production`) and `--sharing on|off` (default `on`). With sharing on the config is
`server/wrangler.jsonc`; with sharing off it is `server/wrangler.assets-only.jsonc`. `--yes`
answers the confirmation without a prompt; `--dry-run` stops before it.

The script stops on a dirty tree, rebuilds `build/web/` from scratch (never reusing an earlier
build), uploads source maps (production only; this rewrites the JS files with debug ids, so it runs
before the upload), builds the name tables (sharing on, below), writes `deploy.json`, runs
`wrangler deploy --dry-run`, asks for confirmation, deploys, then verifies through the public URL
that:

- `https://umacapture.com/deploy.json` is byte-identical to the local one;
- `/` carries `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`;
- `/main.dart.js.map` answers 404;
- `/r/0000000000` answers 404 from the side the `--sharing` option expects: with sharing on the
  Worker's 404, which carries `X-Robots-Tag: noindex`; with sharing off the static 404, which
  carries no `X-Robots-Tag`. A deployment whose Worker did not come up, or did not go away, stops
  here.

`wrangler deploy` ends by printing `Current Version ID:`. Write it down with the `git_sha` and
`tables_module_sha256` of that `deploy.json`: a rollback names the version it returns to (see
"Rolling back and switching off").

**Name tables.** With sharing on, the run builds `server/src/tables.generated.json` with
`tool/cloudflare/build_share_tables.py` from the module archive the live pointer on
`data.umacapture.com` names, and records that archive's sha256 in `deploy.json` as
`tables_module_sha256`. A published record stores ids, and its names are looked up in the tables
deployed when it is read, so the tables must only grow at the end. Each target has its own D1 and
so its own baseline, `tool/cloudflare/.deploy-backup/tables.<target>.json` (gitignored; it holds
game text), which the script passes as `--previous`; `build_share_tables.py` has no default
baseline. The run stops before deploying if the tables are not append-only against it. A target's
first run with sharing has no baseline, and the check is skipped. Only after the deployment has
been verified does the run copy the deployed tables to the baseline, so a run that stopped earlier
leaves the baseline as it was.

A redeploy is needed whenever the app, `web/`, or the wasm core changes. The app itself does not
need one for a new recognizer module: it downloads modules from `data.umacapture.com` at runtime,
and they are published there with `publish_modules.sh` (see "Publishing to data.umacapture.com"
below). The Worker does: it resolves names only through the tables it was deployed with, so after
publishing a new module set, deploy each target that has sharing on again.

### After a deployment with sharing on — the Turnstile check

This shows that production does not accept Turnstile's testing pair. Turnstile's testing sitekeys
produce the dummy token `XXXX.DUMMY.TOKEN.XXXX`, which a production secret key rejects:

```bash
H=$(python -c "import secrets; print(secrets.token_hex(32))")   # a ticket hash no one holds the source of
curl -sS -i -X POST https://umacapture.com/api/tickets \
  -H 'Content-Type: application/json' \
  --data "{\"h\":\"$H\",\"token\":\"XXXX.DUMMY.TOKEN.XXXX\"}"
```

- Expected: `403` with `{"error":"verification_failed"}`. The body has exactly the two keys `h` and
  `token`; any other key is a `400`.
- It shows that the Worker does not run on the always-passing testing secret together with
  `TURNSTILE_TESTING_KEY: "true"`, the only combination that issues a ticket for this token.
- It does not show that `TURNSTILE_TESTING_KEY` is `"false"` (a real secret refuses the dummy token
  either way), nor tell a missing or wrong secret, or a failed call to siteverify, from a working
  one: all of them answer `403`. For the first, read `vars.TURNSTILE_TESTING_KEY` at the top level
  of `server/wrangler.jsonc` as of the `git_sha` the live `/deploy.json` names (a deployment takes
  its vars from the config); for the second, publish a record from the web app with the real widget.
- A `204` means the testing pair is live: stop sharing at once (below). The ticket it issued is
  bound to `H`, whose source no one has, so it cannot be used, but it and one count of the day's
  ticket limit stay in D1.

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
fixing everything it pulls in. `deploy_web.sh` and `publish_modules.sh` run `npm ci` in `server/`
and call `server/node_modules/.bin/wrangler`; a wrangler installed globally or on `PATH` is never
used.
Run wrangler by hand the same way:

```bash
(cd server && npm ci --no-audit --no-fund)
export WRANGLER_SEND_METRICS=false
server/node_modules/.bin/wrangler --version
```

Usage metrics are off twice over: `server/wrangler.assets-only.jsonc`, `server/wrangler.jsonc` and
`server/wrangler.data.jsonc` set `"send_metrics": false`, and `WRANGLER_SEND_METRICS=false` (which
`deploy_web.sh` and `publish_modules.sh` export) overrides the config key and the consent stored in
wrangler's user config. With `WRANGLER_LOG=debug` wrangler prints
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

## Staging

`bash tool/cloudflare/deploy_web.sh --target staging [--sharing on|off] [--dry-run] [--yes]`
deploys the same `build/web/` to `https://umacapture-web-staging.umasagashi.workers.dev`, from
`env.staging` of the config the `--sharing` option picks: with sharing on, together with the
record-sharing Worker (`server/src/`) and the staging database, from `server/wrangler.jsonc`; with
sharing off, the assets alone, from `server/wrangler.assets-only.jsonc`. Both name the same Worker,
`umacapture-web-staging`, so either deployment replaces the other. The invariants are the
production ones: a clean tree, a fresh build from `HEAD` in the same run, and a `deploy.json`
verified through the public URL.

- **Credentials.** The API token also needs Account › D1 › Edit (`tool/cloudflare/.env.example`).
  The staging database (`umacapture-share-staging`) is created once by hand, its id written into
  `env.staging.d1_databases`, and the migrations applied with
  `wrangler d1 migrations apply umacapture-share-staging --env staging --remote -c server/wrangler.jsonc`.
  The Turnstile secret is a Worker secret, set once with
  `wrangler secret put TURNSTILE_SECRET --env staging -c server/wrangler.jsonc`; staging uses
  Turnstile's always-passing test keys, so its publish endpoint has no abuse protection.
- **workers.dev.** Staging has no custom domain. Its `workers.dev` URL bypasses the zone WAF and
  anyone who has it can open it; nothing links to it. It shares the account's daily Worker and D1
  quotas with production.
- **No Sentry.** A staging run uploads no source maps and needs no `SENTRY_AUTH_TOKEN`; the maps
  are still excluded from the deployment by `.assetsignore`.
- **Name tables.** With sharing on, a staging run builds and checks the tables as production does
  (see "Deploying"), against staging's own baseline
  `tool/cloudflare/.deploy-backup/tables.staging.json`.
- **Local web builds.** A web app served locally (`serve_web_build.py`) cannot call the staging
  API: the API is same-origin only. Test sharing from the web app on the staging host; a staging
  run builds it with `--dart-define=UMACAPTURE_SHARING_ORIGIN=` set to the staging URL, so it
  shares through the staging Worker rather than `umacapture.com`.
- **Stopping staging.** `env.staging.vars.PUBLISH_ENABLED: "false"` and a redeploy stop new
  tickets and publishes while reads and withdrawals go on.
  `bash tool/cloudflare/deploy_web.sh --target staging --sharing off` takes the Worker off staging
  and keeps its assets: `/r/` and `/api/` get the static 404, and staging no longer uses the Worker
  request quota or the D1 quota it shares with production. Do this before the Worker ships to
  production. The staging database is left as it is; deleting it is a separate step.

## Publishing to data.umacapture.com

`https://data.umacapture.com` serves what the apps download at run time: the recognizer module
pointer and archives, the news, and the Sentry configuration. The released Windows app and the web
app both read it, the web app cross-origin. It is a second static-assets-only Worker,
`umacapture-data` (`server/wrangler.data.jsonc`): no `main`, no binding, and no R2 behind it, so
every request is a free static-asset request and an unknown path is the static 404.
`tool/cloudflare/publish_modules.sh` assembles the whole served tree in `build/data-site/` on every
run and deploys it; never run a bare `wrangler deploy` against this config.

| Path | Where it comes from |
|---|---|
| `umacapture/version_info.json` | The pointer: the zip's `modules/version_info.json` plus `module_archive` (path, sha256, size) |
| `umacapture/modules.zip` | The archive the pointer names, under its permanent "latest" name |
| `umacapture/modules/<sha256>.zip` | Content-addressed archives: this run's, and those carried over from the live host (retention below) |
| `umacapture/news.md`, `umacapture/sentry_rate_limit.json`, `umacapture/sentry_sample.json` | `server/data-site/umacapture/`, hand-written and committed |
| Response headers | `server/data-site/_headers`: `Access-Control-Allow-Origin: *` on `/umacapture/*`, and per file the cache lifetime and, where the default is not what the apps expect, the content type and disposition |
| `deploy.json` | `git_sha`, `built_at`, `phase`, `pointer_sha256`, and every served archive with its `sha256`, `size` and `published_at` |

The files under `server/data-site/` are served byte for byte, so `.gitattributes` marks them
`-text`: with `core.autocrlf` a checkout would otherwise change the bytes the apps download. The
script refuses to run when `_headers` does not give `/umacapture/*` the CORS header, since the web
app could not read the host without it.

```bash
bash tool/cloudflare/publish_modules.sh <modules.zip> --dry-run   # checks and assembles; no deploy
bash tool/cloudflare/publish_modules.sh <modules.zip>             # the same, then asks 'yes' and publishes
bash tool/cloudflare/publish_modules.sh                           # no zip: re-publish the live archive
```

- **Preconditions.** `server/data-site/`, `server/wrangler.data.jsonc`, `tool/cloudflare/`, and the
  `npm ci` inputs `server/package.json` and `server/package-lock.json` that pin the deploying
  wrangler, are committed with nothing modified or untracked under them, so `deploy.json`'s
  `git_sha` names what is served and what deployed it. The rest of the tree may be dirty. Any committed `HEAD` will do; it need not be `develop`. The credentials are the
  `tool/cloudflare/.env` ones `deploy_web.sh` uses (Workers Scripts and Workers Routes, Edit).
- **`--yes`** skips only the confirmation, for a caller that has already decided to publish:
  umasagashi-trainer runs `publish_modules.sh <zip> --yes` at the end of its deploy. Every check
  still runs, and `--dry-run` still wins over it.
- **No zip** (a news-only update). The archive the live pointer names is fetched back, checked
  against the pointer's sha256 and size, and published again, so the pointer stays byte for byte
  the same and only the static files change. Use it after editing `server/data-site/`.
- **Two deploys per publish.** The pointer only ever names an archive already verified through the
  public URL. Phase 1 serves the new archive beside the current pointer and alias and is checked by
  a GET of the new archive; only then does phase 2 switch the pointer and the alias together. A
  phase 2 that cannot be verified is answered by deploying phase 1 again. When the live pointer
  already names the archive (a re-publish), phase 1 is skipped and the run deploys once.
- **Archives already published stay published.** A client may fetch an archive long after it read
  the pointer, so every archive the live `deploy.json` lists is fetched back, checked against its
  name and size, and carried into the new tree; one that does not match stops the run before any
  deploy. An archive is dropped once it was published more than 30 days ago, except the one this run
  serves, the one the live pointer names, and the most recently published other one (the previous
  version), which stay whatever their age. One whose `published_at` cannot be read is kept.
- **Where it reads and where it checks.** `DATA_READ_ROOT` is where the live pointer, `deploy.json`
  and archives are read from; `DATA_VERIFY_ROOT` is where the deploy is verified. Both default to
  `https://data.umacapture.com`; setting them apart fills a parallel host from the one in service.
- **Backup.** Each run copies the live pointer, the archive it names and the new pointer to
  `tool/cloudflare/.publish-backup/<UTC time>/` (gitignored).

### Changing the custom domain: only from a terminal

`server/wrangler.data.jsonc` names `data.umacapture.com` as a custom domain of `umacapture-data`.
While that stays as it is, a deploy has nothing to confirm, and a run without a terminal (the
trainer's) is fine. A publish that **changes** the custom domain has to run in a terminal where both
stdin and stdout are the terminal: wrangler asks before it overrides an existing DNS record or takes
the name from another Worker only in that case. When stdout is not a terminal, it overrides without
asking. When stdout is a terminal but stdin is not, or when it detects a CI environment, it answers
its own confirmation with yes. Wrapping the command in `$(…)`, piping it through `tee`, feeding it
input from a file, or starting it as a subprocess all count as no terminal.

### Rolling back the data host

- **Publish the previous archive.** `bash tool/cloudflare/publish_modules.sh <older modules.zip>`;
  every run prints the backup it made, whose `modules.zip` is the archive that was live before it.
  The run says when it goes back to an older `recognizer_version`.
- **Faster: `server/node_modules/.bin/wrangler rollback <version-id> -c server/wrangler.data.jsonc`.**
  The version to return to is the one just before that publish began; pick it with
  `server/node_modules/.bin/wrangler deployments list -c server/wrangler.data.jsonc` and pass its
  id. Publishing a new zip deploys twice (phase 1 and phase 2, two versions); re-publishing the
  same zip, or publishing with no zip, deploys once. Without a version-id, `rollback` returns to the
  immediately preceding version, which after a two-deploy publish is that publish's own phase 1.
  The next publish carries over whatever the rolled-back `deploy.json` lists.

### R2 is closed

The R2 bucket `umasagashi-data` that served this host before is not public: it has no custom
domain, `r2.dev` is disabled, and no Worker binds it. Nothing in the repository connects it again.
Serving from R2 brings back requests that are billed per read, so treat it as an emergency path
only. While the bucket still exists it could be reconnected with
`wrangler r2 bucket domain add umasagashi-data --domain data.umacapture.com --zone-id <zone id>`,
but only after `data.umacapture.com` has been removed as a custom domain of `umacapture-data`: a
host name is one custom domain, of a Worker or of a bucket, not both. With R2 back in place:

- No zone route `data.umacapture.com/*` may point at `umacapture-data`: a route runs the Worker in
  front of the bucket's custom domain, so the bucket would not be what answers.
- Take the custom domain out of `server/wrangler.data.jsonc` before any publish. A publish deploys
  the routes in that file, so it would claim the name back, and without a terminal it would do so
  without asking.
- The bucket holds the objects as of the move to `umacapture-data`; nothing published since is in
  it. The CORS rule the web app needs is the bucket's own CORS policy: any origin, `GET` and `HEAD`,
  max age 86400 seconds. Check it with `wrangler r2 bucket cors list umasagashi-data`.

## OGP image function (Vercel)

The record cards' OGP images are drawn by the function in `og/`, deployed to the Vercel project
`umacapture-og` by `tool/vercel/deploy_og.sh`. The function fetches its fonts at run time from
`/og/fonts/*` on the web app's origin (`PUBLIC_ORIGIN`), so a font change is deployed with
`deploy_web.sh`, not with this script. `web/_headers` gives those fonts
`Cache-Control: public, max-age=86400`: a day, not `immutable`, because the file names carry no
content hash.

```bash
bash tool/vercel/deploy_og.sh --target production --dry-run   # checks and tests; no upload
bash tool/vercel/deploy_og.sh --target production             # the same, then asks 'yes' and deploys
```

`--target` defaults to `preview`. The script stops on a dirty tree, runs `npm ci` and `npm test`
in `og/`, uploads with the CLI pinned in `og/package-lock.json` (never a `vercel` on `PATH`),
refuses a deployment that landed on another target than the one asked for, and checks through
the deployment URL that an absent id and a query string both answer 404 from the function.

- **The first deployment is production.** Vercel makes a project's first deployment a production
  one whatever was asked for, and the pinned CLI removes `--target preview` before it calls the
  API. The project has no deployment yet, so its first one is the production deployment. Until a
  production deployment exists, the script refuses a preview before creating anything, also
  under `--dry-run`.
- **`PUBLIC_ORIGIN` per environment.** The function requires it and fails while loading when it
  is unset (`og/api/og.mjs` throws `PUBLIC_ORIGIN is not set`), so every request to that
  deployment fails. Set it in the project before the first deployment to each environment:
  `https://umacapture.com` for **Production**, and the staging origin
  `https://umacapture-web-staging.umasagashi.workers.dev` for **Preview**. With the pinned CLI,
  from `og/` and with `VERCEL_TOKEN` exported from `tool/vercel/.env`:

  ```bash
  node_modules/.bin/vercel env add PUBLIC_ORIGIN production --value https://umacapture.com --yes
  node_modules/.bin/vercel env add PUBLIC_ORIGIN preview --value https://umacapture-web-staging.umasagashi.workers.dev --yes
  ```

  `deploy_og.sh` neither sets nor checks this variable.
- **Firewall before the first deployment.** Deployment protection leaves production domains open,
  so once the project has a production deployment anyone can make the function run. Create one rate limiting rule in the
  project's Firewall first: requests whose path starts with `/r/`, counted per IP, 10 requests in
  10 seconds, the default action (`429`). Hobby allows one rate limiting rule per project, with IP
  or JA4 digest as the key and a window of 10 seconds to 10 minutes. Firewall changes take effect
  when they are published; if the dashboard does not let you publish before the project has a
  deployment, publish it straight after the first one, before anything else.
- **Domain.** Add `og.umacapture.com` to the project, and on the `umacapture.com` zone create the
  `og` CNAME record with the target Vercel shows, proxy status **DNS only**, so requests reach
  Vercel directly. Do not touch the zone's other records (`data` among them). If Vercel asks for a
  TXT record to prove ownership, add that too.
- **Switching the record pages to Vercel images.** `vars.OG_IMAGE_MODE` decides the `og:image` of
  every record page: `"static"` names `/og/default.png` on the web app's own origin as a small
  `summary` card, `"vercel"` names `<OG_IMAGE_ORIGIN>/r/<id>.png` (1200 × 630) as a
  `summary_large_image` card. Deploy production with `"static"` first. Once
  `https://og.umacapture.com` answers anonymously, change the top-level value to `"vercel"`,
  commit, and run `deploy_web.sh` again; until then no page names an image host that does not
  answer yet.
- **Credentials.** `VERCEL_TOKEN` in `tool/vercel/.env` (gitignored); the CLI reads it from the
  environment. `vercel login` is not used: it signs in the whole machine, not this repository.
- **Project link.** `og/.vercel/project.json` (gitignored) names the project and is made once by
  hand. The script never runs `vercel link`: it creates `.vercel/`, can add to `.gitignore`, and
  offers to connect the repository's Git remote, which it does without asking under `--yes`.
- **No Git connection.** Deployments come only from the script, so that what is uploaded is a
  clean, tested `HEAD`. `og/vercel.json` also sets `git.deploymentEnabled: false`.
- **Deployment protection bypass.** Deployments behind Vercel Authentication are checked with
  `VERCEL_AUTOMATION_BYPASS_SECRET` from `tool/vercel/.env`, sent only as the
  `x-vercel-protection-bypass` header of the script's own checks. It never goes into a URL, a page
  or an `og:image`. It stays in place after the release.

## Rolling back and switching off

Restoring an earlier version, stopping record sharing, and removing what sharing created are three
different things. The first two are below; the third is a separate decision taken after a stop.

### The version record

Every deployment and every `wrangler secret put` makes a new version of the Worker. Keep a record
of each one: its version id (`wrangler deploy` prints `Current Version ID:`; after a `secret put`
or a rollback read it from the list below) and, for a deployment, the `git_sha` and
`tables_module_sha256` of its `deploy.json`. A rollback names one of these ids.

```bash
server/node_modules/.bin/wrangler deployments list --name umacapture-web -c server/wrangler.jsonc
```

lists the ten most recent deployments (`--name umacapture-web-staging` for staging).

### Restoring a version

```bash
server/node_modules/.bin/wrangler rollback <version-id> --name umacapture-web -c server/wrangler.jsonc -m "<reason>"
```

- **Always pass the version id.** Without it, wrangler picks the version to return to itself.
  `--name` names the Worker; `-c` is read only for the account. For staging use
  `--name umacapture-web-staging`.
- It needs the API token and the pinned wrangler only: no build, no Sentry, no clean tree.
- Bound resources are not rolled back: D1 keeps its current contents.
- Only the 100 most recently published versions can be rolled back to.
- When secrets have changed since the version, wrangler asks to confirm. Without a terminal (stdin
  or stdout not a terminal, or a CI environment) every prompt of `rollback` takes its default, and
  that confirmation's is yes.

**Between two versions with sharing on**, roll back only when both `deploy.json` files name the
same `tables_module_sha256`. The tables only grow, a record published under longer tables cannot be
read with shorter ones, and D1 is not rolled back. If they differ, stop sharing instead (below), or
deploy a new version whose tables are at least as long. Before a redeploy you may want to roll back
from, compare `module_archive.sha256` in `https://data.umacapture.com/umacapture/version_info.json`
with the live `tables_module_sha256`: if they differ, the new version's tables come from another
archive, and rolling back from it is ruled out. Do not publish a new module set while such a
rollback has to stay possible.

### Stopping record sharing

In this order of preference:

| Means | Effect | Depends on |
|---|---|---|
| **Roll back to the last version without the Worker** (assets only, after `TURNSTILE_SECRET` was put) | `/r/*` and `/api/*` get the static 404 and use no Worker quota; the assets, the notice included, return to that version's. D1 keeps its data | The token and the pinned wrangler only. Use it first, whatever is broken |
| `PUBLISH_ENABLED` `"false"`, committed, then `deploy_web.sh` | New tickets and publishes stop (`503 publishing_paused`); reading and withdrawing go on | A clean tree, a build, the Sentry upload, the data host's pointer and archive (for the tables), the pinned wrangler. Not usable while any of them is broken |
| `deploy_web.sh --sharing off` | As the rollback, with the assets of the current `HEAD` | As above, except the data host: no tables are built. Use it once the version without the Worker is no longer among the last 100 |
| `OG_IMAGE_MODE` `"static"` | Record pages stop naming images on Vercel | A rollback to a version that had it (with the tables condition above), or a deployment with the dependencies above |
| On Vercel | Deny `/r/` with a Firewall rule | The Vercel dashboard. After `OG_IMAGE_MODE` is `"static"` |

None of them recalls source maps already sent to Sentry, cards already taken by social networks, or
copies made by third parties.

### Removing what sharing created

Separate from a stop, and decided on its own: the D1 database, the Turnstile widget, the zone's
rate limiting rule and the Vercel Firewall rule, the `og` DNS record, the Vercel domain, deployments
and environment variables, and the extra token permissions. While D1 holds published records, it is
not deleted.

### Other

| Goal | How |
|---|---|
| Take the site off the domain | Remove the `umacapture.com` custom domain in the dashboard |
