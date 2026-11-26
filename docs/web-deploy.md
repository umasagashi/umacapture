# Deploying the web app

The web app is served from `https://umacapture.com` by **Cloudflare Workers Static Assets**,
together with the **Worker** (`server/src/`, configured by `server/wrangler.jsonc`) and its D1
database. The Worker carries logins (Google, behind Turnstile), record sharing and file sync. It
answers the record pages `/r/<id>` and their JSON `/r/<id>.json`, the report page of a record
`/r/<id>/report`, an account's list of shared records `/u/<id>` and `/u/<id>.json` and the list's report
page `/u/<id>/report`, which serve the list only while its sharer has made it public (every account
starts private), and the API under
`/api/` (file sync under `/api/sync/`), and answers 404 to any other path that matches no file. The
API includes the app's import of a shared record: `GET /api/shares/<id>`, which answers the stored
form and the state of the share's images, and `GET /api/shares/<id>/images`, the image bundle of a
share whose sharer chose to share its images. Both answer without a login, for the app alone: their
shape is not promised to anyone else, who reads `/r/<id>.json`. An hourly run of the same Worker
carries out operators' takedowns of shares, tidies the storage of file sync and of shared images, and
goes on with the deletion of every account being deleted (`triggers.crons`). File sync's objects and
shared images are stored in a Backblaze B2 bucket per environment, which the Worker alone reaches,
with a key held in Worker secrets ([`sync-server.md`](sync-server.md)). A
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
| Fonts | The app still fetches its fonts at runtime from `fonts.gstatic.com` (not bundled). The public pages (`/notice/`, `/terms/`, `/privacy/`, and the Worker's pages) read M PLUS Rounded 1c from this origin: `build/web/site/fonts/`, woff2 subsets the run cuts out of the pinned TTFs in `web/og/fonts/` ("Page fonts" below) |
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

   The billing guard has a token of its own ("The guard's token"); this one is never given to it.

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
     includes a month it bills rather than stops; what stops the Workers and D1 charges is the
     billing guard ("The billing guard"). File sync's service-wide daily limits in
     `server/src/limits.mjs` are set so that production and staging both using them up every day of
     a month stay within what the plan includes; their comments derive each figure. They count the
     requests of logged-in accounts up to each limit, so they bound neither a request from someone
     who is not logged in nor one past a limit: each of those still runs the Worker.
   - `server/wrangler.jsonc` declares **one binding**, the D1 database `DB`, and no R2, and caps
     each invocation's CPU time at 200 ms ("The CPU limit per invocation").
     `server/wrangler.assets-only.jsonc` declares no binding at all. Read both again before deploying.
   - **Backblaze B2** is billed by Backblaze, outside Cloudflare, and the billing guard does not see
     it. Its data caps and alerts (below) limit what it can charge a day, for what they cover.
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
   deployment with sharing on keeps the secrets; a deployment with sharing off (assets only) removes
   them all, and they do not come back with the next deployment ("Stopping staging" under
   "Staging"). These are every secret the Worker reads:

   | Secret | What it is | Without it |
   |---|---|---|
   | `TURNSTILE_SECRET` | The Turnstile widget's secret key (step 7) | Every login begin is refused (`403`) |
   | `GOOGLE_CLIENT_SECRET` | The Google OAuth client's secret (step 8) | Every login fails at the callback |
   | `IDENTITY_HMAC_KEY` | 32 random bytes as 64 lowercase hex digits (step 9) | Every login fails at the callback |
   | `B2_KEY_ID`, `B2_APPLICATION_KEY` | The application key of the environment's B2 bucket (step 10) | Every sync request that reaches B2, every put and fetch of a share's images and every account deletion fail (`502`), and so does every hourly run |
7. **Turnstile.** Create the widget in the dashboard for the hostname `umacapture.com`, in Managed
   mode. Its sitekey goes into the config (below), its secret key into `TURNSTILE_SECRET`. The
   login start page (`/api/auth/start`) shows the widget, and a login begin
   (`POST /api/auth/begin`) is refused unless siteverify reports this hostname and the action
   `login`. The report pages of a record (`/r/<id>/report`) and of a list (`/u/<id>/report`) show the same widget, and a report
   (`POST /api/reports`) is refused unless siteverify reports the action `report` (`REPORT_ACTION` in
   `server/src/report.mjs`, a constant, not a var).
8. **Google login.** In Google Cloud, an OAuth client of type Web application; the Worker asks it
   for the scope `openid email`. Its redirect URI is `<AUTH_REDIRECT_ORIGIN>/api/auth/callback/google`:
   `https://umacapture.com/api/auth/callback/google` for production. Its client id goes into
   `vars.GOOGLE_CLIENT_ID`, its secret into `GOOGLE_CLIENT_SECRET`. While `GOOGLE_CLIENT_ID` is empty,
   a login begin refuses to run rather than send Google a request without a client.

   How a login comes back differs by app, and the callback tells them apart by whether the login
   carries a loopback port. The web app replaces itself with the start page in its own tab (a
   password manager's "Sign in with" follows one tab), keeping the login's secret in that tab's
   `sessionStorage`; the callback answers a `302` to `<PUBLIC_ORIGIN>/#/account` with the proof as a
   cookie, and the app loaded there claims the login once, at start-up. While a capture or a video
   import runs, the web app refuses to leave and says so. The Windows app opens the start page in
   the default browser, and the callback hands its proof to the app's loopback port. The cookie
   reaches the app's claim only while `AUTH_REDIRECT_ORIGIN` is the app's own origin, as it is on
   both targets.
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
    - **Two lifecycle rules**, one per prefix the Worker stores under
      ([`sync-server.md`](sync-server.md#the-b2-bucket)):
      - `daysFromHidingToDeleting` 6 covering the prefix `a/`, file sync's objects
        (`B2_DAYS_FROM_HIDING_TO_DELETING` in `server/src/limits.mjs`). The Worker only hides what is
        no longer referenced, and counts on this rule to delete it; without the rule nothing it hid is
        ever deleted.
      - `daysFromHidingToDeleting` 1 covering the prefix `s/`, the image bundles of shares. B2 hides
        a version once a later one of the same key is uploaded, and a retried or doubled PUT uploads
        one; this rule deletes them a day or two later. Every version of a key holds the same bytes,
        so nothing served changes. Without the rule those versions stay until the share is unshared
        or its account deleted. Set it before the first Worker that stores images is deployed
        ("Rolling out shared images, the link import and reports"), so that it covers every version
        from the first.
    - **Check the rules after setting them.** Read the bucket's lifecycle rules back, in the B2
      console (the bucket's Lifecycle Settings), or read only through the native API:
      `b2_authorize_account` with the bucket's application key, then `b2_list_buckets` with the
      bucket's name in `bucketName` (a key restricted to one bucket has to name it), which returns
      the rules as `lifecycleRules`. Expect exactly two rules: `fileNamePrefix` `a/` with
      `daysFromHidingToDeleting` 6, and `fileNamePrefix` `s/` with `daysFromHidingToDeleting` 1, each
      with no `daysFromUploadingToHiding`: that would hide objects the Worker still references or
      serves. A rule with `fileNamePrefix` `""` would cover both prefixes with one number, which is
      right for neither.
    - **Data caps and alerts** on the B2 account (Caps & Alerts), the stop for B2's charges. A data
      cap limits what one kind of usage may cost a day (UTC), with alerts at 75% and 100% of it;
      Backblaze's documentation offers them for storage and for Class A, B and C transactions. Set
      storage at $0.50 a day, and download at $0.20 a day if the console offers a download cap.
      As read on 2026-11-19:
      - Backblaze's pricing makes Class A, B and C calls free for pay-as-you-go accounts; the Worker's
        calls (PutObject, GetObject, DeleteObjects and ListObjectVersions, `server/src/b2.mjs`) are
        all in those classes. A transaction cap therefore bounds nothing that is billed. Class D (outbound
        event notifications) is billed and cannot be capped; the preparation above sets up no event
        notification.
      - What is billed is storage, and download past three times the average stored. The pages read
        name no download cap apart from the transaction caps, so whether download can be capped is
        not confirmed.
      - What B2 does with a request once a cap is reached is not stated there and has not been
        observed. A request B2 refuses, the Worker answers `502`; as the caps are the account's, file
        sync and shared images would reach them together.
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
    | `SHARE_IMAGES_ENABLED` | `"true"`. `"false"` stops shared images coming in and going out: a share that declares images is refused (its result in `POST /api/shares` is `image_sharing_paused`; one without images goes on), a bundle's PUT answers `503 image_sharing_paused`, the bundle's GET answers `404`, and the import endpoint tells a share with images `{"state": "unavailable"}`. Unsharing, account deletion, takedowns and the hourly run's deletion of images go on. Turning it back to `"true"` serves again every bundle still stored |
    | `REPORT_SENTRY_DSN` | The Sentry DSN reports of shares and lists are sent to: the app's own (`_sentryDsn` in `lib/src/core/sentry_util.dart`), written here a second time because the app and the Worker ship apart. A DSN is a public client value, so it is a var. Empty: the environment takes no reports, and the report page says so. Staging's is empty |
    | `REPORT_SENTRY_ENVIRONMENT` | `production`: the Sentry environment a report's event carries (staging `staging`) |
    | `B2_ENDPOINT` | `s3.us-west-004.backblazeb2.com` |
    | `B2_REGION` | `us-west-004` |
    | `B2_BUCKET` | `umacapture-sync` |

    `SHARING_ENABLED`, `SYNC_ENABLED` and `SHARE_IMAGES_ENABLED` must be `"true"` or `"false"`; any
    other value is a configuration error. `wrangler deploy` replaces the Worker's vars with the ones in the config,
    so a var set in the dashboard does not survive the next deployment.
12. **Zone rate limiting.** One WAF rate limiting rule on the `umacapture.com` zone: requests whose
    URI path starts with `/r/`, `/u/` or `/api/` but not with `/api/sync/`, counted per IP and per
    Cloudflare data centre (the counting characteristics `ip.src` and `cf.colo.id`), 10 requests in
    10 seconds, blocked for 10 seconds. Its expression:

    ```
    (starts_with(http.request.uri.path, "/r/") or starts_with(http.request.uri.path, "/u/")
     or starts_with(http.request.uri.path, "/api/"))
    and not starts_with(http.request.uri.path, "/api/sync/")
    ```

    File sync is left out on purpose: a normal sync round would trip the rule. Its requests are made
    one after another, each as soon as the previous one is answered (`syncRoundEstimate` in
    `lib/src/chara_detail/record_sync_round.dart`), so with an answer in 0.1 seconds a round makes
    about 100 requests in 10 seconds, ten times what the rule lets through, and a first sync of many
    records runs to thousands. Sync's own limits (per account and over every account, per day,
    [`sync-server.md`](sync-server.md#limits)) bound what accepted requests store and do; what
    bounds the bill for every request, sync's included, is the billing guard. Every
    sync endpoint is under `/api/sync/`, so the one prefix covers them. The zone's Free plan allows
    exactly one such rule, with those fields, those counting characteristics, that period and that timeout; if
    the zone already has one, decide which to keep rather than overwriting it.

    **Check the rule from outside**, against production: staging is blocked by the guard's WAF
    rule outside a test window (see the Entrance list). Send 20 requests within 10 seconds to one path at a time, and
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
13. **Notification of reports.** A report of a share (`/r/<id>/report`) or of an account's list
    (`/u/<id>/report`) reaches the operator only as a Sentry event in the app's project
    (`REPORT_SENTRY_DSN`); nothing else tells anyone. Each accepted report is one event of this shape
    (`sendReport` and `TARGETS` in `server/src/report.mjs`); where a list's report differs, the
    value follows the slash:

    | Field | Value |
    |---|---|
    | `message` | `share report` / `list report` |
    | `level` | `warning` |
    | `logger` | `share-report` |
    | `environment` | `REPORT_SENTRY_ENVIRONMENT` |
    | `tags` | `kind`: `share_report` / `list_report`; `reason`: `own_trainer`, `personal_info`, `inappropriate` or `other` (`REPORT_REASONS`) |
    | `extra` | `share_id`, `text` (the reporter's free text, up to 1,000 characters), `shared_on` / `list_id` (the account id of `/u/<id>`), `text` |
    | `fingerprint` | `["share-report", <share id>]` / `["list-report", <account id>]`: one issue a share or a list, whose count grows with each later report of it |

    It carries no user, request or IP. In Sentry, create one issue alert rule on the app's project:
    environment `production`; when a new issue is created, or an issue changes state from resolved
    to unresolved (a share or list reported again after its issue was resolved); if the event's tag `kind`
    equals `share_report` or `list_report`; then notify the operator (email to the member or team who handles
    reports). The tag filter keeps the app's own errors out of it. Any other rule of the project that
    fires on every new issue fires on reports too; decide whether to keep that. Staging's DSN is
    empty, so the rule can only be checked in production: send one report from a production record
    page (it counts toward that day's `REPORT_DAILY_LIMIT`), and expect an issue `share report` with
    the record's `share_id` and a notification. Handling a report is under "Handling a report".

### Entrance list

| Entrance | What it serves | Zone WAF | Expected setting |
|---|---|---|---|
| `umacapture.com` (custom domain) | The web app and the Worker (`umacapture-web`) | Applies: the rate limiting rule on `/r/`, `/u/` and `/api/`, except `/api/sync/`; rule G closes `/r/`, `/u/` and `/api/` at stage A and the whole host at the budget or when the guard cannot measure ("The billing guard") | Production entrance |
| `data.umacapture.com` (custom domain) | Recognizer modules and announcements (`umacapture-data`, static assets only, no R2) | Applies; rule G never blocks it (its allow list: no request there runs a Worker) | Production entrance |
| `og.umacapture.com` (Vercel project domain, CNAME, DNS only) | The OGP image function (`umacapture-og` on Vercel) | Does not apply: the zone does not proxy it. The Vercel Firewall rule applies (see the Vercel section) | Production entrance |
| `umacapture-og.vercel.app` | The project's own production domain on Vercel | Does not apply | Kept. It answers without the bypass header: `/` gets the platform's 404 and `/r/<id>.png` reaches the function, because production domains are outside deployment protection. Whether the Vercel Firewall rule also applies here is not measured: the burst test ran against `og.umacapture.com` only |
| `staging.umacapture.com` (custom domain) | Staging (`umacapture-web-staging`) | Applies: rule G blocks the host except while a test window is open | Staging entrance, closed outside a test window (see "Staging") |
| Any other proxied host of the zone | — | Applies: rule G blocks it whenever it blocks staging: outside a test window, and whenever it closes production | A new proxied DNS record of the zone is blocked from its first request; decide what it is for before adding one |
| `umacapture-guard` (no route, no custom domain) | The billing guard: a Worker run only by its Cron trigger, every minute | Does not apply: no request reaches it | Closed: no route, `workers_dev: false`, `preview_urls: false` (`server/wrangler.guard.jsonc`) |
| `umacapture-web.<account>.workers.dev`, `umacapture-web-staging.<account>.workers.dev`, `umacapture-data.<account>.workers.dev` | Would serve the same Workers | Does not apply | Closed: `workers_dev: false` in every config. The setting takes effect when the Worker is next deployed; staging's URL, closed that way, answered `404` with `error code: 1042` |
| Per-version preview URLs (both Workers) | Would serve each version | Does not apply | Closed: `preview_urls: false` |
| B2 buckets `umacapture-sync`, `umacapture-sync-staging` | File sync's objects (`a/`) and shared images (`s/`), reached only by the Worker with the bucket's key. Nothing under `a/` is public. A bundle under `s/` is served to anyone who knows its share's id, through the Worker's `GET /api/shares/<id>/images` on the entrance above, while the share records it stored and `SHARE_IMAGES_ENABLED` is `"true"` | Does not apply to the bucket; the zone's rule applies to the Worker's `/api/` | Private |

After the first deployment, confirm in the dashboard (Worker › Settings › Domains & Routes) that
`workers.dev` and preview URLs are shown as disabled and that each Worker has exactly one domain:
`umacapture.com` for `umacapture-web`, `data.umacapture.com` for `umacapture-data`,
`staging.umacapture.com` for `umacapture-web-staging`, and none for `umacapture-guard`. No zone route
points at any of them.

Rule G exists only once the guard has been armed ("The billing guard"); until then it blocks nothing
in this table.

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

A Windows build that shares a record's images, sends the trainee's and the parents' icons and the
parents' rank and record type, or imports from a share link is released only after the production
Worker that takes and answers them ("Rolling out shared images, the link import and reports"). An
older Worker refuses every share of such a build as `invalid_payload` (it refuses any key it does not
know), and answers the link import `404`. Once such a build is released, the production Worker is
never rolled back past that version (below).

A build that shows the account's usage reads `GET /api/me/usage` (shares, sync's stored bytes and
synced records, each beside its cap; see `docs/sync-server.md`, "Usage and the database's room"). A
Worker older than that route answers it with the plain-text `404`, as it answers every path it does
not know. Such a build is released only after the production Worker that has the route, and the
production Worker is not rolled back past that version afterwards. A build that meets such a Worker
anyway shows no usage on that `404`; it is not a failure of the account or of the session.

A build that edits a share's tagline (`PUT /api/shares/<id>/tagline`) or the account's public profile
(`PUT /api/me/profile`), and reads them from `GET /api/me/shares` (`tagline`) and `GET /api/me`
(`profile`), is released only after the production Worker that has them ("Rolling out taglines and
the public profile"). The share itself is not affected: `POST /api/shares` is unchanged, so an older
Worker takes such a build's shares as before. It answers the two writes with the plain-text `404`, as
it answers every path it does not know, and its `GET /api/me` and `GET /api/me/shares` carry neither
key; a build that meets such a Worker shows the editing as not available rather than as a failure.

A build that switches the account's list between public and private (`PUT /api/me/list`) and reads
`list_public` from `GET /api/me` is released only after the production Worker that has them ("Rolling
out the list's visibility"). An older Worker answers the switch with the plain-text `404` and leaves
`list_public` out of `GET /api/me`, and the list it serves is always public. The other way round, the
Worker of that release refuses nothing an older build sends, but every list is private from its
deployment and an older build cannot switch it: the older build's links to the account's list lead to
the private page until the sharer switches it from the web app or a newer build.

A build that shows the last login and warns before an account is deleted for inactivity reads
`last_login_day` and `deletion_day` from the claim and `GET /api/me`, and is released only after the
production Worker that has them ("Rolling out deletion for inactivity"). An older Worker leaves both
out, and such a build then has no last login to remember, show or warn about.

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
that exists, `POST /api/shares` of a record, `/u/<id>` and `/u/<id>.json` of an account whose list
is public and that shares something, and `GET /api/me/shares` of an account that shares something.
Without the tables those three answer `500` for such an account that shares nothing too; with the
tables but no load they answer its empty list. A list is decided before any name is looked up: a
record or account that does not exist, and the list of an account being deleted, still get their
`404`, and a private list its `403`, so neither stage 8's check of `/r/0000000000` nor opening a
list nobody has made public would notice. After step 3, do not roll a target back to a version
with the Worker from before it ("Restoring a version").

### Rolling out factor colours and the end of share focus

Once, for the release whose Worker gives each public factor a colour and `factor_totals`, takes no
share focus, and has no `PATCH /api/shares/<id>`, together with the OG function that draws a card
from `factor_totals`. Take these steps in this order:

1. **Apply `0007_share_table_tags.sql`** to both D1s ("Applying a migration"). It only adds a table
   the live Worker does not read, so the apply opens no broken window. Do it before anyone publishes
   a module set from a checkout that loads tags: on a D1 without the table, that publish stops at
   its name-tables stage, before the pointer changes ("Publishing to data.umacapture.com"). The
   apply takes every migration the database lacks, and the tree carries
   `0008_drop_share_focus.sql` (step 6), which breaks a Worker from before step 3 or 4. So a D1
   whose live Worker is from before step 3 or 4 gets `0007` from a commit before step 6 only.
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
   the tree no longer has `web/site/logo.svg` or its line in `tool/web_deps.json`. Apply `0008` to a
   D1 only when its live Worker is from step 3 or 4 or later, staging first, then deploy a commit
   from step 6 or later to staging and production. A D1 has had step 6 once
   `server/node_modules/.bin/wrangler d1 migrations list <database> --remote -c server/wrangler.jsonc`
   no longer lists `0008` as unapplied; the origin has, once the `git_sha` of the deployed
   version's `deploy.json` is a commit without `web/site/logo.svg`.

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

### Rolling out shared images, the link import and reports

Once, for the release whose Worker stores and serves the images a sharer chooses to share, answers
the app's import of a shared record (`GET /api/shares/<id>`), carries out operators' takedowns and
takes reports of shares, with the migration `0009_share_images.sql`. Take these steps in this order,
staging first:

1. **The `s/` lifecycle rule** on the target's bucket, and read the rules back (One-time preparation,
   step 10). Before the Worker stores anything under `s/`, so that the rule covers every version.
2. **Check that the target's D1 has no `0009` yet.** The file was changed after it was first
   committed (it gained `share_takedowns` and `daily.reports`), and `migrations apply` applies a
   migration by its name once, so a D1 that ran an earlier `0009` would never get what was added:

   ```bash
   server/node_modules/.bin/wrangler d1 migrations list umacapture-share --remote -c server/wrangler.jsonc
   # staging: umacapture-share-staging --env staging
   ```

   Go on only when it lists `0009_share_images.sql` as not applied. If it does not, that D1 ran a
   `0009` already: stop, and read which parts it has (the next item's two queries). What it lacks
   goes into a new migration, committed and applied as any other; never into the D1 by hand.
3. **Apply `0009`** ("Checks before a production run", then "Applying a migration"). It adds columns
   and a table and changes none, so the live Worker runs unchanged on it: it names no new column, and
   its writes to `sync_writes` get the space `'a'`. Then confirm that each of these prints one row:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'share_takedowns'"
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT name FROM pragma_table_info('daily') WHERE name = 'reports'"
   # staging: umacapture-share-staging --env staging
   ```

4. **Deploy** the web app and the Worker together ("Deploying"). On staging, check from a staging
   Windows build and from a desktop Chromium-based browser and Firefox: share a record with and
   without its images, and import each from another account; the imported record opens from the
   table with its preview. A share whose bundle was not sent yet is refused as still being sent, and
   imports with its images once the sharer shares it again. After unsharing, `GET /api/shares/<id>`
   and `GET /api/shares/<id>/images` answer `404`. On Android Chrome on a phone (write down the
   model and the CSS viewport width): paste a share link, import, reload, open the record from the
   table, zoom and scroll its preview, close it. Staging's report page says it takes no reports
   (its `REPORT_SENTRY_DSN` is empty). In production, also share eight records with their images at
   once: the zone's rate limiting rule may answer bundle PUTs `429`, after which the app waits once
   and sends again; every share has to end with its images. Then check the report rule (One-time
   preparation, step 13).
5. **Windows release**, after the production deployment ("Ordering against a Windows release").

Shares made before this release carry neither icons nor the parents' ranks, which the import needs, so
the app refuses to import them (`oldFormat` in `lib/src/chara_detail/record_link_import.dart`) until
their sharers unshare them and share them again.

**Do not roll the Worker back past this release** once its web app has been deployed to the target,
or its Windows build released. Stop instead: `SHARE_IMAGES_ENABLED` `"false"` stops images alone,
`SHARING_ENABLED` `"false"` new logins and shares, and a rollback to a version without the Worker
stops the Worker whole ("Stopping record sharing"); none of them leaves anything behind. A Worker from
before this release, rolled back to:

- refuses as `invalid_payload` every share that a web app tab or a Windows build of this release sends,
  since they carry keys it does not know (a resend of a share without images, under a client key it
  already holds, answers `existing` before the check, so that one passes; a share with images is
  refused before the key is looked up);
- deletes a share's row on unshare and on account deletion without recording the share's bundle in
  the write ledger, so the bundle stays in B2 with nothing to delete it, and its hourly run may drop
  the ledger's records of shared images (it reads them as sync's and lists them under `a/`, where
  they are not), with the same result;
- ignores `share_takedowns`, and answers the import `404`.

If an older Worker ran anyway, after the Worker of this release is back, find the bundles no share
accounts for and hand them to the hourly run:

1. List every version under `s/` with `b2_list_file_versions` (`prefix` `s/`), under the same
   authorization as the lifecycle check (One-time preparation, step 10). Each key is
   `s/<account id>/<share id>/<bundle name>`.
2. For each key, the share accounts for it when this prints a row:

   ```sql
   SELECT id FROM records WHERE id = '<share id>' AND owner_id = '<account id>'
     AND images_name = '<bundle name>' AND images_stored_at IS NOT NULL
   ```

3. For each key that no share accounts for, write one record to the write ledger, as a request about
   to write it would have:

   ```sql
   INSERT INTO sync_writes (account_id, write_by, names, written_at, space)
     VALUES ('<account id>', lower(hex(randomblob(16))), json_array('<share id>/<bundle name>'), unixepoch(), 's')
   ```

   The first hourly run two hours and a quarter later (`share_writes`) deletes every version of that
   name uploaded before the record's time, with the code an abandoned PUT's record takes, or only
   clears the record if a share holds the bundle by then. Nothing is deleted in B2 by hand.

### Rolling out taglines and the public profile

Once, for the release whose Worker takes a share's tagline and the account's public profile (the
trainer name and the game's trainer id), with the migration `0010_share_notes.sql`. The sharer writes
them after sharing, from the app:

- `PUT /api/shares/<id>/tagline` `{tagline, previous}` and `PUT /api/me/profile`
  `{trainer_name, game_trainer_id, previous: {trainer_name, game_trainer_id}}` replace the value only
  while it is still `previous`, and otherwise answer `409 changed` with the current value, writing
  nothing. A tagline holds up to 80 code points, a trainer name up to 20, on one line; the game's
  trainer id is 9 or 12 digits, stored without the separators it may be written with. While
  `SHARING_ENABLED` is `"false"` they take only a write that removes a value or leaves it as it is.
  The full contract is on `putTagline` (`server/src/shares.mjs`) and `putProfile`
  (`server/src/account.mjs`).
- The profile is shown on every page of the account's shares (`/r/<id>`) and on its list (`/u/<id>`)
  while the list is public ("Rolling out the list's visibility"), a tagline on its share's page and on
  its row of the list, and both in those pages' JSON (`sharer`, `tagline`). A trainer name or game
  trainer id not written shows as 未公開 on the pages and stays `null` in their JSON. Neither is on the OG card, in a page's description (`og:description`), or in the import
  (`GET /api/shares/<id>`). A change is seen once the pages' caches have passed: five minutes for a
  share's page and its JSON, one minute for a list.
- A tagline's bytes are part of its share's charge against `STORAGE_BUDGET`; the profile is charged
  against nothing. Beginning an account's deletion clears its profile.
- The two writes count together against two daily limits in `server/src/limits.mjs`:
  `ACCOUNT_TEXT_WRITES_PER_DAY` (100 a UTC day for one account) and `TEXT_WRITES_PER_DAY` (10,000 a
  UTC day over every account), held in `accounts.text_writes` / `text_writes_day` and
  `daily.text_writes`. Only a write that stored a value counts; one refused for any reason, `409
  changed` included, counts nothing. A write that only clears — the tagline to null, or a profile
  field to null with the other field left as it is — is neither counted nor refused by the limits, so
  a sharer past them can still take text down; a write that clears one field and changes the other is
  counted like any write. Past either limit a write is `429 daily_limit` with `scope`
  (`"account"` or `"service"`) and a `Retry-After` to the next UTC day, the shape sync's daily limits
  answer with. Lowering either takes a commit and a deployment, like the other limits there.

> Note: The checks below record the completed `0010` rollout. From `0012` onward, lists are
> private by default and a deleting account's list returns `404`, so these checks do not reproduce
> as written. For current checks, see "Rolling out the list's visibility".

Staging first:

1. **Apply `0010`** ("Checks before a production run", then "Applying a migration"). It adds columns
   and changes none, so the live Worker runs unchanged on it. Then confirm that this prints six rows:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT name FROM pragma_table_info('records') WHERE name = 'tagline' UNION ALL SELECT name FROM pragma_table_info('accounts') WHERE name IN ('trainer_name', 'game_trainer_id', 'text_writes_day', 'text_writes') UNION ALL SELECT name FROM pragma_table_info('daily') WHERE name = 'text_writes'"
   # staging: umacapture-share-staging --env staging
   ```

2. **Deploy** the web app and the Worker together ("Deploying"). On staging, write a profile and a
   tagline, and read them on the share's page, on the list and in both JSON; edit the same value from
   two devices and see the second refused as changed; remove both; delete a test account and see its
   list lose the profile at once.
3. **Windows release**, after the production deployment ("Ordering against a Windows release").

**Rolling the Worker back past this release** leaves the columns and what they hold in D1, and the
older Worker shows none of it: the pages and their JSON lose the profile and the taglines, and the two
writes answer `404`. It also does not clear the profile when an account's deletion begins; the row
goes when the deletion completes. If an account began its deletion under the older Worker and the
Worker of this release is back before the deletion completed, clear that account's profile by hand
("Clearing a public profile by hand", under "Handling a report").

### Rolling out the reduced-image default

Once, for the release in which a new account syncs reduced JPEGs, with the migration
`0011_sync_image_form_default.sql`. An account's image form is the `image_form` of its
`sync_accounts` row, and the migration changes that column's default from `'none'` to `'jpeg'`. An
account that has a row keeps the form it holds, `'none'` included: the migration remakes the table
and copies every row as it is. Only an account that makes its row after the migration starts with
reduced JPEGs, and `GET /api/sync/settings` answers `"jpeg"` for an account with no row yet
(`NEW_ACCOUNT_IMAGE_FORM` in `server/src/sync.mjs`, which must equal the column default).

The order is `0010_share_notes.sql`, then the Worker of this release, then `0011`. A request makes an
account's row only after it answered, so the form an account with no row is shown is the Worker's
answer and the form it then syncs is the column default:

- **This release's Worker before `0011`** answers `"jpeg"` for an account with no row while the row
  its request makes holds the old default `'none'`. Someone who opens the dialog that turns sync on in
  that window and turns sync on without choosing sends no images although "縮小した画像" was shown:
  fewer than shown, and nothing leaves the device unchosen. The Worker reads and writes no column
  `0011` adds or moves (the table keeps its columns and their order), so it runs on the table before
  `0011`.
- **An older Worker after `0011`** answers `"none"` while the row holds `'jpeg'`: someone shown
  "画像は送らない" sends reduced JPEGs. That pair must never serve, which is why `0011` comes last.

Staging first:

1. **Apply `0010` and deploy** this release ("Deploying"), with `0011` not yet applied.
   `wrangler d1 migrations apply` applies every migration the database lacks, so where `0010` is not
   applied yet, apply it from a checkout of a commit that has `0010` and not `0011`, then deploy from
   this release's commit.

2. **Read the forms** before applying, to compare after:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT image_form, count(*) AS n FROM sync_accounts GROUP BY image_form"
   # staging: umacapture-share-staging --env staging
   ```

3. **Apply `0011`** ("Checks before a production run", then "Applying a migration"). It runs with
   `PRAGMA legacy_alter_table` on, so that the rename does not check the usage triggers of
   `0003_sync.sql` while the old table is gone; the staging apply is the first run of that pragma on
   D1 itself (the local D1 of the tests allows it). Then read the forms again and see the same counts,
   and confirm that this prints `'jpeg'`, `sync_accounts` alone, and the three usage triggers:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT dflt_value AS v FROM pragma_table_info('sync_accounts') WHERE name = 'image_form' UNION ALL SELECT name FROM sqlite_schema WHERE name LIKE 'sync_accounts%' UNION ALL SELECT name FROM sqlite_schema WHERE type = 'trigger' AND name LIKE 'sync_objects_usage_%'"
   # staging: umacapture-share-staging --env staging
   ```

4. **Check.** On staging, log in with an account that has no `sync_accounts` row (opening the sync
   settings makes one, even without turning sync on), open the dialog that turns sync on and see
   "縮小した画像" chosen; an account that had a row keeps its form.

**Once `0011` is applied to a target, do not roll that target's Worker back to a version from before
this release** (the rollback rules under "Restoring a version"): the older Worker answers `"none"` for
an account with no row while the row holds `'jpeg'`, the pair above that must never serve. If such a
Worker has to run, turn sync off first (`SYNC_ENABLED` `"false"`, "Stopping file sync"), so that no
settings are answered while it does. To give new accounts `'none'` again, a new migration remakes the
table the same way; nothing changes it by hand.

### Rolling out the list's visibility

Once, for the release whose Worker serves an account's list only while its sharer has made it public,
with the migration `0012_list_visibility.sql`. It adds `accounts.list_public` (`1` public, `0`
private) with the default `0`, so every account starts private, the accounts that exist when it is
applied included: by the product's decision, a sharer makes a list public, not private.

- **A private list** answers `/u/<id>` with `403` and a page that says only この一覧は非公開です
  (no profile, records, count or report link), and `/u/<id>.json` with a plain-text `403`. Its report
  page `/u/<id>/report` and a report of it (`POST /api/reports`) answer as if there were no list
  (`404`). The pages of its shares (`/r/<id>`) are not affected: they stay public.
- **An account being deleted** has no list from the start of its deletion: `/u/<id>`, its JSON and
  its report page answer `404`, as once the deletion has completed. Its shares' pages answer until the
  deletion removes them, as before.
- **The switch.** `GET /api/me` carries `list_public` (a boolean). `PUT /api/me/list` `{public}` sets
  it and answers `200` `{public}`. It takes no `previous` (the last write wins) and counts against no
  daily text limit. A `public` that is not a boolean is `400 invalid_payload`; an account being
  deleted is `409 account_deleting`; while `SHARING_ENABLED` is `"false"`, making a private list public
  is `503 sharing_paused`, and making a list private or writing the value it already holds is taken.
  The full contract is on `putListVisibility` (`server/src/account.mjs`).
- **How soon it is seen.** The Worker answers a switch, and the start of a deletion, at once. A list's
  page and JSON, the private `403` included, are cached for a minute (`public, max-age=60`), so a
  reader may see the previous answer for up to a minute after either.

Staging first:

1. **Apply `0012`** ("Checks before a production run", then "Applying a migration"). It adds a column
   and changes none, and the live Worker never names it, so the live Worker runs unchanged on it. Then
   confirm that this prints `0` (it fails if the column is missing):

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT count(*) AS public_lists FROM accounts WHERE list_public <> 0"
   # staging: umacapture-share-staging --env staging
   ```

2. **Deploy** the Worker and the web app together ("Deploying"). From this deployment every list is
   private until its sharer switches it, which the web app can do at once. On staging, open a test
   account's list and see the private page, and its JSON and report page answer `403` and `404`; make
   it public and see the list once a minute has passed; see a share's page open either way; begin the
   deletion of a test account whose list is public and see its list answer `404` within a minute.
3. **Windows release**, after the production deployment ("Ordering against a Windows release").

**Do not roll the Worker back past this release** once it has been deployed to the target. An older
Worker does not read `list_public`: every account's list, those whose sharers never made them public
included, would be public at once, and whatever a reader saw or copied in that time cannot be taken
back. It would also answer `PUT /api/me/list` with the plain-text `404` and `GET /api/me` without
`list_public`. To stop instead, use "Stopping record sharing": a rollback to a version without the
Worker answers every `/u/*` with the static 404. `SHARING_ENABLED` `"false"` does not hide a public
list; it keeps a private one from being made public.

### Rolling out deletion for inactivity

Once, for the release whose Worker deletes an account no device has completed a login to for
`INACTIVE_ACCOUNT_DAYS` (365) days, with the migration `0013_last_login.sql`. It adds
`accounts.last_login_day` (a UTC epoch day) and the partial index `accounts_inactive`, and sets every
existing account's `last_login_day` to the day it is applied. That day is never earlier than an
account's real last login, so the day an account becomes due is never earlier than its real last
login allows; for an account whose last login was on an earlier UTC day, it postpones the deletion day.

- **The Worker** writes `last_login_day` at the claim of a full session and at an account's creation,
  and `GET /api/me` and the claim's `200` carry `last_login_day` and `deletion_day`. The hourly run's
  `inactive` kind marks due accounts as being deleted, and `deletions` deletes them as it deletes one
  its owner began ([`sync-server.md`](sync-server.md#the-hourly-run)). It marks none while
  `SHARING_ENABLED` is `"false"`.
- **Apply and deploy on the same UTC day.** Between the two, the live Worker records no login, and an
  account it creates has a null `last_login_day` and counts from its `created_day`; a login it takes
  on a later day than the apply would leave the stored day earlier than the real one.

Staging first:

1. **Apply `0013`** ("Checks before a production run", then "Applying a migration"). It adds a column
   and an index and changes no other, and the live Worker never names them, so it runs unchanged on
   them. Then confirm that the first prints `0` and that `min`, `max` and `today` of the second are
   one value (it catches a remote `strftime` that evaluates differently). When no account exists,
   `min` and `max` are `NULL`, which is acceptable:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT count(*) AS unset FROM accounts WHERE last_login_day IS NULL"
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT min(last_login_day) AS min, max(last_login_day) AS max, CAST(strftime('%s', 'now') AS INTEGER) / 86400 AS today FROM accounts"
   # staging: umacapture-share-staging --env staging
   ```

2. **Deploy** the Worker and the web app together ("Deploying"), the same UTC day. On staging, log in
   with a test account and see the account tab show its last login; then set that account's
   `last_login_day` 366 days back with `wrangler d1 execute` and see the next hourly run begin its
   deletion (`deleting_since` set). The `deletions` kind of that same run then continues it within the
   run's step and B2 budgets, so a small account can be gone after that one run, and a larger one
   finishes over later runs.
3. **Windows release**, after the production deployment ("Ordering against a Windows release").

**Do not roll the Worker back past this release** while its hourly run marks accounts. An older Worker
records no login, so the logins of the rollback's time are lost and an account could become due
earlier than its real last login allows once this release runs again. To stop the deletions for
inactivity instead, set `SHARING_ENABLED` to `"false"` (it also stops new logins and shares). If the
Worker was rolled back anyway, then on the UTC day of the redeploy, right before it, raise every
account's `last_login_day` to that day, and only then deploy:

```bash
server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
  --command "UPDATE accounts SET last_login_day = MAX(COALESCE(last_login_day, 0), CAST(strftime('%s', 'now') AS INTEGER) / 86400)"
# staging: umacapture-share-staging --env staging
```

### Shared images: declared bytes and what B2 holds

The image limits in `server/src/limits.mjs` (`SHARE_IMAGE_BUDGET`, `SHARE_IMAGE_DAILY_LIMIT`,
`ACCOUNT_SHARE_IMAGE_DAILY_LIMIT`) count what shares **declare** (`records.images_size`, summed in
`totals.image_bytes`, `daily.image_bytes` and `accounts.image_quota_bytes`), once per share, from its
`POST /api/shares`. The total counts it until the share is unshared, its images or itself taken
down, or its account deleted; the daily counts keep what was declared on the day. They
do not count what B2 stores under `s/`, which no D1 row can read, and `SHARE_IMAGE_BUDGET` is not a
bound on it. The two differ in these states, each with what brings them together:

| State | Declared | Stored in B2 | What brings them together |
|---|---|---|---|
| Declared, bundle not put yet | +size | 0 | The sharer sharing again (the app sends the bundle), or unsharing |
| Stored | +size | size | — |
| B2 stored a PUT and answered 429 or 5xx, and the Worker sent it again | +size | up to 3 × size, versions of one key | The `s/` lifecycle rule, a day or two after |
| B2 stored the bundle and the D1 statement after it failed, and the app sent it again | +size | 2 × size | The ledger record is cleared once the share holds the name; the lifecycle rule deletes the extra version |
| Two PUTs of one share at once | +size | 2 × size | As above |
| Unshared, or taken down, and B2's deletion failed; or a PUT arrived after it | 0 | size | The hourly run's `share_writes`, about three hours and a quarter after when nothing is waiting, later when it is |
| Account being deleted | falls as its shares go | the rest | Account deletion's `share_images`; a late PUT, `share_writes` |

So what B2 stores exceeds what is declared by at most two or three bundles of a share, for a day or
two, or for a few hours after a share went. `SELECT image_bytes FROM totals` reads the declared total;
the bucket's own size in the B2 console, which counts `a/` too, is what Backblaze bills and its caps
stop.

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
5. The dashboard's "このサイトについて" card links to `/notice/`, `/terms/`, and `/privacy/`.

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
deploys the same `build/web/` to `https://staging.umacapture.com`, from
`env.staging` of the config the `--sharing` option picks: with sharing on, together with the
Worker (`server/src/`), the staging database, the staging bucket and staging's hourly run
(`45 * * * *`), from `server/wrangler.jsonc`; with sharing off, the assets alone, from
`server/wrangler.assets-only.jsonc`. Both name the same Worker,
`umacapture-web-staging`, so either deployment replaces the other. The invariants are the
production ones: a clean tree, a fresh build from `HEAD` in the same run, and a `deploy.json`
verified through the public URL.

Staging is closed outside a test window: rule G blocks `staging.umacapture.com` from `Es` on, and
the guard keeps `Es` at 0 except while a window is open ("The billing guard"). Every test, a
staging deployment included, goes inside a window:

1. **Read the generation.** `bash tool/cloudflare/guard.sh status` shows staging's `mode` and
   `gen`.
2. **Open a window** with that `gen`:

   ```bash
   GUARD_BY=<who> bash tool/cloudflare/guard.sh open staging --allowance <USD> --for <n>m --gen <gen>
   ```

   `--for` takes `<n>s`, `<n>m` or `<n>h`, at most 8 hours; the allowance is what staging may spend
   inside the window, and the budget of one test is $1. The guard writes `Es` on its next run, about
   a minute later; until then staging is still blocked.
3. **Deploy inside it.** Stage 8 of `deploy_web.sh` checks the deployment through
   `https://staging.umacapture.com`, which a closed staging answers with the zone's block page
   (`403`), so a deployment outside a window fails there after it has deployed. Stage 8 tries again
   every 10 seconds for two minutes, which also covers the first resolution of a new host name: on
   the first deployment to `staging.umacapture.com` the name did not resolve on the first try and did
   on the next.
4. **Close it** with `guard.sh close staging` when the test is done. A window left open ends by
   itself: `Es` never goes past the window's end, so the zone blocks staging from that second on,
   and the guard's next run records staging as `closed`.
5. **After a trip.** A window whose allowance is used up trips staging (`trip`), and staging stays
   blocked until the next `open`; `close` leaves a tripped staging as it is. To test again, read
   `status` and open with the `gen` it shows.

While a window is open, staging answers anyone, not only the test: requests that no one on the test
sent have reached staging's Worker inside windows, and they spend the window's allowance as the
test's own requests do. Keep windows as short as the test.

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
  `https://staging.umacapture.com/api/auth/callback/google`
  (`env.staging.vars.AUTH_REDIRECT_ORIGIN`), so a staging login comes back to staging, where its
  row is.
- **Entrance.** Staging's only entrance is the custom domain `staging.umacapture.com`
  (`env.staging.routes` in both configs), where the zone's WAF applies and the guard's rule blocks
  it outside a test window. Its `workers.dev` URL and preview URLs are off (`workers_dev: false`,
  `preview_urls: false` in both configs), because the WAF does not apply to them.
  It shares the plan's included Worker and D1 usage with production, while its daily limits are counted in its own D1.
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
  Outside a test window rule G already keeps every request from reaching staging's Worker; its
  hourly run still runs.
  `bash tool/cloudflare/deploy_web.sh --target staging --sharing off` takes the Worker off staging
  and keeps its assets: `/r/`, `/u/` and `/api/` get the static 404, the hourly run goes, and
  staging no longer uses the Worker and D1 usage it shares with production. That deployment also
  removes all five of staging's secrets, and a later deployment with sharing on does not bring them
  back: before staging's Worker is used again, put each of them again with
  `wrangler secret put <NAME> --env staging -c server/wrangler.jsonc`. The staging database and
  bucket are left as they are; deleting them is a separate step. Every module publish still writes its name tables to the staging database,
  sharing or not, so deleting it stops every publish before the pointer changes, for as long as
  `publish_modules.sh` names staging among its targets.

## The billing guard

The billing guard stops the account's Workers and D1 charges with no one acting. Its Worker,
`umacapture-guard` (`server/guard/`, configured by `server/wrangler.guard.jsonc`), runs every minute
from its Cron trigger, measures the account's usage and keeps one WAF custom rule of the
`umacapture.com` zone, **rule G**, open only as far as it has proven that usage complete and within
budget. Rule G is a block rule whose expression carries the times it blocks from; the guard moves
them forward while it may, and when it stops, the times pass and the zone closes by itself. A guard
that cannot read Analytics, cannot reach the API, has lost its token or is gone therefore closes
production about 20 minutes (`D_S`) after the last minute it proved.

### What it reads

- **Usage, every minute.** One GraphQL Analytics query a dataset for the whole account: Workers
  invocations by minute and script (requests, CPU time) and D1 by minute and database (rows read,
  rows written). The guard's own runs are its control events: each run is one invocation of its
  script and writes `PROBE_ROWS` rows into its own D1, so a minute for which Analytics returns all of
  the guard's own events is a minute Analytics has counted. The latest minute proven that way is
  `t_p`; the guard adds the usage of the minutes before it to its ledger, in its D1.
- **Spend.** The ledger's usage at list prices (`PRICE_MICROS` in `server/guard/src/config.mjs`),
  with nothing taken off for what the plan includes, so it grows from the first request even while
  the bill is $0. `umacapture-web-staging` and its D1 are staging; every other script and database
  is production, the guard's own included. It is summed over the billing period, which starts on
  the 22nd (UTC), from one day before the period's start.
- **The bill, once a day** (`BILL_STEP_S`): the Billable Usage API, compared with the ledger (below).

### What rule G closes, and when

Rule G carries three times (`server/guard/src/lease.mjs`). Each blocks from that time on:

| Time | Blocks |
|---|---|
| `Ep` | Every host but `data.umacapture.com`: production, staging and any other host of the zone |
| `Es` | Every host but `umacapture.com` and `data.umacapture.com`: staging and any other host |
| `Ea` | `/r/`, `/u/` and `/api/` on `umacapture.com` (stage A) |

`data.umacapture.com` is never blocked: it serves static assets only, so no request there runs a
Worker.

- **Production** (`Ep`) is moved to `t_p` + 20 minutes (`D_S`) by every run that measured and found
  production's spend under its limit, and never past production's `open_until_s` (billing
  reconciliation, below).
- **Stage A** (`Ea`) latches when production's spend reaches 80% of its limit (`warn_permille`):
  `/r/`, `/u/` and `/api/` close — the record and list pages and every API: logins, sharing, link
  imports, sync and reports — while the web app's own pages go on loading.
- **The budget.** At its limit an environment is `tripped`; for production `Ep` becomes 0 and the
  whole host closes. Production's limit each billing period is its base: $10 as the guard's first
  migration sets it, changed with `limit production --base`. The guard never takes an environment
  out of `tripped`; only `open` does.
- **Staging** (`Es`) is closed outside a test window. `open staging` opens one with its own
  allowance, for at most 8 hours; staging closes at the window's end, and trips at the allowance.
- **When the guard cannot measure** — Analytics does not answer or leaves out some of the guard's
  own events, the ledger cannot move on — it extends nothing, and the times already written run
  out. Not measuring changes no state: production opens again by itself on the first run that
  measures. Not measuring is not notified in itself; production closing because of it is
  (`lease_expired`, "Notifications").
- **A new billing period** sets the limit back to the base. It does not clear `tripped` or stage A.

### The CPU limit per invocation

`limits.cpu_ms` caps the CPU time of every invocation of a Worker, its Cron runs included: 200 ms
for `umacapture-web` and `umacapture-web-staging` (`server/wrangler.jsonc`, which `env.staging`
inherits), and 500 ms for the guard (`server/wrangler.guard.jsonc`). The assets-only config runs no
Worker and takes none.

- **Why.** Rule G closes production about 20 minutes (`D_S`) after the last minute the guard proved,
  so what a flood of requests is billed in that time grows with the CPU time each request may take,
  and the budget does not bound it. 200 ms is about three times the heaviest invocation measured on
  production (70.4 ms). The guard's limit is far above its heaviest run measured (61.4 ms): a run
  that is cut off proves nothing, and without proof production closes.
- **When it is exceeded**, the platform stops the invocation: the client gets error `1102`
  (`Worker exceeded resource limits`), and Workers Analytics counts the invocation with the status
  `exceededResources`. A guard run that is stopped may end before it writes rule G; while runs keep
  being stopped, production closes as when the guard cannot measure.
- **Before changing it**, compare it with the heaviest invocation measured (Workers Analytics, CPU
  time by script), and work out again what a flood can be billed between the last proven minute and
  rule G closing: that amount, which no budget bounds, grows with the limit. A value takes effect
  with the next deployment of its Worker.

### Rule G is written by the guard alone

- The guard knows its rule by the description, which starts with `umacapture-guard lease`. It
  writes no rule until the operator arms it (`guard.sh arm`). From then on it creates the rule, first
  in the zone's custom rules, when there is none, and rewrites it when its times move or its form was
  changed (not first, disabled, not a block, or an expression the guard did not write).
- It never deletes the rule, and never creates or replaces the custom-rules entry point: a `PUT`
  would replace every rule of the phase. The entry point has to exist before `arm`; without it the
  guard writes nothing and sends `entrypoint_missing`.
- **Do not edit, disable, move or delete rule G, and do not give another rule a description that
  starts with `umacapture-guard lease`.** A changed rule G is rewritten (`rule_tampered`), and a
  deleted one is created again. With two such rules the guard writes neither, so both run out and
  the zone closes (`rule_ambiguous`) until the extra one is deleted.

### Billing reconciliation

Rule G's times stand on Analytics; billing reconciliation checks Analytics against the bill. Once a
day the guard reads the Billable Usage API (`GUARD_BILL_TOKEN`) and compares it with its ledger, one
UTC day and one metric at a time: requests, CPU milliseconds, D1 rows read and rows written, each
within 10% of the ledger plus $0.01 a day (`BILL_TAU`, `BILL_A_MICROS`).

- A day passes only when the bill also holds a later day of the same metric. A day's rows arrive
  some hours after it ends, so a try normally passes the day before yesterday.
- Each day that passes moves the reach (`guard_bill.to_s`) past it, and production's
  `open_until_s` to the end of that day plus `T_R`, 7 days. Production's times in rule G never go
  past `open_until_s`.
- A day that disagrees (`bill_mismatch`), or for which the bill or the ledger has nothing, stops the
  walk; no day is skipped. A bill that cannot be read (`bill_unreadable`) or that holds a kind of row
  the guard does not know (`bill_unmapped`, `BILL_CLASS` in `server/guard/src/config.mjs`: a new
  way of being billed outside the ledger) stops it too. R2's operations are let through while a
  billing period's total stays within what the plan includes, which bills nothing.
- If reconciliation stays stopped, production closes `T_R` after the end of the last day that
  matched; `lease_closing_soon` is sent 48 hours (`RENEW_WARN_S`) before. Should reconciliation
  catch up afterwards, production opens again by itself.
- `status` shows the reach (`bill.to_s`) and the last try (`last_try_s`, `last_verdict`,
  `last_day`). `last_verdict` `no_row` is the normal state of most days (the next day's rows have not
  arrived yet); a reach that has not moved over two tries or more is the sign that reconciliation
  has stopped.

### Notifications

Each notification is one Sentry event in the app's project, through the DSN that
`server/wrangler.guard.jsonc` carries as `GUARD_SENTRY_DSN` (the one `REPORT_SENTRY_DSN` names):
environment `guard`, level `warning`, message `guard: <event>`, tag `event`, fingerprint
`["guard", <event>]`, or `["guard", <event>, <env>]` for an event about one environment (whose
`extra.env` names it: `trip`, `stage_a`, `close_unapplied`, and the `rules_unreadable` and
`patch_failed` of a closing), and only aggregate values (days, metrics, quantities, statuses,
times), never a row of an answer.

Most notifications are lasting conditions. Each holds a row in the guard's D1 (`guard_alerts`,
which `status` shows as `alerts`, with the `since_s` it started at) for as long as it holds. A sent
condition is sent once, when it starts, and its row is written only once Sentry took the event; a
send that fails is tried again by the next run, so an event can arrive twice. When the condition
ends its row goes, and no notification says so. A condition recorded only holds its row the same
way and is sent to no one (below). `probe_lost` and `bill_mismatch` are one-off events and hold no
row.

In Sentry, create one issue alert rule on the app's project: environment `guard`; when a new issue
is created, or an issue changes state from resolved to unresolved; then notify the operator. Each
event name, per environment where it has one, is one issue, so resolve it once handled, or the next
occurrence does not notify. Staging's `trip` and production's are separate issues, so a staging
test's trip left unresolved does not silence production's. `rules_unreadable` makes three issues:
one with no environment (rule G unreadable for long), and one for each environment (a closing the
guard could not confirm).

| Event | What happened | What to do |
|---|---|---|
| `trip` | An environment reached its limit and closed (production: the whole host) | Find what spent it, then `open` (below) |
| `stage_a` | Production reached 80% of its limit: `/r/`, `/u/` and `/api/` are closed | Find what spent it, then `close production` and `open production` |
| `lease_expired` | Production is open, but the `Ep` of rule G ran out, so the whole host was closed: the guard did not extend it in time | Below |
| `close_unapplied` | An environment is to be closed (a trip, `close`, the end of staging's window, production's stage A), and rule G still lets it through | Below |
| `rules_unreadable`, no environment | The guard has not been able to read rule G for 21 minutes | Below |
| `rules_unreadable`, `patch_failed`, per environment | Reading rule G, or the `PATCH` that writes it, failed while an environment is to be closed and the guard has not yet seen rule G carry that closing | Below |
| `probe_lost` | Analytics never returned some of the guard's own events, an hour on | Nothing for one; many mean Analytics is losing events |
| `probe_rows_mismatch` | A run's own D1 write did not write `PROBE_ROWS` rows; the guard extends nothing | Find out how D1 counts that write now |
| `ledger_stalled` | A dataset's ledger cannot move on: no run of the guard is recorded past it | Find out why the guard did not run, then `ledger-bridge` |
| `ledger_undercount` | The hourly re-read found more usage than the ledger held, and raised the ledger | Nothing |
| `unknown_script` | A Worker the guard does not know (`KNOWN_SCRIPTS`) ran in the account; it counts as production | Decide whether it should exist |
| `entrypoint_missing`, `rule_missing`, `rule_ambiguous`, `rule_tampered` | The custom-rules entry point is missing, or rule G is missing, doubled or not as the guard wrote it | `rule_missing` comes once right after `arm`, until the rule appears. Otherwise read `status` (`last_patch_error`) and the zone's custom rules |
| `lease_closing_soon` | Production's `open_until_s` is less than 48 hours away: reconciliation has not moved | Read `status` (`bill`) |
| `bill_unreadable`, `bill_unmapped`, `bill_mismatch` | The bill could not be read, holds a kind of row the guard does not know, or disagrees with the ledger on a day | Find the cause; `recon-accept` only after |

Every notification below is judged only once the guard is armed, except `rules_unreadable` with no
environment. 21 minutes is `D_S` + `WRITE_MARGIN_S` (1,260 seconds), the furthest ahead the guard
ever writes a time into rule G. It is the length of the unreadable stretch, counted from the
`since_s` of the `rules_unreadable` row, from which a run may send; it is not a delivery time. The
notification goes out on the first run at or after that point that gets as far as judging it, so a
429 backoff, runs that do not happen (a guard that fails itself) and Sentry not taking the event
each push it later.

#### `lease_expired`

- **What happened.** Production's `mode` is `open`, yet the `Ep` rule G holds, or held since
  production was last opened, has passed: every host but `data.umacapture.com` was blocked. Nothing
  changed production's state; the guard did not move `Ep` on in time. A tripped or closed
  production, and staging, never send it. `extra.basis` says how the guard knows: `after_run`, the
  `Ep` rule G is left holding after the run has passed; `before_write`, the run extended `Ep` again,
  but rule G had held an `Ep` that passed after production was last opened (`opened_at_s`);
  `inferred`, the unreadable stretch has reached 21 minutes and rule G was last seen as the guard
  writes it (the protecting form, recorded as `rule_seen_since_s`), so every time it held has
  passed. Without that record — rule G never seen in the protecting form since it was last seen
  otherwise — nothing is inferred: only `rules_unreadable` with no environment is sent, and whether
  production closed is not asserted.
- **What to do.** Read the cause off `extra` and `status`: `blind_since_s` set, the guard could not
  measure; `rules_unreadable_since_s` set, it could not read rule G (its token, the API);
  `open_until_s` in the past, billing reconciliation stopped ("Billing reconciliation"); none of
  them, a run that measured but extended nothing (gaps, `ledger_stalled`), a write that failed
  (`last_patch_error`) or a 429 backoff (`api_backoff_until_s`).
- **Reopens** by itself, on the first run that measures and writes `Ep` again, unless
  `open_until_s` has passed. No notification says it reopened; `status` shows it.
- **Resolve** once rule G lets production through again — read it back, or see the `lease_expired`
  row gone from `status` after a later run; production's `mode` stays `open` throughout, so it says
  nothing here. Left unresolved, the next such closure notifies no one.

#### `close_unapplied`

- **What happened.** An environment is to be closed — production `tripped` or `closed`, or with
  stage A latched; staging not `open` — and the times rule G is left holding after the run still let
  it through (production `Ep`, or `Ea` at stage A; staging `Es`). Sent by the first run that finds
  it, whatever kept the closing from being written: a failed `PATCH`, a run too late to write. Not
  judged while the guard does not know what rule G holds (unreadable, not as the guard writes it,
  none or two); the `rules_unreadable`, `patch_failed` and `rule_*` notifications cover that.
- **What to do.** Read `status` (`last_patch_error`) and rule G in the zone's custom rules. A
  closing `PATCH` whose answer was lost sends it too, although the closing took.
- **Closes** by itself: every run tries to write the closing again. While no write succeeds, the
  times the guard last wrote run out within 21 minutes of that write, and production then closes
  whole.
- **Resolve** once `status` shows `close_applied:<env>` instead (`close_applied:production:stage_a`
  for production's stage A).

#### `rules_unreadable`, no environment

- **What happened.** The `GET` of rule G has failed (no answer, an error, an answer of another
  shape) since the `since_s` of the `rules_unreadable` row, and a run at or after 21 minutes from
  then found it still unreadable: the guard has then neither read nor written rule G for longer
  than any time it writes lasts. When production is open and rule G was last seen in the protecting
  form (`rule_seen_since_s`), `lease_expired` (`inferred`) comes with it; otherwise this is the only
  notification, and it says the guard lost control of rule G, not that production closed.
- **What to do.** Check the guard's token ("The guard's token") and Cloudflare's API.
- **Ends** by itself, on the first run that reads rule G; the guard writes rule G again from then on
  as far as it has measured.
- **Resolve** once `status` no longer shows `rules_unreadable:lasting`. Left unresolved, the next
  long outage notifies no one.

#### `rules_unreadable` and `patch_failed`, per environment

- **What happened.** An environment is to be closed, the guard has not yet seen rule G carry that
  closing (no `close_applied:<env>` row, or rule G as read still lets the environment through), and
  the `GET` of rule G could not be read (`rules_unreadable`) or the `PATCH` writing it failed
  (`patch_failed`, `extra.status` its HTTP status). Sent on the first such run, without waiting 21
  minutes: right after a trip or a `close` the closing is what is at stake. `patch_failed` comes
  with `close_unapplied` of the same environment, or, when rule G was not as the guard writes it,
  with `rule_tampered`.
- **What to do.** As for `close_unapplied`.
- **Ends** by itself: `rules_unreadable` on the first run that reads rule G, `patch_failed` on the
  first run that finds rule G carrying the closing or the environment open again.
- **Resolve** once `status` shows `close_applied:<env>` (`close_applied:production:stage_a` for
  production's stage A), or the environment is open again.
- **Sent although rule G already closes the environment** whenever the record of the closing now
  intended is missing: the first unreadable `GET` or failed `PATCH` before a run sees rule G carry
  it then sends. That happens when no `close_applied:staging` row exists yet (right after the
  first deploy of a guard that writes it, and after a test window a run saw open, which deletes the
  row); and when production moves from stage A to a `close` or a trip, which deletes
  `close_applied:production:stage_a` and starts without `close_applied:production`. The rows are in
  D1, so a later deploy keeps them, and a test window no run saw open leaves staging's row in place.

#### Recorded only

These hold a row while they hold, and are sent to no one: what each one costs is reported by the
notification it leads to.

| Row | Holds while | Reported through |
|---|---|---|
| `blind` | The guard cannot measure (`since_s`: since when). A stretch of about two minutes around 00:00 UTC, while Analytics lags, has been seen every day | `lease_expired` |
| `rules_unreadable` | The `GET` of rule G cannot be read | `rules_unreadable` (no environment) at 21 minutes, `rules_unreadable` of an environment being closed, `lease_expired` |
| `patch_failed` | A `PATCH` of rule G failed, until a run finds rule G holding what the guard wants | `close_unapplied`, `patch_failed` of an environment being closed, `lease_expired` |
| `close_applied:<env>` | The environment is closed or tripped (staging: not `open`) and the guard has seen rule G carry that closing. Once armed, `close_applied:staging` is normally there while staging is closed | The per-environment `rules_unreadable` and `patch_failed` are not sent while it is there |
| `close_applied:production:stage_a` | Production is open with stage A latched and the guard has seen rule G carry stage A (`Ep` or `Ea` passed). Deleted when production leaves stage A, including to a `close` or a trip | Production's `rules_unreadable` and `patch_failed` are not sent during stage A while it is there |

A short outage of the API while nothing is waiting to be closed is therefore no notification.

#### What the notifications do not catch

- During a slow recovery, a closure of a few seconds to a few tens of seconds inside one run may not
  be notified: the run judges every time against the second it started, so an `Ep` that passed
  while the run waited, and that the same run extended, shows no closure.
- During a 429 backoff (`api_backoff_until_s`) only `trip`, `stage_a` and `lease_closing_soon` are
  judged; every other notification waits for the backoff to end, and `Retry-After` has no upper
  bound.
- A closure while rule G cannot be read is notified only on the first judging run after the
  unreadable stretch reaches 1,260 seconds, so up to 1,260 seconds late and later still under a
  backoff, without runs or without Sentry taking it; and as a closure (`lease_expired`, `inferred`)
  only when rule G was last seen in the protecting form, otherwise only as `rules_unreadable` with no
  environment.
- A closing `PATCH` whose answer was lost counts as failed: `close_unapplied` (with `patch_failed`
  of the environment) is sent although the environment closed.
- An operator's command that overlaps a run, for the seconds to tens of seconds the run takes, can
  make it send a notification that does not hold.
- A closure that ends while Sentry rejects every send about it is never notified: a failed send
  writes nothing, and once the condition is over nothing is left to send.
- A guard that fails itself notifies nothing. Production still closes by itself, about 20 minutes
  (`D_S`) after the last minute the guard proved.

`blind_start`, `blind_end`, and `patch_failed` with no environment are not sent by the guard.
Their issues in Sentry come from an earlier deployment. A run that the earlier version started
before the deploy can still send them after it, with a timestamp after the deploy (the event is
stamped when sent), so wait until every such run has ended — past the longest a run takes after the
deploy — and resolve them then. Only an event well after that is a sign that a version sending them
is still running. Resolve the `rules_unreadable` issue with no environment then too, so that the
next lasting outage notifies.

### The operator's commands

`tool/cloudflare/guard.sh` reads and writes the guard's D1 (`umacapture-guard`) through the pinned
wrangler, with the deploy token of `tool/cloudflare/.env`; the guard's own token is not used. Run it
from Git Bash at the repository root:

```bash
GUARD_BY=<who> bash tool/cloudflare/guard.sh <command> [...] [--yes]
```

Every command but `status` shows the state first and asks for `yes` (`--yes` answers it). Each write
is a compare-and-set on the values it was planned on, so a command another writer beat writes
nothing, and a command repeated after it took effect writes nothing more. Exit status: `0` written
or nothing to do, `1` refused or failed, `3` another writer changed the state first (read `status`
and repeat).

| Command | When |
|---|---|
| `status` | Before every other command, and to see why something closed. Writes nothing. Shows each environment (`mode`, `gen`, `stage_a`, limits, `open_until_s`, the trip), the guard's health (`last_measurable_s`, `arm_requested_s`, `rule_seen_since_s`, `last_patch_error`), the ledger, gaps and holes, billing reconciliation (`bill`) and `alerts`, the rows of the notifications that hold now, sent and recorded only ("Notifications") |
| `arm` | Once, at rollout: the guard creates rule G and from then on keeps it. Refused unless the guard measured within the last 10 minutes, production's `open_until_s` is at least 48 hours away, and billing reconciliation has passed a day of its own after the last `recon-accept` |
| `open production --allowance <USD> --gen <n>` | After a trip, or after `close production` to clear stage A: on its first run that measures, the guard sets the limit for the rest of the billing period to what is spent plus the allowance. Takes no `--for`: the guard extends production |
| `open staging --allowance <USD> --for <n>s\|<n>m\|<n>h --gen <n>` | A test window of at most 8 hours, with its own allowance |
| `close production\|staging` | Closes the environment at once. Closing production closes the whole host |
| `limit production --base <USD>` | Changes production's limit from the next billing period |
| `ledger-bridge` | After `ledger_stalled`, once the cause is known: accepts the stretch the ledger cannot cover and moves the ledger on. Days that touch the stretch are not reconciled, so reconciliation stops at the first of them until a `recon-accept` |
| `recon-accept production --through <YYYY-MM-DD>` | At rollout (the ledger's first day cannot be reconciled), and after investigating a reconciliation that stopped: accepts every UTC day up to that one and moves production's `open_until_s` to its end plus `T_R`. Refused for a day that has not ended or lies before the reach |

- **`--gen <n>` is required by both `open`s.** It is the environment's `gen` as `status` shows it
  when you decide to open, and the write holds only while `gen` is still that value. Every change to
  the environment moves `gen` on — the open itself, and the guard consuming the allowance, tripping
  or ending the window — so an open repeated after its answer was lost writes nothing more. Read
  `status` again before a new open.
- **`open` is refused while the environment is open**: a second allowance would add to the first.
  To grant a new one, `close` first. Stage A is cleared only by an `open`, so clearing it closes
  production entirely between the `close` and the guard's first run after the `open`.
- **`arm` cannot be taken back**: no command undoes it, and from then on production is open only as
  long as the guard keeps it so. Before it, check what `arm` does not: that the custom-rules entry
  point exists, that the guard has sent no notification other than an `unknown_script` of a known
  cause, and that the zone has no proxied host other than `umacapture.com`, `data.umacapture.com`
  and `staging.umacapture.com` (rule G would block it).
- **`recon-accept` is never run on a schedule.** It accepts days the bill was not checked for; run
  regularly, it would take away what billing reconciliation guards against.

### When something has closed

| What is closed | Seen as | Notification | How it reopens |
|---|---|---|---|
| `umacapture.com`, the whole host, after a trip | Every request is blocked by the zone; the Worker does not run | `trip` | `status`, find the cause, then `open production --allowance <USD> --gen <n>` |
| `/r/`, `/u/`, `/api/` on `umacapture.com` (stage A) | The web app's pages load; record and list pages, logins, sharing, link imports and sync fail | `stage_a` | `close production`, then `open production --allowance <USD> --gen <n>` |
| The whole host, production open but rule G's `Ep` run out: the guard not measuring, not reaching rule G, or extending nothing | As after a trip | `lease_expired`; with `rules_unreadable` when rule G has been unreadable for 21 minutes | By itself on the first run that measures and writes `Ep`; nothing says so |
| The whole host, `open_until_s` passed | As after a trip | `lease_closing_soon` two days before, the `bill_*` that stopped reconciliation, and `lease_expired` | By itself if reconciliation catches up; otherwise find the cause, then `recon-accept` |
| `staging.umacapture.com` | Blocked outside a test window, as designed | `trip` when a window used up its allowance | `open staging` |

The other way round, an environment that is to be closed while rule G still lets it through sends
`close_unapplied` (or, while rule G cannot be read, `rules_unreadable` for that environment).

### The guard's token

The guard holds one user API token (My Profile › API Tokens; the permissions of an account API
token did not take effect for it) with:

- Account › Account Analytics › Read
- Account › Billing › Read
- Zone › Zone WAF › Edit, zone `umacapture.com`

The same value goes into both of the guard's secrets: `GUARD_CF_TOKEN` (Analytics, and reading and
writing rule G) and `GUARD_BILL_TOKEN` (the bill).

```bash
server/node_modules/.bin/wrangler secret put GUARD_CF_TOKEN -c server/wrangler.guard.jsonc
server/node_modules/.bin/wrangler secret put GUARD_BILL_TOKEN -c server/wrangler.guard.jsonc
```

It has no expiry: a token that stops working makes every read fail, which closes production rather
than leaving it open. It is notified as `rules_unreadable` with no environment by the first judging
run once reads have failed for 21 minutes, with `lease_expired` (`inferred`) only when rule G was
last seen in the protecting form; a backoff or Sentry can delay it further. Never give the guard the deploy token (`CLOUDFLARE_API_TOKEN`), which deploys
Workers and edits billing.

### Taking the guard down

Taking the guard down closes the site, and goes in this order:

1. `guard.sh close production` and `guard.sh close staging`.
2. Check in the zone's custom rules that rule G's `Ep` and `Es` are 0 (the guard writes them on its
   next run).
3. Delete the Worker: `server/node_modules/.bin/wrangler delete -c server/wrangler.guard.jsonc`.
4. Delete its token.
5. Delete its D1 database, `umacapture-guard`.

Rule G stays, and keeps every host but `data.umacapture.com` closed. Deleting it puts the site back
with nothing stopping its bill, and is a decision of its own. Rolling back the site's Worker
(`wrangler rollback`) leaves rule G and the guard as they are.

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
from `/site/logo.png`, on the web app's origin (`PUBLIC_ORIGIN`). A font or logo change is
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
  `https://staging.umacapture.com` for **Preview**. Staging answers only inside a test window, so a preview
  deployment renders no image outside one. With the pinned CLI,
  from `og/` and with `VERCEL_TOKEN` exported from `tool/vercel/.env`:

  ```bash
  node_modules/.bin/vercel env add PUBLIC_ORIGIN production --value https://umacapture.com --yes
  node_modules/.bin/vercel env add PUBLIC_ORIGIN preview --value https://staging.umacapture.com --yes
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
- Once a target has the web app of "Rolling out shared images, the link import and reports", or its
  Windows build is released, do not roll that target's Worker back to a version from before it. That
  section says what such a Worker breaks and leaves behind, and how to clean up after one that ran.
  A version deployed with sharing off is not ruled out by this.
- Once a target has `0011_sync_image_form_default.sql`, do not roll its Worker back to a version
  from before "Rolling out the reduced-image default": that Worker shows "画像は送らない" to an account
  whose row then syncs reduced JPEGs. That section says what to do if one has to run. A version
  deployed with sharing off has no Worker and is not ruled out by this.
- Once a target has the Worker of "Rolling out the list's visibility", do not roll its Worker back to
  a version from before it: that Worker does not read `accounts.list_public`, so every account's list
  would be public at once, those never made public included, and what is read in that time cannot be
  taken back. A version deployed with sharing off has no Worker and is not ruled out by this.
- Once a target has the Worker of "Rolling out deletion for inactivity", do not roll its Worker back
  to a version from before it: that Worker records no login, so an account could later become due
  earlier than its real last login allows. That section says what to do before redeploying if one ran.
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

### Handling a report

A report arrives as a Sentry issue `share report` (One-time preparation, step 13), one issue a share,
or `list report`, one issue an account's list. A list is reported as a whole, and there is no takedown
of a list: find the shares the report is about and handle each of them by its share id as below. A
list can be reported only while it is public, but its sharer may make it private afterwards, and its
account may begin its deletion, after which `https://umacapture.com/u/<list_id>` answers that it is
private (`403`) or nothing (`404`). Open that page while it is public; otherwise list the shares in
the target's D1:

```bash
server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
  --command "SELECT id, shared_day FROM records WHERE owner_id = '<list_id>' ORDER BY shared_day DESC"
# staging: umacapture-share-staging --env staging
```

1. Read the issue: `share_id`, the `reason` tag and the reporter's `text`. Open
   `https://umacapture.com/r/<share id>`; for a report about images, the share's images are what
   `GET /api/shares/<share id>` lists and `GET /api/shares/<share id>/images` serves (or import the
   link into the app).
2. Decide: nothing; take down the images only; take down the whole share; clear the sharer's public
   profile (below); or, for many at once, a switch (the table below). A share's tagline has no
   takedown of its own: a tagline that must go goes with its share (`'share'`), and the sharer may
   share the record again without it.
3. To take down, write one order to the target's D1. `scope` is `'images'` to take down the images
   alone (the share stays, and tells no images from then on, as one shared without them) or
   `'share'` to unshare it:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc \
     --command "INSERT INTO share_takedowns (share_id, scope, ordered_at) VALUES ('<share id>', 'share', unixepoch())"
   # staging: umacapture-share-staging --env staging
   ```

   An order is carried out by the next hourly run (`takedowns`, the first of its kinds), with the
   code a sharer's own unshare runs, as the share's owner: the totals, the account's count and the
   declared image bytes are given back, and the bundle's versions are deleted, or recorded in the
   write ledger for `share_writes` when B2 fails. No switch stops it. A second order of the same
   share and scope is refused by the table's key: one is recorded already.
4. **Done** once its row has a `done_at`:

   ```bash
   server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc --json \
     --command "SELECT share_id, scope, ordered_at, done_at FROM share_takedowns WHERE done_at IS NULL"
   # staging: umacapture-share-staging --env staging
   ```

   lists the orders not carried out yet. An order also counts as done when nothing of its scope was
   left (the sharer unshared first). One whose account is being deleted stays not done until the
   deletion has removed the share. From outside: after `'share'`, `/r/<share id>.json` answers `404`
   once the record pages' five-minute cache (`max-age=300`) has passed; after `'images'`,
   `GET /api/shares/<share id>` answers `"images": null` and `GET /api/shares/<share id>/images`
   answers `404`, neither cached.
5. Resolve the issue in Sentry. A later report of the same share reopens it.

The row stays as the record of what was taken down and when. A share taken down whole leaves its
sharer's app to drop its own mark of it at its next list of the account's shares, without saying why,
and nothing keeps the sharer from sharing the same record again under a new id. Copies already
imported into someone's app stay there. An order waits up to an hour, more when orders are waiting
(`SHARE_TAKEDOWNS_PER_RUN` a run): when that is too long, or there are too many reports to judge one
by one, stop with a switch:

| Situation | Means |
|---|---|
| One share | An order above |
| Many images, or more than can be judged | `SHARE_IMAGES_ENABLED` `"false"` (below): no image is taken or served; shares themselves go on |
| Many shares | `SHARING_ENABLED` `"false"` (below): new logins, shares and making a list public stop; existing shares and public lists are still read, and a list can still be made private |
| A flood of reports | Lower `REPORT_DAILY_LIMIT` in `server/src/limits.mjs`, commit, deploy; `0` takes none. Reports are taken while sharing and images are switched off |

#### Clearing a public profile by hand

The account's public profile (trainer name and the game's trainer id) is shown on every page of its
shares and on its list while the list is public, and is not a share, so no takedown order reaches it. When a report is about
the profile (`reason` `personal_info` or `inappropriate` on a share or a list), clear it in the
target's D1 by hand. `<account id>` is the list's id, or for a share the `owner_id` of
`SELECT owner_id FROM records WHERE id = '<share id>'`:

```bash
server/node_modules/.bin/wrangler d1 execute umacapture-share --remote -c server/wrangler.jsonc \
  --command "UPDATE accounts SET trainer_name = NULL, game_trainer_id = NULL WHERE id = '<account id>'"
# staging: umacapture-share-staging --env staging
```

It is cleared at once (the profile is charged against nothing, so nothing is given back), and is gone
from the pages once their caches have passed: a list within a minute, a share's page and its JSON
within five. Nothing keeps the sharer from writing a profile again; nothing records that it was
cleared but this command and the Sentry issue. Resolve the issue as in step 5.

### Stopping record sharing

In this order of preference:

| Means | Effect | Depends on |
|---|---|---|
| **Roll back to the last version without the Worker** (assets only, after `TURNSTILE_SECRET` was put) | `/r/*`, `/u/*` and `/api/*` get the static 404 and run no Worker; logins, sync and account deletion stop with sharing; the assets, the notice included, return to that version's. D1 and B2 keep their data | The token and the pinned wrangler only. Use it first, whatever is broken |
| `SHARING_ENABLED` `"false"`, committed, then `deploy_web.sh` | New logins and shares stop (`503 sharing_paused`), and so do writing new text into a tagline or the public profile and making a private list public; reading (public lists included), unsharing, removing a tagline or the profile, making a list private, and logging out go on, and so does sync for a device already logged in | A clean tree, a build, the Sentry upload (production), a load of the name tables in the target's D1 (read back at stage 3), the pinned wrangler. Not usable while any of them is broken |
| `deploy_web.sh --sharing off` | As the rollback, with the assets of the current `HEAD`; the hourly run goes too | As above, except D1: the name tables are not read. Use it once the version without the Worker is no longer among the last 100 |
| `SHARE_IMAGES_ENABLED` `"false"`, committed, then `deploy_web.sh` | Shared images alone stop: shares declaring images are refused, bundles are neither stored nor served, and the import endpoint tells such shares' images as unavailable, so an import waits rather than saving a record without them. Shares without images, reads, unshares, takedowns and the hourly run's deletion of images go on. D1 and B2 keep their data; turning it back serves every bundle still stored | As `SHARING_ENABLED` |
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
| B2's data caps (One-time preparation, step 10) | Limit what B2 can charge a day for what they cover. What B2 does with a request once a cap is reached is not confirmed; a request it refuses, the Worker answers `502`. They bound the cost, not who syncs | The B2 console only |
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
synced objects or shares whose images are stored, their bucket is not deleted; while `publish_modules.sh` writes name tables to a
D1, deleting it stops every module publish ("Publishing to data.umacapture.com"). `b2_list_file_versions`, under the same authorization
as the lifecycle check (One-time preparation, step 10), lists every version a bucket holds, hidden
ones included. The kept copy of `IDENTITY_HMAC_KEY` goes only with
the accounts it reaches. The billing guard and rule G come down in their own order, which closes the
site ("Taking the guard down").

### Other

| Goal | How |
|---|---|
| Take the site off the domain | Remove the `umacapture.com` custom domain in the dashboard |
