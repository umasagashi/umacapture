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
| Build marker | `build/web/deploy.json`: `git_sha`, `built_at`, `wasm_sha256` of what was deployed, and `"name_tables": "d1"`, which says that a Worker of this version reads its name tables from its D1 (written with either `--sharing` choice) |

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
   - Account › D1 › Edit (create the databases, apply migrations; `publish_modules.sh` appends the
     name tables to both databases and `deploy_web.sh` reads them back, "Name tables" below)
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
   the tables `0002_accounts.sql` dropped. A D1 that has never held name tables also needs its
   first load before item 6, which otherwise stops at stage 3 ("Switching the name tables to D1",
   step 2; without `--baseline` when no Worker of that target ever ran with sharing).
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
before the upload), reads the name tables back from the target's D1 (sharing on, below), cuts the
page fonts (below), writes `deploy.json`, runs
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
`Current Version ID: <id>`. Write it down with the `git_sha` of that `deploy.json`: a rollback
names the version it returns to (see "Rolling back and switching off").

**Name tables.** A shared record stores ids, and the Worker looks their names up when the record is
read, in the name tables of its own D1 (`share_table_name`, `share_table_gid` and
`share_table_load`, from `server/migrations/0006_share_tables.sql`, and `share_table_tags`, from
`0007_share_table_tags.sql`: each factor's tags in the module set, from which the public record
takes the factor's colour). Each target's D1 holds its
own. They are not part of a deployment: `publish_modules.sh` appends the names each module set adds
to both D1s before it switches the pointer ("Publishing to data.umacapture.com"), and the Worker
reads them from D1. A stored name is never changed or deleted, and a list only grows at its end:
the migration's triggers refuse anything else. The tables' version, which a share from a newer
module set is compared against, is the `recognizer_version` of the latest load.

With sharing on, stage 3 reads the target's tables back with
`tool/cloudflare/load_share_tables.py --read-to build/share_tables.json`, for the page fonts. It
writes nothing to D1. When that D1 records no load, or does not have the tables at all, the run
stops there, before anything is deployed: a Worker there would answer every request that looks a
name up with a `500` ("Switching the name tables to D1"). It stops there too when the D1 holds fewer
factor tags than factor names: the Worker holds a factor only together with its tags, so it would
answer a `500` for every record with a factor whose tags are missing ("Rolling out factor colours
and the end of share focus").
The line `load_share_tables.py` prints just before the run's own message says which of the two it
is. With sharing off D1 is not read.

**Page fonts.** With either `--sharing` choice, the run then writes the font files
`web/site/site.css` names into `build/web/site/fonts/` with `tool/cloudflare/build_page_fonts.py`:
subsets of the pinned M PLUS Rounded 1c TTFs, cut to the characters of `web/**/*.html`,
`server/src/*.mjs` and, with sharing on, the names just read back from D1. The subsets are not
pinned, the TTFs are; a character the font lacks is drawn with a system font. So is a character
that only names published after the deployment use, until the next deployment cuts it in.

A redeploy is needed whenever the app, `web/`, or the wasm core changes. A new recognizer module
set needs none: the app downloads modules from `data.umacapture.com` at runtime, and the Worker
reads the names they add from its D1, which publishing them with `publish_modules.sh` brings up to
date on both targets (see "Publishing to data.umacapture.com" below).

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
- `uv` and `node` are on `PATH` (stage 3: reading the name tables back with sharing on, the page
  fonts always). Stage 0 checks both.
- With sharing on, the target's D1 holds name tables: the stage 3 read,
  `uv run tool/cloudflare/load_share_tables.py --target <target> --read-to build/share_tables.json`
  after `npm ci` in `server/` and with `tool/cloudflare/.env` exported ("The pinned wrangler"),
  prints the entries and the generation it read and exits 0. It only reads D1.
- `web/` matches its pins: `.fvm/flutter_sdk/bin/dart run tool/check_web_pins.dart --licenses
  --require-verified`, the check stage 1 runs before it builds. It fails when the wasm module is
  older than the `native/` sources it was built from.

`--dry-run` is not a cheaper way to the same answer in production: it builds, sends the source maps
to Sentry (an outward transmission like the real run's), and the real run builds and sends them
again.

### Ordering against a Windows release

A Windows build that sends something the Worker in production does not accept is released only
after that Worker is deployed.

Sharers no longer choose how a shared record is shown. A web app tab opened before that still
sends a share's `view` `{focus}` (`"training"` or `"inheritance"`) and `PATCH /api/shares/<id>` to
change it. The Worker accepts such a share and keeps nothing of its `view`; it has no `PATCH` route,
so the change gets the plain-text `404`, which the tab shows as a failure and which leaves its
shares as they are. No Windows release has sent either. Do not release a Windows build that does:
its shares would keep the Worker accepting `view` for good, and its changes would always fail.

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
  reading the name tables back, `wrangler deploy` and the checks, about four minutes for a
  production run. A run that stops partway keeps it open until a later run gets through, which is
  why the checks come first.

### Switching the name tables to D1

Once per target whose live Worker bundles its name tables — its live `deploy.json` lacks
`"name_tables": "d1"` — and before the first deployment of a Worker that reads them from D1. Take
these steps in this order:

1. **Apply `0006_share_tables.sql`** to both D1s ("Applying a migration"). It only adds tables the
   live Worker does not read, so the apply opens no broken window. Do it before anyone publishes a
   module set from a checkout whose `publish_modules.sh` has the name-tables stage: that stage
   writes to both D1s, and a D1 without these tables stops the publish before the pointer changes
   ("Publishing to data.umacapture.com").
2. **Load the archive the live pointer names** into each D1, with the tables the target's Worker
   bundles as `--baseline`. They are in `tool/cloudflare/.deploy-backup/tables.<target>.json`
   (gitignored; it holds game text), written by that target's last verified deployment with sharing.
   From Git Bash at the repository root:

   ```bash
   mkdir -p build
   curl -fsS -o build/pointer.json https://data.umacapture.com/umacapture/version_info.json
   sha=$(jq -r .module_archive.sha256 build/pointer.json | tr -d '\r')
   curl -fsS -o build/live-modules.zip "https://data.umacapture.com/umacapture/modules/$sha.zip"
   echo "$sha  build/live-modules.zip" | sha256sum -c
   (cd server && npm ci --no-audit --no-fund)
   set -a; source tool/cloudflare/.env; set +a
   for t in production staging; do
     uv run tool/cloudflare/load_share_tables.py --target "$t" --archive build/live-modules.zip \
       --baseline "tool/cloudflare/.deploy-backup/tables.$t.json" --dry-run
   done
   ```

   then the same loop without `--dry-run`. Each run prints how many entries it adds. `--baseline`
   refuses, and writes nothing, when the result would drop a name the target's Worker bundles, or
   when the file does not exist; a refusal means that target is not switched. Running the loop
   again after a failure completes the load, and a target already loaded adds nothing.
3. **Deploy each target that runs with sharing** with `deploy_web.sh` ("Deploying"; staging first,
   as always). Stage 3 now finds the tables. From this deployment on, the target's Worker serves the
   names its D1 holds: a target whose bundled tables came from another archive than the one the
   pointer names, as production's do, gets the pointer's names at this point and not before.

The order is what keeps names answering. `deploy_web.sh` refuses a sharing-on deployment to a D1
without the tables or without a load, at stage 3, with nothing deployed. A Worker of this version
that reached such a D1 another way (a bare `wrangler deploy`, which "Deploying" rules out) would
answer with a `500` wherever it has a name to look up: `/r/<id>` and `/r/<id>.json` of a record
that exists, `POST /api/shares` of a record, and `/u/<id>`, `/u/<id>.json` and `GET /api/me/shares`
of an account that shares something. Without the tables those three answer `500` for an account
that shares nothing too; with the tables but no load they answer its empty list. A record or account that does not exist still gets its `404`, so stage 8's
check of `/r/0000000000` would not notice. After step 3, do not roll a target back to a version
with the Worker from before it ("Restoring a version").

### Rolling out factor colours and the end of share focus

Once, for the release whose Worker gives each public factor a colour and `factor_totals`, takes no
share focus, and has no `PATCH /api/shares/<id>`, together with the OG function that draws a card
from `factor_totals`. Take these steps in this order:

1. **Apply `0007_share_table_tags.sql`** to both D1s ("Applying a migration"). It only adds a table
   the live Worker does not read, so the apply opens no broken window. Do it before anyone publishes
   a module set from a checkout that loads tags: on a D1 without the table, that publish stops at
   its name-tables stage, before the pointer changes ("Publishing to data.umacapture.com"). Apply it
   from a checkout without `0008_drop_share_focus.sql` (step 6): the apply takes every migration the
   database lacks, and `0008` breaks a Worker from before step 3 or 4.
2. **Load the archive the live pointer names into both D1s again**: the commands of step 2 under
   "Switching the name tables to D1", without `--baseline` and its file, `--dry-run` first and then
   without it. Both D1s already hold the archive's names and gids, so each run adds only the tags,
   one per entry of the archive's `factor_info.json`, and records a new load. The live Worker does
   not read the tags; readers see no change. Then
   `uv run tool/cloudflare/load_share_tables.py --target <target> --read-to build/share_tables.json`
   exits 0 for both targets: it refuses a D1 with fewer factor tags than factor names, as stage 3 of
   `deploy_web.sh` does.
3. **Staging.** Deploy it ("Deploying") and check there: `/r/<id>.json` of a record shared on
   staging gives every factor a `color` and carries `factor_totals`; `/r/<id>` answers `200`; a web
   app tab opened before the deployment still shares. Then deploy the OG function as a preview
   (`deploy_og.sh`, whose preview reads the staging origin) and check that a staging record's card
   draws, rather than redirecting to `/og/default.png`.
4. **Production web app and Worker** ("Checks before a production run", then "Deploying").
5. **Production OG function**, after step 4 (`deploy_og.sh --target production`): it draws a card
   only from a record JSON that carries `factor_totals`, and answers one without it with the
   redirect to `/og/default.png`; it also reads its logo from the origin step 4 deployed. Check a
   production card, and write down the deployment URL the script prints last.
6. **Afterwards, in a commit of its own**: `0008_drop_share_focus.sql` drops `records.focus`, and
   `web/site/logo.svg` goes, with its line in `tool/web_deps.json`. Apply `0008` to a D1 only when
   its live Worker is from step 3 or 4 or later, staging first, then deploy that commit to staging
   and production.

Until step 6 a rollback of the Worker is bounded only as "Restoring a version" says. A Worker from
before step 4 serves a record JSON without `factor_totals`, so once the OG function of step 5 is
live, rolling the Worker back past step 4 makes every card the default image; roll the OG function
back with it, or roll neither back.

After step 6 two more limits hold:

- **Worker.** Do not roll a target back to a version whose Worker reads `records.focus`: every
  version deployed before step 3 (staging) or step 4 (production), the version production ran before
  this release included. That Worker names a column D1 no longer has in every query that reads or
  writes a shared record, so each of them fails. A version reads it
  when `git grep -n focus <git_sha> -- server/src/store.mjs` prints anything for its `deploy.json`'s
  `git_sha`. The way back is a new deployment.
- **OG function.** Do not roll the OG function back on its own to a deployment from before step 5.
  Such a function reads `/site/logo.svg`, which the origin no longer serves, so it answers every
  card with the redirect to `/og/default.png`. An instance that fetched the logo before keeps
  drawing until it is replaced, so a card checked right after the rollback can still look right.
  `deploy_og.sh` records the commit of each deployment as its `git_sha` meta; a deployment reads
  `/site/logo.svg` when `og/src/handler.mjs` at that commit sets `LOGO_PATH` to it. Cards draw again
  once either holds: a deployment from step 5 or later is the production one again
  (`og/node_modules/.bin/vercel promote <deployment url>`, or `deploy_og.sh --target production`),
  or the origin serves `/site/logo.svg` again (a rollback to the version deployed in step 3 or 4,
  which still serves it and reads no `records.focus`, or a new deployment that restores the file).

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
- **Name tables.** Staging's Worker reads them from the staging database, which every module
  publish writes along with production's (see "Deploying", Name tables). With sharing on, a staging
  run reads them back from there at stage 3, as a production run does from production's.
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
  is a separate step. Every module publish still writes its name tables to the staging database,
  sharing or not, so deleting it stops every publish before the pointer changes, for as long as
  `publish_modules.sh` names staging among its targets.

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

- **Preconditions.** `server/data-site/`, `server/wrangler.data.jsonc`, `server/wrangler.jsonc`
  (whose D1 bindings name the databases the name tables are written to), `tool/cloudflare/`, and the
  `npm ci` inputs `server/package.json` and `server/package-lock.json` that pin the deploying
  wrangler, are committed with nothing modified or untracked under them, so `deploy.json`'s
  `git_sha` names what is served, where its name tables went, and what deployed it. A new file under `tool/cloudflare/` counts:
  until it is committed, the run stops here. The rest of the tree may be dirty. Any committed
  `HEAD` will do; it need not be `develop`. The credentials are the `tool/cloudflare/.env` ones
  `deploy_web.sh` uses: Workers Scripts and Workers Routes, Edit, for the data host, and D1, Edit,
  for the name tables. `uv` has to be on `PATH`.
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
- **Name tables, between the two phases.** Before phase 2, on both paths (a new archive and a
  re-publish), the run appends the names the archive adds to the D1 of production and then of
  staging, with `tool/cloudflare/load_share_tables.py --archive`, from the same bytes phase 1
  verified. Every list has to agree with the rows D1 already holds over the range both hold; only
  the entries D1 lacks are added, so an older archive adds nothing and writes nothing. The rows are
  read back and checked, and only then is the load recorded (`share_table_load`). A Worker that
  reads D1 in the middle of a load counts, per key, only the entries its names and, where the
  key has them, its gids and its tags (factors only) already hold; a sid past those makes it check D1 once for a newer load. Any refusal or
  failure on either target stops the run before phase 2, so no client is pointed at modules whose
  names a Worker does not have; running the publish again completes the load. Both D1s need
  `0006_share_tables.sql` and `0007_share_table_tags.sql` ("Applying a migration"); a D1 without
  the tags table stops the run here. `--dry-run` stops before this stage and writes
  nothing to D1. A share Worker picks the new names up from D1 by itself; no web deployment follows.
- **Publish from a checkout that loads tags.** A `load_share_tables.py` older than
  `0007_share_table_tags.sql` writes names and gids but no tags, and the run succeeds. The Worker
  then holds none of the factors that publish added: a shared record carrying one of them answers
  `500`, and a share of one is refused as `invalid_payload`. The next publish from a current
  checkout (a re-publish with no zip will do) adds the missing tags, and the Worker picks them up by
  itself.
- **A name in D1 is final.** Once a load has written a name, no later archive can change it: an
  archive whose lists disagree with D1's rows is refused, and its publish stops before the pointer
  changes.
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

Neither way rolls the name tables back. D1 keeps every name the later publish loaded, and the
tables' version stays that of the latest load. That is safe: an older module set uses only sids
the tables already hold, and records shared under the later set stay readable.

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
Regular and the logo, so the origin has to serve them first.

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
or a rollback read it from the list below) and, for a deployment, the `git_sha` of its
`deploy.json` and whether it carries `"name_tables": "d1"`. A rollback names one of these ids.

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
- After step 6 of "Rolling out factor colours and the end of share focus" (`records.focus` dropped,
  `/site/logo.svg` no longer served), do not roll a target back to a version whose Worker reads
  `records.focus`, and do not roll the OG function back on its own to a deployment that reads
  `/site/logo.svg`. That section says how to tell them, and what brings the cards back.
- When secrets have changed since the version, wrangler asks to confirm. Without a terminal (stdin
  or stdout not a terminal, or a CI environment) every prompt of `rollback` takes its default, and
  that confirmation's is yes.

**Name tables.** Do not roll back to a version with the Worker whose `deploy.json` lacks
`"name_tables": "d1"`. Its Worker resolves names through tables bundled when it was deployed,
which can be shorter than the ones in D1, and a record shared under longer tables cannot be read
with shorter ones. To undo such a step, stop sharing instead (below), or deploy a new version.
Between two versions that both carry `"name_tables": "d1"` the name tables set no condition: both
Workers read the same tables from D1, which a rollback leaves as they are, so publishing module
sets does not narrow which of them can be returned to. A version deployed with sharing off has no
Worker and reads no names.

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
| `SHARING_ENABLED` `"false"`, committed, then `deploy_web.sh` | New logins and shares stop (`503 sharing_paused`); reading, unsharing and logging out go on, and so does sync for a device already logged in | A clean tree, a build, the Sentry upload (production), a load of the name tables in the target's D1 (read back at stage 3), the pinned wrangler. Not usable while any of them is broken |
| `deploy_web.sh --sharing off` | As the rollback, with the assets of the current `HEAD`; the hourly run goes too | As above, except D1: the name tables are not read. Use it once the version without the Worker is no longer among the last 100 |
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
synced objects, their bucket is not deleted; while `publish_modules.sh` writes name tables to a
D1, deleting it stops every module publish ("Publishing to data.umacapture.com"). `b2_list_file_versions`, under the same authorization
as the lifecycle check (One-time preparation, step 10), lists every version a bucket holds, hidden
ones included. The kept copy of `IDENTITY_HMAC_KEY` goes only with
the accounts it reaches.

### Other

| Goal | How |
|---|---|
| Take the site off the domain | Remove the `umacapture.com` custom domain in the dashboard |
