// DELETE /api/me: deleting an account, which no request can finish at once (D1 bounds the queries
// of one invocation, B2 the requests, and the day's sync row limit the sync rows). Two columns hold
// its state: `accounts.deleting_since` (the account is being deleted, so every write to it is
// refused) and `sessions.scope = 'delete'` (the one session allowed to continue). The app repeats
// the call with that session until it answers 204.

import { AccountDeleting, clock, fail, json, noContent, SessionRequired, untilTomorrow } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { StorageFailed } from "./b2.mjs";
import { beginAccountDeletion, countShares, deleteShareChunk, finishAccountDeletion } from "./store.mjs";
import { chargeDeletionReads, countSyncRows, deleteSyncRowChunk, deleteSyncVersions } from "./sync_deletion.mjs";

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
    step: ({ env, now, accountId }, left) =>
      deleteSyncVersions(env, now, accountId, left.sync_rows > 0 ? 0 : limits.ACCOUNT_DELETE_B2_PAGES),
  },
  {
    key: "shares",
    step: async ({ db, accountId, tokenHash }) => {
      const removed = await deleteShareChunk(db, accountId, tokenHash, limits.ACCOUNT_DELETE_CHUNK);
      return { removed, remaining: await countShares(db, accountId) };
    },
  },
];

/**
 * DELETE /api/me. The first call, from a full session, marks the account as being deleted, removes
 * its other sessions and turns this one into the deletion-only session; that call and every later
 * one take one step of each kind and answer 200 `{remaining}` while anything is left, or 429
 * sync_paused_today `{remaining}` with a Retry-After to the next UTC day when no step removed
 * anything: what is left is sync rows the day's limits (rows written, rows read) have no room for. The call that finds nothing
 * left removes the account's trainers, identities, sessions and logins and the account itself, and
 * answers 204.
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
  const context = { env, now, db, at, accountId: session.accountId, tokenHash: session.tokenHash };
  const remaining = {};
  let removed = 0;
  try {
    for (const kind of KINDS) {
      const outcome = await kind.step(context, remaining);
      removed += outcome.removed;
      remaining[kind.key] = outcome.remaining;
    }
  } catch (error) {
    // What the steps before removed stays removed; the app's next call goes on from there.
    if (error instanceof StorageFailed) return fail(502, "storage_unavailable");
    throw error;
  }
  if (Object.values(remaining).every((n) => n === 0)) {
    await finishAccountDeletion(db, session.accountId);
    return noContent();
  }
  if (removed === 0) return fail(429, "sync_paused_today", { remaining }, { "Retry-After": String(untilTomorrow(at)) });
  return json(200, { remaining });
}
