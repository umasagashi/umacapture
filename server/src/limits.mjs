// Every limit the write endpoints enforce. The budget figures come from measuring the staging D1
// (bytes per row, rows written per operation) with 4,096-byte pages.

/**
 * Bytes charged per record on top of its payload, for the row, its two index entries and page slack.
 * The measured overhead (physical bytes per row minus payload) is 325.9 to 439.4 B for real records
 * and peaks at 1,248.8 B for the largest accepted form: its ~2.9 KB payload fills a page by itself.
 * The charge is that peak rounded up to a multiple of 256, so the charge covers the physical size of
 * every accepted form, not only of typical ones.
 */
export const ROW_CHARGE = 1_280;

/**
 * Bytes one D1 database may hold on the Workers Paid plan: 10 GB, which the platform does not raise,
 * read as 10^9 bytes a GB (the smaller of the two readings). Sharing, logins, accounts and file sync
 * all keep their rows in the one database (`DB`).
 */
export const D1_DATABASE_BYTES = 10 * 1000 ** 3;

/**
 * Bytes up to which the writes users ask for may fill the database: 80% of D1_DATABASE_BYTES. Sharing
 * and file sync divide it between them. Sharing's part is STORAGE_BUDGET, counted by its own charges;
 * file sync gets the rest and checks it against the size D1 reports (`admitDatabase` in
 * sync_quota.mjs), which counts every table, sharing's rows and the logins' included, so no estimate of
 * bytes per row enters sync's side.
 * The 2 GB above it holds what no check refuses: what the requests admitted at the same moment add
 * after their check (one replacement at most SYNC_REPLACE_RESERVE.database_bytes), the rows of logins,
 * sessions and accounts (at ACCOUNT_CREATE_LIMIT a day, an account and its identity estimated at 1 KB
 * add under 200 MB a year), and the daily counters. Provisional: that the figure D1 reports is the one
 * its limit applies to, and whether removing rows lowers it, were not measured on the real platform.
 */
export const DATABASE_BUDGET = 0.8 * D1_DATABASE_BYTES;

/**
 * Upper bound on the sum of `records.charge`: sharing's part of DATABASE_BUDGET, an eighth of it. At
 * DAILY_LIMIT a day, filling it takes at least 1,000,000,000 / 1,048,576, about 954 days. File sync
 * never takes what sharing has not used of it, so a database that sync filled still shares.
 */
export const STORAGE_BUDGET = DATABASE_BUDGET / 8;

/**
 * Upper bound on the charge shared in one UTC day, so that filling STORAGE_BUDGET takes years. At the
 * average real payload (999.5 B) this admits about 460 shares a day.
 */
export const DAILY_LIMIT = 1_048_576;

/**
 * Upper bound on the records one account holds at a time. It bounds an account's list (its JSON and
 * the rows one list request reads) and the rows an account can spend by sharing and unsharing.
 */
export const ACCOUNT_SHARE_CAP = 300;

/**
 * Upper bound on the charge one account shares in one UTC day: a quarter of DAILY_LIMIT, so one
 * account cannot use up a day by itself.
 */
export const ACCOUNT_DAILY_LIMIT = 262_144;

/**
 * Upper bound on the trainer ids one account registers: room for the devices of one person and
 * their reinstalls (one id per device). Without it one account could write a row per request for
 * as long as it liked, outside every share limit.
 */
export const ACCOUNT_TRAINERS_CAP = 20;

/** Records one POST /api/shares carries at most. */
export const MAX_SHARES_PER_REQUEST = 8;

/**
 * Upper bound on the logins begun in one UTC day. A begin writes the login row and the daily counter
 * (plus the index entries), so the worst day stays a small share of the D1 rows written a day that
 * SYNC_DAILY_ROWS leaves to sharing and the logins, next to the share and account limits.
 */
export const LOGIN_LIMIT = 2_000;

/**
 * How long a begun login stays valid, counted from the begin: the round trip through Google's
 * screens. The begin cookie's Max-Age is the same value. Keeping it short is a condition of the
 * accepted risk that someone who can read an unused authorisation URL completes it in the user's
 * browser, so it is not lengthened.
 */
export const LOGIN_TTL_SECONDS = 180;

/**
 * Upper bound on the accounts created in one UTC day. A first login writes the account, its
 * identity and the daily counter on top of a returning login's writes (plus the index entries).
 */
export const ACCOUNT_CREATE_LIMIT = 500;

/**
 * How long a session lives, fixed from the claim and never extended: extending it on use would
 * write a row per request, and logging in again loses nothing.
 */
export const SESSION_TTL_SECONDS = 180 * 86_400;

/**
 * How long the session that began an account's deletion may continue it, counted from the begin (or
 * from a claim onto an account being deleted). Past it, logging in again continues the deletion.
 */
export const ACCOUNT_DELETE_SESSION_TTL_SECONDS = 7 * 86_400;

/** Shared records one DELETE /api/me removes at most, so one call stays within D1's queries per invocation. */
export const ACCOUNT_DELETE_CHUNK = 20;

/**
 * D1 rows one DELETE /api/me writes at most removing the account's sync rows. Provisional: the CPU
 * time of a chunk this size was not measured on the real platform.
 */
export const ACCOUNT_DELETE_SYNC_ROWS = 5_000;

/**
 * D1 rows one DELETE /api/me reads at most removing the account's sync rows: the chunk's delete (6
 * rows read for each sync_objects row, the triggers' included, measured with Miniflare's D1, at
 * ACCOUNT_DELETE_SYNC_ROWS / 3 rows) and the count of what is left (ACCOUNT_DELETE_SYNC_ROWS). A
 * deletion removes no row once the day leaves fewer of SYNC_DAILY_READ_ROWS. Provisional, as
 * ACCOUNT_DELETE_SYNC_ROWS.
 */
export const ACCOUNT_DELETE_SYNC_READ_ROWS = 15_000;

/** Pages of ListObjectVersions (and a DeleteObjects for each) one DELETE /api/me takes on at most. */
export const ACCOUNT_DELETE_B2_PAGES = 4;

/**
 * Pages of ListObjectVersions (and a DeleteObjects for each) one DELETE /api/me takes on at most under
 * the account's shared images (s/<account id>/). An account holds ACCOUNT_SHARE_CAP shares at most, a
 * bundle each, so a page of 1,000 versions usually holds them all; what it does not, the next call takes.
 */
export const ACCOUNT_DELETE_SHARE_IMAGE_PAGES = 1;

/** Expired rows removed per sweep and table, so one sweep never costs more than this many deletions. */
export const SWEEP_LIMIT = 100;

/** One record of POST /api/shares, and the request body of MAX_SHARES_PER_REQUEST of them, counted as received. */
export const MAX_SHARE_RECORD = 20 * 1024;
export const MAX_SHARE_BODY = MAX_SHARES_PER_REQUEST * MAX_SHARE_RECORD;

/** Canonical JSON of the posted form, before compression. */
export const MAX_CANONICAL = 16 * 1024;

// Shared images. A share may declare one bundle of its record's reduced JPEGs (share_images.mjs). Every
// byte limit below counts what shares declare (`records.images_size`), once per share, from its POST
// until it is unshared or its account deleted: declared bytes, not the bytes B2 stores. B2 may hold
// fewer (a bundle not put yet) or more (a version a retried PUT or a late one added, until the bucket's
// lifecycle or the hourly run removes it), and no D1 row can read what it holds. Provisional, every
// one: the values await the approval asked before the deployment.

/** One part of a bundle, a reduced JPEG: about four times the largest measured, 460 KB. */
export const MAX_SHARE_IMAGE_PART = 2 * 1024 ** 2;

/** One bundle: three parts of MAX_SHARE_IMAGE_PART; the trainee's portrait, about 9 KB, is not budgeted for apart. */
export const MAX_SHARE_IMAGE_BUNDLE = 6 * 1024 ** 2;

/**
 * Declared bytes of every share's bundle at a time: about 195,000 shares of a typical 1.1 MB bundle.
 * Declared bytes, not what B2 stores (see above).
 */
export const SHARE_IMAGE_BUDGET = 200 * 1024 ** 3;

/**
 * Declared bytes of the bundles shared in one UTC day, over every account: about 1,950 typical bundles,
 * four times the shares DAILY_LIMIT admits a day at the average payload. Declared bytes, not what B2 stores.
 */
export const SHARE_IMAGE_DAILY_LIMIT = 2 * 1024 ** 3;

/**
 * Declared bytes of the bundles one account shares in one UTC day: an eighth of SHARE_IMAGE_DAILY_LIMIT,
 * about 240 typical bundles, so one account cannot use up a day by itself. Declared bytes, not what B2 stores.
 */
export const ACCOUNT_SHARE_IMAGE_DAILY_LIMIT = 256 * 1024 ** 2;

/**
 * Bytes a share's declaration adds to its row past the posted form: the stored parts' JSON, counted as
 * it is, plus this for the bundle's name (64), its size and the time it was stored. The declaration's
 * bytes are charged with the form (`records.charge`), against the sharing budgets measured for rows.
 */
export const SHARE_IMAGE_ROW_CHARGE = 96;

/**
 * Bodies one sync request puts or fetches at most. Measured on the real platform, ten bodies took a
 * Worker at most 8 to 9 ms of CPU either way, and twenty up to 19 ms. The value keeps a request within
 * 10 ms of CPU; a Workers Paid request may use more, and whether a larger bundle should be allowed is
 * to be measured on the deployed server.
 */
export const MAX_SYNC_BODIES_PER_REQUEST = 10;

/** One body's UTF-8 bytes. Provisional: a record's body is a few KB, and nothing measured bounds it yet. */
export const MAX_SYNC_BODY = 256 * 1024;

/** Request body of a bundled body put, counted as received: JSON escaping can double each body. */
export const MAX_SYNC_BODIES_REQUEST = MAX_SYNC_BODIES_PER_REQUEST * (2 * MAX_SYNC_BODY + 256);

/** One image's bytes. Provisional: a stitched screenshot is a few MB, and nothing measured bounds it yet. */
export const MAX_SYNC_IMAGE = 32 * 1024 * 1024;

/**
 * Parts one replacement of the root may change: slots the new root fills, empties or fills with
 * another part than the current root, the column titles' and dismissed pairs' slots included.
 * Provisional: on the real platform, replacements that each added four parts of a 5,000-record
 * account stayed within 10 ms of CPU in 62 of 64 runs and took 14 ms in the other two; fewer parts
 * per replacement were not measured. The value keeps a replacement near 10 ms of CPU; a Workers Paid
 * request may use more, and whether more parts per replacement should be allowed is to be measured on
 * the deployed server.
 */
export const SYNC_PARTS_PER_REPLACE = 4;

/** One part's UTF-8 bytes. Provisional: 128 parts of a 5,000-record account measured 22 to 56 KB each. */
export const MAX_SYNC_PART = 512 * 1024;

/** Request body of a part put, counted as received: JSON escaping can double the part. */
export const MAX_SYNC_PART_REQUEST = 2 * MAX_SYNC_PART + 256;

/** One root's UTF-8 bytes: 130 slots naming a part each fit in about 11 KB. */
export const MAX_SYNC_ROOT = 16 * 1024;

/** Request body of a root replacement, counted as received. */
export const MAX_SYNC_ROOT_REQUEST = 2 * MAX_SYNC_ROOT + 256;

/**
 * Requests to B2 one sync request makes at most. Measured on the real platform, a Worker invocation
 * may fetch 50 times and the 51st throws; D1 queries are not counted. Every request finishes the hides
 * and shows it causes, so each endpoint counts them before it changes anything: hides and shows go
 * up to 1,000 names to a DeleteObjects, and a replacement whose count exceeds this is refused. What a
 * write leaves of it after its own work goes to the shows and hides cut-off requests left
 * (SYNC_LEFTOVER_SHOWS and SYNC_LEFTOVER_HIDES).
 */
export const B2_REQUESTS_PER_INVOCATION = 50;

/**
 * Times the Worker sends one PUT or GET to B2 at most: once, and again while B2 answers it 429 or 5xx
 * (`503 SlowDown` when it is busy), which Backblaze's documentation asks a client to retry with
 * exponential backoff. Every endpoint counts a PUT or GET as this many of B2_REQUESTS_PER_INVOCATION
 * before it changes anything: a bundle of MAX_SYNC_BODIES_PER_REQUEST takes 30 at most. Three
 * attempts take a bundle of ten through PUTs that fail one in a hundred, independently, all but once
 * in about 10^5 bundles; a failure that lasts longer is the next sync's to retry.
 */
export const B2_ATTEMPTS = 3;

/**
 * Seconds the Worker waits before its first retry when B2 names no wait (Retry-After): the 1 s
 * Backblaze's integration checklist starts its exponential backoff at. Each retry after waits twice the
 * one before, so the attempts of B2_ATTEMPTS wait 1 + 2 = 3 s in all.
 */
export const B2_RETRY_FIRST_WAIT = 1;

/**
 * Seconds of Retry-After the Worker still waits for. A longer one ends the attempts there: the request
 * answers 502 storage_unavailable at once instead of retrying earlier than B2 asked. So a request
 * waits for B2 at most (B2_ATTEMPTS - 1) * 4 = 8 s on top of its attempts; the Worker's CPU time does not
 * count the wait.
 */
export const B2_RETRY_WAIT_MAX = 4;

/**
 * PNGs one reduced JPEG stands in for at most, across the rows of an account's root. Storing the JPEG
 * takes the references off all of them and hides those left unreferenced together with the JPEG,
 * which this keeps to one DeleteObjects. A JPEG reduces one PNG, so a root that pairs it with more
 * than one is already unusual.
 */
export const SYNC_PNGS_PER_JPEG = 999;

/**
 * Hides left by cut-off requests (sync_objects_to_hide, sync_objects_hiding) that one sync write or
 * one hourly run takes on at most: one DeleteObjects. Provisional: the CPU of a DeleteObjects of 1,000 names was not measured
 * on the real platform, in a request or in a scheduled run (each under the CPU time the Workers Paid plan gives an
 * invocation).
 */
export const SYNC_LEFTOVER_HIDES = 1_000;

/**
 * Names left referenced and hidden by cut-off requests (sync_objects_to_show) that one sync write or
 * one hourly run takes on at most: one DeleteObjects for the markers their rows recorded, and, for the
 * rows that recorded none, the ListObjectVersions pages of the account (up to 1,000 versions each)
 * that the B2 requests left have room for. Locally a page of 1,000 versions took as much CPU to read
 * as a DeleteObjects of 1,000 names took to build. Provisional, as SYNC_LEFTOVER_HIDES.
 */
export const SYNC_LEFTOVER_SHOWS = 1_000;

/**
 * Names whose B2 write a request left unrecorded (sync_writes) that one sync write or one hourly run
 * takes on at most. A name the account holds costs one D1 statement and no B2 request; the others are
 * listed by the ListObjectVersions pages of their account that the B2 requests left have room for, and
 * their versions deleted a DeleteObjects per 1,000. Provisional, as SYNC_LEFTOVER_HIDES.
 */
export const SYNC_LEFTOVER_WRITES = 1_000;

/** Rows of names gone and referenced by nothing (sync_objects_gone) that one statement of the hourly run deletes at most. */
export const SYNC_FORGETS_PER_STATEMENT = 1_000;

/**
 * Rows of names gone and referenced by nothing that one hourly run deletes at most, a statement per
 * SYNC_FORGETS_PER_STATEMENT. Such a row was stored by a sync request, and storing a row writes three
 * at least (the row, and through the triggers of migrations/0003_sync.sql the account's usage and the
 * totals'), so the SYNC_DAILY_ROWS a day's requests write store SYNC_DAILY_ROWS / 3 = 200,000 rows at
 * most, about 8,300 an hour: a run of 10,000 keeps up with the most a day can leave. It takes 10 of the
 * 1,000 D1 queries a Workers Paid invocation may make, no B2 request, and the Worker's CPU only to
 * await them. Provisional: how long D1 takes over a statement of 1,000 deletions and their triggers was
 * not measured on the real platform.
 */
export const SYNC_FORGETS_PER_RUN = 10_000;

/**
 * Seconds after which a hide or show whose request has recorded no marker counts as abandoned, its
 * request stopped mid-way, and is hidden again by the account's next sync write or the hourly run;
 * after which a name a cut-off request left referenced and hidden is shown by them; and after which an
 * object put and referenced by nothing is hidden by them, its sync having had the time to reference it.
 * A sync request makes at most 50 B2 requests and no other wait, so one still running after a quarter
 * of an hour, the wall time the platform gives a scheduled run, is not expected. Taking over a hide
 * whose request is still running is safe either way (that request finds the row no longer its own),
 * and only costs a replacement its commit.
 */
export const SYNC_ABANDONED_AFTER = 15 * 60;

/**
 * Days the sync bucket's lifecycle rule waits from hiding a version to deleting it
 * (`daysFromHidingToDeleting`, set on the bucket by the operator, not by the Worker). B2 deletes a
 * version some time within the day after that.
 */
export const B2_DAYS_FROM_HIDING_TO_DELETING = 6;

/**
 * Seconds before B2's lifecycle may delete a hidden version from which the server counts it as gone:
 * a name hidden since `B2_DAYS_FROM_HIDING_TO_DELETING` days less this is not stored, is not shown
 * again, and is stored anew when put. A show counts only when the Worker's clock, read after B2
 * answered it, is still inside that, so the margin covers how far the Worker's clock and B2's
 * lifecycle may differ, not how long a request runs. The versions a cut-off request may have written
 * are told by B2's LastModified with the same margin, from that request's clock (sync_refs.mjs,
 * `writtenBy`). Provisional: the difference was not measured on the real platform.
 */
export const RESTORE_MARGIN_SECONDS = 3600;

// File sync's daily limits and capacity, applied by sync_quota.mjs. Its `usage` is the one place
// that reads how much an account and the service hold in B2, from the counters the triggers of
// migrations/0003_sync.sql keep, and its `admitDatabase` the one place that reads how much the D1
// database holds (DATABASE_BUDGET).

// The service-wide limits are per environment: production and staging each count in their own D1, and
// both are billed to the one Cloudflare account. Each is set so that both environments using it up
// every day of a 31-day month stay within what the Workers Paid plan includes a month, and past it the
// plan bills rather than stops.

/**
 * Sync requests over every account in one UTC day: both environments using it up make 6.2 million of
 * the 10 million requests a month includes. It does not bind before the rows do: the five accounts
 * that use up SYNC_DAILY_ROWS make at most 5 * ACCOUNT_SYNC_REQUESTS_PER_DAY = 40,000 requests.
 */
export const SYNC_DAILY_REQUESTS = 100_000;

/**
 * D1 rows sync requests read over every account in one UTC day: both environments using it up read
 * 3.1 billion of the 25 billion rows a month includes.
 */
export const SYNC_DAILY_READ_ROWS = 50_000_000;

/**
 * D1 rows sync requests write over every account in one UTC day: both environments using it up write
 * 37.2 million of the 50 million rows a month includes. The rest holds sharing's rows (a day of
 * DAILY_LIMIT and the logins, estimated at 33,500 rows, 2.1 million a month for both) and the hourly
 * runs' hides, which no limit counts (SYNC_LEFTOVER_HIDES names at about 3 rows each, 24 runs a day,
 * 4.5 million a month for both), which leaves about 13% for what those estimates miss.
 */
export const SYNC_DAILY_ROWS = 600_000;

/**
 * Of SYNC_DAILY_ROWS, the rows account deletions may write in one UTC day: half, so a day of deletions
 * leaves at least as many to the sync of every other account.
 */
export const SYNC_DAILY_DELETE_ROWS = SYNC_DAILY_ROWS / 2;

/**
 * Steps of account deletion, each what one DELETE /api/me takes on, that one hourly run takes on at
 * most over every account being deleted: as many as let the 24 runs of a UTC day write the whole of
 * SYNC_DAILY_DELETE_ROWS a chunk of ACCOUNT_DELETE_SYNC_ROWS a step, ceil(300,000 / (24 * 5,000)) = 3.
 * A step sends at most 2 * ACCOUNT_DELETE_B2_PAGES + 1 = 9 B2 requests under the sync prefix and
 * 2 * ACCOUNT_DELETE_SHARE_IMAGE_PAGES + 1 = 3 under the shared images', 12 in all, so three take 36 of
 * the run's B2_REQUESTS_PER_INVOCATION at most, and about 50 of the 1,000 D1 queries a Workers Paid
 * invocation may make. Provisional, as ACCOUNT_DELETE_SYNC_ROWS.
 */
export const ACCOUNT_DELETE_STEPS_PER_RUN = Math.ceil(SYNC_DAILY_DELETE_ROWS / (24 * ACCOUNT_DELETE_SYNC_ROWS));

// The per-account limits let the bodies and the list of a first sync of ACCOUNT_SYNC_RECORDS_CAP
// records go through in one day where the rows allow it; its images may take more days. Measured on the
// local D1, not on the real platform, for 5,000 records over 128 parts, each body binding six image
// names and no image put: 672 requests reading 306,725 rows and writing 99,213.

/**
 * Sync requests of one account in one UTC day. Every request of every device of the account counts.
 * Estimated, not measured, for a first sync of R = 5,000 records of which I, about 2,000, have images
 * (as many as ACCOUNT_SYNC_BYTES_CAP holds as reduced JPEGs), each with three images and an icon:
 * - the device that sends: the 672 measured above, plus held queries for the icons,
 *   ceil(7R / MAX_SYNC_HELD_NAMES) - ceil(6R / MAX_SYNC_HELD_NAMES) = 5, plus a put of each image and
 *   icon, 4I = 8,000: about 8,677;
 * - a device that receives: a fetch of each body bundle, R / MAX_SYNC_BODIES_PER_REQUEST = 500, of each
 *   of the 128 parts and of the root, held queries ceil(7R / MAX_SYNC_HELD_NAMES) = 35, and a fetch of
 *   each image and icon, 4I = 8,000: about 8,664.
 * About 17,300 in all, before retries. With SYNC_REPLACE_RESERVE.requests kept back, a day takes about
 * 7,995 of the requests other than part puts and replacements, so such a sync takes three UTC days:
 * each request past the limit is refused 429 daily_limit with Retry-After to the next UTC day, and the
 * sync goes on from where it stopped with the same result.
 */
export const ACCOUNT_SYNC_REQUESTS_PER_DAY = 8_000;

/** D1 rows the sync requests of one account read in one UTC day: more than the 306,725 of a first sync with SYNC_REPLACE_RESERVE.rows_read. */
export const ACCOUNT_SYNC_READ_ROWS_PER_DAY = 450_000;

/**
 * D1 rows the sync requests of one account write in one UTC day: a fifth of SYNC_DAILY_ROWS, so one
 * account cannot use up a day by itself (as ACCOUNT_DAILY_LIMIT is to DAILY_LIMIT). The first sync
 * measured above writes 99,213 rows, so it completes in one day. One that writes more is refused
 * part-way and goes on the next day where it stopped, and its result does not change.
 */
export const ACCOUNT_SYNC_ROWS_PER_DAY = SYNC_DAILY_ROWS / 5;

/**
 * What each limit, the daily ones per account and over every account and the database's room, keeps
 * back for one replacement: the puts of SYNC_PARTS_PER_REPLACE parts and the replacement that commits
 * them. A request other than those is refused once what is left of a limit would not exceed this, and
 * may overrun it by its own rows, so the reserve also holds one such request.
 * - requests: the parts and the replacement (the generation's request is not counted).
 * - rows: measured on the local D1 for the first sync above (4 parts of about 39 records each, each
 *   record a body binding six image names): a part put reads at most 99 and writes 9, a replacement
 *   reads at most 8,918 and writes at most 3,087; one bundled body put reads at most 187 and writes 73,
 *   one held query of 1,000 names reads about 2,000. The reserve is twice the replacement, so a
 *   replacement whose parts hold up to about twice as many records still fits, with 4 part puts and
 *   one other request: 2 * 8,918 + 4 * 99 + 2,000 = 20,232 read, 2 * 3,087 + 4 * 9 + 73 = 6,283
 *   written. A larger replacement may be refused at the end of a day; it goes through the next.
 * - database_bytes: what the 4 part puts and the replacement add to the database at most. A part's row
 *   holds its references, at most its text (MAX_SYNC_PART), and each name it is the first to reference
 *   gets a row of about 200 bytes for each 67 bytes of text that name it, three times the text; the
 *   root's row holds at most MAX_SYNC_ROOT. That is 4 * 4 * 512 KiB + 16 KiB, about 8 MiB, doubled
 *   for B-tree pages half full. Provisional: derived from the columns, not measured.
 */
export const SYNC_REPLACE_RESERVE = Object.freeze({
  requests: SYNC_PARTS_PER_REPLACE + 1,
  rows_read: 21_000,
  rows_written: 6_500,
  database_bytes: 16 * 1024 ** 2,
});

/**
 * Bytes the objects one account's current root references may take: about 550 records with PNGs or
 * 2,000 with reduced JPEGs. What it no longer references does not count (ACCOUNT_SYNC_HIDDEN_BYTES_CAP).
 */
export const ACCOUNT_SYNC_BYTES_CAP = 2 * 1024 ** 3;

/** Records one account's current root lists at most. */
export const ACCOUNT_SYNC_RECORDS_CAP = 5_000;

/**
 * Bytes of one account's objects that nothing references and B2 still keeps, hidden until its
 * lifecycle deletes them six to seven days later. Past it, puts of new bytes wait for them to go.
 */
export const ACCOUNT_SYNC_HIDDEN_BYTES_CAP = 2 * 1024 ** 3;

/** Bytes in the sync bucket over every account, referenced or hidden. */
export const SYNC_BUDGET = 1024 ** 4;

/** Names one POST /api/sync/held asks about at most. */
export const MAX_SYNC_HELD_NAMES = 1_000;

/** Request body of POST /api/sync/held, counted as received: 64 hex digits, two quotes and a comma per name. */
export const MAX_SYNC_HELD_REQUEST = MAX_SYNC_HELD_NAMES * 67 + 256;

/** Request body of the other JSON endpoints (a login's secret and proof). */
export const MAX_SMALL_BODY = 4 * 1024;

/**
 * Upper bound on the reports of shares and of lists (POST /api/reports) accepted in one UTC day, all
 * of them together. Each accepted report is one Sentry event, so a flood stops here rather than in the
 * project's event quota. 0 accepts none.
 */
export const REPORT_DAILY_LIMIT = 50;

/** Characters a report's free text holds at most. */
export const MAX_REPORT_TEXT = 1_000;

/**
 * Request body of a report form: the text at its longest percent-encoded (up to 9 bytes a character),
 * a Turnstile token (up to 2,048 characters) and the other fields.
 */
export const MAX_REPORT_BODY = 16 * 1024;

/**
 * Upper bound on the operators' takedowns (share_takedowns) one hourly run carries out. Each sends at
 * most REMOVE_BUNDLE_B2_REQUESTS (2) of the run's B2_REQUESTS_PER_INVOCATION, so five take 10 of 50 and
 * leave the kinds after them room. Takedowns are written by hand, a few at a time; more wait an hour.
 */
export const SHARE_TAKEDOWNS_PER_RUN = 5;
