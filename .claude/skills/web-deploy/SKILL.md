---
name: web-deploy
description: >-
  Use when the web app or its Worker is to be deployed to staging or production, when record
  sharing or file sync is to be switched off or on, when a D1 migration is to be applied, when a
  web deployment is to be rolled back, or when someone asks how a web deployment is done or why
  one failed. Also use before publishing to data.umacapture.com or deploying the OG image function.
---

# Deploying the web app

`docs/web-deploy.md` is the source of truth for every command, option, config value and expected
answer. This skill holds what that document leaves to the reader: which of its sections a goal
needs, the order to take them in, which steps cannot be taken back, and where to stop and check.
It names the document's headings and copies nothing out of them; a copied command goes stale the
first time the script changes. **If a step is missing from the document, add it there, not here.**

## 1. Pick the run from the goal

| Goal | Section of `docs/web-deploy.md` |
| --- | --- |
| Ship a commit to staging or production | "Deploying" (`--target`, `--sharing`) |
| A Worker change that needs a new table or column | "Applying a migration", then "Deploying" |
| Stop or resume logins and sharing | "Stopping record sharing" |
| Stop or resume file sync | "Stopping file sync" |
| Go back to an earlier version | "The version record", then "Restoring a version" |
| Take the Worker off staging | "Staging" (Stopping staging) |
| New recognizer modules or news | "Publishing to data.umacapture.com". It also appends the names to both D1s; no web deployment follows ("Deploying", the paragraph on when a redeploy is needed) |
| A target whose live Worker still bundles its name tables | "Switching the name tables to D1", before its next deployment |
| OG image function | "OGP image function (Vercel)" |
| A first deployment to a new environment | "One-time preparation" before anything else |

A var (`SHARING_ENABLED`, `SYNC_ENABLED`, `OG_IMAGE_MODE`, …) changes only by a commit and a run of
`deploy_web.sh`. There is no shortcut through a bare `wrangler deploy`, `--var` or the dashboard
("Deploying").

## 2. What cannot be taken back

Know these before starting, and get the decision for each one before the step that does it:

- **Every production run sends the source maps to Sentry**, `--dry-run` included. There is no
  option to skip it, and no way to recall them ("Stopping record sharing", the paragraph after the
  table). A staging run sends nothing.
- **A migration.** Nothing rolls D1 back — not `wrangler rollback`, not a redeploy. A migration that
  drops a table loses its rows ("Applying a migration"; the first production deployment's
  "Count the old shares" item is the shape of the gate to use).
- **`wrangler secret put`** deploys a new version at once ("One-time preparation", step 6).
- **A changed custom domain** may override a DNS record without asking ("Changing the custom
  domain: only from a terminal").
- **The first write to a production bucket**, and anything a user then stores there.
- **A module publish's names.** Every publish writes the names its archive adds to the D1 of
  production and of staging, and nothing removes or changes them ("Publishing to
  data.umacapture.com", Name tables; "A name in D1 is final").

A rollback restores the Worker only. It does not undo any of the above.

## 3. The order

1. **Commit everything.** The script stops on a dirty tree — untracked files included — and deploys
   only what `HEAD` builds. Work notes belong under a gitignored directory.
2. **Staging first** when the change touches `server/`, `web/`, the wasm core, or the app's
   sharing or sync: deploy the same commit there and exercise it ("Staging"). Staging cannot show
   the zone WAF, the real Turnstile keys, the Sentry upload or the custom domain; those are checked
   in production only (step 7 below).
3. **Push the commit** before a production run. It is recommended, not required: the script does
   not look at the remote ("Deploying", the paragraph on the remote).
4. **Run the checks** ("Checks before a production run") in the shell that will run the script.
   Do not use a production `--dry-run` as the check: it sends to Sentry.
5. **Migration, if the Worker needs one** ("Applying a migration"). Read what it drops first, and
   stop if it would drop rows that matter. Apply it only after step 4 passed, and deploy straight
   after it: the live Worker is broken from the apply until the new one is up.
6. **Deploy** ("Deploying"). Without a terminal, `--yes` is required; with one, the script asks.
   When the OG image function changes too, deploy it after `deploy_web.sh` on the same target: it
   reads its fonts and logo from the web app's origin ("OGP image function (Vercel)").
7. **Check what the script does not.** Stage 8 verifies `deploy.json`, COOP/COEP, the hidden source
   map and which side answers 404. After that:
   - write down the version id with the `git_sha` ("The version record"); a rollback needs them;
   - with sharing on in production, the Turnstile check ("After a deployment with sharing on");
   - after a first deployment, the browser checks ("After the first deployment") and the
     dashboard checks under "Entrance list";
   - after a first deployment or a change to the zone's rule, the rate limiting check ("One-time
     preparation", step 12);
   - whatever the goal itself changed: a var flip shows in the endpoint it gates (the `503` bodies
     under "Stopping record sharing" and "Stopping file sync").

Stop and report, rather than retry, when any check fails after step 5: the state is now half new.

## 4. Before rolling back

"Restoring a version" lists the conditions; check every one of them against the version you return
to:

- if the version has the Worker, its `deploy.json` carries `"name_tables": "d1"`; publishing
  module sets since then is no obstacle;
- no migration applied since that version, if it has the Worker; a version without the Worker reads
  no schema, and returning to it is the first means of stopping sharing ("Stopping record sharing");
- the version is still among those that can be rolled back to (the limit is in "Restoring a
  version").

When a condition fails, the way back is a new deployment, not a rollback. Always pass the version id.

## 5. Gotchas

- **The confirmation reads standard input.** In a background job or an agent's shell, a run without
  the option that answers it stops at stage 6 with nothing uploaded to Cloudflare ("Deploying", the
  paragraph on the options) — but a production run sent the source maps to Sentry at stage 2,
  before that stop. Without a terminal, wrangler does the opposite:
  `wrangler rollback` and `d1 migrations apply` answer their own confirmations with yes, and
  `secret put` reads the value from standard input ("Restoring a version", "Applying a migration",
  "One-time preparation" step 6).
- **A stop at stage 2 or later costs a rebuild.** Every run rebuilds `build/web/` from scratch;
  nothing a stopped run built is reused. Missing tools and tokens are cheapest to find in step 4.
- **A run with sharing off removes the hourly run** as well as the Worker ("Deploying", the options;
  "Stopping file sync" explains
  what a long stop costs: hidden images are lost after the window it names).
- **Staging and production have their own D1, with its own name tables, and their own bucket.** A
  check on one says nothing about the other ("Deploying", Name tables). A module publish writes the
  names to both D1s, so the staging database is needed even while staging runs without the Worker
  ("Staging", Stopping staging).
- **A sharing-on run stops at stage 3 when the target's D1 holds no name tables.** Nothing is
  deployed; the way forward is "Switching the name tables to D1", not a retry.
- **The first production deployment** has its own list under "Deploying"; read it whenever
  production has not yet run the current schema.
