# File sync: the server

What the Worker's file sync is made of, for whoever deploys it, configures its bucket, or changes its
code: the configuration it reads, what it assumes of the B2 bucket, its endpoints and D1 schema, every
limit it enforces, and the invariants its hides and shows keep. What a client must send and may expect
back is [`sync-protocol.md`](sync-protocol.md); this document does not repeat it, and points there for
what a client sees. It states facts, not operating procedures: setting up the bucket, the key and the
secrets, deploying, and stopping sync are in [`web-deploy.md`](web-deploy.md).

## Configuration

`server/wrangler.jsonc` sets, for production and for `env.staging` separately:

| Name | Kind | Production | Staging | Read by |
|---|---|---|---|---|
| `SYNC_ENABLED` | var | `"true"` | `"true"` | `syncEnabled` (`server/src/sync.mjs`) |
| `B2_ENDPOINT` | var | `s3.us-west-004.backblazeb2.com` | the same | `Bucket` (`server/src/b2.mjs`) |
| `B2_REGION` | var | `us-west-004` | the same | `Bucket` |
| `B2_BUCKET` | var | `umacapture-sync` | `umacapture-sync-staging` | `Bucket` |
| `B2_KEY_ID`, `B2_APPLICATION_KEY` | secret | the production bucket's key | the staging bucket's key | `Bucket` |
| `triggers.crons` | trigger | `30 * * * *` | `45 * * * *` | the hourly run (`server/src/scheduled.mjs`) |
| `DB` | D1 binding | `umacapture-share` | `umacapture-share-staging` | everything; sync shares the database with sharing and logins |

- **`SYNC_ENABLED`** is `"true"` or `"false"`; any other value throws, as a configuration error.
  `"false"` answers every endpoint under `/api/sync/` `503 sync_paused` before it reads anything, and
  the hourly run does nothing. Sharing, logins and account deletion go on.
- **`server/wrangler.assets-only.jsonc`** has no script and sets `triggers.crons` to `[]`, so a deploy
  of it removes the hourly run that a deploy of `wrangler.jsonc` set.

## The B2 bucket

- **Keys.** An account's object is stored at `a/<account id>/<name>` (`objectKey`), `<name>` the
  SHA-256 of its bytes as 64 lowercase hex digits. Two accounts storing the same bytes hold two
  objects, and every request names keys under its own account's prefix `a/<account id>/` only.
- **Signing.** Every request is signed with AWS Signature Version 4. A PUT signs the object's name as
  `x-amz-content-sha256` and never `UNSIGNED-PAYLOAD`, so B2 checks the bytes it receives against
  the name and stores nothing on a mismatch.
- **A name that does not match its bytes.** The Worker hashes bodies, parts and roots itself (it
  parses them anyway) and refuses a mismatch with `400 invalid_payload` before B2 is asked. An image
  it reads whole and passes to B2 unhashed; B2 refuses a mismatch with 403, the same answer as a wrong
  key, and the Worker answers `502 storage_refused`. Any other answer B2 gives that the Worker cannot
  act on, after the retries below, is `502 storage_unavailable`.
- **Retries.** A PUT or GET that B2 answers 429 or 5xx (`503 SlowDown` when it is busy, which
  Backblaze's documentation asks a client to retry with exponential backoff) is sent again, up to
  `B2_ATTEMPTS` (3) times in all (`#ask` in `server/src/b2.mjs`). Both are idempotent: a PUT stores the
  same bytes under the same name. Before a retry the Worker waits what B2's `Retry-After` asks, or
  without one `B2_RETRY_FIRST_WAIT` (1 s) doubled per attempt before (1 s, then 2 s); a `Retry-After`
  longer than `B2_RETRY_WAIT_MAX` (4 s) ends the attempts there. A request therefore waits for B2 at
  most 8 s on top of its attempts. A 403 or any other 4xx is not retried. The ten PUTs of a body
  bundle run concurrently and retry independently; one that runs out of attempts still fails the
  whole request `502 storage_unavailable`. DeleteObjects and ListObjectVersions are sent once: every
  endpoint counts them exactly before it changes anything, a hide (a DeleteObjects naming no version)
  is not idempotent, and what a failed one leaves is a row state the account's next write or the
  hourly run takes on.
- **Logging.** Every answer B2 fails (anything but 200, and a GET's 404) writes one line to the
  Worker's log: the operation, the status, B2's error code and `Retry-After` when present, and the
  attempt, never the key, which names the account and the object. Workers Logs is off
  (`observability` in `wrangler.jsonc`), so the lines are seen only through `wrangler tail`.
- **Versions and markers.** To hide an object the Worker adds a delete marker over it (a
  `DeleteObjects` that names no version); to show it again it deletes that marker by its version id.
  Both go up to 1,000 keys to a `DeleteObjects` (`DELETE_OBJECTS_MAX`). It lists an account's versions
  with `ListObjectVersions` under the account's prefix, a page of up to 1,000 versions per request.
  Account deletion deletes every version and marker under the prefix by version id.
- **The lifecycle rule** is set on the bucket by the operator, not by the Worker:
  `daysFromHidingToDeleting` is 6 (`B2_DAYS_FROM_HIDING_TO_DELETING`). The server counts on it to
  delete what it hid, and on nothing else deleting or hiding what it stored; it never reads the rule.
- **Requests per invocation.** One request or one hourly run sends at most
  `B2_REQUESTS_PER_INVOCATION` (50) requests to B2; the `Bucket` of the invocation throws on the
  next, as the platform would. Every endpoint counts the requests its hides and shows take before it
  changes anything, and counts a PUT or GET as its `B2_ATTEMPTS`: a body bundle takes 30 at most.

## Endpoints

Every sync endpoint is in `ROUTES` (`server/src/routes.mjs`) under the one prefix `/api/sync/`, so a
rule matching that prefix covers all of them. The handlers are in `server/src/sync.mjs` and
`server/src/sync_list.mjs`; [`sync-protocol.md`](sync-protocol.md) states what each takes and
answers.

| Method | Path | Route | Handler |
|---|---|---|---|
| GET | `/api/sync/generation` | `syncGeneration` | `getGeneration` |
| GET | `/api/sync/settings` | `syncGetSettings` | `getSettings` |
| PUT | `/api/sync/settings` | `syncPutSettings` | `putSettings` |
| POST | `/api/sync/bodies` | `syncPutBodies` | `putBodies` |
| POST | `/api/sync/bodies/get` | `syncGetBodies` | `getBodies` |
| POST | `/api/sync/held` | `syncHeld` | `getHeld` |
| PUT | `/api/sync/images/<name>` | `syncPutImage` | `putImage` |
| GET | `/api/sync/images/<name>` | `syncGetImage` | `getImage` |
| POST | `/api/sync/parts` | `syncPutPart` | `putPart` |
| GET | `/api/sync/parts/<name>` | `syncGetPart` | `getPart` |
| POST | `/api/sync/root` | `syncReplaceRoot` | `replaceRoot` |
| GET | `/api/sync/roots/<name>` | `syncGetRoot` | `getRoot` |

Account deletion (`DELETE /api/me`, `server/src/account_deletion.mjs` and
`server/src/sync_deletion.mjs`) removes an account's sync too, and lives outside the prefix with the
rest of the account.

## Schema

`server/migrations/0003_sync.sql`:

| Table | Key | What a row is |
|---|---|---|
| `sync_accounts` | `account_id` | An account that synced: `generation`, `root_name`, `image_form` (`'none'` until set), `stored_bytes`, `hidden_bytes` (JSON, UTC day to bytes), `record_count`, `last_synced_day`, and its day's counters `daily_day`, `daily_requests`, `daily_rows_read`, `daily_rows_written` |
| `sync_objects` | `account_id`, `name` | A name the account stored, or that its list names before it is stored: `kind` (`'body'`, `'png'`, `'jpeg'`, `'part'`, `'root'`), `size`, a body's `binding` (its image binding and icon), a part's `slot` and `record_count`, `refs`, `stored_at`, `ref_count`, `pending`, and the hide state `hidden_at`, `hidden_since`, `hide_by`, `marker` |
| `sync_writes` | `account_id`, `write_by` | A request about to write under an account's prefix in B2: `names` (JSON) and `written_at`. It references no account, so it outlives the account it names |
| `sync_daily` | `day` | Sync's counters of one UTC day over every account: `requests`, `rows_read`, `rows_written`, and `delete_rows`, the part of `rows_written` account deletions wrote |
| `sync_totals` | `id` = 1 | `stored_bytes` and `hidden_bytes` over every account |

The partial indexes on `sync_objects` name the states a row is left in when a request stops part-way
(see [Invariants](#invariants-of-hides-and-shows)):

| Index | Condition |
|---|---|
| `sync_objects_to_hide` | `ref_count = 0 AND hidden_at IS NULL AND stored_at IS NOT NULL` |
| `sync_objects_hiding` | `ref_count = 0 AND hidden_at IS NOT NULL AND marker IS NULL AND hide_by IS NOT NULL` |
| `sync_objects_to_show` | `ref_count > 0 AND hidden_at IS NOT NULL` |
| `sync_objects_gone` | `ref_count = 0 AND hidden_since IS NOT NULL` |

The triggers `sync_objects_usage_insert`, `sync_objects_usage_update` and `sync_objects_usage_delete`
keep `stored_bytes` and `hidden_bytes` of the account and of `sync_totals` equal to what its rows hold
([Usage](#usage-and-the-databases-room)).

## Limits

Every limit is a constant in `server/src/limits.mjs`. Those marked provisional state in their comment
what was not measured on the real platform.

**Requests and objects**

| Constant | Value | What it bounds |
|---|---|---|
| `MAX_SYNC_BODIES_PER_REQUEST` | 10 | Bodies one put or fetch carries |
| `MAX_SYNC_BODY` | 256 KiB | One body's UTF-8 bytes (provisional) |
| `MAX_SYNC_BODIES_REQUEST` | `MAX_SYNC_BODIES_PER_REQUEST * (2 * MAX_SYNC_BODY + 256)` | A bundled body put's request body |
| `MAX_SYNC_IMAGE` | 32 MiB | One image's bytes (provisional) |
| `SYNC_PARTS_PER_REPLACE` | 4 | `S`: slots one replacement may change (provisional) |
| `MAX_SYNC_PART` | 512 KiB | One part's UTF-8 bytes (provisional) |
| `MAX_SYNC_PART_REQUEST` | `2 * MAX_SYNC_PART + 256` | A part put's request body |
| `MAX_SYNC_ROOT` | 16 KiB | One root's UTF-8 bytes |
| `MAX_SYNC_ROOT_REQUEST` | `2 * MAX_SYNC_ROOT + 256` | A replacement's request body |
| `MAX_SYNC_HELD_NAMES` | 1,000 | Names one `held` query asks about |
| `MAX_SYNC_HELD_REQUEST` | `MAX_SYNC_HELD_NAMES * 67 + 256` | A `held` query's request body |
| `MAX_SMALL_BODY` | 4 KiB | The settings' request body (and the logins') |
| `B2_REQUESTS_PER_INVOCATION` | 50 | B2 requests one request or hourly run makes |
| `B2_ATTEMPTS` | 3 | Times one PUT or GET is sent to B2 while it answers 429 or 5xx |
| `B2_RETRY_FIRST_WAIT` | 1 s | The wait before the first retry when B2 names none, doubled per retry |
| `B2_RETRY_WAIT_MAX` | 4 s | The longest `Retry-After` the Worker waits for |
| `SYNC_PNGS_PER_JPEG` | 999 | PNGs one reduced JPEG stands in for across a root's rows |

**Hides, shows and the hourly run**

| Constant | Value | What it bounds |
|---|---|---|
| `SYNC_LEFTOVER_HIDES` | 1,000 | Hides one sync write or hourly run takes on (provisional) |
| `SYNC_LEFTOVER_SHOWS` | 1,000 | Shows one sync write or hourly run takes on (provisional) |
| `SYNC_LEFTOVER_WRITES` | 1,000 | Unrecorded writes one sync write or hourly run takes on (provisional) |
| `SYNC_FORGETS_PER_STATEMENT` | 1,000 | Gone rows one statement of the hourly run deletes |
| `SYNC_FORGETS_PER_RUN` | 10,000 | Gone rows one hourly run deletes (provisional) |
| `SYNC_ABANDONED_AFTER` | 900 s (15 minutes) | Age from which a request is taken as stopped |
| `B2_DAYS_FROM_HIDING_TO_DELETING` | 6 | The bucket's `daysFromHidingToDeleting` |
| `RESTORE_MARGIN_SECONDS` | 3,600 | How far the Worker's clock and B2's may differ (provisional) |

**Daily limits, per environment, from 00:00 UTC**

| Constant | Value |
|---|---|
| `SYNC_DAILY_REQUESTS` | 100,000 |
| `SYNC_DAILY_READ_ROWS` | 50,000,000 |
| `SYNC_DAILY_ROWS` | 600,000 |
| `SYNC_DAILY_DELETE_ROWS` | `SYNC_DAILY_ROWS / 2` = 300,000 (account deletions' share of `SYNC_DAILY_ROWS`) |
| `ACCOUNT_SYNC_REQUESTS_PER_DAY` | 8,000 |
| `ACCOUNT_SYNC_READ_ROWS_PER_DAY` | 450,000 |
| `ACCOUNT_SYNC_ROWS_PER_DAY` | `SYNC_DAILY_ROWS / 5` = 120,000 |
| `SYNC_REPLACE_RESERVE` | `requests` `SYNC_PARTS_PER_REPLACE + 1` = 5, `rows_read` 21,000, `rows_written` 6,500, `database_bytes` 16 MiB |

**Capacity**

| Constant | Value |
|---|---|
| `ACCOUNT_SYNC_BYTES_CAP` | 2 GiB |
| `ACCOUNT_SYNC_RECORDS_CAP` | 5,000 |
| `ACCOUNT_SYNC_HIDDEN_BYTES_CAP` | 2 GiB |
| `SYNC_BUDGET` | 1 TiB (`1024 ** 4` bytes) |
| `D1_DATABASE_BYTES` | 10 × 1000³ bytes |
| `DATABASE_BUDGET` | `0.8 * D1_DATABASE_BYTES` (provisional) |
| `STORAGE_BUDGET` | `DATABASE_BUDGET / 8`: sharing's part, which sync never takes |

**Account deletion's sync part**

| Constant | Value |
|---|---|
| `ACCOUNT_DELETE_SYNC_ROWS` | 5,000 (provisional) |
| `ACCOUNT_DELETE_SYNC_READ_ROWS` | 15,000 (provisional) |
| `ACCOUNT_DELETE_B2_PAGES` | 4 |

The other constants of `limits.mjs` bound sharing and logins.

## Invariants of hides and shows

`server/src/sync_refs.mjs` holds them; its header states them in full.

- **Visible exactly while referenced.** A row's `ref_count` counts the references to its name from the
  account's current root: the root, each part it names, and what each part's rows reference
  (`referencesOf`). After a replacement commits and every request has finished, every name the
  current root references has a latest version in B2 that is not a delete marker. A name it does not
  reference is hidden by the request that stopped referencing it, or, when a put stored it, once it is
  `SYNC_ABANDONED_AFTER` old (below).
- **No request leaves a debt that only it can pay.** The request that makes a name unreferenced hides
  it before it answers, and the one that references a hidden name shows it before it commits. What a
  request owes and does not finish is a row state in D1, written before B2 is asked: a row in
  `sync_objects_to_hide`, `sync_objects_hiding` or `sync_objects_to_show`, or a `sync_writes` row. The
  account's next sync write that answers 200 (`tidyLeftoversOf`) and the hourly run take each on once
  it is `SYNC_ABANDONED_AFTER` old, a `sync_writes` row once it is `SYNC_ABANDONED_AFTER` and twice
  `RESTORE_MARGIN_SECONDS` old.
- **The six-day boundary.** A row hidden since (`hidden_since`) `B2_DAYS_FROM_HIDING_TO_DELETING` days
  less `RESTORE_MARGIN_SECONDS` ago is gone (`goneBy`): it is not held (`HELD`), nothing shows it again,
  and a put of its name stores it anew. A show counts only when the Worker's clock read after B2
  answered it is still inside the boundary.
- **Rows follow what is referenced.** The hourly run deletes a gone row nothing references a day after
  the boundary (`forgetBy`, `forgetLeftovers`), and the statement that leaves the row of an image never
  stored unreferenced deletes it.

## The hourly run

`runScheduled` (`server/src/scheduled.mjs`) runs the kinds of `KINDS` in this order, each sharing the
run's one `Bucket`, each after the one before has finished or failed:

| Kind | Function | What it does |
|---|---|---|
| `shows` | `showLeftovers` | Shows what cut-off requests left referenced and hidden, up to `SYNC_LEFTOVER_SHOWS` |
| `hides` | `hideLeftovers` | Hides what nothing references and no request is hiding, up to `SYNC_LEFTOVER_HIDES` |
| `writes` | `writeLeftovers` | Deletes what requests wrote under an account's prefix and no row accounts for, up to `SYNC_LEFTOVER_WRITES` names |
| `forgets` | `forgetLeftovers` | Deletes gone rows nothing references, up to `SYNC_FORGETS_PER_RUN` |
| `days` | `forgetDays` | Deletes the `sync_daily` rows before yesterday |

A kind that fails does not stop the ones after it; the run then fails with the first failure. Nothing
runs while `SYNC_ENABLED` is `"false"`.

## Daily limits and the reserve

`server/src/sync_quota.mjs` applies them.

- **Counting.** Every sync request but the generation's runs on a `MeteredD1`, which adds up the
  `meta.rows_read` and `meta.rows_written` D1 reports for its statements, the triggers' rows included.
  When the request ends, `chargeRequest` charges one request and those rows, plus 2 read and 2 written
  for the charge itself, to the account's day and to `sync_daily`. The generation's request is neither
  admitted nor charged. A request refused by a daily limit is charged to nobody.
- **Admission.** `admit` checks the six limits (`DAILY_LIMITS`: requests, rows read, rows written, per
  account and over every account) before a request's work. A request of use `"normal"` (a put of
  bodies or an image, a fetch, `held`, the settings) is refused when what is left of a limit is not
  more than its share of `SYNC_REPLACE_RESERVE`; a request of use `"reserve"` (a part put or a
  replacement) only when a limit is used up. The refusal is `429 daily_limit` with `scope` and a
  `Retry-After` to the next UTC day.
- **The reserve `R`** is one replacement's worth: the puts of `SYNC_PARTS_PER_REPLACE` parts and the
  replacement that commits them, in requests, rows read, rows written and database bytes. Its comment
  in `limits.mjs` derives each figure.
- **Account deletion** writes its share of the day's rows within `SYNC_DAILY_DELETE_ROWS`, counted in
  `sync_daily.delete_rows` and in `rows_written`.

## Usage and the database's room

- **Bytes.** The triggers count a row stored (`stored_at` and `size` set) and referenced
  (`ref_count > 0`) in `stored_bytes`, and a row stored and referenced by nothing in `hidden_bytes`
  under the UTC day of its `hidden_since`, or of its `stored_at` while it is not hidden. `usage` reads
  `hidden_bytes` only from the UTC day the six-day boundary falls on, so a day's bytes stop counting
  once B2's lifecycle may have deleted them. A referenced row a cut-off request left hidden counts as
  stored.
- **A put of new bytes** (`admitGrowth`) is refused, in this order: `507 account_limit` `"bytes"` when
  the account's stored bytes plus the new would pass `ACCOUNT_SYNC_BYTES_CAP`; `507 hidden_limit` when
  its hidden bytes already pass `ACCOUNT_SYNC_HIDDEN_BYTES_CAP`; `507 storage_full` when the bytes over
  every account plus the new would pass `SYNC_BUDGET`; then the database's room as a `"normal"` request.
- **Records.** A replacement that makes the root list more records than the current one and more than
  `ACCOUNT_SYNC_RECORDS_CAP` is `507 account_limit` `"records"` (`recordsRefusal`).
- **The database's room** (`admitDatabase`) is `DATABASE_BUDGET` less the database's size as D1 reports
  it after the check's statement (`meta.size_after`, every table counted) less what sharing has not
  used of `STORAGE_BUDGET` (the charges in `totals`). A put of bodies or an image is refused
  `507 database_full` when the room is not more than `SYNC_REPLACE_RESERVE.database_bytes`, a part put
  and a replacement when none is left. A D1 that reports no size refuses the write as
  `503 temporarily_unavailable`. What takes rows away (account deletion, hides and shows, the hourly
  run) and what only reads is not checked.

## What the server relies on clients to do

The server enforces these by refusing; the client contract that avoids the refusals is in
[`sync-protocol.md`](sync-protocol.md).

- **`S`.** A replacement may change at most `SYNC_PARTS_PER_REPLACE` slots of the current root: a slot
  changes when the new root fills it, empties it, or fills it with another part, the `"columns"` and
  `"dismissed"` slots included. Past it the replacement is `400 too_many_parts`, and a client splits the
  change into several replacements.
- **Archiving under the image form `"none"`.** The reduced JPEG of an archive is taken only when the
  current root already references it from a row archived as `"jpeg"`, so the client replaces the root
  first and puts the JPEG after.
- **Bodies** carry the app-defined fields that [`sync-protocol.md`](sync-protocol.md#bodies) names; the
  server reads `metadata.binding` and `metadata.icon` alone.
