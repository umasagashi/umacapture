// DELETE /api/me: deleting an account, which no request can finish at once (D1 bounds the queries
// of one invocation). Two columns hold its state: `accounts.deleting_since` (the account is being
// deleted, so every write to it is refused) and `sessions.scope = 'delete'` (the one session allowed
// to continue). The app repeats the call with that session until it answers 204.

import { AccountDeleting, clock, json, noContent, SessionRequired } from "./api.mjs";
import { requireSession } from "./auth.mjs";
import * as limits from "./limits.mjs";
import { beginAccountDeletion, countShares, deleteShareChunk, finishAccountDeletion } from "./store.mjs";

/**
 * What a deletion removes before the account itself, one kind per row: `remove` takes one chunk of
 * it away, `remaining` counts what is left. Each call removes one chunk of every kind, and the
 * `remaining` of a 200 has one key per kind.
 */
const KINDS = [
  {
    key: "shares",
    remove: (db, accountId, tokenHash) => deleteShareChunk(db, accountId, tokenHash, limits.ACCOUNT_DELETE_CHUNK),
    remaining: (db, accountId) => countShares(db, accountId),
  },
];

/**
 * DELETE /api/me. The first call, from a full session, marks the account as being deleted, removes
 * its other sessions and turns this one into the deletion-only session; that call and every later
 * one remove a chunk of each kind and answer 200 `{remaining}` while anything is left. The call that
 * finds nothing left removes the account's trainers, identities, sessions and logins and the
 * account itself, and answers 204.
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
  const remaining = {};
  for (const kind of KINDS) {
    await kind.remove(db, session.accountId, session.tokenHash);
    remaining[kind.key] = await kind.remaining(db, session.accountId);
  }
  if (Object.values(remaining).some((n) => n > 0)) return json(200, { remaining });
  await finishAccountDeletion(db, session.accountId);
  return noContent();
}
