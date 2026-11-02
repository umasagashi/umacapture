// DELETE /api/me: deleting an account, which no request can finish at once (D1 bounds the queries
// of one invocation, B2 the requests, and the day's sync row limit the sync rows). Two columns hold
// its state: `accounts.deleting_since` (the account is being deleted, so every write to it is
// refused) and `sessions.scope = 'delete'` (the one session allowed to continue). The app repeats
// the call with that session until it answers 204. The hourly run continues every account being
// deleted too (`continueAccountDeletions`), so a deletion the day's sync rows stopped finishes
// without the app.

import { AccountDeleting, clock, fail, json, noContent, SessionRequired, untilTomorrow } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { Bucket, StorageFailed } from "./b2.mjs";
import { accountsBeingDeleted, beginAccountDeletion, countShares, deleteShareChunk, finishAccountDeletion } from "./store.mjs";
import {
  chargeDeletionReads,
  countSyncRows,
  deleteSyncRowChunk,
  deleteSyncVersions,
  deleteVersionsRequests,
} from "./sync_deletion.mjs";

/**
 * What a deletion removes before the account itself, one kind per row, in order: `step` takes one
 * chunk of it away and answers `{removed, remaining}`, given what the kinds before it left. The
 * `remaining` of a 200 has one key per kind.
 */
const KINDS = [
  {
    // The rows reference the account (D1 enforces it), so they go before it. Bounded by the day's
    // sync rows written and read (sync_deletion.mjs), and what it reads is counted with them.
    key: "sync_rows",
    step: async ({ db, accountId, at }) => {
      const chunk = await deleteSyncRowChunk(db, accountId, at.day);
      const count = await countSyncRows(db, accountId);
      await chargeDeletionReads(db, at.day, chunk.read + count.read);
      return { removed: chunk.removed, remaining: count.remaining };
    },
  },
  {
    // After the rows, so that nothing adds a marker under the prefix once it is empty: while a row is
    // left, this only counts what B2 lists.
    key: "sync_versions",
    step: ({ bucket, accountId }, left) =>
      deleteSyncVersions(bucket, accountId, left.sync_rows > 0 ? 0 : limits.ACCOUNT_DELETE_B2_PAGES),
  },
  {
    key: "shares",
    step: async ({ db, accountId }) => {
      const removed = await deleteShareChunk(db, accountId, limits.ACCOUNT_DELETE_CHUNK);
      return { removed, remaining: await countShares(db, accountId) };
    },
  },
];

/** B2 requests one step (`stepAccountDeletion`) sends at most. */
const STEP_B2_REQUESTS = deleteVersionsRequests(limits.ACCOUNT_DELETE_B2_PAGES);

/**
 * One step of the deletion of account `accountId`, already marked as being deleted, at clock `at`
 * (`clock`), its B2 requests sent through `bucket`: one chunk of each kind, and, once nothing is left,
 * the account's trainers, identities, sessions and logins and the account itself. Returns `{removed,
 * remaining, done}`: what the kinds removed in all, what each has left, and whether the account is
 * gone. What a kind removed stays removed when a later one throws. Throws StorageFailed, Unavailable.
 */
async function stepAccountDeletion(db, bucket, at, accountId) {
  const context = { db, bucket, at, accountId };
  const remaining = {};
  let removed = 0;
  for (const kind of KINDS) {
    const outcome = await kind.step(context, remaining);
    removed += outcome.removed;
    remaining[kind.key] = outcome.remaining;
  }
  const done = Object.values(remaining).every((n) => n === 0);
  if (done) await finishAccountDeletion(db, accountId);
  return { removed, remaining, done };
}

/**
 * DELETE /api/me. The first call, from a full session, marks the account as being deleted, removes
 * its other sessions and turns this one into the deletion-only session; that call and every later
 * one take one step and answer 200 `{remaining}` while anything is left, or 429 sync_paused_today
 * `{remaining}` with a Retry-After to the next UTC day when the step removed nothing: what is left is
 * sync rows the day's limits (rows written, rows read) have no room for. The call whose step finds
 * nothing left answers 204.
 */
export async function deleteAccount(request, env, now) {
  const at = clock(now);
  const session = await requireSession(request, env, at.now, { deletion: true });
  const db = env.DB;
  if (session.scope === "full") {
    const outcome = await beginAccountDeletion(
      db,
      session.accountId,
      session.tokenHash,
      at.now,
      at.now + limits.ACCOUNT_DELETE_SESSION_TTL_SECONDS,
    );
    if (outcome === "gone") throw new SessionRequired();
    // Another session began it first: only that one continues.
    if (outcome === "deleting") throw new AccountDeleting();
  }
  let step;
  try {
    step = await stepAccountDeletion(db, new Bucket(env, now), at, session.accountId);
  } catch (error) {
    // What the kinds before removed stays removed; the app's next call goes on from there.
    if (error instanceof StorageFailed) return fail(502, "storage_unavailable");
    throw error;
  }
  if (step.done) return noContent();
  const { remaining } = step;
  if (step.removed === 0) return fail(429, "sync_paused_today", { remaining }, { "Retry-After": String(untilTomorrow(at)) });
  return json(200, { remaining });
}

/**
 * The hourly run's deletions at clock `at` (`clock`): up to ACCOUNT_DELETE_STEPS_PER_RUN steps over
 * the accounts being deleted, the longest deleted first, each account taken on until it is gone or a
 * step of it removes nothing (the day's sync rows have no room for it; the next run tries again), and
 * each step taken only while `bucket` has the B2 requests left for a whole one. What it does not reach
 * waits for the next run.
 */
export async function continueAccountDeletions(db, bucket, at) {
  let steps = limits.ACCOUNT_DELETE_STEPS_PER_RUN;
  const room = () => steps > 0 && bucket.sent + STEP_B2_REQUESTS <= limits.B2_REQUESTS_PER_INVOCATION;
  for (const accountId of await accountsBeingDeleted(db, steps)) {
    while (room()) {
      steps--;
      const step = await stepAccountDeletion(db, bucket, at, accountId);
      if (step.done || step.removed === 0) break;
    }
    if (!room()) return;
  }
}
