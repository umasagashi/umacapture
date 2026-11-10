// File sync's part of deleting an account (account_deletion.mjs): its D1 rows, a chunk a call within
// what the day's sync row limit leaves to deletions, and every version and delete marker under its B2
// prefix, named by version. A delete naming no version only adds another marker, so the versions are
// listed (ListObjectVersions) and each is deleted by its version id.
//
// The rows go first and the bucket after them, once no row is left: while a row is left, a sync write
// cannot reach the account (it is being deleted), but the hourly run can still hide or show its name
// and add a marker under the prefix, which the bucket's step then deletes with the rest.

import { accountPrefix } from "./b2.mjs";
import * as limits from "./limits.mjs";
import { d1 } from "./sync.mjs";

/**
 * D1 rows that deleting one sync_objects row writes at most, as D1 counts them: the row and what the
 * usage triggers of migrations/0003_sync.sql change for it, the account's sync_accounts row and
 * sync_totals (measured with Miniflare's D1: 3 for a stored row in every state, 1 for a row not stored).
 */
export const SYNC_OBJECT_DELETE_ROWS = 3;

const deleting = "EXISTS (SELECT 1 FROM accounts WHERE id = ?1 AND deleting_since IS NOT NULL)";

/**
 * Removes a chunk of the sync rows of account `accountId`, being deleted, on UTC day `day` (one
 * batch): as many sync_objects rows as fit in ACCOUNT_DELETE_SYNC_ROWS rows written, in what the day
 * leaves of SYNC_DAILY_ROWS and of the deletions' share SYNC_DAILY_DELETE_ROWS, then, once none is
 * left, the sync_accounts row. Each row is counted as SYNC_OBJECT_DELETE_ROWS on both of the day's
 * counters (rows_written and delete_rows), in the batch that deletes it, so two deletions at once
 * cannot both take what is left. It removes none once what the day leaves of SYNC_DAILY_READ_ROWS is
 * less than ACCOUNT_DELETE_SYNC_READ_ROWS. Returns `{removed, read}`: the rows it removed, and the
 * rows its statements read (`meta.rows_read`, the triggers' included), for `chargeDeletionReads`.
 * Throws Unavailable.
 */
export async function deleteSyncRowChunk(db, accountId, day) {
  // D1 binds a JavaScript number as REAL, which LIMIT refuses: the room is cast back to whole rows.
  const room = `SELECT CASE WHEN ?7 - rows_read < ?8 THEN 0
    ELSE CAST(max(0, min(?3, ?4 - rows_written, ?5 - delete_rows)) / ?6 AS INTEGER) END FROM sync_daily WHERE day = ?2`;
  const charge = `UPDATE sync_daily SET rows_written = rows_written + changes() * ?3, delete_rows = delete_rows + changes() * ?3
     WHERE day = ?2`;
  const args = [accountId, day, limits.ACCOUNT_DELETE_SYNC_ROWS, limits.SYNC_DAILY_ROWS, limits.SYNC_DAILY_DELETE_ROWS];
  const reads = [limits.SYNC_DAILY_READ_ROWS, limits.ACCOUNT_DELETE_SYNC_READ_ROWS];
  const results = await d1(() =>
    db.batch([
      db.prepare("INSERT INTO sync_daily (day) VALUES (?1) ON CONFLICT (day) DO NOTHING").bind(day),
      // The chunk is chosen in the primary key's order, so the subquery reads the account's rows from
      // the front of the index and stops at the limit: rows the calls before removed are not there.
      db
        .prepare(
          `DELETE FROM sync_objects WHERE account_id = ?1 AND ${deleting} AND name IN (
             SELECT name FROM sync_objects WHERE account_id = ?1 ORDER BY name LIMIT (${room}))`,
        )
        .bind(...args, SYNC_OBJECT_DELETE_ROWS, ...reads),
      db.prepare(charge).bind(accountId, day, SYNC_OBJECT_DELETE_ROWS),
      db
        .prepare(
          `DELETE FROM sync_accounts WHERE account_id = ?1 AND ${deleting}
             AND NOT EXISTS (SELECT 1 FROM sync_objects WHERE account_id = ?1) AND (${room}) > 0`,
        )
        .bind(...args, 1, ...reads),
      db.prepare(charge).bind(accountId, day, 1),
    ]),
  );
  return {
    removed: results[1].meta.changes + results[3].meta.changes,
    read: results.reduce((sum, r) => sum + (r.meta?.rows_read ?? 0), 0),
  };
}

/**
 * Adds `read` rows, what a deletion's statements on the sync rows read, to the sync rows read on UTC
 * day `day`, over every account as the rows it writes are (the account's own counters go with its
 * sync_accounts row). After the statements, since D1 tells how many rows they read only once they ran:
 * a deletion may pass the day's limit by what one call reads. Throws Unavailable.
 */
export async function chargeDeletionReads(db, day, read) {
  await d1(() => db.prepare("UPDATE sync_daily SET rows_read = rows_read + ?2 WHERE day = ?1").bind(day, read).run());
}

/**
 * The sync rows account `accountId` still has, counted up to ACCOUNT_DELETE_SYNC_ROWS: its
 * sync_objects rows and its sync_accounts row, and the rows the count read: `{remaining, read}`.
 * Throws Unavailable.
 */
export async function countSyncRows(db, accountId) {
  const result = await d1(() =>
    db
      .prepare(
        `SELECT (SELECT count(*) FROM (SELECT 1 FROM sync_objects WHERE account_id = ?1 LIMIT ?2))
              + EXISTS (SELECT 1 FROM sync_accounts WHERE account_id = ?1) AS n`,
      )
      .bind(accountId, limits.ACCOUNT_DELETE_SYNC_ROWS)
      .all(),
  );
  return { remaining: Math.min(result.results[0].n, limits.ACCOUNT_DELETE_SYNC_ROWS), read: result.meta.rows_read ?? 0 };
}

/** B2 requests `deleteSyncVersions` sends at most for `pages` pages. */
export const deleteVersionsRequests = (pages) => 2 * pages + 1;

/**
 * Deletes the versions and delete markers under the B2 prefix of account `accountId`'s synced objects
 * (`deleteVersionsUnder`).
 */
export const deleteSyncVersions = (bucket, accountId, pages) => deleteVersionsUnder(bucket, accountPrefix(accountId), pages);

/**
 * Deletes the versions and delete markers under B2 key prefix `prefix`, by version, at most `pages`
 * pages of ListObjectVersions and one DeleteObjects for each, then one more listing, all through
 * `bucket` (`deleteVersionsRequests(pages)` B2 requests at most). Every page is listed from the start of
 * the prefix: what the page before deleted is no longer there. Returns `{removed, remaining}`: the
 * versions deleted, and those B2 still lists, up to one page (0 once a page came back whole and every
 * version on it was deleted). With `pages` 0 it only counts. Throws StorageFailed.
 */
export async function deleteVersionsUnder(bucket, prefix, pages) {
  let removed = 0;
  for (let page = 0; page < pages; page++) {
    const { entries, next } = await bucket.listVersions(prefix);
    if (entries.length === 0) return { removed, remaining: 0 };
    const errors = await bucket.deleteObjects(entries.map((e) => ({ key: e.key, versionId: e.versionId })));
    removed += entries.length - errors.length;
    if (next === null && errors.length === 0) return { removed, remaining: 0 };
  }
  const { entries } = await bucket.listVersions(prefix);
  return { removed, remaining: entries.length };
}
