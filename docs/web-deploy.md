# Deploying the web app

The web app is served from `https://umacapture.com` by **Cloudflare Workers Static Assets**,
together with the **Worker** (`server/src/`, configured by `server/wrangler.jsonc`) and its D1
database. The Worker carries logins (Google, behind Turnstile), record sharing and file sync. It
answers the record pages `/r/<id>` and their JSON `/r/<id>.json`, an account's list of shared records
`/u/<id>` and `/u/<id>.json`, and the API under `/api/` (file sync under `/api/sync/`), and answers 404
to any other path that matches no file. An hourly run of the same Worker tidies file sync's storage
and goes on with the deletion of every account being deleted (`triggers.crons`). File sync stores its objects in a Backblaze B2 bucket per environment, which the
Worker alone reaches, with a key held in Worker secrets ([`sync-server.md`](sync-server.md)). A
request for a file in `build/web/` is a static-asset request: no Worker script runs and it is not
counted as a Worker request.

The Worker can be switched off without touching the app: `server/wrangler.assets-only.jsonc` deploys
the same assets with no Worker script and no hourly run, so every path that matches no file gets the
static 404 (see "Rolling back and switching off").

Deployment runs from the one PC that can build the wasm recognition core (CI cannot; see
`docs/wasm-toolchain/`). `tool/cloudflare/deploy_web.sh` does the whole run, except for D1
migrations, which are applied by hand ("Applying a migration").

## What is served, and how

| Piece | Where it comes from |
|---|---|
| Files | `build/web/`, built in the same run by `tool/build_web.sh` from a clean `HEAD` |
| Excluded files | `web/.assetsignore` (copied into `build/web/`): `*.map` (uploaded to Sentry, not public) and `.last_build_id` |
| Response headers | `web/_headers` (copied into `build/web/`): `Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`, `X-Content-Type-Options: nosniff` on every file |
| Caching | The platform default, `Cache-Control: public, max-age=0, must-revalidate` with an `ETag`, except `/og/fonts/*` (one day, see the Vercel section) and `/site/fonts/*` (one day; the public pages' font subsets, whose names carry no content hash either, and a stale one only sends a few new characters to a system font). Not overridden: `main.dart.js`, `worker.js`, `*.mjs` and `wasm/*` have fixed names, so every visit revalidates and an old script never runs against a new wasm module. Revalidations of static assets are free |
| CanvasKit | Served from the bundle's own `canvaskit/`. `tool/build_web.sh` always passes `--no-web-resources-cdn`, so nothing is loaded from `www.gstatic.com` |
| Fonts | The app still fetches its fonts at runtime from `fonts.gstatic.com` (not bundled). The public pages (`/notice/`, `/privacy/`, and the Worker's pages) read M PLUS Rounded 1c from this origin: `build/web/site/fonts/`, woff2 subsets the run cuts out of the pinned TTFs in `web/og/fonts/` ("Page fonts" below) |
| Record pages, lists and API | `/r/*`, `/u/*` and `/api/*` run the Worker first (`assets.run_worker_first`), so a static file can never shadow an endpoint |
| Unknown paths | `not_found_handling: "none"`: no SPA fallback. With `--sharing on`, the Worker's 404, which carries `X-Robots-Tag: noindex`; with `--sharing off`, the static 404. The app uses hash routing and needs no server-side path but `/` |
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

   The same file carries `CLOUDFLARE_ACCOUNT_ID`. `deploy_web.sh` and `publish_modules.sh` read
   both from it and stop when either is empty; a `wrangler login` does not stand in for them. A
   wrangler command run by hand takes them from the same file ("The pinned wrangler").
2. **Sentry.** `deploy_web.sh` uploads the source maps with `tool/upload_web_sourcemaps.sh`, an
   authenticated transmission to Sentry. Put a Sentry auth token with release / artifact upload
   rights in `~/.sentry_token` and export it before deploying (below). The upload runs `sentry-cli`
   from `PATH` (or the one `SENTRY_CLI` names), with the organisation and project of the committed
   `.sentryclirc`; install it with `npm install -g @sentry/cli` if `sentry-cli --version` fails.
   `deploy_web.sh` checks the token before it builds, but not `sentry-cli`: without it a production
   run fails at stage 2, after the build.
3. **Pre-deployment checks.** Confirm and write down the result before the first deployment.
   They are the grounds for what this deployment can be billed for:
   - The account is on **Workers Paid** (Dashboard › Workers & Pages › Plans). Past what the plan
     includes a month it bills rather than stops. File sync's service-wide daily limits in
     `server/src/limits.mjs` are set so that production and staging both using them up every day of
     a month stay within what the plan includes; their comments derive each figure.
   - `server/wrangler.jsonc` declares **one binding**, the D1 database `DB`, and no R2.
     `server/wrangler.assets-only.jsonc` declares none at all. Read both again before deploying.
   - **Backblaze B2** is billed by Backblaze, outside Cloudflare. Its data caps and alerts (below)
     stop it rather than bill past them.
   - The **list of existing Workers** in the account (Workers & Pages › Overview). They share the
     plan's included usage with this one; write the names down.
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
   `DB`, `database_name` `umacapture-share`, `migrations_dir` `migrations`. The same `migrations
   apply` applies the migrations a database does not have yet; apply them before deploying a Worker
   that reads their tables, because a deployment does not apply them ("Applying a migration").
6. **Worker secrets.** A secret is never a var and never in a file in the repository. Put each one
   before the first deployment with the Worker:

   ```bash
   server/node_modules/.bin/wrangler secret put <NAME> -c server/wrangler.jsonc
   ```

   In a terminal `secret put` asks for the value; otherwise it reads it from standard input.
   It creates a new version of the Worker and deploys it at once; it uploads no local code. A
   deployment never deletes a secret. These are every secret the Worker reads:

   | Secret | What it is | Without it |
   |---|---|---|
   | `TURNSTILE_SECRET` | The Turnstile widget's secret key (step 7) | Every login begin is refused (`403`) |
   | `GOOGLE_CLIENT_SECRET` | The Google OAuth client's secret (step 8) | Every login fails at the callback |
   | `IDENTITY_HMAC_KEY` | 32 random bytes as 64 lowercase hex digits (step 9) | Every login fails at the callback |
   | `B2_KEY_ID`, `B2_APPLICATION_KEY` | The application key of the environment's B2 bucket (step 10) | Every sync request that reaches B2 and every account deletion fail (`502`), and so does every hourly run |
7. **Turnstile.** Create the widget in the dashboard for the hostname `umacapture.com`, in Managed
   mode. Its sitekey goes into the config (below), its secret key into `TURNSTILE_SECRET`. The
   login start page (`/api/auth/start`) shows the widget, and a login begin
   (`POST /api/auth/begin`) is refused unless siteverify reports this hostname and the action
   `login`.
8. **Google login.** In Google Cloud, an OAuth client of type Web application; the Worker asks it
   for the scope `openid email`. Its redirect URI is `<AUTH_REDIRECT_ORIGIN>/api/auth/callback/google`:
   `https://umacapture.com/api/auth/callback/google` for production. Its client id goes into
   `vars.GOOGLE_CLIENT_ID`, its secret into `GOOGLE_CLIENT_SECRET`. While `GOOGLE_CLIENT_ID` is empty,
   a login begin refuses to run rather than send Google a request without a client.
9. **Identity key.** `IDENTITY_HMAC_KEY` is the key every login identity is stored under
   (HMAC-SHA256 of the provider and the provider's user id). Make it once per environment and keep a
   copy outside Cloudflare: a secret cannot be read back, and an environment whose key is lost or
   changed can no longer reach any of its accounts by logging in.

   ```bash
   python -c "import secrets; print(secrets.token_hex(32))"
   ```

10. **Backblaze B2.** One account in the region `us-west-004`, and per environment:
    - **A private bucket**: `umacapture-sync` for production, `umacapture-sync-staging` for staging
      (`vars.B2_BUCKET`). The endpoint `s3.us-west-004.backblazeb2.com` and the region go into
      `vars.B2_ENDPOINT` and `vars.B2_REGION`.
    - **An application key** restricted to that bucket, with read and write access (which lists,
      reads, writes and deletes files), into `B2_KEY_ID` and `B2_APPLICATION_KEY`.
    - **The lifecycle rule** `daysFromHidingToDeleting` 6 covering the prefix `a/`, under which the
      Worker stores every object (`B2_DAYS_FROM_HIDING_TO_DELETING` in `server/src/limits.mjs`). The
      Worker only hides what is no longer referenced, and counts on this rule to delete it; without
      the rule nothing it hid is ever deleted ([`sync-server.md`](sync-server.md#the-b2-bucket)).
    - **Check the rule after setting it.** Read the bucket's lifecycle rules back, in the B2
      console (the bucket's Lifecycle Settings), or read only through the native API:
      `b2_authorize_account` with the bucket's application key, then `b2_list_buckets` with the
      bucket's name in `bucketName` (a key restricted to one bucket has to name it), which returns
      the rules as `lifecycleRules`. Expect the rule with
      `fileNamePrefix` `a/` and `daysFromHidingToDeleting` 6, and no `daysFromUploadingToHiding`
      covering `a/`: that would hide objects the Worker still references.
    - **Data caps and alerts** on the B2 account (Caps & Alerts), the stop for B2's charges: storage
      $0.50 a day and download $0.20 a day, and the transaction classes that offer a cap $0.10 a day,
      with alerts at 75% and 100%. A cap that is reached makes B2 refuse what it covers, and the
      Worker answers those requests `502`.
11. **Production config.** The top level of `server/wrangler.jsonc` carries what `env.staging`
    does, with production values: `"main": "src/index.mjs"`, `assets.run_worker_first`
    `["/r/*", "/u/*", "/api/*"]`, `"observability": { "enabled": false }`, `triggers.crons`
    `["30 * * * *"]` (staging `["45 * * * *"]`), the D1 entry above, and these `vars`, which with
    the secrets above are every variable the Worker reads:

    | Var | Production value |
    |---|---|
    | `PUBLIC_ORIGIN` | `https://umacapture.com` |
    | `OG_IMAGE_MODE` | `"vercel"`; `"static"` while `og.umacapture.com` does not answer (see the Vercel section) |
    | `OG_IMAGE_ORIGIN` | `https://og.umacapture.com` |
    | `SHARING_ENABLED` | `"true"`; `"false"` stops new logins and shares (`503 sharing_paused`) while reads, unshares and logouts go on |
    | `TURNSTILE_SITEKEY` | The widget's sitekey |
    | `TURNSTILE_TESTING_KEY` | `"false"`: answers issued for Turnstile's testing secrets are refused |
    | `TURNSTILE_HOSTNAME` | `umacapture.com` |
    | `TURNSTILE_ACTION` | `login` |
    | `GOOGLE_CLIENT_ID` | The OAuth client's id (step 8) |
    | `AUTH_REDIRECT_ORIGIN` | `https://umacapture.com`, the origin of the redirect URI registered with Google |
    | `SYNC_ENABLED` | `"true"` (a first production deployment starts with `"false"`, see "Deploying"). `"false"` answers every endpoint under `/api/sync/` `503 sync_paused` and stops the hourly run's sync kinds, while sharing, logins and account deletion go on, the hourly run's included |
    | `B2_ENDPOINT` | `s3.us-west-004.backblazeb2.com` |
    | `B2_REGION` | `us-west-004` |
    | `B2_BUCKET` | `umacapture-sync` |

    `SHARING_ENABLED` and `SYNC_ENABLED` must be `"true"` or `"false"`; any other value is a
    configuration error. `wrangler deploy` replaces the Worker's vars with the ones in the config,
    so a var set in the dashboard does not survive the next deployment.
12. **Zone rate limiting.** One WAF rate limiting rule on the `umacapture.com` zone: requests whose
    URI path starts with `/r/`, `/u/` or `/api/` but not with `/api/sync/`, and that do not come
    from a verified bot, counted per IP, 10 requests in 10 seconds, blocked for 10 seconds. The
    path part of its expression:

    ```
    (starts_with(http.request.uri.path, "/r/") or starts_with(http.request.uri.path, "/u/")
     or starts_with(http.request.uri.path, "/api/"))
    and not starts_with(http.request.uri.path, "/api/sync/")
    ```

    File sync is left out on purpose: it is held by its own limits instead (per account and over
    every account, per day, [`sync-server.md`](sync-server.md#limits)). Every
    sync endpoint is under `/api/sync/`, so the one prefix covers them. The zone's Free plan allows
    exactly one such rule, with those fields, that counting key, that period and that timeout; if
    the zone already has one, decide which to keep rather than overwriting it.

    **Check the rule from outside**, against production: staging's `workers.dev` URL does not pass
    the zone (see the Entrance list). Send 20 requests within 10 seconds to one path at a time, and
    wait between paths so that one path's block does not carry into the next:

    ```bash
    for p in /api/me /u/0000000000000000 /r/0000000000 /api/sync/generation; do
      echo "$p: $(for i in $(seq 20); do curl -s -o /dev/null -w '%{http_code} ' "https://umacapture.com$p"; done)"
      sleep 20
    done
    ```

    `/api/me`, `/u/…` and `/r/…` answer their usual status (`401`, `404`) up to the 10th or 11th
    request and `429` after it. `/api/sync/generation` never answers `429`: every request gets the
    Worker's own answer (`401` without a login, `503` while sync is off). The check blocks only the
    IP it runs from, for 10 seconds at a time.

### Entrance list

| Entrance | What it serves | Zone WAF | Expected setting |
|---|---|---|---|
| `umacapture.com` (custom domain) | The web app and the Worker (`umacapture-web`) | Applies: the rate limiting rule on `/r/`, `/u/` and `/api/`, except `/api/sync/` | Production entrance |
| `data.umacapture.com` (custom domain) | Recognizer modules and announcements (`umacapture-data`, static assets only, no R2) | Applies, unused | Production entrance |
| `og.umacapture.com` (Vercel project domain, CNAME, DNS only) | The OGP image function (`umacapture-og` on Vercel) | Does not apply: the zone does not proxy it. The Vercel Firewall rule applies (see the Vercel section) | Production entrance |
| `umacapture-og.vercel.app` | The project's own production domain on Vercel | Does not apply | Kept. It answers without the bypass header: `/` gets the platform's 404 and `/r/<id>.png` reaches the function, because production domains are outside deployment protection. Whether the Vercel Firewall rule also applies here is not measured: the burst test ran against `og.umacapture.com` only |
| `umacapture-web-staging.umasagashi.workers.dev` | Staging (`umacapture-web-staging`), assets only once sharing is off there | Does not apply | Open, linked from nowhere (see "Staging") |
| `umacapture-web.<account>.workers.dev`, `umacapture-data.<account>.workers.dev` | Would serve the same Workers | Does not apply | Closed: `workers_dev: false` |
| Per-version preview URLs (both Workers) | Would serve each version | Does not apply | Closed: `preview_urls: false` |
| B2 buckets `umacapture-sync`, `umacapture-sync-staging` | Nothing public: file sync's objects, reached only by the Worker with the bucket's key | Does not apply | Private |

After the first deployment, confirm in the dashboard (Worker › Settings › Domains & Routes) that
`workers.dev` and preview URLs are shown as disabled and that each Worker has exactly one domain:
`umacapture.com` for `umacapture-web`, `data.umacapture.com` for `umacapture-data`. No zone route
points at either of them.

## Deploying

**The first production deployment** — of a new environment, or onto a production D1 that does not
have `0002_accounts.sql` yet — goes in this order. The committed production `GOOGLE_CLIENT_ID` is
the OAuth client staging already logs in through (One-time preparation, step 8). The committed
`SYNC_ENABLED` is `"true"`; this order commits `"false"` first (item 3), deploys it (item 6) and
turns sync on after it (item 7).

1. **Google stays in Testing.** The OAuth consent screen keeps the publishing status Testing for
   the whole production test, so only its test users can log in. In production and brand
   verification are asked for last (item 9): the review requires the home page to link to the
   privacy policy, and `https://umacapture.com/privacy/` is published only by a production
   deployment.
2. **Count the old shares, and stop unless there are none.** Read the production D1's
   `records`:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc \
     --json --command "SELECT COUNT(*) FROM records"
   ```

   If it is not 0, do not go on: `0002_accounts.sql` runs `DROP TABLE tickets;` and
   `DROP TABLE records;`, and only D1's Time Travel brings them back.
3. **Commit sync off.** Commit `SYNC_ENABLED` `"false"` in the top-level `vars` now, before the
   checks and the migration. The script builds the `HEAD` of a clean tree, so this fixes the commit
   item 6 deploys before anything changes, and nothing is left to edit or commit between the
   migration and the deployment.
4. **Check what the run needs, before anything changes** ("Checks before a production run",
   below), on the tree item 3 committed. The next item cannot be taken back, and a run that stops
   after it leaves production without its tables for as long as it takes to put right.
5. **Apply the migrations right before the deployment** ("Applying a migration", below).
   `0002_accounts.sql` and `0003_sync.sql` go together; deploy straight after them (item 6).
   From the apply until the new Worker is up, the Worker in production still runs code that reads
   the tables `0002_accounts.sql` dropped.
6. **Deploy with sync off.** Run `deploy_web.sh --target production` (below) on the commit of
   item 3. The deployment also adds the hourly run `30 * * * *`
   (`triggers.crons`). Confirm that sync answers `503`:
   `curl -sS -i https://umacapture.com/api/sync/generation` answers `503` with
   `{"error":"sync_paused"}`. The Worker has no endpoint of publishing with a ticket and a
   delete key, so `GET /api/verify?h=<64 zeros>`, `POST /api/tickets`, `POST /api/records`,
   `POST /api/records/lookup` and `DELETE /api/records/<id>` answer `404`: an older Worker would
   still serve them. The first production login after it, whatever it is for, is the
   first proof that the production redirect URI is registered with the OAuth client (One-time
   preparation, step 8): if Google answers `redirect_uri_mismatch`, register it there and log in
   again.
7. **Turn sync on.** Commit `SYNC_ENABLED` `"true"` in the top-level `vars` and run
   `deploy_web.sh --target production` again ("Rolling back and switching off" covers the switch).
   Without a login, the same `curl` now answers `401` with `{"error":"session_required"}`.
8. **The first write to the production bucket**: log in with your own account and turn sync on in
   the app.
9. **Ask Google for In production and brand verification**, now that `/privacy/` is live.

Each production run, `--dry-run` included, sends the source maps to Sentry, so this order sends
them at least twice (items 6 and 7).

From Git Bash at the repository root, on a clean, committed tree:

```bash
export SENTRY_AUTH_TOKEN="$(tr -d ' \t\r\n' < ~/.sentry_token)"
bash tool/cloudflare/deploy_web.sh --dry-run   # builds, uploads maps to Sentry, validates; no Cloudflare upload
bash tool/cloudflare/deploy_web.sh             # the same, then asks 'yes' and deploys
```

Two independent options pick what is deployed: `--target production|staging` (default
`production`) and `--sharing on|off` (default `on`). With sharing on the config is
`server/wrangler.jsonc`, and the Worker comes with the assets: logins, sharing, file sync and the
hourly run. With sharing off it is `server/wrangler.assets-only.jsonc`: the assets alone, with no
Worker and no hourly run. `--yes` answers the confirmation without a prompt; `--dry-run` stops
before it. Without a terminal (a background job, a script, an agent's shell) the confirmation
reads nothing and the run stops there with nothing uploaded to Cloudflare, so such a run needs
`--yes`. A production run has already sent the source maps to Sentry by then (stage 2 comes before
the confirmation): stopping at the confirmation does not keep them from leaving.

Every deployment of these two configs goes through `deploy_web.sh`. Never run a bare
`wrangler deploy` against `server/wrangler.jsonc` or `server/wrangler.assets-only.jsonc`, not
even to flip one var with `--var`: it uploads whatever `build/web/` holds, with no check that it
was built from the commit `deploy.json` names, and the next deployment puts the committed vars
back. To change a var, commit it and run the script.

The script neither pushes nor reads the remote. Pushing the commit before a production deployment
is recommended, so that the `git_sha` the live `deploy.json` names is one any clone can check out;
the script does not require it.

The script stops on a dirty tree, rebuilds `build/web/` from scratch (never reusing an earlier
build), uploads source maps (production only; this rewrites the JS files with debug ids, so it runs
before the upload), builds the name tables (sharing on, below) and the page fonts (below), writes `deploy.json`, runs
`wrangler deploy --dry-run`, asks for confirmation, deploys, then verifies through the public URL
that:

- `https://umacapture.com/deploy.json` is byte-identical to the local one;
- `/` carries `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp`;
- `/main.dart.js.map` answers 404;
- `/r/0000000000` answers 404 from the side the `--sharing` option expects: with sharing on the
  Worker's 404, which carries `X-Robots-Tag: noindex`; with sharing off the static 404, which
  carries no `X-Robots-Tag`. A deployment whose Worker did not come up, or did not go away, stops
  here.

Stage 7, `wrangler deploy`, prints the new version's id in the run's output, on the line
`Current Version ID: <id>`. Write it down with the `git_sha` and
`tables_module_sha256` of that `deploy.json`: a rollback names the version it returns to (see
"Rolling back and switching off").

**Name tables.** With sharing on, the run builds `server/src/tables.generated.json` with
`tool/cloudflare/build_share_tables.py` from the module archive the live pointer on
`data.umacapture.com` names, and records that archive's sha256 in `deploy.json` as
`tables_module_sha256`. A shared record stores ids, and its names are looked up in the tables
deployed when it is read, so the tables must only grow at the end. Each target has its own D1 and
so its own baseline, `tool/cloudflare/.deploy-backup/tables.<target>.json` (gitignored; it holds
game text), which the script passes as `--previous`; `build_share_tables.py` has no default
baseline. The run stops before deploying if the tables are not append-only against it. A target's
first run with sharing has no baseline, and the check is skipped. Only after the deployment has
been verified does the run copy the deployed tables to the baseline, so a run that stopped earlier
leaves the baseline as it was.

**Page fonts.** With either `--sharing` choice, the run then writes the font files
`web/site/site.css` names into `build/web/site/fonts/` with `tool/cloudflare/build_page_fonts.py`:
subsets of the pinned M PLUS Rounded 1c TTFs, cut to the characters of `web/**/*.html`,
`server/src/*.mjs` and, with sharing on, the names in the tables just built. The subsets are not
pinned, the TTFs are; a character the font lacks is drawn with a system font.

A redeploy is needed whenever the app, `web/`, or the wasm core changes. The app itself does not
need one for a new recognizer module: it downloads modules from `data.umacapture.com` at runtime,
and they are published there with `publish_modules.sh` (see "Publishing to data.umacapture.com"
below). The Worker does: it resolves names only through the tables it was deployed with, so after
publishing a new module set, deploy each target that has sharing on again.

### Checks before a production run

Stage 0 checks the tools, the clean tree and the credentials before anything is built, but not
everything a production run needs, and what it does not check fails minutes later, after the
build. Before a production run, and before any step that cannot be taken back (a migration, below),
confirm in the shell that will run the script:

- The tree is clean and committed: `git status --porcelain` prints nothing.
- `tool/cloudflare/.env` sets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID` (One-time
  preparation, step 1).
- `SENTRY_AUTH_TOKEN` is exported and not empty (the `export` above). Stage 0 stops without it.
- `sentry-cli --version` runs (One-time preparation, step 2). Stage 0 does not check it; stage 2
  fails without it.
- `uv` is on `PATH` (stage 3: the name tables with sharing on, the page fonts always).
- `web/` matches its pins: `.fvm/flutter_sdk/bin/dart run tool/check_web_pins.dart --licenses
  --require-verified`, the check stage 1 runs before it builds. It fails when the wasm module is
  older than the `native/` sources it was built from.

`--dry-run` is not a cheaper way to the same answer in production: it builds, sends the source maps
to Sentry (an outward transmission like the real run's), and the real run builds and sends them
again.

### Applying a migration

`deploy_web.sh` never applies migrations. A migration in `server/migrations/` that a new Worker
needs is applied by hand, before that Worker is deployed:

```bash
server/node_modules/.bin/wrangler d1 migrations apply umacapture-share --remote -c server/wrangler.jsonc
# staging: umacapture-share-staging --env staging
```

- It lists the migrations the database does not have yet and asks before it applies them; without
  a terminal it answers that question itself with yes.
- A migration is not rolled back by anything: neither `wrangler rollback` nor a redeploy changes
  D1 (see "Restoring a version").
- When a migration drops or reshapes what the live Worker reads, the live Worker is broken from the
  apply until the new one is up. Run the checks above first, then apply, then deploy at once.
- That window is the whole run that follows it: the build, in production the upload to Sentry,
  the tables, `wrangler deploy` and the checks, about four minutes for a production run. A run that
  stops partway keeps it open until a later run gets through, which is why the checks come first.

### After a deployment with sharing on — the Turnstile check

This shows that production does not accept Turnstile's testing pair. Turnstile's testing sitekeys
produce the dummy token `XXXX.DUMMY.TOKEN.XXXX`, which a production secret key rejects. The begin
is the start page's form, so the request carries the form's content type and the start page's
`Origin`:

```bash
H=$(python -c "import secrets; print(secrets.token_hex(32))")   # a login hash no one holds the source of
curl -sS -i -X POST https://umacapture.com/api/auth/begin \
  -H 'Origin: https://umacapture.com' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data "h=$H&p=google&token=XXXX.DUMMY.TOKEN.XXXX"
```

- Expected: `403` with the refusal page that reads 「確認できませんでした。アプリからログインをやり直してください。」.
  The form has exactly the fields `h`, `p` and `token` (and optionally `port`); any other field is
  a `400`, and so is any other content type. Another `Origin` is a `403` before Turnstile is asked,
  with the same page, so leave it as above: the `403` stands for Turnstile's refusal only because
  the request carries the right `Origin` and content type.
- It shows that the Worker does not run on the always-passing testing secret together with
  `TURNSTILE_TESTING_KEY: "true"`, the only combination that lets this token through.
- It does not show that `TURNSTILE_TESTING_KEY` is `"false"` (a real secret refuses the dummy token
  either way), nor tell a missing or wrong secret, or a failed call to siteverify, from a working
  one: all of them answer `403`. For the first, read `vars.TURNSTILE_TESTING_KEY` at the top level
  of `server/wrangler.jsonc` as of the `git_sha` the live `/deploy.json` names (a deployment takes
  its vars from the config); for the second, log in from the web app with the real widget.
- A `302` to Google means the testing pair is live: stop logins at once (`SHARING_ENABLED`, below).
  The login it began is bound to `H`, whose source no one has, so it cannot be claimed, but its row
  and one count of the day's login limit (`LOGIN_LIMIT`) stay in D1. While `GOOGLE_CLIENT_ID` is
  empty, a begin that passed Turnstile fails instead of answering `302`; anything but the `403`
  above means the same.

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
set -a; source tool/cloudflare/.env; set +a   # CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID, as the scripts read them
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
Worker (`server/src/`), the staging database, the staging bucket and staging's hourly run
(`45 * * * *`), from `server/wrangler.jsonc`; with sharing off, the assets alone, from
`server/wrangler.assets-only.jsonc`. Both name the same Worker,
`umacapture-web-staging`, so either deployment replaces the other. The invariants are the
production ones: a clean tree, a fresh build from `HEAD` in the same run, and a `deploy.json`
verified through the public URL.

- **Credentials.** The API token also needs Account › D1 › Edit (`tool/cloudflare/.env.example`).
  The staging database (`umacapture-share-staging`) is created once by hand, its id written into
  `env.staging.d1_databases`, and the migrations applied with
  `wrangler d1 migrations apply umacapture-share-staging --env staging --remote -c server/wrangler.jsonc`.
  Every secret of the table in "One-time preparation" is set once for staging too, with
  `wrangler secret put <NAME> --env staging -c server/wrangler.jsonc`: staging's own
  `IDENTITY_HMAC_KEY` (kept as production's is), and the key of the staging bucket. Staging uses
  Turnstile's always-passing test keys, so its login has no abuse protection.
- **Google login.** `env.staging.vars.GOOGLE_CLIENT_ID` names the client staging logs in with, and
  that client must have staging's redirect URI registered:
  `https://umacapture-web-staging.umasagashi.workers.dev/api/auth/callback/google`
  (`env.staging.vars.AUTH_REDIRECT_ORIGIN`), so a staging login comes back to staging, where its
  row is.
- **workers.dev.** Staging has no custom domain. Its `workers.dev` URL bypasses the zone WAF and
  anyone who has it can open it; nothing links to it. It shares the plan's included Worker and D1
  usage with production, while its daily limits are counted in its own D1.
- **No Sentry.** A staging run uploads no source maps and needs neither `SENTRY_AUTH_TOKEN` nor
  `sentry-cli`; the maps are still excluded from the deployment by `.assetsignore`.
- **Name tables.** With sharing on, a staging run builds and checks the tables as production does
  (see "Deploying"), against staging's own baseline
  `tool/cloudflare/.deploy-backup/tables.staging.json`.
- **Local web builds.** A web app served locally (`serve_web_build.py`) cannot call the staging
  API: the API is same-origin only. Test logins, sharing and sync from the web app on the staging
  host; a staging run builds it with `--dart-define=UMACAPTURE_SHARING_ORIGIN=` set to the staging
  URL, so it logs in, shares and syncs through the staging Worker rather than `umacapture.com`.
- **Stopping staging.** `env.staging.vars.SHARING_ENABLED: "false"` and a redeploy stop new
  logins and shares while reads, unshares and logouts go on; `env.staging.vars.SYNC_ENABLED:
  "false"` and a redeploy stop sync and staging's hourly run.
  `bash tool/cloudflare/deploy_web.sh --target staging --sharing off` takes the Worker off staging
  and keeps its assets: `/r/`, `/u/` and `/api/` get the static 404, the hourly run goes, and
  staging no longer uses the Worker and D1 usage it shares with production. Do this before the
  Worker ships to production. The staging database and bucket are left as they are; deleting them
  is a separate step.

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

`umacapture-data` is the only origin of this host. The R2 bucket `umasagashi-data` that served it
before has been deleted, so there is no other origin to fall back to: going back always means one
of the two ways above, to an earlier archive or an earlier version of the Worker.

## OGP image function (Vercel)

The record cards' OGP images are drawn by the function in `og/`, deployed to the Vercel project
`umacapture-og` by `tool/vercel/deploy_og.sh`. The function bundles neither its fonts nor its
mark: at run time it fetches M PLUS Rounded 1c and Noto Sans JP from `/og/fonts/*`, and the logo
from `/site/logo.svg`, on the web app's origin (`PUBLIC_ORIGIN`). A font or logo change is
therefore deployed with `deploy_web.sh`, not with this script. `web/_headers` gives those fonts
`Cache-Control: public, max-age=86400`: a day, not `immutable`, because the file names carry no
content hash.

**Deploy the web app first, the function after**, whenever a change reaches both. A function that
asks for a font or the logo the origin does not serve yet cannot draw, and answers every card with
a redirect to `/og/default.png`. The current function reads M PLUS Rounded 1c, Noto Sans JP
Regular and the logo, so the origin has to serve them first. The earlier function still running in
production also reads `/og/fonts/NotoSansJP-Bold.otf`, which the current one does not; the web app
keeps serving it (it stays pinned in `tool/web_deps.json`) so that the old function can still draw
between the two deploys. Remove that pin only in a commit after the current function is deployed to
production.

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
  `summary_large_image` card. Production carries `"vercel"`, which holds only while
  `https://og.umacapture.com` answers anonymously. An environment whose image host does not answer
  yet is deployed with `"static"`, and switched to `"vercel"` by a commit and another run of
  `deploy_web.sh` once it does, so that no page names an image host that does not answer.
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

Restoring an earlier version, stopping record sharing or file sync, and removing what the Worker
created are three different things. The first two are below; the third is a separate decision taken
after a stop.

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
- Bound resources are not rolled back: D1 and the B2 bucket keep their current contents, and D1
  keeps every migration applied since the version (below).
- Only the 100 most recently published versions can be rolled back to.
- When secrets have changed since the version, wrangler asks to confirm. Without a terminal (stdin
  or stdout not a terminal, or a CI environment) every prompt of `rollback` takes its default, and
  that confirmation's is yes.

**Between two versions with sharing on**, roll back only when both `deploy.json` files name the
same `tables_module_sha256`. The tables only grow, a record shared under longer tables cannot be
read with shorter ones, and D1 is not rolled back. If they differ, stop sharing instead (below), or
deploy a new version whose tables are at least as long. Before a redeploy you may want to roll back
from, compare `module_archive.sha256` in `https://data.umacapture.com/umacapture/version_info.json`
with the live `tables_module_sha256`: if they differ, the new version's tables come from another
archive, and rolling back from it is ruled out. Do not publish a new module set while such a
rollback has to stay possible.

**Across a migration**, do not roll back to a version whose Worker reads a schema D1 no longer has:
a version with the Worker deployed before a migration was applied to its database reads the schema
the migration replaced, and the rollback leaves D1 as it is. In production this rules out every
version with the Worker from before `0002_accounts.sql`, which read the `records` table that
migration dropped. To undo a deployment that came with a migration, deploy a new version that reads
the schema D1 now has. A version deployed with sharing off (`server/wrangler.assets-only.jsonc`) has
no Worker and no D1 binding and reads no schema, so a rollback to it is not ruled out by any
migration: it is the first means under "Stopping record sharing".

### Stopping record sharing

In this order of preference:

| Means | Effect | Depends on |
|---|---|---|
| **Roll back to the last version without the Worker** (assets only, after `TURNSTILE_SECRET` was put) | `/r/*`, `/u/*` and `/api/*` get the static 404 and run no Worker; logins, sync and account deletion stop with sharing; the assets, the notice included, return to that version's. D1 and B2 keep their data | The token and the pinned wrangler only. Use it first, whatever is broken |
| `SHARING_ENABLED` `"false"`, committed, then `deploy_web.sh` | New logins and shares stop (`503 sharing_paused`); reading, unsharing and logging out go on, and so does sync for a device already logged in | A clean tree, a build, the Sentry upload (production), the data host's pointer and archive (for the tables), the pinned wrangler. Not usable while any of them is broken |
| `deploy_web.sh --sharing off` | As the rollback, with the assets of the current `HEAD`; the hourly run goes too | As above, except the data host: no tables are built. Use it once the version without the Worker is no longer among the last 100 |
| `OG_IMAGE_MODE` `"static"` | Record pages stop naming images on Vercel | A rollback to a version that had it (with the conditions above), or a deployment with the dependencies above |
| On Vercel | Deny `/r/` with a Firewall rule | The Vercel dashboard. After `OG_IMAGE_MODE` is `"static"` |

None of them recalls source maps already sent to Sentry, cards already taken by social networks, or
copies made by third parties.

Every means above or below that runs `deploy_web.sh --target production` sends the source maps to
Sentry again: stage 2 of the script runs for every production run, `--dry-run` included, and there
is no option to skip it. A staging run sends nothing to Sentry.

### Stopping file sync

Sync can be stopped alone, with logins and sharing going on. In this order of preference:

| Means | Effect | Depends on |
|---|---|---|
| `SYNC_ENABLED` `"false"` in the target's `vars`, committed, then `deploy_web.sh --target <target>` | Every endpoint under `/api/sync/` answers `503 sync_paused` before it reads anything, and the hourly run runs none of sync's kinds. Logins, sharing and account deletion go on, account deletion's B2 part and the hourly run's deletions included. D1 and B2 keep their data. What cut-off requests left to hide stays unhidden, and so undeleted by the lifecycle rule, until sync is on again | As `SHARING_ENABLED` above, the Sentry upload included for production |
| Revoke the bucket's application key in the B2 console | B2 refuses every request the Worker sends: a sync request that has to reach B2 answers `502`, the hourly run fails, and no account deletion can finish (each call answers `502 storage_unavailable` after its D1 part). Sync resumes once a new key pair is put with `wrangler secret put B2_KEY_ID` and `B2_APPLICATION_KEY`, each of which deploys a new version at once | The B2 console only. Use it when the Worker cannot be deployed, or when the key itself may have leaked |
| Lower a limit in `server/src/limits.mjs` (the daily limits per account and over every account, the capacity), committed, then `deploy_web.sh` | Sync past the new limit is refused (`429 daily_limit` to the next UTC day, `507` for capacity); the rest goes on ([`sync-server.md`](sync-server.md#limits)) | As `SYNC_ENABLED` |
| B2's data caps (One-time preparation, step 10) | Bound what B2 can charge a day. A cap that is reached makes B2 refuse what it covers for the rest of the day, which the Worker answers `502`. They bound the cost, not who syncs | The B2 console only |
| Roll back to the last version without the Worker, or `deploy_web.sh --sharing off` | Sync stops together with logins and sharing (above) | As above |

Turning `SYNC_ENABLED` back to `"true"` is the same commit and deployment; the next hourly run and
each account's next sync write take on what was left over, with one exception.

**A stop also stops the repair of referenced images left hidden, and a long one can lose them.** A
request cut off at the wrong point can leave an object that a current list references hidden in B2;
the hourly run and the account's next sync write show it again (`showLeftovers`, `tidyLeftoversOf`).
Every means above that stops the hourly run's sync kinds or keeps them from reaching B2 —
`SYNC_ENABLED` `"false"`, a revoked key, the rollback, `--sharing off` — stops that repair too. Once
such an object has been
hidden for 143 hours (`B2_DAYS_FROM_HIDING_TO_DELETING` days less `RESTORE_MARGIN_SECONDS`, both in
`server/src/limits.mjs`), counted from its first hide and not from the stop, the server treats it as
gone: neither the hourly run nor a write shows it again after sync resumes, and the lifecycle rule
may delete its version. Only a client putting the same bytes again stores it anew. So a stop that
has already lasted a while is not made safe by turning sync back on. Before choosing a long stop,
weigh what may be left hidden and how much of those 143 hours remains; resuming alone does not bring
back a version the lifecycle rule has deleted.

### Removing what the Worker created

Separate from a stop, and decided on its own: the D1 database, the B2 buckets and their keys, the
Turnstile widget, the Google OAuth client, the zone's rate limiting rule and the Vercel Firewall
rule, the `og` DNS record, the Vercel domain, deployments and environment variables, and the extra
token permissions. While D1 holds shared records or accounts, it is not deleted; while D1 lists
synced objects, their bucket is not deleted. `b2_list_file_versions`, under the same authorization
as the lifecycle check (One-time preparation, step 10), lists every version a bucket holds, hidden
ones included. The kept copy of `IDENTITY_HMAC_KEY` goes only with
the accounts it reaches.

### Other

| Goal | How |
|---|---|
| Take the site off the domain | Remove the `umacapture.com` custom domain in the dashboard |
