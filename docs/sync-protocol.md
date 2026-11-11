# File sync protocol

The contract between the sync endpoints of the Worker (`server/src/sync.mjs`,
`server/src/sync_list.mjs`) and the apps that sync through them. The server's side of each rule is
enforced by the code; this document states what a client must send and may expect back. Later
stages extend it (account deletion); a section they have not written yet is not a promise. What the
server is made of — its configuration, bucket, schema and limits — is [`sync-server.md`](sync-server.md).

## Common to every endpoint

- **Prefix.** Every sync endpoint lives under `/api/sync/`, so the zone's WAF can tell them apart by
  prefix.
- **Session.** Every request carries `Authorization: Bearer <session token>` of a full session.
- **Object names.** Every stored object — body, image, part, root — is named by the SHA-256 of its
  bytes, as 64 lowercase hex digits. An account stores a name once; a put of a name it already holds
  answers `"exists"` without reaching B2. An object hidden past the
  [six-day boundary](#the-six-day-boundary) is no longer held. Objects of one account are invisible
  to every other.
- **Errors** are JSON `{error, ...}`:

  | Status | `error` | Meaning |
  |---|---|---|
  | 400 | `invalid_payload` | `field` names the offending field (`body` for an oversized or non-JSON request) |
  | 401 | `session_required` | No valid session |
  | 409 | `account_deleting` | The session may only continue an account deletion |
  | 503 | `sync_paused` | The operator switched sync off (`SYNC_ENABLED=false`); sharing and logins go on |
  | 503 | `temporarily_unavailable` | D1 failed. A replacement can answer it after its commit, its new generation current (see [References and retention](#references-and-retention)), so a client reads the generation again before it retries |
  | 502 | `storage_unavailable` | B2 answered something the Worker cannot act on |
  | 502 | `storage_refused` | B2 refused a put (403): for an image, its bytes do not hash to its name, or the key is wrong — B2 does not tell the two apart. Nothing was stored |
  | 429 | `daily_limit` | A daily limit is used up; `scope` is `"account"` or `"service"`, and `Retry-After` the seconds to the next UTC day. See [Daily limits and capacity](#daily-limits-and-capacity) |
  | 507 | `account_limit` | The account's cap: `limit` `"bytes"` (a put of new bytes) or `"records"` (a replacement that adds records). Nothing was stored |
  | 507 | `hidden_limit` | The account holds more deleted bytes than its cap allows; `Retry-After` is when some of them stop counting. Nothing was stored |
  | 507 | `storage_full` | The service's budget is used up. Nothing was stored |
  | 507 | `database_full` | The server's database has no room for what the request would add. Nothing was stored, and nothing the client does makes room. See [Daily limits and capacity](#daily-limits-and-capacity) |

  Each endpoint below lists the errors of its own.

## Generation

`GET /api/sync/generation` → `200 {generation, root}`: the account's generation and the name of
its current root; `0` and `null` before its first replacement. Every replacement of the root
advances the generation by one. No daily limit stops it, and it counts against none.

## Settings

An account's sync settings are the server's, shared by every device of the account.

- `GET /api/sync/settings` → `200 {image_form}`.
- `PUT /api/sync/settings` `{image_form}` → `200 {image_form}`. `400 invalid_payload`, `field`
  `image_form`, for any other value.

`image_form` is `"png"`, `"jpeg"` (reduced JPEG) or `"none"`, and `"jpeg"` until the account sets
one. It decides which new images a put may store (see [Images](#images)); every request after the
`PUT` answers reads the new form. There is no endpoint that resends images after a change: a device
puts what the form lets it put from then on.

## Bodies

A body is a record's text. It must be a JSON object carrying the record's image binding at
`metadata.binding`: an object whose keys are among `campaign_png`, `campaign_jpeg`, `factor_png`,
`factor_jpeg`, `skill_png`, `skill_jpeg`, each an image name or `null`. A missing key means the
same as `null` (unknown). It may carry the record's icon (`trainee.jpg`, a JPEG) at `metadata.icon`:
an image name, or missing (or `null`) when the record has none. The server reads the binding and the
icon when the body is put and keeps them; a list row must copy them (see `image` and `icon` below).

**Fields the app defines.** The server reads nothing of a body but `metadata.binding` and
`metadata.icon`; the rest is the app's:

- A body is the record's `record.json` without the fields only the device holds,
  `metadata.body_written_at` (when the body was written) and `metadata.relation_bonus`, as
  `recordJsonWithoutLocalFields` (`lib/src/chara_detail/record_export_shape.dart`) writes it.
- `metadata.binding` is the app's `RecordBinding`: the six keys above, each omitted when unknown.
- A record's archive state is not in its body. The app keeps it in `archive.json` beside
  `record.json` (`recordArchiveNoteName`, `lib/src/chara_detail/record_archive_state.dart`):
  `normal_written_at`, and `archived` with `state` (`"jpeg"` or `"none"`) and `written_at`.

- `POST /api/sync/bodies` `{bodies: [{name, body}]}`, 1 to 10 bodies, each at most 256 KiB of
  UTF-8 → `200 {results: [{name, status}]}`, status `"stored"` or `"exists"`. A body whose `name` is
  not the SHA-256 of its UTF-8 bytes, or that carries no valid binding or an icon that is not an
  image name, refuses the whole request with 400 (`field` `bodies[i].name` / `bodies[i].body`) and stores nothing.
- `POST /api/sync/bodies/get` `{names}`, 1 to 10 names → `200 {bodies: [{name, body}]}` in the
  order asked, or `404 not_found {names}` listing the names the account does not hold.

## Images

- `PUT /api/sync/images/<name>`, the image's bytes as the request body, `Content-Type` `image/png`
  or `image/jpeg`, `Content-Length` of at most 32 MiB → `200 {name, status}`. The Worker streams the
  bytes to B2 signed with `<name>`; bytes that do not hash to it are `502 storage_refused` (not 400:
  see the table above).
- **Image form.** Under `"png"` and `"jpeg"` any image may be put. Under `"none"` a put of an image
  the account does not hold is `409 images_not_synced` and nothing reaches B2, with one exception: the
  reduced JPEG an archive puts in place of its PNG. That JPEG is taken when the account's **current
  root** has a part whose row is archived as reduced JPEG and names this JPEG and a PNG in its
  binding, and the account holds that PNG (stored, and not gone past the
  [six-day boundary](#the-six-day-boundary)). A part put and not yet named by the root does not
  count, and neither does a normal row that names the JPEG. A put of a name the account holds answers
  `"exists"` under every form.
- **Client contract for archiving under `"none"`.** Replace the root with the parts whose rows are
  archived as reduced JPEG **first**, and put the reduced JPEG **after**. In the other order the put
  is refused. Between the replacement and the put, the root still references the PNG (see
  [References and retention](#references-and-retention)); the put moves those references to the JPEG.
- Errors of its own: `409 images_not_synced` — the account's image form refuses this image. It is
  409, not 403: the session may put images, and the refusal follows from the account's state, which
  a `PUT /api/sync/settings` or a replacement of the root can change.
- `GET /api/sync/images/<name>` → the bytes with their content type, or `404 not_found`.

## Held

`POST /api/sync/held` `{names}`, 1 to 1,000 names → `200 {held}`: the names of `names` the account
holds, in the order asked. A name is held when a put of it would answer `"exists"`: stored, whether
the current root references it or not, and not gone past the [six-day boundary](#the-six-day-boundary).
It reads the server's records alone and never reaches B2, so it is how a client learns which images
the server has without fetching them. `400 invalid_payload`, `field` `names` or `names[i]`.

## The list: a root and its parts

The list is one root and up to 130 parts, all stored objects.

### Root

```json
{"format": 1, "parts": {"0": "<part name>", "17": "<part name>", "columns": "<part name>"}}
```

- `format` is `1`. `parts` maps **slots** to part names. Slots `"0"` to `"127"` are record parts;
  `"columns"` and `"dismissed"` are the opaque parts. A slot left out is empty. No other key is
  allowed, so the root stays small.

### Record parts

A record belongs to record part `n` where `n` is the first two bytes of the SHA-256 of the UTF-8
bytes of its id, read as a big-endian integer, modulo 128:

```js
n = sha256(utf8(id)).readUInt16BE(0) % 128
```

```json
{"format": 1, "part": 17, "records": [
  {"id": "…", "body": {"name": "<body name>", …}, "archive": {"state": "normal", …}, "image": {"skill_png": "…", …}, …}
]}
```

- Top level: exactly `format` (`1`), `part` (the number, 0 to 127) and `records` (at least one row).
  A part with no records is not put; its slot is left out of the root.
- **Fields the server checks**, per row:
  - `id`: a string of 1 to 128 UTF-16 code units; it falls in `part`, and appears once in the part.
  - `body.name`: the name of a body the account holds.
  - `archive.state`: `"normal"`, `"jpeg"` or `"none"`.
  - `image`: the record's image binding, with the same keys and meaning as a body's
    `metadata.binding`. It must be present and equal the binding of the body `body.name` names (a
    missing key and `null` are equal); otherwise 400, `field` `part.records[i].image`. As the body a
    row names carries a binding, so does every row the server holds: `{}` there is a binding that
    names no image.
  - `icon`: the record's icon, an image name, or missing (or `null`) when it has none. It must equal
    the `metadata.icon` of the body `body.name` names; otherwise 400, `field` `part.records[i].icon`.
- **Opaque fields**: every other key of a row (`body.written_at`, `archive.written_at`, ratings,
  memos, …), and every other key inside `body` and `archive`, is stored and returned byte for byte
  and never read by the server. The app defines them here (to be added by the client stage).
- What a part's rows reference is read when the part is put (see
  [References and retention](#references-and-retention)).

### Opaque parts

```json
{"format": 1, "part": "columns", "content": …}
{"format": 1, "part": "dismissed", "content": …}
```

Exactly `format`, `part` and `content`; the server never reads `content` (the column titles and the
dismissed pairs, defined by the app). They live in parts rather than the root so the root stays
small, and they count toward the replacement limit like any part.

### What the app puts in the list

The app writes the list from what a device holds (`syncListParts`,
`lib/src/chara_detail/record_sync_list.dart`) and reads it back to the same values
(`syncListOfParts`). Every value travels with the time it was written, in milliseconds since the
epoch, by the clock of the device that wrote it; sync carries the time as written, never the time the
value arrived. A value from before the app timed its values has time `0`. A value written to none
keeps its time and has no value key.

A record row:

```json
{"id": "R1",
 "body": {"name": "<body name>", "written_at": 1767225600123, "content": "<content name>", "parents": {"parent1": "P1"}},
 "archive": {"state": "jpeg", "written_at": 1767225600400},
 "image": {"skill_png": "…", "skill_jpeg": "…"},
 "absorbed": ["R9"],
 "cells": {"rating/<key>": {"value": 4.5, "written_at": 1767225600600}, "memo/<key>": {"written_at": 1767225600800}}}
```

| Field | Holds |
|---|---|
| `body.name` | The record's body object: its `record.json` without `metadata.body_written_at` and `metadata.relation_bonus` (see [Bodies](#bodies)) |
| `body.written_at` | The body's time, `metadata.body_written_at` of the device's `record.json` |
| `body.content` | The SHA-256 of the recognised content alone (`recognizedContentKey`): two bodies with the same content and bindings that agree are the same body, whatever else differs |
| `body.parents` | The inheritance parents, `parent1` and `parent2`, each left out when empty; the whole key left out when both are |
| `archive.state`, `archive.written_at` | The archive state and its time, from the record's `archive.json` and the store it is in |
| `image` | The body's `metadata.binding`, `{}` where it names no image; left out where the device's `record.json` carries none — not worked out yet, or worked out and not written to it (a read-only file) —, which only a list the device has not sent holds (the server refuses such a row): a round leaves such a record as the server lists it, with every record of its operation, and tells how many it left so in its last attempt, whether that attempt ended the round done or failed after choosing them. Archiving takes the same course: a record whose binding could not be written goes into the archive store without one, so the next round works it out again |
| `icon` | The body's `metadata.icon`; left out when the body has none |
| `absorbed` | The ids the record absorbed in merges (`merged_ids.json`), sorted; left out when none |
| `split_from` | The id a round split the record off, where it did |
| `cells` | The record's rating and memo cells, by column: `<storage>/<key>`, `storage` `rating` or `memo` and `key` the column storage's. `value` is the rating (a number) or the memo (a string); left out when none |

The body's content and parents are in the row as well as in the body object, so a round merges the
list without fetching a body it does not apply. A cell of a record the list does not hold is not
carried.

The opaque parts:

- `columns`: `content` maps each column to `{"title": "…", "written_at": …}`; a removed column
  storage has no `title`.
- `dismissed`: `content` is the dismissed pairs, `[["R1", "R2"], …]`, each pair and the list sorted.

The same values make the same text: keys come in one order, rows by id, columns and pairs sorted, and
a number with no fraction is written as an integer (`4`, never `4.0`), the one form a build on the
web, whose numbers do not tell the two apart, writes as well. An unchanged part therefore keeps its
name, and a put of it answers `"exists"`. A part an older build wrote may hold the same values in
another text; a client leaves it in its slot under the name it has until it changes the part.

### Endpoints

- `POST /api/sync/parts` `{name, part}`: `part` is the part's text, at most 512 KiB of UTF-8, and
  `name` its SHA-256 → `200 {name, status}`, `"stored"` or `"exists"`. Refusals store nothing:
  - `400 invalid_payload`, `field` one of `name` (not the SHA-256), `part`, `part.format`,
    `part.part`, `part.records`, `part.records[i]`, `part.records[i].id` (out of the part's number,
    or repeated), `part.records[i].body`, `part.records[i].archive`, `part.records[i].image` (not a
    binding, or not the binding of its body).
  - `409 missing_objects {names}`: bodies the rows name that the account does not hold. Put them
    first.
  - `507 database_full`: the server's database has no room left (see
    [Daily limits and capacity](#daily-limits-and-capacity)).
- `POST /api/sync/root` `{generation, name, root}`: `root` is the root's text, at most 16 KiB of
  UTF-8, `name` its SHA-256, and `generation` the generation the client read →
  `200 {generation, root}` with the new generation (the old one plus one) and root name. The
  replacement commits only if the account is still at `generation`; of two replacements made from
  the same generation, exactly one goes through. Refusals change nothing:
  - `409 stale_generation {generation}`: another replacement came first; `generation` is the
    current one. Read the current root, merge, and replace again.
  - `409 missing_objects {names}`: parts the root names, or bodies the rows of the parts it adds
    name, that the account does not hold; or objects the replacement was making fetchable again that
    went past the [six-day boundary](#the-six-day-boundary) while it ran. Put them, and replace again.
  - `400 too_many_parts {limit}`: the root changes more than `limit` slots of the current root. A
    slot changes when the new root fills it, empties it, or fills it with another part; the opaque
    slots count. `limit` is 4 (provisional, to be measured again on the deployed server), so a
    first sync of a full list takes at least 33 replacements, and an ordinary change touching more
    parts is split into several replacements in the same way.
  - `409 too_many_objects`: showing what the replacement starts to reference and hiding what it
    stops referencing would take more requests to B2 than one request may make (50; see
    [References and retention](#references-and-retention)). The client replaces again changing
    fewer slots — half of them, down to one — the same way as for `too_many_parts`; the result is
    the same, only reached in more replacements. Hidden objects it references whose hide recorded
    no delete marker (a hide that was stopped, and hidden again by the server) are found by listing
    the account's versions in pages of up to 1,000, one request each, as below; a page lists at
    least one such object, and usually many. So a replacement changing one slot is refused only when
    those objects of its one part are spread over more pages than its requests have room for (from
    about 8 for the largest part to about 44 for a small one; a page lists only one of them when the
    next lies more than 1,000 versions on), and it stays refused until they go past the
    [six-day boundary](#the-six-day-boundary).
  - `400 too_many_pngs_per_jpeg {limit}`: the new root would make one reduced JPEG stand in for
    more than `limit` (999) distinct PNGs across its `"jpeg"` rows. A JPEG is the reduction of one
    PNG, so a client that builds bindings from its images never meets this.
  - `507 account_limit {limit: "records"}`: the new root lists more records than the current one
    and more than the account's records cap (see [Daily limits and capacity](#daily-limits-and-capacity)).
  - `507 database_full`: the server's database has no room left, as for a part put.
  - `400 invalid_payload`, `field` `generation`, `name`, `root`, `root.format`, `root.parts`, or
    `root.parts.<slot>` (an unknown slot, a value that is not a name, or a part put for another
    slot).
- `GET /api/sync/roots/<name>` and `GET /api/sync/parts/<name>` → the object's text as stored
  (`application/json`), or `404 not_found` when the account holds no root or part of that name.

## Daily limits and capacity

Every endpoint but the generation's counts against six daily limits: requests, D1 rows read and D1
rows written, per account and over every account, from 00:00 UTC (`server/src/limits.mjs`:
`ACCOUNT_SYNC_REQUESTS_PER_DAY`, `ACCOUNT_SYNC_READ_ROWS_PER_DAY`, `ACCOUNT_SYNC_ROWS_PER_DAY`,
`SYNC_DAILY_REQUESTS`, `SYNC_DAILY_READ_ROWS`, `SYNC_DAILY_ROWS`). A request refused by one of them
(`429 daily_limit`) changes nothing and counts against none.

- **The reserve.** Each limit keeps back one replacement's worth, `SYNC_REPLACE_RESERVE`: the puts of
  `S` parts and the replacement that commits them. Puts of bodies and images, fetches, `held` and the
  settings are refused once what is left of a limit is not more than the reserve; part puts and
  replacements only once a limit is used up. So a client refused a body or image put can still put
  the parts it already changed and commit them, and should, before it waits for the next day. A
  replacement that changes more than one reserve's worth (taking many records away) may still be
  refused near the end of a day; it goes through the next.
- **Held names.** A put of a name the account holds answers `"exists"` whatever the limits and caps.
- **What a long sync does.** A first sync of a large account can take more than one day's rows or
  requests: it is refused part-way and goes on the next day where it stopped, with the same result.
  Every device of the account counts against the same limits. The bodies and the list of a first
  sync of `ACCOUNT_SYNC_RECORDS_CAP` records fit in a day; its images may not: about 2,000 records
  with three reduced JPEGs and an icon each are about 8,000 puts on the device that sends them and as
  many fetches on each device that receives them, against `ACCOUNT_SYNC_REQUESTS_PER_DAY` (8,000), so
  they take two to three days (the estimate is on that constant in `server/src/limits.mjs`).

Capacity (`ACCOUNT_SYNC_BYTES_CAP`, `ACCOUNT_SYNC_RECORDS_CAP`, `ACCOUNT_SYNC_HIDDEN_BYTES_CAP`,
`SYNC_BUDGET`, and the server's database, `DATABASE_BUDGET`) is checked only by what makes the
account or the database hold more:

| Request | Checked against |
|---|---|
| A put of bodies or an image with a name the account does not hold | `account_limit` `"bytes"`: the account's referenced bytes plus the new bytes would pass the cap. `hidden_limit`: its hidden bytes already pass theirs. `storage_full`: the service's bytes plus the new ones would pass the budget. `database_full`: the database's room is not more than the reserve |
| A put of a part the account does not hold, and any replacement | `database_full`: the database has no room left |
| A replacement that makes the root list more records than the current one | `account_limit` `"records"`, when it would list more than the cap |
| Account deletion, settings, fetches, `held`, a put of a name the account holds | Nothing |

- **The account's bytes** are those of the stored objects its current root references: bodies,
  images, parts and the root. An account exactly at its cap may still change ratings and delete or
  archive records; deleting frees the deleted bytes at once, so new bytes can be put right after.
- **Hidden bytes** are those of stored objects nothing references: what was deleted, replaced, or put
  and not yet referenced. B2 keeps them six to seven days after they were hidden, so they count
  against the hidden cap, not the account's cap, until the UTC day they were hidden on is past the
  [six-day boundary](#the-six-day-boundary). Past the hidden cap, puts of new bytes wait
  (`507 hidden_limit` with `Retry-After`); nothing a client does makes them free sooner, and deleting
  only adds to them. A name the current root references counts as the account's bytes even while a
  cut-off request left it hidden.
- **The service's budget** counts both, every account's.
- **The server's database** holds a row for every object an account's current root references, and
  for what it stopped referencing for about a week: the hourly run deletes the row of an object once
  it is a day past the [six-day boundary](#the-six-day-boundary), and the row of an image a list named
  and nobody put goes with the replacement (or the JPEG put) that stops referencing it. So deleting,
  archiving or replacing records frees the database's room about a week later, and what an account
  takes follows the records it lists, not how often it replaced them. A deleted row answers as a gone
  object does: nothing a client sees changes. Sharing keeps its
  own part of the database, so a database that sync filled still takes shares, and sync is refused
  before sharing is. Like the daily limits, the database keeps back one replacement's room
  (`SYNC_REPLACE_RESERVE`): once puts of bodies and images are refused `database_full`, a client can
  still put the parts it changed and commit them, and should. Past that, every write that stores
  something is refused until the operator makes room; fetches and account deletion go on.

## Account deletion

Deleting the account (`DELETE /api/me`, outside `/api/sync/`) removes what it synced too: every
version and delete marker under its B2 prefix, deleted by version id, and every sync row in D1. Once
the account is gone (a 204, or an hourly run that finished the deletion) nothing of the account's sync
is left, but for what a request still running then writes
to B2 afterwards: a sync request of the account that passed its session check before the deletion
began, or the hourly run hiding one of its objects. The server records each such write before it
asks B2, and that record outlives the account; the hourly run deletes what it wrote, usually within
about three and a half hours: a record is taken once it is two hours and a quarter old, and one run
takes up to 1,000 names and as many accounts as its 50 requests to B2 reach, over the records of
every account. When more is waiting than one run takes, it waits an hour more for each run ahead of
it ([what no row accounts for](#references-and-retention)).

- **While it is being deleted** every sync endpoint answers `409 account_deleting`, the
  deletion-only session's requests included.
- **`remaining`.** A 200 carries `{remaining: {sync_rows, sync_versions, shares, share_images}}`: the
  sync rows left (counted up to `ACCOUNT_DELETE_SYNC_ROWS`), the versions and markers B2 still lists
  under the sync prefix (up to one page), the shared records left, and the versions of shared images B2
  still lists under the account's `s/` prefix (up to one page). The app repeats the call with the same session until
  it answers 204, and reads none of the counts.
- **The day's share.** The sync rows go a chunk a call within half of `SYNC_DAILY_ROWS`
  (`SYNC_DAILY_DELETE_ROWS`, over every deletion), counted in the day's sync rows written, so a day of
  deletions leaves at least as many rows to everyone's sync. B2's versions go once no row is left. A
  rows they read count in the day's sync rows read, and none is removed once the day leaves fewer of
  `SYNC_DAILY_READ_ROWS` than one call reads (`ACCOUNT_DELETE_SYNC_READ_ROWS`). A
  call that removes nothing because that share has no room answers `429 sync_paused_today` with the
  same `remaining` and a `Retry-After` to the next UTC day; the next call after it goes on where the
  deletion stopped.
- **The hourly run finishes it.** Every hourly run goes on with the accounts being deleted, whether
  sync is switched on or off, taking the same steps a call takes within the same day's share, so a
  deletion finishes without the app. After `429 sync_paused_today` the app leaves the rest to the
  server and drops its session; a run that meets the share with no room removes nothing, and a run of
  a later UTC day goes on. Once a run has removed the account, its deletion-only session is gone with
  it, and a call with that session answers `401`.

## References and retention

The server keeps an object fetchable only while the account's current root references it, and
derives the references itself from the root and the parts it names.

- **What the current root references**: the root itself, every part it names, and for each row of
  those parts:
  - its body;
  - archive state `"normal"`: every image its `image` names, and its `icon`;
  - archive state `"jpeg"`: each image's reduced JPEG, and that image's PNG only while the account
    has not stored the JPEG — once the JPEG is stored, the row references the JPEG alone, whether
    it was stored before or after the replacement; and its `icon`;
  - archive state `"none"`: no image and no icon.

  An icon is an image like the others: it is put and fetched under `/api/sync/images/` as
  `image/jpeg`, refused under the image form `"none"`, and counts as the account's bytes while
  referenced.

  A name stays referenced while any row of any part of the current root references it: a PNG one
  row stops referencing because its JPEG arrived stays fetchable while another row (a `"normal"`
  one, in the same part or another) still references it.
- **What the current root does not reference answers 404.** A GET of such an object answers
  `404 not_found` (for bodies, `404 not_found {names}`), though the account still holds it, whether
  or not B2 has hidden it yet:
  - a body, image or part just put, until a replacement references it;
  - a part or root no replacement made current, including the root of a replacement refused with
    `409 stale_generation`;
  - the root a replacement replaced, and everything a replacement stopped referencing.

  A put of such a name still answers `"exists"` and stores nothing again; the replacement that
  references it makes it fetchable.
- **What a put stores is hidden only once it is 15 minutes old.** A put leaves what it stored
  unhidden in B2, for the replacement of the same sync to reference. What nothing references 15
  minutes after it was put is hidden by the account's next sync write or the hourly run, the same two
  that finish what a cut-off request left (below). So an object put and never referenced is deleted
  by the bucket's lifecycle at most about seven days and one hour and a quarter after it was put; the
  "seven days" told about deleted records does not cover it, since no record of it was ever synced.
  A client sees no difference: such an object answers 404 either way, and one referenced later is
  fetchable from that replacement on, hidden meanwhile or not.
- **A replacement shows what it references.** When `POST /api/sync/root` answers 200, every stored
  object the new root references is fetchable, including ones hidden before. An image a row names
  before it is put is fetchable as soon as it is put.
- **The request that changes a reference finishes the hides and shows it causes** before it
  answers: a replacement shows what it starts to reference before it commits and hides what it stops
  referencing after, and a JPEG put hides the PNGs it took the references off. Apart from what a put
  stores, a request that answers leaves nothing for a later one. The
  server hides and shows up to 1,000 objects in one request to B2, and one Worker request may make
  at most 50 requests to B2: a body put takes at most 10, a part put 1, an image put 3, and a
  replacement counts its own before it changes anything and answers `409 too_many_objects` when
  they do not fit (at most 41 for a replacement changing one slot, plus the pages listing the hidden
  objects it references whose hide recorded no delete marker). It lists them all before it shows
  anything, or refuses without having shown any.
- **A request cut off before its hides is finished by others.** A replacement stopped after it
  committed and before it hid what it stopped referencing — past the Worker's CPU limit, or
  disconnected — answers an error (`503 temporarily_unavailable`, or none at all), though its new
  generation is current. What it did not hide stays unhidden in B2 (and answers 404, as anything the
  current root does not reference), and the server keeps a record of each such object in D1 that is
  written by the commit itself, so the record cannot be lost with the request.
  A request stopped inside a hide or a show is recorded the same way, by the hide or show itself
  before it asks B2 anything: a hide stopped before B2 hid the object, a hide B2 failed (the request
  still answers), and a replacement stopped after it showed what it references again and before its
  commit (its new generation is not current, and what it showed stays unhidden). Such an object is
  taken on once that request is 15 minutes old, the longest the server expects a request to run (one
  a replacement left unhidden, once it was put 15 minutes ago, as anything put is); a
  request still running then finds the object no longer its own, and a replacement that does answers
  `503 temporarily_unavailable` without committing. Two things hide them, whichever comes first:
  - the account's next sync write that answers 200 (`POST /api/sync/bodies`, `PUT
    /api/sync/images/<name>`, `POST /api/sync/parts`, `POST /api/sync/root`, a put answering
    `"exists"` included) hides up to 1,000 of them, with the requests to B2 its own work left over;
    `GET /api/sync/generation`, the fetches and refused writes do not;
  - an hourly run at half past every hour UTC (a quarter to every hour on staging) hides up to 1,000
    of them across all accounts, as many accounts as its 50 requests to B2 have room for, and leaves
    the rest recorded for the next hour's run. It hides nothing while sync is switched off.

  An object referenced again before either comes is not hidden. A client that sees such an error
  reads the generation again, as after any failed replacement; the objects left unhidden meanwhile
  cost it nothing.
- **A request cut off before its shows is finished by others too.** A request can be stopped where
  an object the current root references is left hidden: a replacement after its commit and before
  it showed what a concurrent put hid after the replacement looked (the replacement answers an
  error, though its new generation is current), and a hide that found the object referenced, or
  taken over by a replacement, before it took its marker back. Such an object answers `404 not_found`
  though the current root references it. Each is recorded in D1 by the commit or the hide that
  leaves it, and so is an object a replacement took over from a request still running, since that
  request may hide it after the replacement looked. Once the request is 15 minutes old, the same two
  as above make each such object fetchable again, before they hide anything: the account's next sync
  write that answers 200, and the hourly run, up to 1,000 objects across all accounts, as many as
  their requests to B2 have room for. An object whose hide recorded its delete marker takes no request
  of its own: one request deletes the markers of up to 1,000. For one whose marker is not recorded
  (its hide was stopped before recording it, or B2 failed to delete the recorded one), the server
  lists the versions of the account's objects in pages of up to 1,000, one request each, beginning at
  the first such object not listed yet, and reads the markers of every such object a page passes.
  The rest stays recorded for the next. So a backlog as large as an account can leave, every object
  of its records hidden, is shown within a day: about one hourly run for each 1,000 objects. Showing
  them comes days before the bucket's lifecycle would delete them; one that went past the
  [six-day boundary](#the-six-day-boundary) meanwhile is not shown, and stays gone.
- **What B2 holds that no row accounts for is deleted.** Before a request asks B2 to store an object
  or to add a delete marker over one, it records that write in D1, and it clears the record in the
  statement that records what B2 then holds. A request stopped in between, or one that reached an
  account being deleted, leaves the record, and B2 may hold a version under that name that no row
  accounts for: an object stored and never recorded, the object of a put whose other objects B2
  refused (`502 storage_refused` stores nothing a client can rely on), a marker over a name the
  deletion already emptied. Once a record is two hours and a quarter old (15 minutes for its request
  to be abandoned, and twice the hour by which the server's clock and B2's may differ), the account's
  next sync write and the hourly run delete the versions of that name its request may have written,
  up to 1,000 names, unless the account holds the name and is not being deleted. A name it holds
  whose row is hidden and referenced by nothing may have what the request wrote over its delete
  marker (a put that reached B2 after another put of the name stored it and a replacement hid it):
  it is hidden again, by a later sync write or run, as what a cut-off hide left. A put that finds
  such a row when it records what it stored keeps its record for the same reason. A put of the same
  name since is left alone: its versions are newer than what the record covers, and a name a newer
  record names waits for that one. A client sees nothing of this: a put that answered an error is
  retried, and its retry stores the object again.
- **Hidden objects are deleted later** by the bucket's lifecycle, six days after they were hidden.
  Until the boundary below, a replacement that references one again makes it fetchable again.

### The six-day boundary

The bucket's lifecycle deletes a hidden object from six days after it was hidden, and may pick it for
deletion before a replacement makes it fetchable again and delete it after. So the server counts an
object hidden for six days less one hour as **gone**, as if it had never been put:

- It is not held: `POST /api/sync/held` leaves it out, every GET of it answers `404 not_found`, and
  a put of its name answers `"stored"` and stores it anew, fetchable again once referenced.
- Nothing makes it fetchable again. A part or a root that names a gone body or part is refused with
  `409 missing_objects`, as for one never put. A gone image is as one never put: a row may name it,
  and it is fetchable once put. A row archived as `"jpeg"` whose JPEG is gone references its PNG
  again, until the JPEG is put. What a cut-off request left hidden though referenced is not shown
  once gone.
- Once nothing references it, the hourly run deletes its row a day after the boundary (see
  [the server's database](#daily-limits-and-capacity)). A gone object and one with no row answer
  every request the same way, so the deletion changes nothing above.
- A replacement that makes hidden objects fetchable again commits only if they are still inside the
  boundary once B2 has answered; otherwise it answers `409 missing_objects {names}` with those, and
  changes nothing. A put of each and a replacement again goes through.

The hour covers how far the server's clock and B2's may differ. The six days count from the first
time an object was hidden since it was last fetchable: a request cut off and hidden again later does
not move it.
