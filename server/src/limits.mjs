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

/** Upper bound on the sum of `records.charge`: 80% of the 500 MB a D1 database may hold. */
export const STORAGE_BUDGET = 400_000_000;

/**
 * Upper bound on the charge shared in one UTC day: 400,000,000 / 1,048,576 is about 381, so filling
 * the budget takes at least 381 days. At the average real payload (999.5 B) this admits about 460
 * shares a day.
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
 * (plus the index entries), so the worst day stays a small share of the 100,000 rows a D1 database
 * allows next to the share and account limits.
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

/** Expired rows removed per sweep and table, so one sweep never costs more than this many deletions. */
export const SWEEP_LIMIT = 100;

/** One record of POST /api/shares, and the request body of MAX_SHARES_PER_REQUEST of them, counted as received. */
export const MAX_SHARE_RECORD = 20 * 1024;
export const MAX_SHARE_BODY = MAX_SHARES_PER_REQUEST * MAX_SHARE_RECORD;

/** Canonical JSON of the posted form, before compression. */
export const MAX_CANONICAL = 16 * 1024;

/** Request body of the other JSON endpoints (a login's secret and proof). */
export const MAX_SMALL_BODY = 4 * 1024;
