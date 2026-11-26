// File sync's daily limits and capacity. Every sync request but the generation's runs on a D1 handle
// that counts the rows its statements read and write (`MeteredD1`), and charges them with the request
// to the account's and the service's counters of the day when it ends (`chargeRequest`). Before its
// work a request is admitted against the six daily limits (`admit`): requests, rows read and rows
// written, per account and over every account. A put that stores new bytes is also checked against
// the capacity (`admitGrowth`), and a replacement that adds records against the records cap
// (`recordsRefusal`). Every request that adds rows to the D1 database by storing an object — a put of
// bodies, an image or a part, and a replacement — is checked against the database's room
// (`admitDatabase`); what takes rows away (an account's deletion, hides and shows, the hourly run) and
// what only reads is not.
//
// One replacement's worth of each daily limit and of the database's room is kept back
// (SYNC_REPLACE_RESERVE): a "normal" request — a put of bodies or images, any fetch, the settings — is
// refused once what is left of a limit would not exceed it, while a part put and a replacement
// ("reserve") go on until a limit is used up. So a client that was refused a normal request can still
// put the parts it changed and commit them.
//
// Usage is what the triggers of migrations/0003_sync.sql keep on sync_accounts and sync_totals:
// stored_bytes, the bytes of stored objects something references, and hidden_bytes, the bytes of stored
// objects nothing references by the UTC day they were hidden on. `usage` reads them; it is the one
// place that decides which days of hidden_bytes still count.

import { fail, untilTomorrow } from "./api.mjs";
import * as limits from "./limits.mjs";
import { Unavailable } from "./store.mjs";
import { goneBy } from "./sync_refs.mjs";

const DAY = 86_400;

/** A refusal decided before the request changed anything; `answerSync` answers `response`. */
export class Refused extends Error {
  constructor(response) {
    super("sync request refused");
    this.response = response;
  }
}

/**
 * A D1 handle that adds up the rows read and written its statements report (`meta.rows_read`,
 * `meta.rows_written`; the triggers' rows included), and knows the account to charge them to once
 * `admit`, `countWithin` or `countFor` named one.
 */
export class MeteredD1 {
  rowsRead = 0;
  rowsWritten = 0;
  /** The account the request is charged to, or null while none is. */
  accountId = null;
  #db;

  constructor(db) {
    this.#db = db;
  }

  prepare(sql) {
    return new MeteredStatement(this, this.#db.prepare(sql));
  }

  async batch(statements) {
    const results = await this.#db.batch(statements.map((s) => s.inner));
    for (const r of results) this.tally(r.meta);
    return results;
  }

  tally(meta) {
    this.rowsRead += meta?.rows_read ?? 0;
    this.rowsWritten += meta?.rows_written ?? 0;
  }

  /** The handle it counts for, for the charge that must not count itself. */
  get inner() {
    return this.#db;
  }
}

class MeteredStatement {
  #meter;

  constructor(meter, inner) {
    this.#meter = meter;
    this.inner = inner;
  }

  bind(...values) {
    return new MeteredStatement(this.#meter, this.inner.bind(...values));
  }

  async all() {
    const result = await this.inner.all();
    this.#meter.tally(result.meta);
    return result;
  }

  async run() {
    const result = await this.inner.run();
    this.#meter.tally(result.meta);
    return result;
  }

  /** D1's `first`, read through `all` so that its rows are counted too. */
  async first(column) {
    const row = (await this.all()).results[0] ?? null;
    return column === undefined || row === null ? row : row[column];
  }
}

/**
 * Rows the charge itself reads and writes on top of what it charges: the account's row and the day's
 * row, each read and written once (measured with Miniflare's D1: 2 read, 2 written).
 */
const CHARGE_ROWS = 2;

/**
 * The hourly run's deletion of sync_daily's rows before the day before the UTC day of clock `at`. A request is
 * admitted and charged on the day it began on (`admit`, `chargeRequest`), and an account deletion on
 * the day of its call, so no request still running reads or writes an earlier one.
 */
export async function forgetDays(db, at) {
  await db.prepare("DELETE FROM sync_daily WHERE day < ?1").bind(Math.floor(at / DAY) - 1).run();
}

/** Charges the request run on `db` (a MeteredD1) to its account and the day `clk`, when it has one. */
export async function chargeRequest(db, clk) {
  if (db.accountId === null) return;
  const read = db.rowsRead + CHARGE_ROWS;
  const written = db.rowsWritten + CHARGE_ROWS;
  await db.inner.batch([
    db.inner
      .prepare(
        `INSERT INTO sync_accounts (account_id, daily_day, daily_requests, daily_rows_read, daily_rows_written) VALUES (?1, ?2, 1, ?3, ?4)
         ON CONFLICT (account_id) DO UPDATE SET
           daily_requests = CASE WHEN daily_day = ?2 THEN daily_requests + 1 ELSE 1 END,
           daily_rows_read = CASE WHEN daily_day = ?2 THEN daily_rows_read + ?3 ELSE ?3 END,
           daily_rows_written = CASE WHEN daily_day = ?2 THEN daily_rows_written + ?4 ELSE ?4 END,
           daily_day = ?2`,
      )
      .bind(db.accountId, clk.day, read, written),
    db.inner
      .prepare(
        `INSERT INTO sync_daily (day, requests, rows_read, rows_written) VALUES (?1, 1, ?2, ?3)
         ON CONFLICT (day) DO UPDATE SET requests = requests + 1, rows_read = rows_read + ?2, rows_written = rows_written + ?3`,
      )
      .bind(clk.day, read, written),
  ]);
}

/** Charges the request run on `db` to account `accountId` without checking any limit. */
export function countFor(db, accountId) {
  db.accountId = accountId;
}

/** The six daily limits: [scope, counter, limit, the reserve kept back from it]. */
const DAILY_LIMITS = [
  ["account", "requests", limits.ACCOUNT_SYNC_REQUESTS_PER_DAY, limits.SYNC_REPLACE_RESERVE.requests],
  ["account", "rows_read", limits.ACCOUNT_SYNC_READ_ROWS_PER_DAY, limits.SYNC_REPLACE_RESERVE.rows_read],
  ["account", "rows_written", limits.ACCOUNT_SYNC_ROWS_PER_DAY, limits.SYNC_REPLACE_RESERVE.rows_written],
  ["service", "requests", limits.SYNC_DAILY_REQUESTS, limits.SYNC_REPLACE_RESERVE.requests],
  ["service", "rows_read", limits.SYNC_DAILY_READ_ROWS, limits.SYNC_REPLACE_RESERVE.rows_read],
  ["service", "rows_written", limits.SYNC_DAILY_ROWS, limits.SYNC_REPLACE_RESERVE.rows_written],
];

/**
 * What is left of each of the six daily limits for account `accountId` on `db` at clock `clk`, in the
 * order of DAILY_LIMITS: [scope, left, reserve]. A counter of an earlier UTC day counts as zero.
 */
async function dailyLeft(db, accountId, clk) {
  const row = await db
    .prepare(
      `SELECT CASE WHEN a.daily_day = ?2 THEN a.daily_requests ELSE 0 END AS account_requests,
              CASE WHEN a.daily_day = ?2 THEN a.daily_rows_read ELSE 0 END AS account_rows_read,
              CASE WHEN a.daily_day = ?2 THEN a.daily_rows_written ELSE 0 END AS account_rows_written,
              coalesce(d.requests, 0) AS service_requests, coalesce(d.rows_read, 0) AS service_rows_read,
              coalesce(d.rows_written, 0) AS service_rows_written
       FROM (SELECT 1) LEFT JOIN sync_accounts a ON a.account_id = ?1 LEFT JOIN sync_daily d ON d.day = ?2`,
    )
    .bind(accountId, clk.day)
    .first();
  return DAILY_LIMITS.map(([scope, counter, limit, reserve]) => [scope, limit - row[`${scope}_${counter}`], reserve]);
}

/**
 * Admits a request of account `accountId` on `db` at clock `clk` against the daily limits, and charges
 * it to the account from here on. `use` "normal" is refused when what is left of any limit is not more
 * than the reserve; "reserve" (a part put or a replacement) only when a limit is used up. Throws
 * Refused with 429 daily_limit `{scope}` ("account" or "service") and a Retry-After to the next UTC day.
 */
export async function admit(db, accountId, clk, use) {
  for (const [scope, left, reserve] of await dailyLeft(db, accountId, clk)) {
    if (left <= (use === "normal" ? reserve : 0)) {
      // Refused here, the request is charged to nobody, even when `countWithin` named its account before:
      // charging it would take a request and rows out of the reserve it was refused to keep.
      db.accountId = null;
      throw new Refused(fail(429, "daily_limit", { scope }, { "Retry-After": String(untilTomorrow(clk)) }));
    }
  }
  countFor(db, accountId);
}

/**
 * Charges the request run on `db` to account `accountId` while no daily limit is used up, without
 * refusing it: an answer that stores nothing (a held name's "exists", a 409) is given whatever the
 * limits, and once a limit is used up it is given without writing the two counter rows, so such
 * requests past the limit cost D1 no writes.
 */
export async function countWithin(db, accountId, clk) {
  for (const [, left] of await dailyLeft(db, accountId, clk)) {
    if (left <= 0) return;
  }
  countFor(db, accountId);
}

/** Hidden bytes by day (`hidden_bytes` JSON): the sum of the days from `firstDay` on, and the earliest such day with bytes. */
function hiddenFrom(json, firstDay) {
  let sum = 0;
  let earliest = null;
  for (const [key, bytes] of Object.entries(JSON.parse(json ?? "{}"))) {
    const day = Number(key);
    if (day < firstDay || bytes <= 0) continue;
    sum += bytes;
    if (earliest === null || day < earliest) earliest = day;
  }
  return { sum, earliest };
}

/**
 * The usage of account `accountId` at clock `at`: `stored` (bytes of the stored objects its current
 * root references, the hidden ones a cut-off request left referenced included), `hidden` (bytes of the
 * stored objects nothing references, hidden on a day B2's lifecycle may not have reached: from the UTC
 * day the six-day boundary `goneBy(at)` falls on), `records` (the current root's), and over every
 * account `total` (stored and hidden alike). `hiddenSince` is the earliest day of `hidden`, or null.
 */
export async function usage(db, accountId, at) {
  const row = await db
    .prepare(
      `SELECT a.stored_bytes, a.hidden_bytes, a.record_count, t.stored_bytes AS total_stored, t.hidden_bytes AS total_hidden
       FROM sync_totals t LEFT JOIN sync_accounts a ON a.account_id = ?1 WHERE t.id = 1`,
    )
    .bind(accountId)
    .first();
  const firstDay = Math.floor(goneBy(at) / DAY);
  const hidden = hiddenFrom(row.hidden_bytes, firstDay);
  return {
    stored: row.stored_bytes ?? 0,
    hidden: hidden.sum,
    hiddenSince: hidden.earliest,
    records: row.record_count ?? 0,
    total: row.total_stored + hiddenFrom(row.total_hidden, firstDay).sum,
  };
}

/**
 * Checks a put of account `accountId` at clock `at` that stores `bytes` new bytes. Throws Refused with
 * 507: account_limit `{limit: "bytes"}` when the account's stored bytes would pass
 * ACCOUNT_SYNC_BYTES_CAP; hidden_limit with a Retry-After when its hidden bytes already pass
 * ACCOUNT_SYNC_HIDDEN_BYTES_CAP (they fall as B2's lifecycle deletes them, and nothing the client does
 * makes them fall sooner: the Retry-After is when the earliest day of them stops counting); storage_full
 * when the bytes over every account would pass SYNC_BUDGET; database_full as `admitDatabase` "normal".
 */
export async function admitGrowth(db, accountId, at, bytes) {
  const u = await usage(db, accountId, at);
  if (bytes > accountBytesLeft(u)) throw new Refused(fail(507, "account_limit", { limit: "bytes" }));
  if (hiddenPastCap(u)) {
    const lapses = (u.hiddenSince + 1) * DAY + (limits.B2_DAYS_FROM_HIDING_TO_DELETING * DAY - limits.RESTORE_MARGIN_SECONDS);
    throw new Refused(fail(507, "hidden_limit", {}, { "Retry-After": String(Math.max(1, lapses - at)) }));
  }
  if (bytes > serviceBytesLeft(u)) throw new Refused(fail(507, "storage_full"));
  await admitDatabase(db, "normal");
}

/** New bytes the account's stored bytes `u.stored` may still grow by before `account_limit`; negative past the cap. */
const accountBytesLeft = (u) => limits.ACCOUNT_SYNC_BYTES_CAP - u.stored;

/** Whether the account's hidden bytes `u.hidden` are past their cap, which refuses every put with `hidden_limit`. */
const hiddenPastCap = (u) => u.hidden > limits.ACCOUNT_SYNC_HIDDEN_BYTES_CAP;

/** New bytes the bytes over every account `u.total` may still grow by before `storage_full`; negative past the budget. */
const serviceBytesLeft = (u) => limits.SYNC_BUDGET - u.total;

/**
 * The room for new bytes account `accountId` has at clock `at`: `{account, service}`, both whole bytes
 * of 0 or more. `account` is the most new bytes the account's own caps take (`account_limit`,
 * `hidden_limit`): 0 while its hidden bytes are past their cap, else ACCOUNT_SYNC_BYTES_CAP less its
 * stored bytes. `service` is the most the service's take (`storage_full`, `database_full`): 0 while
 * `admitDatabase` "normal" refuses, else SYNC_BUDGET less the bytes over every account. Both are worked
 * out by the expressions `admitGrowth` checks with, so at one state a put of `bytes` > 0 new bytes is
 * refused for the account (account_limit or hidden_limit) exactly when `bytes > account`, else for the
 * service (storage_full or database_full) exactly when `bytes > service`, and taken otherwise. It is a
 * reading, not a reservation: what a later put is answered is what counts. Throws as `usage` and
 * `databaseRoom` do.
 */
export async function roomOf(db, accountId, at) {
  const u = await usage(db, accountId, at);
  return {
    account: hiddenPastCap(u) ? 0 : Math.max(0, accountBytesLeft(u)),
    service: databaseTakes(await databaseRoom(db), "normal") ? Math.max(0, serviceBytesLeft(u)) : 0,
  };
}

/**
 * `roomOf`, or undefined when it cannot be read: the room is stated beside another answer and never
 * fails it, and an answer without it says that the server stated none.
 */
export async function statedRoom(db, accountId, at) {
  try {
    return await roomOf(db, accountId, at);
  } catch {
    return undefined;
  }
}

/**
 * Checks a sync write on `db` that adds rows to the D1 database against the room DATABASE_BUDGET
 * leaves it: the budget less the database's size as D1 reports it after this check's statement
 * (`meta.size_after`, every table counted), and less what sharing has not used of its part
 * (STORAGE_BUDGET less the charges in `totals`), so sync never takes sharing's room. `use` "normal"
 * (a put of bodies or an image) is refused when the room is not more than
 * SYNC_REPLACE_RESERVE.database_bytes; "reserve" (a part put or a replacement) only when none is left.
 * Throws Refused with 507 database_full, and Unavailable when D1 reports no size: without one nothing
 * bounds the database.
 */
export async function admitDatabase(db, use) {
  if (!databaseTakes(await databaseRoom(db), use)) throw new Refused(fail(507, "database_full"));
}

/**
 * The room DATABASE_BUDGET leaves sync on `db`, in bytes, as `admitDatabase` states it. Throws
 * Unavailable when D1 reports no size.
 */
async function databaseRoom(db) {
  const result = await db.prepare("SELECT bytes FROM totals WHERE id = 1").all();
  const size = result.meta?.size_after;
  if (!Number.isFinite(size)) throw new Unavailable("D1 reported no database size");
  const sharingRoom = Math.max(0, limits.STORAGE_BUDGET - result.results[0].bytes);
  return limits.DATABASE_BUDGET - size - sharingRoom;
}

/** Whether a sync write of `use` ("normal" or "reserve") is taken while the database's room is `room`. */
const databaseTakes = (room, use) => room > (use === "normal" ? limits.SYNC_REPLACE_RESERVE.database_bytes : 0);

/**
 * The refusal of a replacement that makes the account list `records` records where its current root
 * lists `current`: 507 account_limit `{limit: "records"}` when it adds records past
 * ACCOUNT_SYNC_RECORDS_CAP, or null. A replacement that adds none goes on whatever the count.
 */
export function recordsRefusal(records, current) {
  if (records > limits.ACCOUNT_SYNC_RECORDS_CAP && records > current) return fail(507, "account_limit", { limit: "records" });
  return null;
}
